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
        case 330...333: menuItem.state = model.sensorScale.commandID == id ? .on : .off
        case 340...344: menuItem.state = Self.singleScreenModes[id] == model.projection.mode ? .on : .off
        case 311: menuItem.state = model.projection.mode == .grid16 ? .on : .off
        case 362: menuItem.state = model.muted ? .on : .off
        case 380: menuItem.state = model.speedUnit == .kilometersPerHour ? .on : .off
        case 384: menuItem.state = model.speedUnit == .knots ? .on : .off
        case 382: menuItem.state = model.showMap ? .on : .off
        case 383: menuItem.state = model.showMap ? .off : .on
        case 400...455: if LegacyModelCatalog.model(commandID: id) != nil { menuItem.state = model.legacyModelID == id ? .on : .off }
        default: break
        }
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
        case 301, 302, 303, 312, 313, 345, 370, 381: explain(id)
        case 304: model.fileListVisible.toggle()
        case 305: model.printFrame()
        case 306: NSApp.terminate(nil)
        case 307: model.closeData()
        case 310: if [.frontRear, .quad, .grid16].contains(model.projection.mode) { model.projection.mode = .perspective }
        case 311: model.projection.mode = .grid16
        case 314: model.detachedPreview()
        case 330...333: if let scale = GSensorScale(commandID: id) { model.sensorScale = scale }
        case 340...344: if let mode = Self.singleScreenModes[id] { model.projection.mode = mode }
        case 350: model.play(rate: 1, backwards: false)
        case 351: model.play(rate: 4, backwards: false)
        case 352: model.step(1)
        case 353: model.play(rate: 1, backwards: true)
        case 354: model.step(-1)
        case 355: model.play(rate: 4, backwards: true)
        case 356: model.pause()
        case 360: model.volume = max(0, model.volume - 0.1)
        case 361: model.volume = min(1, model.volume + 0.1)
        case 362: model.muted.toggle()
        case 380: model.speedUnit = .kilometersPerHour
        case 384: model.speedUnit = .knots
        case 382: model.showMap = true
        case 383: model.showMap = false
        case 371: model.settingsTab = 4; model.showSettings = true
        case 372: model.exportMovie()
        case 373: model.exportStill()
        case 374: model.exportLog("csv")
        case 375: model.backup()
        case 377: model.showReport = true
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
        default: explain(id)
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
