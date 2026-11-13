import Foundation
import AppKit
import AVFoundation
import CoreText
import PCBrowserCore

struct MovieExportOptions: Sendable {
    var frames: Range<Int>
    var projection = ProjectionSettings()
    var subtitles = false
    var audio = true
    var datum = GPSDatum.deviceTokyo
    var width = 1920
}
enum MediaExport {
    private static func failure(_ stage:String,_ error:Error?)->BrowserError {
        guard let error else{return .io(stage+": 詳細不明")};let e=error as NSError
        return .io(stage+": \(e.localizedDescription) [\(e.domain) \(e.code)] \(e.userInfo)")
    }
    static func still(_ image:CGImage,to url:URL,jpeg:Bool=false) throws {
        let rep=NSBitmapImageRep(cgImage:image)
        guard let d=rep.representation(using:jpeg ? .jpeg:.png,properties:jpeg ? [.compressionFactor:0.95]:[:]) else {throw BrowserError.io("静止画を作成できません")}
        try d.write(to:url,options:.withoutOverwriting)
    }
    static func checkNew(_ url:URL) throws {
        guard !FileManager.default.fileExists(atPath:url.path) else {throw BrowserError.invalid("既存ファイルには上書きしません。新しい出力名を選んでください")}
    }
    static func movie(source:any ByteSource,recording:Recording,options:MovieExportOptions,to output:URL,
                      cancelled:@escaping @Sendable ()->Bool={false},progress:@escaping @Sendable (Double)->Void={_ in}) async throws {
        try checkNew(output)
        let range=options.frames
        guard range.lowerBound>=0,range.lowerBound<range.upperBound,range.upperBound<=recording.packets.count else {throw BrowserError.invalid("動画の出力範囲が不正です")}
        guard let first=stride(from:range.lowerBound,through:0,by:-1).first(where:{recording.packets[$0].isIntra}) else {throw BrowserError.unsupported("出力範囲の前にIフレームがありません")}
        let fm=FileManager.default,folder=fm.temporaryDirectory.appendingPathComponent("pcbrowser-export-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:folder,withIntermediateDirectories:false);defer{try? fm.removeItem(at:folder)}
        let video=folder.appendingPathComponent("video.mp4"),staging=output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.mp4")
        var committed=false;defer{if !committed {try? fm.removeItem(at:staging)}}
        let decoder=NativeVideoDecoder(),projection=try NativeProjection(),timeline=RecordingTimeline(packets:recording.packets)
        let base=timeline.starts[range.lowerBound]
        var writer:AVAssetWriter?,input:AVAssetWriterInput?,adaptor:AVAssetWriterInputPixelBufferAdaptor?
        var lastPresentationTime=CMTime.invalid
        for i in first..<range.upperBound {
            if cancelled() || Task.isCancelled {writer?.cancelWriting();throw BrowserError.io("動画変換をキャンセルしました")}
            let p=recording.packets[i],raw=try decoder.decode(source.read(at:p.payloadOffset,count:p.videoBytes),ordinal:i,fps:max(1,Int(timeline.nominalFPS)))
            if i<range.lowerBound {continue}
            let image=try projection.render(raw,settings:options.projection,width:options.width)
            if writer==nil {
                let w=try AVAssetWriter(outputURL:video,fileType:.mp4)
                let config:[String:Any]=[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:image.width,AVVideoHeightKey:image.height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:8_000_000,AVVideoMaxKeyFrameIntervalKey:60]]
                let v=AVAssetWriterInput(mediaType:.video,outputSettings:config);v.expectsMediaDataInRealTime=false
                guard w.canAdd(v) else {throw BrowserError.unsupported("H.264の動画出力を作成できません")};w.add(v)
                let a=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:v,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:image.width,kCVPixelBufferHeightKey as String:image.height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
                guard w.startWriting() else {throw failure("動画開始",w.error)};w.startSession(atSourceTime:.zero);writer=w;input=v;adaptor=a
            }
            guard let w=writer,let v=input,let a=adaptor else {throw BrowserError.io("動画出力の初期化に失敗しました")}
            while !v.isReadyForMoreMediaData {
                if cancelled() || Task.isCancelled {w.cancelWriting();throw BrowserError.io("動画変換をキャンセルしました")}
                guard w.status == .writing else {throw w.error ?? BrowserError.io("動画の書き込みが停止しました")}
                try await Task.sleep(nanoseconds:2_000_000)
            }
            var pixel:CVPixelBuffer?
            let attributes:[String:Any]=[kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
            let rc=CVPixelBufferCreate(kCFAllocatorDefault,image.width,image.height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&pixel)
            guard rc==kCVReturnSuccess,let pixel else {throw BrowserError.io("動画フレームのメモリーを確保できません（CV \(rc)、writer \(w.status.rawValue): \(w.error?.localizedDescription ?? "none")）")}
            CVPixelBufferLockBaseAddress(pixel,[])
            let context=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue)
            guard let context else {CVPixelBufferUnlockBaseAddress(pixel,[]);throw BrowserError.io("動画フレームを描画できません")}
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            if options.subtitles {
                var text=p.cardTime
                if let speed=p.telemetry.speedKMH {text+=String(format:"  %.1f km/h",speed)}
                if let c=p.telemetry.coordinate(datum:options.datum) {text+=String(format:"  %.6f, %.6f",c.latitude,c.longitude)}
                let font=CTFontCreateWithName("Menlo" as CFString,max(14,CGFloat(image.width)/65),nil)
                let attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)]
                context.setFillColor(CGColor(gray:0,alpha:0.65));context.fill(CGRect(x:0,y:0,width:image.width,height:52))
                context.textPosition=CGPoint(x:16,y:18);CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attrs)),context)
            }
            CVPixelBufferUnlockBaseAddress(pixel,[])
            let pts=CMTime(seconds:max(0,timeline.starts[i]-base),preferredTimescale:60000)
            guard !lastPresentationTime.isValid || CMTimeCompare(pts,lastPresentationTime)>0 else {
                w.cancelWriting()
                throw BrowserError.invalid("動画の時刻が重複しています（フレーム \(i)）。出力を中止しました")
            }
            guard a.append(pixel,withPresentationTime:pts) else {throw failure("動画フレーム追加 \(i) / PTS \(pts.seconds)",w.error)}
            lastPresentationTime=pts
            progress(Double(i-range.lowerBound+1)/Double(range.count)*0.8)
        }
        guard let writer,let input else {throw BrowserError.io("出力するフレームがありません")}
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {throw failure("動画確定",writer.error)}
        var audioClip:AudioClip?
        if options.audio,recording.packets.contains(where:{$0.auxiliaryBytes>0}) {
            let format=try PCMFormat.recordFormat(source:source,recording:recording)
            audioClip=try AudioClip.load(source:source,packets:recording.packets,format:format,cancelled:cancelled)
        }
        if let clip=audioClip,base<clip.duration {
            let duration=min(clip.duration-base,timeline.starts[range.upperBound-1]-base+1/timeline.nominalFPS)
            let wav=folder.appendingPathComponent("audio.wav");try clip.wav(range:base..<(base+duration)).write(to:wav,options:.withoutOverwriting)
            let videoAsset=AVURLAsset(url:video),audioAsset=AVURLAsset(url:wav),composition=AVMutableComposition()
            guard let v=try await videoAsset.loadTracks(withMediaType:.video).first,
                  let a=try await audioAsset.loadTracks(withMediaType:.audio).first,
                  let cv=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid),
                  let ca=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else {throw BrowserError.io("動画と音声のトラックを読み取れません")}
            let vd=try await videoAsset.load(.duration)
            try cv.insertTimeRange(CMTimeRange(start:.zero,duration:vd),of:v,at:.zero)
            try ca.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:min(duration,vd.seconds),preferredTimescale:60000)),of:a,at:.zero)
            guard let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality) else {throw BrowserError.io("音声付きMP4を作成できません")}
            export.outputURL=staging;export.outputFileType = .mp4;export.shouldOptimizeForNetworkUse=true
            let observer=Task { while !Task.isCancelled {if cancelled(){export.cancelExport();return};progress(0.8+Double(export.progress)*0.2);try? await Task.sleep(nanoseconds:100_000_000)} }
            await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in export.exportAsynchronously {c.resume()} }
            observer.cancel()
            guard export.status == .completed else {throw failure("音声付きMP4確定",export.error)}
        } else {try fm.moveItem(at:video,to:staging)}
        if cancelled() {throw BrowserError.io("動画変換をキャンセルしました")}
        try fm.moveItem(at:staging,to:output);committed=true;progress(1)
    }
}
