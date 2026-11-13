import AppKit
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu=NSMenu();let root=NSMenuItem();let appMenu=NSMenu();root.submenu=appMenu;menu.addItem(root)
        appMenu.addItem(withTitle:"PC Browser Macを終了",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let file=NSMenuItem();let fileMenu=NSMenu(title:"ファイル");file.submenu=fileMenu;menu.addItem(file)
        let open=NSMenuItem(title:"IMGを開く…",action:#selector(openImage),keyEquivalent:"o");open.target=self;fileMenu.addItem(open)
        NSApp.mainMenu=menu
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:880),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title="PC Browser Mac — 読み取り専用";w.minSize=NSSize(width:1080,height:760)
        w.contentView=NSHostingView(rootView:BrowserView(model:model));w.center();w.makeKeyAndOrderFront(nil);window=w
        NSApp.activate(ignoringOtherApps:true)
        let args=CommandLine.arguments
        if let path=InspectionCLI.value("--image",in:args) { model.open(URL(fileURLWithPath:path),limit:InspectionCLI.value("--scan-limit",in:args).flatMap(UInt64.init)) }
        if let report=InspectionCLI.value("--ui-check-report",in:args) {
            Task { await runUICheck(report:URL(fileURLWithPath:report),snapshot:InspectionCLI.value("--ui-snapshot",in:args)) }
        }
    }
    private func runUICheck(report:URL,snapshot:String?) async {
        var result:[String:Any] = ["scope":"Real-media partial backup: GUI/audio/map/projection smoke test; not physical SD"]
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
            result["continuous_recordings"] = index.recordings.count
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
    private func captureOwnView(_ view:NSView,to url:URL) throws {
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
        try await Task.sleep(nanoseconds:600_000_000)
        guard let reportView=window?.attachedSheet?.contentView else{throw BrowserError.io("録画レポートを表示できません")}
        try captureOwnView(reportView,to:folder.appendingPathComponent("recording-report.png"))
        model.showReport=false;try await Task.sleep(nanoseconds:300_000_000)
        result["settings_and_report_views_captured"]=true;result["report_notes_local_roundtrip"]=true
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
    }
    @objc func openImage() { model.openPanel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ sender:NSApplication,openFiles filenames:[String]) { if let file=filenames.first { model.open(URL(fileURLWithPath:file)) };sender.reply(toOpenOrPrint:.success) }
}
@main enum PCBrowserLauncher {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--inspect") { exit(await InspectionCLI.run(CommandLine.arguments)) }
        runApplication()
    }
    @MainActor static func runApplication() {
        let application=NSApplication.shared;application.setActivationPolicy(.regular)
        let delegate=AppDelegate();application.delegate=delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
