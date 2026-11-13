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
            result["validated_frames"] = index.frameCount
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
            let beforeReverse=model.frameIndex
            model.togglePlay(backwards:true);try await Task.sleep(nanoseconds:500_000_000);model.pause()
            result["reverse_playback_decreased"]=model.frameIndex<beforeReverse
            guard model.frameIndex<beforeReverse else {throw BrowserError.io("逆再生位置が戻りませんでした")}
            var modes:[String:Bool]=[:]
            for mode in ProjectionMode.allCases {model.projection.mode=mode;await model.renderFrame(0);modes[mode.rawValue]=model.displayedFrame != nil}
            result["projection_modes"]=modes
            model.projection.mode = .perspective;model.projection.night=true;model.showMap=true;await model.renderFrame(0)
            try await Task.sleep(nanoseconds:2_000_000_000)
            result["window_number"] = window?.windowNumber ?? -1
            result["process_id"] = ProcessInfo.processInfo.processIdentifier
            if let snapshot, let view=window?.contentView {
                view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw BrowserError.io("GUI画像を作成できません") }
                view.cacheDisplay(in:view.bounds,to:rep)
                guard let data=rep.representation(using:.png,properties:[:]) else { throw BrowserError.io("GUI画像を保存できません") }
                try data.write(to:URL(fileURLWithPath:snapshot));result["own_window_snapshot_saved"] = true
            }
            result["passed"] = true
        } catch { result["passed"] = false;result["error"] = error.localizedDescription }
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:report) }
        if !CommandLine.arguments.contains("--ui-check-keep-open") { NSApp.terminate(nil) }
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
