import Foundation
import AppKit
import AVFoundation
import CoreText
import PCBrowserCore

struct MovieExportOptions: Sendable {
    var frames: Range<Int>
    var projection = ProjectionSettings()
    var subtitles = false
    var subtitleFields: SubtitleFields = .defaults
    var externalGPS: GPSLogSynchronization?
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
            drawSubtitles(context, width: image.width, packet: p, options: options)
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
    /// Shared overlay for H.264 and Motion JPEG. Raw inputs are never relabelled
    /// as brake/turn-signal bits until their model-specific mapping is verified.
    private static func drawSubtitles(_ context: CGContext, width: Int, packet: FramePacket, options: MovieExportOptions) {
        guard options.subtitles else { return }
        let lines = SubtitleText.lines(packet: packet, datum: options.datum, fields: options.subtitleFields, externalGPS: options.externalGPS)
        guard !lines.isEmpty else { return }
        let fontSize = max(14, CGFloat(width) / 65), lineHeight = fontSize * 1.5
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 0, alpha: 0.7)); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(lines.count) * lineHeight + 16))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        for (i, text) in lines.reversed().enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 12, y: 12 + CGFloat(i) * lineHeight)
            CTLineDraw(CTLineCreateTruncatedLine(line, max(1, CGFloat(width) - 24), .end, ellipsis) ?? line, context)
        }
    }
    private static func withSubtitles(_ image: CGImage, packet: FramePacket, options: MovieExportOptions) throws -> CGImage {
        guard options.subtitles else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw BrowserError.io("字幕用メモリーを確保できません") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        drawSubtitles(context, width: image.width, packet: packet, options: options)
        guard let result = context.makeImage() else { throw BrowserError.io("字幕を描画できません") }; return result
    }
    static func avi(source: any ByteSource, recording: Recording, options: MovieExportOptions, to output: URL,
                    segmentLimit: UInt64 = 1_000_000_000, cancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AVIWriteSummary {
        try checkNew(output)
        let timeline = RecordingTimeline(packets: recording.packets)
        let schedule = try ConstantRateSchedule(starts: timeline.starts, range: options.frames, framesPerSecond: timeline.nominalFPS)
        let renderer = FrameRenderer(source: source, packets: recording.packets), projection = try NativeProjection()
        var clip: AudioClip?
        if options.audio, recording.packets.contains(where: { $0.auxiliaryBytes > 0 }) {
            let format = try PCMFormat.recordFormat(source: source, recording: recording)
            clip = try AudioClip.load(source: source, packets: recording.packets, format: format, cancelled: cancelled)
        }
        var writer: MJPEGAVIWriter?, lastIndex = -1, encoded = Data()
        let base = timeline.starts[options.frames.lowerBound]
        for outputFrame in 0..<schedule.outputFrameCount {
            if cancelled() || Task.isCancelled { throw BrowserError.io("AVI変換をキャンセルしました") }
            let index = schedule.sourceIndex(for: outputFrame)
            if index != lastIndex {
                let raw = try await renderer.render(index)
                encoded = try autoreleasepool {
                    let projected = try projection.render(raw, settings: options.projection, width: options.width)
                    let image = try withSubtitles(projected, packet: recording.packets[index], options: options)
                    if writer == nil { writer = try MJPEGAVIWriter(output: output, width: image.width, height: image.height,
                                                                  framesPerSecond: schedule.framesPerSecond, expectedFrames: schedule.outputFrameCount,
                                                                  audioFormat: clip?.format, segmentLimit: segmentLimit) }
                    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw BrowserError.io("AVI用JPEGを作成できません") }
                    return data
                }
                lastIndex = index
            }
            var pcm = Data()
            if let clip {
                let rate = Double(clip.format.sampleRate), align = clip.format.channels * clip.format.bitsPerSample / 8
                let start = Int((base * rate).rounded()), lo = start + Int((Double(outputFrame) * rate / schedule.framesPerSecond).rounded())
                let hi = start + Int((Double(outputFrame + 1) * rate / schedule.framesPerSecond).rounded())
                let validEnd = min(clip.samples.count / align, Int(((base + schedule.duration) * rate).rounded()))
                let availableEnd = max(lo, min(hi, validEnd))
                if lo < availableEnd { pcm.append(clip.samples.subdata(in: (lo * align)..<(availableEnd * align))) }
                if availableEnd < hi { pcm.append(Data(repeating: clip.format.bitsPerSample == 8 ? 128 : 0, count: (hi - availableEnd) * align)) }
            }
            guard let writer else { throw BrowserError.io("AVIを初期化できません") }
            try writer.append(jpeg: encoded, pcm: pcm); progress(Double(outputFrame + 1) / Double(schedule.outputFrameCount))
        }
        if cancelled() || Task.isCancelled { throw BrowserError.io("AVI変換をキャンセルしました") }
        guard let writer else { throw BrowserError.io("AVIに出力する映像がありません") }
        return try writer.finish()
    }

}
