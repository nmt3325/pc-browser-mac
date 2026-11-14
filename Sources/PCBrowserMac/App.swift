import AppKit
import PDFKit
import SwiftUI
import PCBrowserCore

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model=BrowserModel()
    var window: NSWindow?
    var legacyMenu: LegacyMenuController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller=LegacyMenuController(model:model);legacyMenu=controller;NSApp.mainMenu=controller.buildMainMenu()
        model.onTitleChange={[weak self] in guard let self else{return};self.window?.title=self.model.windowTitle}
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:880),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title=model.windowTitle;w.minSize=NSSize(width:1080,height:760)
        w.contentView=NSHostingView(rootView:BrowserView(model:model));w.center();w.makeKeyAndOrderFront(nil);window=w
        NSApp.activate(ignoringOtherApps:true)
        let args=CommandLine.arguments
        if let path=InspectionCLI.value("--image",in:args) { model.open(URL(fileURLWithPath:path),limit:InspectionCLI.value("--scan-limit",in:args).flatMap(UInt64.init)) }
        if let report=InspectionCLI.value("--ui-check-report",in:args) {
            Task { await runUICheck(report:URL(fileURLWithPath:report),snapshot:InspectionCLI.value("--ui-snapshot",in:args)) }
        }
    }
    private func runUICheck(report:URL,snapshot:String?) async {
        var result:[String:Any] = ["scope":"GUI/audio/map/projection/view-operation smoke test on the supplied image (synthetic test pattern or real-media backup); not physical SD"]
        do {
            model.muted=true // Exercise the audio clock without playing private recordings aloud.
            for _ in 0..<200 {
                if model.image != nil && !model.scanning { break }
                if let error=model.errorMessage { throw BrowserError.io(error) }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            guard let image=model.image, let index=model.index, index.frameCount > 30 else { throw BrowserError.io("GUI映像表示の待機が終了しました") }
            result["window_visible"] = window?.isVisible ?? false
            result["indexed_frames_estimate"] = index.frameCount
            result["validated_frames"] = index.validatedFrameCount
            result["continuous_recordings"] = index.continuousRecordings.count;result["event_recordings"] = index.eventRecordings.count
            result["storage_blocks"] = index.blockCount
            result["first_list_seconds"] = model.firstListSeconds
            result["catalog_seconds"] = model.catalogSeconds
            result["selected_detail_seconds"] = model.detailSeconds
            result["partial_scan"] = index.isPartialScan
            result["preview_width"] = Int(image.size.width);result["preview_height"] = Int(image.size.height)
            await model.renderFrame(20)
            guard model.frameIndex == 20 else { throw BrowserError.io("シーク位置が一致しません") }
            result["seek_to_frame_20"] = true
            for _ in 0..<100 {if model.audioDuration>0{break};try await Task.sleep(nanoseconds:50_000_000)}
            model.togglePlay(backwards:false)
            try await Task.sleep(nanoseconds:2_000_000_000)
            let videoTime=model.currentSeconds,audioTime=model.activeAudioClockSeconds
            result["audio_clock_active_during_playback"]=audioTime != nil
            if let audioTime {result["av_clock_difference_seconds"]=videoTime-audioTime}
            model.pause()
            result["playback_advanced"] = model.frameIndex > 20
            result["playback_advanced_to_frame"] = model.frameIndex
            guard model.frameIndex >= 50 else { throw BrowserError.io("実時間再生で十分に位置が進みませんでした") }
            guard let audioTime,abs(videoTime-audioTime)<0.35 else {throw BrowserError.io("音声クロックと映像の同期を確認できませんでした")}
            result["audio_prepared"]=model.audioDuration>0;result["audio_seconds"]=model.audioDuration
            result["route_points"]=model.route.count;result["raw_sensor_points"]=model.sensors.count
            guard model.audioDuration>0,!model.route.isEmpty else{throw BrowserError.io("音声またはGPSがGUIに読み込まれていません")}
            let beforeReverse=model.frameIndex,reverseBegan=ProcessInfo.processInfo.systemUptime
            model.togglePlay(backwards:true)
            // Observe actual progress rather than assuming every VM completes
            // a decoder reset and a GPU presentation within exactly 500 ms.
            for _ in 0..<60 {
                if model.frameIndex<beforeReverse {break}
                if let error=model.errorMessage {throw BrowserError.io(error)}
                try await Task.sleep(nanoseconds:50_000_000)
            }
            model.pause()
            result["reverse_start_frame"]=beforeReverse
            result["reverse_end_frame"]=model.frameIndex
            result["reverse_first_progress_seconds"]=ProcessInfo.processInfo.systemUptime-reverseBegan
            result["reverse_playback_decreased"]=model.frameIndex<beforeReverse
            guard model.frameIndex<beforeReverse else {throw BrowserError.io("逆再生位置が戻りませんでした")}
            if let r=model.recording {
                let boundaries=r.packets.indices.dropFirst().filter{r.packets[$0].recordSector != r.packets[$0-1].recordSector}
                var crossed:[Int]=[]
                for boundary in boundaries.prefix(2) {
                    let selection=model.selectedID;await model.renderFrame(max(0,boundary-6));model.togglePlay(backwards:false)
                    try await Task.sleep(nanoseconds:700_000_000)
                    let at=model.frameIndex,audio=model.activeAudioClockSeconds,video=model.currentSeconds;model.pause()
                    guard at>boundary,model.selectedID==selection,let audio,abs(video-audio)<0.35 else {throw BrowserError.io("内部保存ブロックの境界を連続再生できませんでした（\(boundary)）")}
                    crossed.append(boundary)
                }
                result["continuously_played_boundaries"]=crossed
                result["one_timeline_seconds"]=model.timeline.duration
                result["audio_video_duration_difference_seconds"]=model.audioDrift
            }
            result["archive_sha256_status"]=model.archiveNotice
            var modes:[String:Bool]=[:]
            for mode in ProjectionMode.allCases {model.projection.mode=mode;await model.renderFrame(0);modes[mode.rawValue]=model.displayedFrame != nil}
            result["projection_modes"]=modes
            model.projection.mode = .perspective;model.projection.night=true;model.showMap=true;await model.renderFrame(0)
            try await Task.sleep(nanoseconds:2_000_000_000)
            result["window_number"] = window?.windowNumber ?? -1
            result["process_id"] = ProcessInfo.processInfo.processIdentifier
            if let snapshot, let view=window?.contentView {
                try captureOwnView(view,to:URL(fileURLWithPath:snapshot));result["own_window_snapshot_saved"] = true
            }
            if CommandLine.arguments.contains("--ui-check-extra") {
                try await checkAdditionalFeatures(result:&result,folder:report.deletingLastPathComponent())
            }
            result["passed"] = true
        } catch { result["passed"] = false;result["error"] = error.localizedDescription }
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:report) }
        if !CommandLine.arguments.contains("--ui-check-keep-open") { NSApp.terminate(nil) }
    }
    func captureOwnView(_ view:NSView,to url:URL) throws {
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw BrowserError.io("GUI画像を作成できません")}
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let data=rep.representation(using:.png,properties:[:]) else{throw BrowserError.io("GUI画像を保存できません")}
        try data.write(to:url)
    }
    private func checkAdditionalFeatures(result:inout [String:Any],folder:URL) async throws {
        guard let r=model.recording,let clock=model.packet?.telemetry.clock,let zone=TimeZone(identifier:"Asia/Tokyo"),let date=clock.date(in:zone) else{throw BrowserError.io("追加GUI検証の録画時刻がありません")}
        let oldQuery=model.rawQuery
        var query=RawSensorQuery();query.enabled=true;query.eventByte=Int(r.packets[0].telemetry.eventRaw);model.rawQuery=query
        guard model.rawQueryResults[r.id]==true,model.filteredRecordings.contains(where:{$0.id==r.id}) else{throw BrowserError.io("raw一致検索で録画を確認できません")}
        let used=Set(r.packets.map{Int($0.telemetry.eventRaw)})
        if let absent=(0...255).first(where:{!used.contains($0)}) {
            query.eventByte=absent;model.rawQuery=query
            guard model.rawQueryResults[r.id]==false,!model.filteredRecordings.contains(where:{$0.id==r.id}) else{throw BrowserError.io("raw不一致検索が録画を除外しません")}
        }
        model.rawQuery=oldQuery;result["raw_filter_matches_and_excludes"]=true
        let oldTrack=model.externalGPSTrack,oldZone=model.deviceTimeZoneID,oldOffset=model.gpsLogOffset,oldUse=model.useExternalGPS
        model.externalGPSTrack=ExternalGPSTrack(points:[.init(id:0,latitude:35.1,longitude:139.2,speedKMH:12,timestamp:date)])
        model.useExternalGPS=true;model.deviceTimeZoneID=""
        guard model.coordinate==nil else{throw BrowserError.io("未指定タイムゾーンで外部GPSが同期しました")}
        model.deviceTimeZoneID="Asia/Tokyo";model.gpsLogOffset=0
        guard let fix=model.coordinate,abs(fix.latitude-35.1)<1e-8,abs(fix.longitude-139.2)<1e-8,model.currentSpeedKMH==12 else{throw BrowserError.io("明示外部GPS同期を確認できません")}
        model.gpsLogOffset=100
        guard model.coordinate==nil else{throw BrowserError.io("外部GPSの範囲外を補外してしまいました")}
        model.externalGPSTrack=oldTrack;model.deviceTimeZoneID=oldZone;model.gpsLogOffset=oldOffset;model.useExternalGPS=oldUse
        result["external_gps_explicit_opt_in_and_no_extrapolation"]=true
        model.settingsTab=2;model.showSettings=true
        for _ in 0..<30{if window?.attachedSheet != nil{break};try await Task.sleep(nanoseconds:100_000_000)}
        guard let sheet=window?.attachedSheet,let view=sheet.contentView else{throw BrowserError.io("設定シートを表示できません")}
        for (tab,name) in [(0,"projection"),(1,"gps"),(2,"export"),(3,"raw-search"),(4,"card")] {
            model.settingsTab=tab;try await Task.sleep(nanoseconds:400_000_000)
            try captureOwnView(view,to:folder.appendingPathComponent("settings-\(name).png"))
            func scrollViews(_ parent: NSView) -> [NSScrollView] {
                (parent as? NSScrollView).map { [$0] } ?? parent.subviews.flatMap { scrollViews($0) }
            }
            if let scroll = scrollViews(view).filter({ ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 10 }).max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }), let document = scroll.documentView {
                let bottom = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(nanoseconds: 200_000_000)
                try captureOwnView(view, to: folder.appendingPathComponent("settings-\(name)-bottom.png"))
            }
        }
        model.showSettings=false;try await Task.sleep(nanoseconds:400_000_000)
        let notes=model.reportNotes();model.saveReportNotes("GUI checkpoint — raw semantics remain unclassified")
        guard model.reportNotes()=="GUI checkpoint — raw semantics remain unclassified" else{throw BrowserError.io("レポート備考を保存できません")}
        model.saveReportNotes(notes);model.showReport=true
        for _ in 0..<30{if window?.attachedSheet != nil{break};try await Task.sleep(nanoseconds:100_000_000)}
        try await Task.sleep(nanoseconds:2_500_000_000)
        guard let reportView=window?.attachedSheet?.contentView else{throw BrowserError.io("録画レポートを表示できません")}
        try captureOwnView(reportView,to:folder.appendingPathComponent("recording-report.png"))
        model.showReport=false;try await Task.sleep(nanoseconds:300_000_000)
        result["settings_and_report_views_captured"]=true;result["report_notes_local_roundtrip"]=true
        // Both printed layouts from made-up values: one A4 PDF page each, plus a picture of the page.
        var pages:[String:Any]=[:]
        for kind in [LegacyReportKind.event,LegacyReportKind.continuous] {
            let synthetic=LegacyReportPage.syntheticReport(kind:kind),pictures=kind == .event ? LegacyReportPage.syntheticThumbnails():[]
            let text="備考のテスト\n二行目",data=try LegacyReportPage.pdf(synthetic,thumbnails:pictures,notes:text)
            guard let document=PDFDocument(data:data),document.pageCount == 1,let first=document.page(at:0),abs(first.bounds(for:.mediaBox).width-595)<1 else{throw BrowserError.io("レポートページPDFを検証できません")}
            guard let image=LegacyReportPage.image(synthetic,thumbnails:pictures,notes:text),let png=LegacyReportPage.png(image) else{throw BrowserError.io("レポートページを描画できません")}
            try png.write(to:folder.appendingPathComponent("report-page-\(kind.rawValue).png"))
            pages[kind.rawValue]=["pdf_bytes":data.count,"png_bytes":png.count]
        }
        result["legacy_report_pages"]=pages
        // The history report from a made-up journal: list dialog, printed pages and CSV pair.
        guard let history=HistoryReportPage.syntheticReport() else{throw BrowserError.io("履歴記録レポートの試験データを作成できません")}
        let historyPDF=try HistoryReportPage.pdf(history)
        guard let historyDocument=PDFDocument(data:historyPDF),historyDocument.pageCount == HistoryReportPage.pageCount(history),let historyFirst=historyDocument.page(at:0),abs(historyFirst.bounds(for:.mediaBox).width-842)<1 else{throw BrowserError.io("履歴記録レポートPDFを検証できません")}
        guard let historyPage=HistoryReportPage.image(history,page:0),let historyPNG=LegacyReportPage.png(historyPage) else{throw BrowserError.io("履歴記録レポートページを描画できません")}
        try historyPNG.write(to:folder.appendingPathComponent("history-report-page.png"))
        let historySummary=try history.summaryCSVData(),historyData=try history.dataCSV()
        guard history.rowCount == 3,history.dataLineCount > 0,!historySummary.isEmpty,historyData.count > historySummary.count else{throw BrowserError.io("履歴記録レポートのCSVを作成できません")}
        model.historyReportOverride=history;model.showHistoryReport=true
        for _ in 0..<30{if window?.attachedSheet != nil{break};try await Task.sleep(nanoseconds:100_000_000)}
        try await Task.sleep(nanoseconds:1_500_000_000)
        guard let historyView=window?.attachedSheet?.contentView else{throw BrowserError.io("履歴記録レポートを表示できません")}
        try captureOwnView(historyView,to:folder.appendingPathComponent("history-report.png"))
        model.showHistoryReport=false;model.historyReportOverride=nil;try await Task.sleep(nanoseconds:300_000_000)
        result["history_report"]=["rows":history.rowCount,"data_lines":history.dataLineCount,"pdf_pages":historyDocument.pageCount,"summary_bytes":historySummary.count,"data_bytes":historyData.count,"total_row":history.totalCells] as [String:Any]
        // ログデータ変換 from the made-up journal: the dialog and the file it would write (nothing is written to disk here).
        guard let journal=HistoryReportPage.syntheticLog(),let journalKML=JournalKML(log:journal) else{throw BrowserError.io("ログデータ変換の試験データを作成できません")}
        let kmlData=try journalKML.data()
        guard Array(kmlData.prefix(3)) == [0xEF,0xBB,0xBF] else{throw BrowserError.io("ログデータ変換のKMLを検証できません(先頭 \(Array(kmlData.prefix(3))))")}
        guard kmlData.suffix(8) == Data("</kml>\r\n".utf8) else{throw BrowserError.io("ログデータ変換のKMLを検証できません(末尾 \(Array(kmlData.suffix(8))))")}
        // The first entry of a ring has no lagging record before it, so its shown clock is its own clock minus one second (docs/history-report.md).
        guard journalKML.defaultFileName == "YP_20261111_085959.kml" else{throw BrowserError.io("ログデータ変換のKMLを検証できません(名前 \(journalKML.defaultFileName))")}
        let previousLog=model.historyLog;model.historyLog=journal;model.showLogConversion=true
        for _ in 0..<30{if window?.attachedSheet != nil{break};try await Task.sleep(nanoseconds:100_000_000)}
        try await Task.sleep(nanoseconds:1_000_000_000)
        guard let conversionView=window?.attachedSheet?.contentView else{throw BrowserError.io("ログデータ変換ダイアログを表示できません")}
        try captureOwnView(conversionView,to:folder.appendingPathComponent("log-conversion.png"))
        model.showLogConversion=false;model.historyLog=previousLog;try await Task.sleep(nanoseconds:300_000_000)
        result["log_conversion"]=["bytes":kmlData.count,"entries":journalKML.entryCount,"default_file":journalKML.defaultFileName] as [String:Any]
        if CommandLine.arguments.contains("--ui-check-earth") {
            var style=TrackStyle();style.showPoints=true;style.lineRGB="12A4E0";style.pointRGB="E06012";style.alpha=173;style.width=7;style.density=17
            let kml=folder.appendingPathComponent("explicit-earth-\(UUID().uuidString).kml")
            try Data(TrackExport.kml([r],datum:model.datum,name:"PC Browser explicit integration check",style:style).utf8).write(to:kml,options:.withoutOverwriting)
            let application:NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                model.openKMLInEarth(kml){application,error in
                    if let error {continuation.resume(throwing:error)}
                    else if let application {continuation.resume(returning:application)}
                    else {continuation.resume(throwing:BrowserError.io("Google Earthの起動結果がありません"))}
                }
            }
            guard !application.isTerminated else{throw BrowserError.io("Google Earthが起動直後に終了しました")}
            result["earth_launch"]=["explicit_opt_in":true,"bundle_identifier":application.bundleIdentifier ?? "","process_id":application.processIdentifier,"kml":kml.lastPathComponent,"scope":"LaunchServices open completion; verify Earth document UI separately"] as [String:Any]
        }
        try await checkViewOperations(result:&result,folder:folder)
        try await checkLegacyMenu(result:&result,folder:folder)
    }
    /// 表示 ▸ 画面表示 ▸ 16分割表示: enabled only for the FDR class (grayed out for Q-01 like the original), and the sheet
    /// really holds the sixteen most recent frames, the newest bottom right, shifting one tile per frame.
    private func checkFrameHistoryMenu(controller:LegacyMenuController,result:inout [String:Any]) async throws {
        guard let fdr=LegacyModelCatalog.all.first(where:{$0.name == "FDR-800"}),let q01=LegacyModelCatalog.all.first(where:{$0.name == "Q-01"}),
              let item310=controller.menuItem(tag:310),let item311=controller.menuItem(tag:311) else{throw BrowserError.io("画面表示メニューが不足しています")}
        func checked(_ item:NSMenuItem)->Bool{_=controller.validateMenuItem(item);return item.state == .on}
        model.projection.mode = .perspective
        controller.dispatch(q01.commandID)
        guard !controller.validateMenuItem(item311),!controller.validateMenuItem(item310),checked(item310) else{throw BrowserError.io("Q-01で画面表示メニューがグレーアウトされていません")}
        controller.dispatch(fdr.commandID)
        guard controller.validateMenuItem(item311),controller.validateMenuItem(item310),!checked(item311),checked(item310) else{throw BrowserError.io("FDR-800で画面表示メニューが有効になりません")}
        controller.dispatch(311)
        guard model.projection.mode == .frameHistory,checked(item311),!checked(item310) else{throw BrowserError.io("16分割表示メニューが反映されません")}
        func mean(_ image:CGImage,_ rect:CGRect)->[Double]?{
            guard let part=image.cropping(to:rect),let context=CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),!rect.isEmpty else{return nil}
            context.interpolationQuality = .high;context.draw(part,in:CGRect(x:0,y:0,width:1,height:1))
            guard let data=context.data else{return nil};let p=data.bindMemory(to:UInt8.self,capacity:4);return [Double(p[0]),Double(p[1]),Double(p[2])]
        }
        func close(_ a:[Double]?,_ b:[Double]?,_ tolerance:Double)->Bool{guard let a,let b else{return false};return zip(a,b).allSatisfy{abs($0-$1)<=tolerance}}
        await model.renderFrame(0)
        guard let first=model.displayedFrame,let raw0=model.rawFrame else{throw BrowserError.io("16分割表示のシートを取得できません")}
        let size=FrameHistorySheet.pictureSize(sourceWidth:raw0.width,sourceHeight:raw0.height),layout=FrameHistorySheet.layout(pictureWidth:size.width,pictureHeight:size.height)
        guard first.width == layout.width,first.height == layout.height else{throw BrowserError.io("16分割表示のシートの大きさが想定と異なります")}
        func slot(_ image:CGImage,_ index:Int)->CGRect{let p=layout.pictures[index];return CGRect(x:p.x,y:p.y,width:p.width,height:p.height)}
        // Frame 0 is the newest tile; the fifteen before it do not exist and show the empty tile colour.
        guard close(mean(first,slot(first,0)),[25.5,25.5,25.5],8),close(mean(first,slot(first,15)),mean(raw0,CGRect(x:0,y:0,width:raw0.width,height:raw0.height)),20) else{throw BrowserError.io("16分割表示の最初のシートが想定と異なります")}
        let before=mean(first,slot(first,15))
        await model.renderFrame(1)
        guard let second=model.displayedFrame,let raw1=model.rawFrame,second.width == layout.width else{throw BrowserError.io("16分割表示の次のシートを取得できません")}
        guard close(mean(second,slot(second,14)),before,3),close(mean(second,slot(second,15)),mean(raw1,CGRect(x:0,y:0,width:raw1.width,height:raw1.height)),20) else{throw BrowserError.io("16分割表示でコマが1つ前へ送られません")}
        result["frame_history_sheet"]=["width":second.width,"height":second.height,"tiles":FrameHistorySheet.tileCount,"enabled_for_fdr":true,"grayed_for_q01":true] as [String:Any]
        model.projection.mode = .perspective;model.modeBeforeFrameHistory = .perspective
        controller.dispatch(311);controller.dispatch(310)
        guard model.projection.mode == .perspective,checked(item310) else{throw BrowserError.io("1画面表示メニューが反映されません")}
    }
    /// Verifies the original-command menu bar and exercises the non-modal commands.
    private func checkLegacyMenu(result:inout [String:Any],folder:URL) async throws {
        guard let controller=legacyMenu,let main=NSApp.mainMenu else{throw BrowserError.io("原版メニューが作成されていません")}
        let tags=Set(LegacyMenuController.allItems(in:main).filter{$0.action == #selector(LegacyMenuController.legacyCommand(_:))}.map(\.tag))
        let required=LegacyMenuInventory.all.filter{LegacyMenuInventory.menuBarGroups.contains($0.group)}.map(\.id)
        let missing=required.filter{!tags.contains($0)}
        guard missing.isEmpty else{throw BrowserError.io("原版メニューIDが不足しています: \(missing)")}
        guard LegacyModelCatalog.all.allSatisfy({controller.menuItem(tag:$0.commandID) != nil}) else{throw BrowserError.io("機種選択メニューが不足しています")}
        func checked(_ id:Int)->Bool{guard let item=controller.menuItem(tag:id) else{return false};_=controller.validateMenuItem(item);return item.state == .on}
        let oldUnit=model.speedUnit,oldScale=model.sensorScale,oldMap=model.showMap,oldModel=model.legacyModelID,oldMode=model.projection.mode,oldVisible=model.fileListVisible
        controller.dispatch(384);guard model.speedUnit == .knots,checked(384),!checked(380) else{throw BrowserError.io("knot表示メニューが反映されません")}
        controller.dispatch(380);guard model.speedUnit == .kilometersPerHour,checked(380) else{throw BrowserError.io("GPS速度メニューが反映されません")}
        for scale in GSensorScale.allCases{controller.dispatch(scale.commandID);guard model.sensorScale == scale,checked(scale.commandID) else{throw BrowserError.io("センサースケールメニューが反映されません")}}
        controller.dispatch(383);guard !model.showMap,checked(383) else{throw BrowserError.io("地図非表示メニューが反映されません")}
        controller.dispatch(382);guard model.showMap,checked(382) else{throw BrowserError.io("地図表示メニューが反映されません")}
        for model_ in LegacyModelCatalog.all{controller.dispatch(model_.commandID);guard model.legacyModelID == model_.commandID,window?.title == model_.windowTitle+" — Mac 読み取り専用",checked(model_.commandID) else{throw BrowserError.io("機種選択メニューが反映されません: \(model_.name)")}}
        for (id,mode) in LegacyMenuController.singleScreenModes{controller.dispatch(id);guard model.projection.mode == mode,checked(id) else{throw BrowserError.io("周囲カメラ表示メニューが反映されません: \(id)")}}
        try await checkFrameHistoryMenu(controller:controller,result:&result)
        controller.dispatch(9018);guard model.projection.mode == .grid16,checked(9018) else{throw BrowserError.io("16方向ビューのメニューが反映されません")}
        controller.dispatch(310);guard model.projection.mode == .perspective,!checked(9018),checked(310) else{throw BrowserError.io("1画面表示メニューが反映されません")}
        controller.dispatch(304);guard !model.fileListVisible,!checked(304) else{throw BrowserError.io("ファイルリスト表示メニューが反映されません")}
        controller.dispatch(304);guard model.fileListVisible else{throw BrowserError.io("ファイルリスト表示メニューが戻りません")}
        let oldVolume=model.volume;controller.dispatch(360);guard model.volume<oldVolume || oldVolume==0 else{throw BrowserError.io("音量小さくメニューが反映されません")}
        controller.dispatch(361);controller.dispatch(361);guard model.volume>=oldVolume || oldVolume==1 else{throw BrowserError.io("音量大きくメニューが反映されません")}
        model.volume=oldVolume
        let oldMuted=model.muted;controller.dispatch(362)
        guard model.muted != oldMuted,checked(362) == model.muted else{throw BrowserError.io("ミュートメニューが反映されません")}
        controller.dispatch(362);guard model.muted == oldMuted else{throw BrowserError.io("ミュートメニューが元に戻りません")}
        let before=model.frameIndex;controller.dispatch(352);try await Task.sleep(nanoseconds:700_000_000)
        guard model.frameIndex>before || model.recording.map({before>=$0.packets.count-1}) == true else{throw BrowserError.io("次コマメニューが反映されません")}
        controller.dispatch(354);try await Task.sleep(nanoseconds:700_000_000)
        controller.dispatch(356)
        model.speedUnit=oldUnit;model.sensorScale=oldScale;model.showMap=oldMap;model.legacyModelID=oldModel;model.projection.mode=oldMode;model.fileListVisible=oldVisible
        model.showInventory=true
        for _ in 0..<30{if window?.attachedSheet != nil{break};try await Task.sleep(nanoseconds:100_000_000)}
        try await Task.sleep(nanoseconds:500_000_000)
        guard let inventoryView=window?.attachedSheet?.contentView else{throw BrowserError.io("原版メニュー対応表を表示できません")}
        try captureOwnView(inventoryView,to:folder.appendingPathComponent("legacy-inventory.png"))
        model.showInventory=false;try await Task.sleep(nanoseconds:300_000_000)
        result["legacy_menu"]=["menu_bar_command_ids":required.count,"model_items":LegacyModelCatalog.all.count,"checked_state_roundtrip":true,"inventory_commands":LegacyMenuInventory.all.count,"inventory_view_captured":true] as [String:Any]
        if !CommandLine.arguments.contains("--ui-check-keep-open") {
            controller.dispatch(307)
            guard model.index == nil,model.source == nil,model.image == nil else{throw BrowserError.io("データフォルダを閉じるメニューが状態を破棄しません")}
            result["legacy_close_data"]=true
        }
    }
    @objc func openImage() { model.openPanel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ sender:NSApplication,openFiles filenames:[String]) { if let file=filenames.first { model.open(URL(fileURLWithPath:file)) };sender.reply(toOpenOrPrint:.success) }
}
@main enum PCBrowserLauncher {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--inspect") { exit(await InspectionCLI.run(CommandLine.arguments)) }
        if let output=InspectionCLI.value("--legacy-inventory",in:CommandLine.arguments) { exit(InspectionCLI.legacyInventory(output)) }
        if let output=InspectionCLI.value("--view-check",in:CommandLine.arguments) { exit(InspectionCLI.viewCheck(output)) }
        if CommandLine.arguments.contains("--settings-show") { exit(SettingsCLI.show(CommandLine.arguments)) }
        if CommandLine.arguments.contains("--settings-apply") { exit(SettingsCLI.run(CommandLine.arguments)) }
        if CommandLine.arguments.contains("--password-check") { exit(SettingsCLI.passwordCheck(CommandLine.arguments)) }
        if CommandLine.arguments.contains("--erase-recordings") { exit(SettingsCLI.erase(CommandLine.arguments)) }
        runApplication()
    }
    @MainActor static func runApplication() {
        let application=NSApplication.shared;application.setActivationPolicy(.regular)
        let delegate=AppDelegate();application.delegate=delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
