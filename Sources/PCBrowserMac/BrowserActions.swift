import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PCBrowserCore

extension BrowserModel {
    func destination(_ name:String,extension ext:String)->URL? {
        let p=NSSavePanel();p.nameFieldStringValue=name+"."+ext;p.title="新しいファイルへ書き出し";p.canCreateDirectories=true
        if p.runModal() == .OK,let u=p.url {
            if FileManager.default.fileExists(atPath:u.path){errorMessage="既存ファイルには上書きしません。新しい出力名を選んでください";return nil}
            return u
        };return nil
    }
    func exportStill(jpeg:Bool=false) {
        pause();guard let image=displayedFrame,let u=destination("PCBrowser-\(frameIndex+1)",extension:jpeg ? "jpg":"png") else{return}
        do{try MediaExport.still(image,to:u,jpeg:jpeg);status="静止画を書き出しました"}catch{errorMessage=error.localizedDescription}
    }
    func exportLog(_ type:String) {
        let records=selectedRecordings;guard !records.isEmpty,let u=destination("PCBrowser-route",extension:type) else{return};let datum=datum
        performExport(type.uppercased()+"書き出し"){flag,progress in
            if flag.cancelled{throw BrowserError.io("キャンセルしました")}
            let text:String
            switch type {case "kml":text=TrackExport.kml(records,datum:datum);case "gpx":text=TrackExport.gpx(records,datum:datum);default:text=TrackExport.csv(records,datum:datum)}
            try Data(text.utf8).write(to:u,options:.withoutOverwriting);progress(1)
        }
    }
    func exportAudio() {
        guard let source,let r=recording,let u=destination("PCBrowser-audio",extension:"wav") else{return}
        let range=exportFrames,timeline=timeline
        performExport("WAV書き出し"){_,progress in
            let f=try PCMFormat.recordFormat(source:source,recording:r),clip=try AudioClip.load(source:source,packets:r.packets,format:f)
            let begin=min(clip.duration,timeline.starts[range.lowerBound]),end=min(clip.duration,timeline.starts[range.upperBound-1]+1/timeline.nominalFPS)
            guard begin<end else{throw BrowserError.invalid("選択範囲に音声がありません")}
            try clip.wav(range:begin..<end).write(to:u,options:.withoutOverwriting);progress(1)
        }
    }
    func exportMovie() {
        guard let source,let r=recording,let u=destination("PCBrowser-video",extension:"mp4") else{return}
        var options=MovieExportOptions(frames:exportFrames);options.projection=projection;options.subtitles=exportSubtitles;options.datum=datum
        let captured=options
        performExport("音声付きMP4書き出し"){flag,progress in try await MediaExport.movie(source:source,recording:r,options:captured,to:u,cancelled:{flag.cancelled},progress:progress)}
    }
    func backup() {
        guard let source,let index,!selectedRecordings.isEmpty,let u=destination("PCBrowser-selected",extension:"pcbbackup") else{return}
        let records=selectedRecordings,name=sourceName
        performExport("選択録画のバックアップ"){flag,progress in try ArchiveWriter.write(source:source,index:index,recordings:records,name:name,to:u,cancelled:{flag.cancelled},progress:progress)}
    }
    func exportSequence() {
        guard let source,let r=recording else{return};let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.title="静止画連続出力の保存先"
        guard panel.runModal() == .OK,let parent=panel.url else{return}
        let range=exportFrames,settings=projection,out=parent.appendingPathComponent("PCBrowser-frames-\(UUID().uuidString.prefix(8))",isDirectory:true)
        performExport("PNG連続出力"){flag,progress in
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false)
            guard let first=stride(from:range.lowerBound,through:0,by:-1).first(where:{r.packets[$0].isIntra}) else{throw BrowserError.unsupported("Iフレームがありません")}
            let decoder=NativeVideoDecoder(),projector=try NativeProjection()
            for i in first..<range.upperBound {
                if flag.cancelled{throw BrowserError.io("キャンセルしました。出力済みの画像は保存先に残っています")}
                let p=r.packets[i],raw=try decoder.decode(source.read(at:p.payloadOffset,count:p.videoBytes),ordinal:i,fps:30)
                if i>=range.lowerBound {try MediaExport.still(projector.render(raw,settings:settings,width:2560),to:out.appendingPathComponent(String(format:"frame-%08d.png",i)));progress(Double(i-range.lowerBound+1)/Double(range.count))}
            }
        }
    }
    func saveCalibration() {
        guard let u=destination("PCBrowser-view-preset",extension:"json") else{return}
        do{let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(projection.clamped).write(to:u,options:.withoutOverwriting)}catch{errorMessage=error.localizedDescription}
    }
    func loadCalibration() {
        let p=NSOpenPanel();p.allowedContentTypes=[.json];if p.runModal() == .OK,let u=p.url {do {let d=try Data(contentsOf:u);guard d.count<65536 else{throw BrowserError.invalid("設定ファイルが大きすぎます")};projection=try JSONDecoder().decode(ProjectionSettings.self,from:d).clamped}catch{errorMessage=error.localizedDescription}}
    }
    func detachedPreview() {
        guard image != nil else{return}
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:580),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        w.title="PC Browser Mac — 別ウインドウ";w.isReleasedWhenClosed=false;w.contentView=NSHostingView(rootView:DetachedPreview(model:self));w.center();w.makeKeyAndOrderFront(nil)
        DetachedWindows.windows.append(w)
    }
    func printFrame() {
        pause();guard let image else{return}
        let view=NSImageView(frame:NSRect(x:0,y:0,width:760,height:420));view.image=image;view.imageScaling = .scaleProportionallyUpOrDown
        let operation=NSPrintOperation(view:view);operation.showsPrintPanel=true;operation.showsProgressPanel=true;operation.run()
    }
    func printContactSheet() {
        pause();guard let source,let r=recording else{return};let range=exportFrames,settings=projection
        guard !range.isEmpty else{return}
        Task {
            do {
                let frames=try await Task.detached {() async throws ->[CGImage] in
                    let decoder=FrameRenderer(source:source,packets:r.packets),projection=try NativeProjection()
                    // A separate renderer is used so printing never changes the playback decoder.
                    var frames:[CGImage]=[]
                    for i in 0..<4 {
                        let position=range.lowerBound+(range.count-1)*i/3
                        let raw=try await decoder.render(position)
                        frames.append(try projection.render(raw,settings:settings,width:1280))
                    };return frames
                }.value
                let view=ContactSheetView(images:frames,title:r.startTime+" / CH \(r.channel)")
                let operation=NSPrintOperation(view:view);operation.showsPrintPanel=true;operation.run()
            }catch{errorMessage=error.localizedDescription}
        }
    }
    func importNMEA() {
        let p=NSOpenPanel();p.title="NMEAログを開く（外部ログ・映像との自動同期なし）"
        if p.runModal() == .OK,let u=p.url {do{let d=try Data(contentsOf:u);guard d.count<=32*1024*1024 else{throw BrowserError.invalid("ログが32 MiBを超えています")};let log=NMEAParser.parse(INIParser.decode(d));route=log.points.map{GeoCoordinate(latitude:$0.latitude,longitude:$0.longitude)};status="外部NMEA: \(log.points.count)点 / 不正チェックサム\(log.rejected)件。映像とは自動同期しません"}catch{errorMessage=error.localizedDescription}}
    }
}
@MainActor enum DetachedWindows {static var windows:[NSWindow]=[]}
struct DetachedPreview:View {
    @ObservedObject var model:BrowserModel
    var body:some View {ZStack {Color.black;if let image=model.image {Image(nsImage:image).resizable().scaledToFit()}}.gesture(DragGesture().onChanged{v in model.projection.yaw=max(-180,min(180,Double(v.translation.width)/3))})}
}

final class ContactSheetView:NSView {
    let images:[CGImage],title:String
    init(images:[CGImage],title:String){self.images=images;self.title=title;super.init(frame:NSRect(x:0,y:0,width:760,height:560))}
    required init?(coder:NSCoder){fatalError("init(coder:) is unavailable")}
    override var isFlipped:Bool{true}
    override func draw(_ dirtyRect:NSRect){
        NSColor.white.setFill();bounds.fill()
        (title as NSString).draw(at:NSPoint(x:12,y:12),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.black])
        for (i,cg) in images.prefix(4).enumerated(){
            let cell=NSRect(x:12+CGFloat(i%2)*374,y:40+CGFloat(i/2)*254,width:362,height:242)
            let ratio=min(cell.width/CGFloat(cg.width),cell.height/CGFloat(cg.height))
            let size=NSSize(width:CGFloat(cg.width)*ratio,height:CGFloat(cg.height)*ratio)
            NSImage(cgImage:cg,size:size).draw(in:NSRect(x:cell.midX-size.width/2,y:cell.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
    }
}
