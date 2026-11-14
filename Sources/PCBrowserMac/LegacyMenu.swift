import AppKit
import PCBrowserCore

/// Builds the Mac menu bar from the analysed original menu structure and routes
/// every item (tagged with the original command ID) to the Mac implementation.
/// Items without a safe implementation explain why instead of guessing.
@MainActor final class LegacyMenuController: NSObject, NSMenuItemValidation {
    let model: BrowserModel
    init(model: BrowserModel) { self.model = model; super.init() }

    static let recordingCommands: Set<Int> = [305, 314, 350, 351, 352, 353, 354, 355, 356, 372, 373, 374, 375, 377, 9010, 9011, 9012, 9013, 9014, 9015, 9016]
    static let singleScreenModes: [Int: ProjectionMode] = [340: .raw, 341: .perspective, 342: .panorama, 343: .ring, 344: .dome]
    /// Display modes that show several pictures at once: 1画面表示 (310) leaves them.
    static let multiPictureModes: Set<ProjectionMode> = [.frontRear, .quad, .grid16, .frameHistory]

    // MARK: Menu construction
    func buildMainMenu() -> NSMenu {
        let main = NSMenu(title: "メインメニュー")
        let appItem = NSMenuItem(), app = NSMenu(title: "PC Browser Mac")
        appItem.submenu = app; main.addItem(appItem)
        app.addItem(item("PC Browser Macについて", 390))
        app.addItem(.separator())
        app.addItem(item("設定…", 9004, key: ","))
        app.addItem(.separator())
        app.addItem(item("PC Browser Macを終了", 306, key: "q"))
        main.addItem(groupItem("ファイル"))
        main.addItem(editItem())
        for group in ["表示", "再生", "ツール"] { main.addItem(groupItem(group)) }
        main.addItem(extrasItem())
        main.addItem(windowItem())
        main.addItem(groupItem("ヘルプ"))
        return main
    }
    private func item(_ title: String, _ tag: Int, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(legacyCommand(_:)), keyEquivalent: key)
        menuItem.target = self; menuItem.tag = tag
        return menuItem
    }
    private func commandItem(_ command: LegacyCommand) -> NSMenuItem {
        let menuItem = item(command.label, command.id, key: command.key)
        menuItem.toolTip = command.macEquivalent
        return menuItem
    }
    private func groupItem(_ group: String) -> NSMenuItem {
        let root = NSMenuItem(title: group, action: nil, keyEquivalent: ""), menu = NSMenu(title: group)
        root.submenu = menu
        var submenus: [String: NSMenu] = ["": menu]
        for command in LegacyMenuInventory.commands(in: group) {
            var parent = menu, key = ""
            for part in command.path {
                key += "/" + part
                if let existing = submenus[key] { parent = existing; continue }
                let holder = NSMenuItem(title: part, action: nil, keyEquivalent: ""), sub = NSMenu(title: part)
                holder.submenu = sub; parent.addItem(holder); submenus[key] = sub; parent = sub
            }
            if command.separatorBefore { parent.addItem(.separator()) }
            parent.addItem(commandItem(command))
        }
        return root
    }
    private func editItem() -> NSMenuItem {
        let root = NSMenuItem(title: "編集", action: nil, keyEquivalent: ""), menu = NSMenu(title: "編集")
        root.submenu = menu
        menu.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return root
    }
    private func extrasItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Mac独自", action: nil, keyEquivalent: ""), menu = NSMenu(title: "Mac独自")
        root.submenu = menu
        menu.addItem(item("SDカードを読み取り専用で開く…", 9001))
        menu.addItem(item("全領域の復旧走査…", 9002))
        menu.addItem(item("外部NMEAログを開く…", 9003))
        menu.addItem(.separator())
        menu.addItem(item("表示中の静止画をJPEGで書き出し…", 9010))
        menu.addItem(item("連続静止画（PNG）を書き出し…", 9011))
        menu.addItem(item("Motion JPEG AVIを書き出し…", 9012))
        menu.addItem(item("WAV音声を書き出し…", 9013))
        menu.addItem(item("KML（Google Earth対応）を書き出し…", 9014))
        menu.addItem(item("GPXを書き出し…", 9015))
        menu.addItem(.separator())
        menu.addItem(item("間隔指定のページ印刷…", 9016))
        menu.addItem(item("入力全体を新しいIMGへ複製…", 9017))
        menu.addItem(.separator())
        menu.addItem(item("16方向ビュー（Mac独自の360°表示）", 9018))
        menu.addItem(.separator())
        let viewRoot = NSMenuItem(title: "映像の操作（右クリック相当）", action: nil, keyEquivalent: ""), viewMenu = NSMenu(title: "映像の操作")
        viewRoot.submenu = viewMenu
        let viewItems: [(String, Int)] = [("標準に戻す", 501), ("範囲拡大", 502), ("移動", 503), ("回転", 504), ("左右反転", 505), ("上下反転", 506), ("前後反転", 507),
                                           ("拡大", 508), ("縮小", 509), ("時計回り（角度指定）…", 510), ("反時計回り（角度指定）…", 511),
                                           ("周囲カメラ表示調整：標準に戻す", 514), ("周囲カメラ表示調整：移動", 512), ("周囲カメラ表示調整：大きさ", 513), ("NIGHTモード", 517)]
        for (title, tag) in viewItems { viewMenu.addItem(item(title, tag)) }
        menu.addItem(viewRoot)
        menu.addItem(.separator())
        menu.addItem(item("機種指定を解除", 9030))
        menu.addItem(item("対応状況", 9005))
        menu.addItem(item("原版メニュー対応表", 9006))
        return root
    }
    private func windowItem() -> NSMenuItem {
        let root = NSMenuItem(title: "ウインドウ", action: nil, keyEquivalent: ""), menu = NSMenu(title: "ウインドウ")
        root.submenu = menu
        menu.addItem(NSMenuItem(title: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "拡大／縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = menu
        return root
    }

    // MARK: Menu lookup (used by tests and the UI check)
    static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for entry in menu.items {
            out.append(entry)
            if let sub = entry.submenu { out.append(contentsOf: allItems(in: sub)) }
        }
        return out
    }
    func menuItem(tag: Int) -> NSMenuItem? {
        guard let main = NSApp.mainMenu else { return nil }
        return Self.allItems(in: main).first { $0.tag == tag && $0.action == #selector(legacyCommand(_:)) }
    }

    // MARK: Validation and check marks
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let id = menuItem.tag
        switch id {
        case 304: menuItem.state = model.fileListVisible ? .on : .off
        case 301, 302, 303: menuItem.state = RecordListKind(commandID: id) == model.listKind ? .on : .off
        case 330...333: menuItem.state = model.sensorScale.commandID == id ? .on : .off
        case 340...344: menuItem.state = Self.singleScreenModes[id] == model.projection.mode ? .on : .off
        case 310: menuItem.state = Self.multiPictureModes.contains(model.projection.mode) ? .off : .on
        case 311: menuItem.state = model.projection.mode == .frameHistory ? .on : .off
        case 9018: menuItem.state = model.projection.mode == .grid16 ? .on : .off
        case 362: menuItem.state = model.muted ? .on : .off
        case 380: menuItem.state = model.speedUnit == .kilometersPerHour ? .on : .off
        case 384: menuItem.state = model.speedUnit == .knots ? .on : .off
        case 382: menuItem.state = model.showMap ? .on : .off
        case 383: menuItem.state = model.showMap ? .off : .on
        case 400...455: if LegacyModelCatalog.model(commandID: id) != nil { menuItem.state = model.legacyModelID == id ? .on : .off }
        case 555...559: menuItem.state = ViewCommands.displayMode(commandID: id) == model.projection.mode ? .on : .off
        default:
            if let kind = ViewCommands.kind(commandID: id) {
                if let mode = kind.mouseMode { menuItem.state = model.viewMouseMode == mode ? .on : .off }
                if kind == .night { menuItem.state = model.projection.night ? .on : .off }
            }
        }
        if let kind = ViewCommands.kind(commandID: id), kind != .closeWindow { return model.image != nil }
        if (555...559).contains(id) { return model.image != nil }
        // 画面表示: the original enables 1画面 / 16分割 only for the FDR class; for the other classes both are grayed out
        // (1画面 checked). 1画面表示 stays available on the Mac while one of its extra multi-picture views is shown.
        if id == 311 { return model.image != nil && model.frameHistoryAvailable }
        if id == 310 { return model.image != nil && (model.frameHistoryAvailable || Self.multiPictureModes.contains(model.projection.mode)) }
        if id == 9018 { return model.image != nil }
        if id == 377, model.listKind == .history { return model.historyLog != nil && !model.busy && !model.scanning }
        // ログ変換 works without a loaded recording: it converts the journal of the opened input.
        if id == 374 { return model.source != nil && !model.busy && !model.scanning }
        if Self.recordingCommands.contains(id) { return model.recording != nil && !model.busy && !model.scanning }
        switch id {
        case 307: return model.source != nil || model.index != nil
        case 9017: return model.source != nil && !model.busy && !model.scanning
        case 9002: return model.source != nil && !model.busy && !model.scanning
        default: return true
        }
    }

    // MARK: Dispatch
    @objc func legacyCommand(_ sender: NSMenuItem) { dispatch(sender.tag) }
    func dispatch(_ id: Int) {
        switch id {
        case 300: model.openPanel()
        case 301, 302, 303:
            if let kind = RecordListKind(commandID: id) { model.fileListVisible = true; model.listKind = kind }
        case 312, 313, 345, 370, 381: explain(id)
        case 304: model.fileListVisible.toggle()
        case 305: model.printFrame()
        case 306: NSApp.terminate(nil)
        case 307: model.closeData()
        case 310: model.showSingleScreen()
        case 311: model.showFrameHistory()
        case 9018: model.projection.mode = .grid16
        case 314: model.detachedPreview()
        case 330...333: if let scale = GSensorScale(commandID: id) { model.sensorScale = scale }
        case 340...344: if let mode = Self.singleScreenModes[id] { model.projection.mode = mode }
        case 350...356: model.performPlayback(commandID: id)
        case 570...576: model.performPlayback(commandID: id - 220)
        case 555...559: if let mode = ViewCommands.displayMode(commandID: id) { model.projection.mode = mode }
        case 360: model.volume = PlaybackVolume.fraction(level: PlaybackVolume.down(PlaybackVolume.level(fraction: model.volume)))
        case 361: model.volume = PlaybackVolume.fraction(level: PlaybackVolume.up(PlaybackVolume.level(fraction: model.volume)))
        case 362: model.muted.toggle()
        case 380: model.speedUnit = .kilometersPerHour
        case 384: model.speedUnit = .knots
        case 382: model.showMap = true
        case 383: model.showMap = false
        case 371: model.showRecordingSettings = true
        case 372: model.exportMovie()
        case 373: model.exportStill()
        case 374: model.openLogConversion()
        case 375: model.backup()
        case 377: if model.listKind == .history { model.openHistoryReport() } else { model.showReport = true }
        case 390: showAbout()
        case 391, 392, 393: if let url = LegacyLinks.url(commandID: id) { NSWorkspace.shared.open(url) }
        case 400...455: if LegacyModelCatalog.model(commandID: id) != nil { model.legacyModelID = id } else { explain(id) }
        case 9001: model.chooseSD()
        case 9002: model.recoveryScan()
        case 9003: model.importNMEA()
        case 9004: model.settingsTab = 0; model.showSettings = true
        case 9005: model.showCapabilities = true
        case 9006: model.showInventory = true
        case 9010: model.exportStill(jpeg: true)
        case 9011: model.exportSequence()
        case 9012: model.exportMovie(avi: true)
        case 9013: model.exportAudio()
        case 9014: model.exportLog("kml")
        case 9015: model.exportLog("gpx")
        case 9016: model.printContactSheet()
        case 9017: model.copyInputImage()
        case 9030: model.legacyModelID = 0
        default:
            if let kind = ViewCommands.kind(commandID: id) { model.performViewCommand(kind) } else { explain(id) }
        }
    }
    /// Explains a command that is blocked, refused for original-media safety, or not yet available.
    func explain(_ id: Int) {
        guard let command = LegacyMenuInventory.command(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = command.label
        alert.informativeText = "状態: \(command.status.displayName)\n\n\(command.reason)\n\nMacでの代替: \(command.macEquivalent)"
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
    }
    private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0-beta"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let text = "原版 Yupiteru PC Browser 1.9.60.0 の機能をMacへ移植中のネイティブ実装です。\nSDカード・IMG・バックアップは読み取り専用で扱い、書き出しは常に新しいファイルへ行います。\nフォーマット・録画消去・パスワード・ファームウェア更新は実装していません。"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "PC Browser Mac", .applicationVersion: version, .version: build, .credits: NSAttributedString(string: text)])
    }
}
