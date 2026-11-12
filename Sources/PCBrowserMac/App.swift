import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PCBrowserCore

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor final class BrowserModel: ObservableObject {
    @Published var index: ImageIndex?
    @Published var selectedID: String? { didSet { if oldValue != selectedID { prepareSelection() } } }
    @Published var image: NSImage?
    @Published var frameIndex = 0
    @Published var scrubber = 0.0
    @Published var playing = false
    @Published var scanning = false
    @Published var rendering = false
    @Published var progress = 0.0
    @Published var status = "IMGファイルまたはSDカードを選択してください"
    @Published var sourceName = "未選択"
    @Published var errorMessage: String?
    @Published var playbackFPS = 30.0
    @Published var cardNotice = ""
    private var source: FileByteSource?
    private var renderer: FrameRenderer?
    private var cancellation = ScanCancellation()
    private var generation = UUID()
    private var playTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    var recording: Recording? { index?.recordings.first { $0.id == selectedID } }
    var packet: FramePacket? { guard let r=recording, r.packets.indices.contains(frameIndex) else { return nil }; return r.packets[frameIndex] }
    init() {
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cardNotice = "外部メディアの接続状態が変わりました。SDカードを選択できます" }
            })
        }
    }
    func openPanel() {
        let panel=NSOpenPanel(); panel.title="SDカードのディスクイメージを開く"; panel.allowedContentTypes=[.data]
        panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        if panel.runModal() == .OK, let url=panel.url { open(url) }
    }
    func open(_ url: URL, limit: UInt64? = nil) {
        do { load(try FileByteSource(url:url), name:url.lastPathComponent, limit:limit) }
        catch { errorMessage=error.localizedDescription }
    }
    func cancel() { cancellation.cancel(); pause() }
    private func load(_ source: FileByteSource, name: String, limit: UInt64? = nil) {
        cancel(); generation=UUID();let token=generation;let cancel=ScanCancellation();cancellation=cancel
        self.source=source; index=nil;selectedID=nil;image=nil;sourceName=name;progress=0;scanning=true;errorMessage=nil
        status="録画領域を読み取り専用で走査しています…"
        Task {
            do {
                let result=try await Task.detached(priority:.userInitiated) {
                    try ImageScanner.scan(source,limitBytes:limit,cancelled:{cancel.cancelled}) { done,total,count in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            self.progress=total > 0 ? Double(done)/Double(total) : 0
                            self.status="\(count)フレームを確認 · \(Int(self.progress*100))%"
                        }
                    }
                }.value
                guard generation == token else { return }
                index=result;scanning=false;progress=1
                status="\(result.recordings.count)件の録画 · \(result.frameCount)フレーム" + (result.isPartialScan ? "（一部領域のみ）" : "")
                if result.frameCount == 0 { status="対応する映像パケットが見つかりませんでした" }
                selectedID=result.recordings.first?.id
            } catch {
                guard generation == token else { return };scanning=false
                status=cancel.cancelled ? "走査をキャンセルしました" : "読み取りを完了できませんでした"
                if !cancel.cancelled { errorMessage=error.localizedDescription }
            }
        }
    }
    private func prepareSelection() {
        pause();image=nil;rendering=false;frameIndex=0;scrubber=0
        guard let r=recording,let source else { renderer=nil;return }
        renderer=FrameRenderer(source:source,packets:r.packets)
        playbackFPS=30 // provisional display speed; not inferred from raw field 0x1E8
        let first=r.packets.firstIndex(where:{$0.isIntra}) ?? 0
        Task { await renderFrame(first) }
    }
    func renderFrame(_ position: Int) async {
        guard let renderer,let r=recording,r.packets.indices.contains(position) else { return }
        let selection=selectedID; rendering=true
        do {
            let frame=try await renderer.render(position)
            guard selectedID == selection else { return }
            image=NSImage(cgImage:frame,size:NSSize(width:frame.width,height:frame.height));frameIndex=position;scrubber=Double(position)
        } catch { if selectedID == selection { pause();errorMessage=error.localizedDescription } }
        rendering=false
    }
    func seek() { pause(); let position=Int(scrubber.rounded());Task { await renderFrame(position) } }
    func step(_ delta: Int) {
        pause(); guard let r=recording,!r.packets.isEmpty else { return }
        let target=max(0,min(r.packets.count-1,frameIndex+delta));Task { await renderFrame(target) }
    }
    func pause() { playing=false;playTask?.cancel();playTask=nil }
    func togglePlay() {
        if playing { pause();return }
        guard let r=recording,!r.packets.isEmpty else { return };playing=true
        playTask=Task { [weak self] in
            guard let self else { return }
            if frameIndex == r.packets.count-1 { await renderFrame(0) }
            while !Task.isCancelled && playing && frameIndex+1 < r.packets.count {
                let started=Date(); await renderFrame(frameIndex+1)
                let delay=max(0,1.0/playbackFPS-Date().timeIntervalSince(started))
                try? await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))
            }
            playing=false
        }
    }
    func chooseSD() {
        pause();status="外部メディアの一覧を確認しています…"
        Task {
            do {
                let disks=try await Task.detached { try SDCardAccess.list() }.value
                guard !disks.isEmpty else { throw BrowserError.io("外部の物理ディスクが見つかりません。SDカードとカードリーダーを確認してください") }
                let alert=NSAlert();alert.messageText="読み取るSDカードを選択";alert.informativeText="選択した外部ディスクをO_RDONLYで開きます。消去・設定変更・マウント解除は行いません。"
                let popup=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28))
                popup.addItems(withTitles:disks.map{"\($0.name) — \($0.bsd) — \(ByteCountFormatter.string(fromByteCount:Int64($0.bytes),countStyle:.file))"})
                alert.accessoryView=popup;alert.addButton(withTitle:"読み取り専用で開く");alert.addButton(withTitle:"キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else { status="SDカードの選択をキャンセルしました";return }
                guard let helper=Bundle.main.url(forAuxiliaryExecutable:"PCBrowserRawReader") else { throw BrowserError.io("SDカード用ヘルパーがありません。ビルドした.appから起動してください") }
                let disk=disks[popup.indexOfSelectedItem];status="SDカードの読み取り許可を待っています…"
                let source=try await Task.detached { try SDCardAccess.open(disk,helper:helper) }.value
                cardNotice="";load(source,name:"\(disk.name) / \(disk.bsd)")
            } catch { errorMessage=error.localizedDescription;status="SDカードを開けませんでした" }
        }
    }
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:0) {
                VStack(alignment:.leading,spacing:6) {
                    Label("PC Browser Mac",systemImage:"sdcard").font(.headline)
                    Text(model.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.padding(16)
                Divider()
                List(selection:$model.selectedID) {
                    ForEach(model.index?.recordings ?? []) { r in
                        VStack(alignment:.leading,spacing:5) {
                            Text(r.startTime).font(.system(.body,design:.monospaced))
                            Text("CH \(r.channel) · \(r.packets.count)フレーム").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical,5).tag(r.id)
                    }
                }
                Divider()
                Label("読み取り専用",systemImage:"lock.shield").font(.caption).foregroundStyle(.secondary).padding(14)
            }.navigationSplitViewColumnWidth(min:230,ideal:275,max:340)
        } detail: {
            VStack(spacing:16) {
                if model.scanning {
                    VStack(alignment:.leading,spacing:8) {
                        HStack { Text(model.status);Spacer();Button("キャンセル",action:model.cancel) }
                        ProgressView(value:model.progress)
                    }.padding(.horizontal,4)
                }
                preview
                controls
                metadata
                HStack {
                    Text(model.status).lineLimit(2)
                    Spacer()
                    if model.index?.isPartialScan == true { Text("一部走査").foregroundStyle(.orange) }
                }.font(.caption).foregroundStyle(.secondary)
                Text("再生速度は暫定30fpsです。音声・地図・精密な時刻同期は解析中です。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                if !model.cardNotice.isEmpty { Text(model.cardNotice).font(.caption).foregroundStyle(.blue).frame(maxWidth:.infinity,alignment:.leading) }
            }.padding(20).frame(minWidth:650,minHeight:600)
            .toolbar {
                ToolbarItemGroup {
                    Button(action:model.openPanel) { Label("IMGを開く",systemImage:"doc.badge.plus") }.disabled(model.scanning)
                    Button(action:model.chooseSD) { Label("SDカードを選択",systemImage:"sdcard") }.disabled(model.scanning)
                }
            }
        }.alert("確認が必要です",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage=nil}})) {
            Button("閉じる",role:.cancel){model.errorMessage=nil}
        } message: { Text(model.errorMessage ?? "") }
    }
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius:10).fill(Color.black)
            if let image=model.image {
                Image(nsImage:image).resizable().scaledToFit().padding(1).accessibilityLabel("録画映像プレビュー")
            } else {
                VStack(spacing:12) {
                    Image(systemName:"video").font(.system(size:44,weight:.light))
                    Text(model.scanning ? "録画を探しています" : "SDカードの録画をMacで確認")
                    Text("IMGを開くか、SDカードを選択してください").font(.caption)
                }.foregroundStyle(.white.opacity(0.75))
            }
            if model.rendering { ProgressView().controlSize(.large).padding(16).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10)) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).aspectRatio(2560.0/1080.0,contentMode:.fit)
    }
    private var controls: some View {
        VStack(spacing:12) {
            Slider(value:$model.scrubber,in:0...Double(max(1,(model.recording?.packets.count ?? 1)-1)),step:1) { editing in
                if editing { model.pause() } else { model.seek() }
            }.disabled(model.recording == nil).accessibilityLabel("フレーム位置")
            HStack(spacing:16) {
                Button { model.step(-1) } label: { Image(systemName:"backward.frame") }.help("1フレーム戻る")
                Button(action:model.togglePlay) { Image(systemName:model.playing ? "pause.fill":"play.fill").frame(width:22) }
                    .keyboardShortcut(.space,modifiers:[]).help("再生・一時停止")
                Button { model.step(1) } label: { Image(systemName:"forward.frame") }.help("1フレーム進む")
                Text("\(model.frameIndex+1) / \(model.recording?.packets.count ?? 0)").font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                Spacer()
                Picker("再生速度",selection:$model.playbackFPS) {
                    ForEach([5.0,10,15,20,25,30,60],id:\.self){ n in Text("\(Int(n)) fps").tag(n) }
                }.frame(width:140).help("暫定30fpsです。正確な同期は解析中で、変更は表示速度のみです")
            }.disabled(model.recording == nil)
        }
    }
    private var metadata: some View {
        GroupBox("録画情報") {
            HStack(alignment:.top,spacing:32) {
                VStack(alignment:.leading,spacing:7) {
                    LabeledContent("カード時刻",value:model.packet?.cardTime ?? "—")
                    LabeledContent("チャンネル",value:model.packet.map{String($0.channel)} ?? "—")
                    LabeledContent("映像サイズ",value:model.image.map{"\(Int($0.size.width)) × \(Int($0.size.height))"} ?? "—")
                }
                VStack(alignment:.leading,spacing:7) {
                    LabeledContent("パケットLBA",value:model.packet.map{String($0.headerSector)} ?? "—")
                    LabeledContent("映像データ",value:model.packet.map{"\($0.videoBytes) bytes"} ?? "—")
                    LabeledContent("補助データ",value:model.packet.map{"\($0.auxiliaryBytes) bytes（未解釈）"} ?? "—")
                }
            }.font(.caption).padding(8)
        }
    }
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
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1160,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title="PC Browser Mac — 読み取り専用";w.minSize=NSSize(width:980,height:700)
        w.contentView=NSHostingView(rootView:BrowserView(model:model));w.center();w.makeKeyAndOrderFront(nil);window=w
        NSApp.activate(ignoringOtherApps:true)
        let args=CommandLine.arguments
        if let path=InspectionCLI.value("--image",in:args) { model.open(URL(fileURLWithPath:path),limit:InspectionCLI.value("--scan-limit",in:args).flatMap(UInt64.init)) }
        if let report=InspectionCLI.value("--ui-check-report",in:args) {
            Task { await runUICheck(report:URL(fileURLWithPath:report),snapshot:InspectionCLI.value("--ui-snapshot",in:args)) }
        }
    }
    private func runUICheck(report:URL,snapshot:String?) async {
        var result:[String:Any] = ["scope":"Partial real-image fixture GUI smoke test; not a physical SD test"]
        do {
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
            model.togglePlay(); try await Task.sleep(nanoseconds:500_000_000); model.pause()
            result["playback_advanced"] = model.frameIndex > 20
            result["playback_advanced_to_frame"] = model.frameIndex
            guard model.frameIndex > 20 else { throw BrowserError.io("再生位置が進みませんでした") }
            await model.renderFrame(0)
            try await Task.sleep(nanoseconds:300_000_000)
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
    @MainActor static func main() {
        if CommandLine.arguments.contains("--inspect") { exit(InspectionCLI.run(CommandLine.arguments)) }
        let application=NSApplication.shared;application.setActivationPolicy(.regular)
        let delegate=AppDelegate();application.delegate=delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
