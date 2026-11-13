import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PDFKit
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
        let summaries=selectedRecordings;guard let source,!summaries.isEmpty,let u=destination("PCBrowser-route",extension:type) else{return};let datum=datum,style=trackStyle,launchEarth=openEarthAfterExport
        performExport(type.uppercased()+"書き出し"){flag,progress in
            if flag.cancelled{throw BrowserError.io("キャンセルしました")}
            var records:[Recording]=[]
            for (i,r) in summaries.enumerated(){records.append(try CatalogScanner.loadRecording(r,source:source,cancelled:{flag.cancelled}));progress(Double(i+1)/Double(summaries.count)*0.8)}
            let text:String
            switch type {case "kml":text=TrackExport.kml(records,datum:datum,style:style);case "gpx":text=TrackExport.gpx(records,datum:datum);default:text=TrackExport.csv(records,datum:datum)}
            try Data(text.utf8).write(to:u,options:.withoutOverwriting);progress(1)
            if type=="kml",launchEarth {await MainActor.run{self.openKMLInEarth(u)}}
        }
    }
    func exportAudio() {
        guard let source,let r=recording,let u=destination("PCBrowser-audio",extension:"wav") else{return}
        let range=exportFrames,timeline=timeline
        performExport("WAV書き出し"){flag,progress in
            let f=try PCMFormat.recordFormat(source:source,recording:r),clip=try AudioClip.load(source:source,packets:r.packets,format:f,cancelled:{flag.cancelled})
            let begin=min(clip.duration,timeline.starts[range.lowerBound]),end=min(clip.duration,timeline.starts[range.upperBound-1]+1/timeline.nominalFPS)
            guard begin<end else{throw BrowserError.invalid("選択範囲に音声がありません")}
            try clip.wav(range:begin..<end).write(to:u,options:.withoutOverwriting);progress(1)
        }
    }
    func exportMovie(avi: Bool = false) {
        guard let source,let r=recording,let u=destination("PCBrowser-video",extension:avi ? "avi":"mp4") else{return}
        if useExternalGPS && gpsSynchronization == nil {errorMessage="外部GPSのタイムゾーンとログを指定してください。元GPSに戻す場合は外部ログの使用をオフにしてください";return}
        var options=MovieExportOptions(frames:exportFrames);options.projection=projection;options.subtitles=exportSubtitles;options.datum=datum
        options.subtitleFields=subtitleFields;options.externalGPS=gpsSynchronization
        let captured=options
        performExport(avi ? "音声付きMotion JPEG AVI書き出し":"音声付きMP4書き出し"){flag,progress in
            if avi {_ = try await MediaExport.avi(source:source,recording:r,options:captured,to:u,cancelled:{flag.cancelled},progress:progress)}
            else {try await MediaExport.movie(source:source,recording:r,options:captured,to:u,cancelled:{flag.cancelled},progress:progress)}
        }
    }
    func backup() {
        guard let source,let index,!selectedRecordings.isEmpty,let u=destination("PCBrowser-selected",extension:"pcbbackup") else{return}
        let records=selectedRecordings,name=sourceName
        performExport("選択録画のバックアップ"){flag,progress in
            var loaded:[Recording]=[]
            for (i,r) in records.enumerated(){loaded.append(try CatalogScanner.loadRecording(r,source:source,cancelled:{flag.cancelled}));progress(Double(i+1)/Double(records.count)*0.1)}
            try ArchiveWriter.write(source:source,index:index,recordings:loaded,name:name,to:u,cancelled:{flag.cancelled},progress:{progress(0.1+$0*0.9)})
        }
    }
    func exportSequence() {
        guard let source,let r=recording else{return};let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.title="静止画連続出力の保存先"
        guard panel.runModal() == .OK,let parent=panel.url else{return}
        do {
            let indices=try sampledExportFrames(),settings=projection,out=parent.appendingPathComponent("PCBrowser-frames-\(UUID().uuidString.prefix(8))",isDirectory:true)
            guard !indices.isEmpty else{return}
            if indices.count>1000 {
                let alert=NSAlert();alert.messageText="\(indices.count)枚のPNGを書き出します";alert.informativeText="大量の空き容量が必要です。間隔は設定画面で変更できます。";alert.addButton(withTitle:"書き出す");alert.addButton(withTitle:"キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else{return}
            }
            performExport("PNG連続出力"){flag,progress in
                _ = try await FrameExport.sequence(source:source,recording:r,indices:indices,settings:settings,to:out,cancelled:{flag.cancelled},progress:progress)
            }
        } catch {errorMessage=error.localizedDescription}
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
        pause();guard let source,let r=recording else{return}
        do {
            let indices=try sampledExportFrames(),settings=projection,layout=printFramesPerPage
            guard !indices.isEmpty else{return}
            let pages=(indices.count+layout-1)/layout
            let alert=NSAlert();alert.messageText="\(indices.count)枚 / \(pages)ページを準備します";alert.informativeText="設定した間隔でIN / OUT範囲から抽出します。続いてプリンターと保存先を選べます。";alert.addButton(withTitle:"印刷を準備");alert.addButton(withTitle:"キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else{return}
            let pdf=FileManager.default.temporaryDirectory.appendingPathComponent("PCBrowser-print-\(UUID().uuidString).pdf")
            performExport("ページ印刷の準備"){flag,progress in
                defer{try? FileManager.default.removeItem(at:pdf)}
                _ = try await FrameExport.printPDF(source:source,recording:r,indices:indices,framesPerPage:layout,settings:settings,to:pdf,cancelled:{flag.cancelled},progress:progress)
                try await MainActor.run {
                    guard let document=PDFDocument(url:pdf),let operation=document.printOperation(for:NSPrintInfo.shared,scalingMode:.pageScaleToFit,autoRotate:true) else{throw BrowserError.io("印刷ジョブを作成できません")}
                    operation.showsPrintPanel=true;operation.showsProgressPanel=true;operation.run()
                }
            }
        }catch{errorMessage=error.localizedDescription}
    }
    func openKMLInEarth(_ url:URL, completion: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        let workspace=NSWorkspace.shared
        // The current signed Google Earth Pro uses an uppercase "Google".
        // Keep older bundle IDs without assuming LaunchServices is case-insensitive.
        let identifiers=["com.Google.GoogleEarthPro","com.google.GoogleEarthPro","com.google.GoogleEarthPlus","com.google.GoogleEarth"]
        guard url.isFileURL, url.pathExtension.lowercased()=="kml", FileManager.default.fileExists(atPath:url.path) else {
            let error=BrowserError.invalid("保存済みのKMLファイルを指定してください")
            errorMessage=error.localizedDescription;completion?(nil,error);return
        }
        guard let app=identifiers.compactMap({workspace.urlForApplication(withBundleIdentifier:$0)}).first else {
            let error=BrowserError.io("KMLは保存済みです。Google Earthが見つからないため自動起動しませんでした")
            errorMessage=error.localizedDescription;completion?(nil,error);return
        }
        workspace.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration()){application,error in
            Task{@MainActor [weak self] in
                if let error {self?.errorMessage="KMLは保存済みです。Google Earthの起動: "+error.localizedDescription}
                completion?(application,error)
            }
        }
    }
    func importNMEA() {
        let p=NSOpenPanel();p.title="外部NMEAログを開く（同期は明示設定後のみ）"
        guard p.runModal() == .OK,let u=p.url else{return}
        do {
            let size=(try FileManager.default.attributesOfItem(atPath:u.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard size<=32*1024*1024 else{throw BrowserError.invalid("ログが32 MiBを超えています")}
            let d=try Data(contentsOf:u);guard d.count<=32*1024*1024 else{throw BrowserError.invalid("ログが32 MiBを超えています")}
            let log=NMEAParser.parse(INIParser.decode(d)),track=ExternalGPSTrack(points:log.points)
            useExternalGPS=false;externalGPSTrack=track
            externalGPSStatus="\(u.lastPathComponent): \(log.points.count)点（UTC付き \(track.points.count)点）/ 不正チェックサム\(log.rejected)件"
            status=externalGPSStatus+"。タイムゾーンを指定し外部ログを有効にすると同期します"
        }catch{errorMessage=error.localizedDescription}
    }
}
@MainActor enum DetachedWindows {static var windows:[NSWindow]=[]}
struct DetachedPreview:View {
    @ObservedObject var model:BrowserModel
    var body:some View {ZStack {Color.black;if let image=model.image {Image(nsImage:image).resizable().scaledToFit()}}.gesture(DragGesture().onChanged{v in model.projection.yaw=max(-180,min(180,Double(v.translation.width)/3))})}
}

