import SwiftUI
import AppKit
import PCBrowserCore

/// State of the 記録設定 sheet (the Mac counterpart of the original's recording-settings dialog 130).
/// The input image is only ever read; a save always creates a NEW image copy (`RecordingSettingsStore.writeCopy`).
@MainActor
final class RecordingSettingsEditor: ObservableObject {
    @Published var settings = RecordingSettings()
    @Published var timeEnabled = false
    @Published var pickerDate = Date()
    @Published var angleDetection = false
    /// The 「パスワード」 box as typed; empty = no password. Judged by `CardPassword.parse` like the original does on save.
    @Published var passwordText = ""
    @Published private(set) var loaded = false
    @Published private(set) var problem: String?
    @Published private(set) var commandsAvailable = false
    @Published private(set) var generation: UInt32 = 0
    @Published private(set) var backupsMatch = true
    @Published private(set) var regionsStandard = true
    /// The choice of the original's 「録画データ削除」 dialog (録画データ削除 / 記録設定データ初期化). Either one only writes a NEW image copy.
    @Published var eraseOperation = RecordingDataOperation.deleteRecordings
    /// What each operation would write to the opened image (nothing is written to compute it); empty when the image cannot be handled.
    @Published private(set) var erasePlans: [RecordingDataOperation: RecordingDataPlan] = [:]
    @Published private(set) var eraseProblem: String?
    private(set) var inputURL: URL?
    private var original = RecordingSettings()
    private var openedDate = Date()
    private var commandState: CardCommandState?

    func load(from url: URL?) {
        loaded = false; problem = nil; commandsAvailable = false; inputURL = nil; commandState = nil; erasePlans = [:]; eraseProblem = nil
        guard let url = url else {
            problem = "入力が開かれていません。カードのIMGファイルを開くと、その記録設定を読み出して新しいコピーへ書き込めます。"
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            problem = "記録設定を編集できるのは単一のIMGファイルです。SDカード・フォルダー・分割BAKを直接書き換えることはしません。"
            return
        }
        do {
            let source = try FileByteSource(url: url)
            let state = try RecordingSettingsStore.read(source)
            let commands = RecordingSettingsStore.readCommandState(source)
            let opened = try RecordingSettingsDraft(opening: state.snapshot.settings, commands: commands, now: Date())
            inputURL = url
            original = state.snapshot.settings
            settings = state.snapshot.settings
            passwordText = state.snapshot.settings.password.map(String.init) ?? ""
            commandState = commands
            commandsAvailable = commands != nil
            timeEnabled = opened.timeEnabled
            openedDate = opened.time.date() ?? Date()
            pickerDate = openedDate
            angleDetection = opened.angleDetection
            generation = state.snapshot.generation
            backupsMatch = state.backupControlMatches && state.backupChannelMatches
            regionsStandard = state.snapshot.regionsAreStandard
            var plans: [RecordingDataOperation: RecordingDataPlan] = [:]
            for operation in RecordingDataOperation.allCases {
                do { plans[operation] = try RecordingDataEraser.plan(source, operation: operation) } catch { eraseProblem = error.localizedDescription }
            }
            erasePlans = plans
            if !plans.isEmpty { eraseProblem = nil }
            loaded = true
        } catch {
            problem = "このIMGの記録設定を読み出せません: " + error.localizedDescription
        }
    }

    var passwordEntry: CardPassword.Entry { CardPassword.parse(passwordText) }
    /// The settings as edited, including what the password box holds (an invalid box counts as no password and blocks saving).
    var currentSettings: RecordingSettings {
        var s = settings
        s.password = passwordEntry.value
        return s
    }
    var draft: RecordingSettingsDraft? {
        guard let t = try? CardLocalTime(date: pickerDate) else { return nil }
        return RecordingSettingsDraft(settings: currentSettings, timeEnabled: timeEnabled, time: t, angleDetection: angleDetection)
    }
    var pickerText: String { (try? CardLocalTime(date: pickerDate).text) ?? "—" }
    var changeLines: [String] { draft?.summary(against: original, commands: commandState) ?? [] }
    var layoutChanged: Bool { settings.changesLayout(from: original) }
    var validationMessage: String? {
        if let message = passwordEntry.message { return message }
        do { try currentSettings.normalized().validate(); return nil } catch { return error.localizedDescription }
    }
    var canSave: Bool { loaded && validationMessage == nil && !changeLines.isEmpty }
    var frameRateChoices: [Int] { RecordingSettingsTables.availableFrameRateIndices(for: settings.mode) }

    var modeBinding: Binding<RecordingSettings.Mode> {
        Binding(get: { self.settings.mode }, set: { self.settings.setMode($0) })
    }
    func sensitivityBinding(_ keyPath: WritableKeyPath<RecordingSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(self.settings[keyPath: keyPath]) }, set: { self.settings[keyPath: keyPath] = Int($0.rounded()) })
    }
    var easySensitivityBinding: Binding<Double> {
        Binding(get: { Double(self.settings.shockSensitivity) }, set: { self.settings.setEasySensitivity(Int($0.rounded())) })
    }

    /// 「初期設定に戻す」 as the original does it: the recording settings go to the dialog defaults and both command rows are unticked;
    /// SDカードID, パスワード and マルチバッテリー stay as they are.
    func resetToDialogDefaults() {
        settings = currentSettings.resettingToDialogDefaults()
        timeEnabled = false
        angleDetection = false
    }
    func revert() {
        settings = original
        passwordText = original.password.map(String.init) ?? ""
        timeEnabled = commandState?.timeFileExists ?? false
        pickerDate = openedDate
        angleDetection = commandState?.angleDetectionRequested ?? false
    }
    func setNow() { pickerDate = Date() }

    /// What the chosen operation would do to the opened image, one line (generation step, regions that disappear, settings that change).
    func erasePreview(_ operation: RecordingDataOperation) -> String? {
        guard let plan = erasePlans[operation] else { return nil }
        var text = plan.changes.joined(separator: "、")
        if plan.loadedRegions.isEmpty {
            text += "。一覧に表示されている録画区画はありません"
        } else {
            text += "。一覧から非表示になる区画: " + plan.loadedRegions.map(\.label).joined(separator: "・")
        }
        return text
    }

    /// 「録画データ削除」 as the original runs it: the first confirmation (OK／キャンセル), for 記録設定データ初期化 also the second one
    /// (はい／いいえ), then the four management sectors are written. Here they are written into a NEW image copy; no recorded data is erased
    /// (the original does not erase either: it raises the generation byte and the region counters, which hides the older recordings).
    func erase(model: BrowserModel) {
        guard let url = inputURL, erasePlans[eraseOperation] != nil else { return }
        let operation = eraseOperation
        guard PasswordPrompts.proceed(title: "記録設定", message: operation.confirmation) else { return }
        if let warning = operation.settingsChangedWarning {
            guard PasswordPrompts.confirm(title: "録画データ削除", message: warning) else { return }
        }
        guard let output = model.destination("PCBrowser-\(operation.rawValue)-copy", extension: "img") else { return }
        model.performExport(operation.title + "コピーの作成") { flag, progress in
            let summary = try RecordingDataEraser.writeCopy(of: url, to: output, operation: operation, cancelled: { flag.cancelled }, progress: progress)
            let how = summary.usedClone ? "APFSクローン" : "全体コピー"
            let note = operation.completion + "（新しいコピー: " + output.lastPathComponent + "・" + how + "・読み戻し検証済み。録画データ本体は消去せず、世代番号で非表示にしています）"
            await MainActor.run { model.cardNotice = note }
        }
    }

    /// Like the original, closing with unsaved changes asks first (here: unsaved = not yet written to a new copy).
    func confirmDiscardIfNeeded() -> Bool {
        guard loaded, !changeLines.isEmpty else { return true }
        return PasswordPrompts.confirm(title: "記録設定", message: "設定が変更されています。\n新しいコピーへ保存せずに終了してよろしいですか？")
    }

    func save(model: BrowserModel) {
        guard let url = inputURL, let current = draft else { return }
        if let message = validationMessage { model.errorMessage = message; return }
        // The original's password steps come first: a new or changed password is typed again, clearing it is confirmed.
        switch current.passwordCheck(against: original) {
        case .none: break
        case .reenter(let expected):
            guard let typed = PasswordPrompts.ask(message: CardPassword.Message.reenter) else { return }
            guard CardPassword.confirms(typed, expected: expected) else { PasswordPrompts.showError(CardPassword.Message.wrong); return }
        case .confirmClear:
            guard PasswordPrompts.confirm(title: "パスワード", message: CardPassword.Message.confirmClear) else { return }
        }
        let files = current.commandFiles(from: commandState)
        let settingsChanged = !current.settings.normalized().differences(from: original.normalized()).isEmpty
        if settingsChanged && current.settings.changesLayout(from: original) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "記録区画の構成が変わります"
            alert.informativeText = "録画方法・履歴記録の変更は、常時／イベント／履歴の区画テーブルを書き換えます。原版はこのとき録画データの消去を確認します。この版は録画データを消去せず、新しいIMGコピーの管理領域だけを更新します。元のIMG・SDカードは変更しません。区画が変わるため、コピー内の既存録画は正しく表示されない場合があります。"
            alert.addButton(withTitle: "新しいコピーを作る")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let output = model.destination("PCBrowser-settings-copy", extension: "img") else { return }
        let requested: RecordingSettings? = settingsChanged ? current.settings : nil
        model.performExport("記録設定コピーの作成") { flag, progress in
            let summary = try RecordingSettingsStore.writeCopy(of: url, to: output, new: requested, commandFiles: files,
                                                               cancelled: { flag.cancelled }, progress: progress)
            let how = summary.usedClone ? "APFSクローン" : "全体コピー"
            let note = "新しい記録設定コピーを作成しました（" + how + "・読み戻し検証済み）: " + output.lastPathComponent
            await MainActor.run { model.cardNotice = note }
        }
    }
}

struct RecordingSettingsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var editor: RecordingSettingsEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("記録設定").font(.title2)
                Spacer()
                Button("閉じる") { if editor.confirmDiscardIfNeeded() { dismiss() } }.keyboardShortcut(.cancelAction)
            }
            if let problem = editor.problem {
                SettingsHelp(problem)
                Spacer()
            } else if editor.loaded {
                ScrollView { form }
                footer
            } else {
                ProgressView("読み込み中…")
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 680, height: 760)
        .onAppear { editor.load(from: model.sourceURL) }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).frame(width: 170, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHelp("入力のIMGは読み取り専用で開いています。変更は「新しいコピーに保存」で作る別のIMGにだけ書き込み、元のIMG・マウント中のSDカードには書き込みません。カードの設定領域はQ-01系の1チャンネル構成で検証した形式のみ対応し、未知の構成は書き込まず拒否します。")
            SettingsGroup("録画方法") {
                labeled("録画方法") {
                    Picker("録画方法", selection: editor.modeBinding) {
                        ForEach(RecordingSettings.Mode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
                }
                labeled("録画コマ数") {
                    Picker("録画コマ数", selection: $editor.settings.frameRateIndex) {
                        ForEach(editor.frameRateChoices, id: \.self) { index in Text(RecordingSettingsTables.frameRates[index].label).tag(index) }
                    }.labelsHidden().frame(width: 200)
                }
                if editor.settings.mode == .eventOnly {
                    SettingsHelp("イベント記録のみのときは、1コマ/秒より遅い録画コマ数は選べません（原版と同じ）。")
                }
                labeled("イベント記録時間") {
                    Picker("イベント記録時間", selection: $editor.settings.eventWindowIndex) {
                        ForEach(Array(RecordingSettingsTables.eventWindows.enumerated()), id: \.offset) { pair in Text(pair.element.label).tag(pair.offset) }
                    }.labelsHidden().frame(width: 260).disabled(editor.settings.mode == .continuousOnly)
                }
                labeled("音声") { Toggle("音声を記録する", isOn: $editor.settings.audioEnabled) }
            }
            SettingsGroup("履歴記録") {
                labeled("履歴記録時間") {
                    Picker("履歴記録時間", selection: $editor.settings.historyHoursIndex) {
                        ForEach(Array(RecordingSettingsTables.historyHours.enumerated()), id: \.offset) { pair in Text("\(pair.element)時間").tag(pair.offset) }
                    }.labelsHidden().frame(width: 160)
                }
                labeled("履歴記録コマ数") { Toggle("2倍（1秒に2件）で記録する", isOn: $editor.settings.historyDoubleRate) }
            }
            SettingsGroup("上書き（循環録画）") {
                Toggle("常時録画を上書きする", isOn: $editor.settings.overwriteContinuous).disabled(editor.settings.mode == .eventOnly)
                Toggle("イベント録画を上書きする", isOn: $editor.settings.overwriteEvent).disabled(editor.settings.mode == .continuousOnly)
                Toggle("履歴記録を上書きする", isOn: $editor.settings.overwriteHistory)
            }
            SettingsGroup("本体") {
                Toggle("ビープ音を鳴らす", isOn: $editor.settings.beepEnabled)
                Toggle("マルチバッテリーを接続している", isOn: $editor.settings.multiBatteryConnected)
                labeled("SDカードID") {
                    TextField("半角24文字以内", text: $editor.settings.cardID).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                labeled("パスワード") {
                    TextField("1000～9999（空欄 = なし）", text: $editor.passwordText).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                SettingsHelp("4桁のパスワードを設定したカードは、原版・この版とも開くときにパスワードを求め、違うと読み込みません（録画データは暗号化されません）。設定・変更の保存前にもう一度入力して確認し、空欄にして解除するときも確認します。")
            }
            SettingsGroup("Gセンサー") {
                Toggle("Gセンサーを記録する", isOn: $editor.settings.gSensorEnabled)
                Toggle("簡単設定（感度を1つで指定）", isOn: $editor.settings.easyMode).disabled(!editor.settings.gSensorEnabled)
                if editor.settings.easyMode && editor.settings.gSensorEnabled {
                    sensitivityRow("感度", editor.easySensitivityBinding)
                } else {
                    sensitivityRow("衝撃感度", editor.sensitivityBinding(\.shockSensitivity))
                    sensitivityRow("急発進・急ブレーキ感度", editor.sensitivityBinding(\.accelerationSensitivity))
                    sensitivityRow("急ハンドル感度", editor.sensitivityBinding(\.steeringSensitivity))
                }
                if !editor.settings.gSensorEnabled {
                    SettingsHelp("Gセンサーを記録しない設定では、カードに感度は保存されません（原版と同じ）。")
                }
            }
            SettingsGroup("日時・設置角度（CONFIGフォルダーの指示ファイル）") {
                if !editor.commandsAvailable {
                    SettingsHelp("このIMGにはFAT16のCONFIGフォルダーが見つからないため、日時設定と設置角度検出は変更できません。")
                }
                HStack(spacing: 10) {
                    Toggle("日時を設定する", isOn: $editor.timeEnabled)
                    DatePicker("日時", selection: $editor.pickerDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden().disabled(!editor.timeEnabled)
                    Button("現在時刻") { editor.setNow() }.disabled(!editor.timeEnabled)
                }.disabled(!editor.commandsAvailable)
                Text("書き込む値: " + editor.pickerText + "（CONFIG/TIME.INI）").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Toggle("設置角度検出を実行", isOn: $editor.angleDetection).disabled(!editor.commandsAvailable)
                SettingsHelp("原版が作るのと同じ内容の TIME.INI（[SET] と LOCALTIME）／空の SELFADJ.INI を新しいコピーの CONFIG に作成・削除します。実際のレコーダーがこれらをどう扱うかは、ここでは検証できていません。")
            }
            SettingsGroup("録画データ削除・初期化（新しいコピーへ）") {
                Picker("操作", selection: $editor.eraseOperation) {
                    ForEach(RecordingDataOperation.allCases, id: \.self) { operation in Text(operation.title).tag(operation) }
                }.pickerStyle(.radioGroup).labelsHidden()
                if let preview = editor.erasePreview(editor.eraseOperation) {
                    Text("書き込む内容: " + preview).font(.caption).fixedSize(horizontal: false, vertical: true)
                } else if let problem = editor.eraseProblem {
                    SettingsHelp("このIMGでは実行できません: " + problem)
                }
                HStack {
                    Button("実行…") { editor.erase(model: model) }.disabled(editor.erasePlans[editor.eraseOperation] == nil || model.busy)
                    Spacer(minLength: 0)
                }
                SettingsHelp("原版の「録画データ削除」と同じ4つの管理セクター（管理・チャンネル設定とそれぞれのバックアップ）だけを、新しいIMGコピーに書き込みます。原版も録画データ本体は消さず、世代番号を上げて古い録画を一覧から外します。この版でも消去はせず、コピーの一覧からは非表示になり、復旧走査（--recovery-scan）では残りのデータを参照できます。「記録設定データ初期化」は録画設定を初期値に戻し、パスワードを解除します（SDカードIDは残ります）。元のIMG・SDカードには一切書き込みません。")
            }
            SettingsGroup("カードの状態") {
                Text("管理領域の世代: \(editor.generation)").font(.caption).monospacedDigit()
                Text(editor.regionsStandard ? "記録区画: 原版の標準配置" : "記録区画: 標準配置と異なる（区画を変える保存は拒否されます）").font(.caption)
                if !editor.backupsMatch {
                    Text("バックアップ管理セクターが現在の設定と一致していません。保存すると両方を同じ内容にそろえます。").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func sensitivityRow(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 170, alignment: .leading)
            Slider(value: value, in: 1...9, step: 1).frame(width: 260)
            Text(String(format: "%.0f", value.wrappedValue)).monospacedDigit().frame(width: 24, alignment: .trailing)
            Spacer(minLength: 0)
        }.disabled(!editor.settings.gSensorEnabled)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let message = editor.validationMessage {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if editor.changeLines.isEmpty {
                Text("変更はありません").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("変更: " + editor.changeLines.joined(separator: "、")).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if editor.layoutChanged {
                Text("記録区画の構成が変わります。保存前に確認を表示します。").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("初期設定に戻す") { editor.resetToDialogDefaults() }
                Button("変更を取り消す") { editor.revert() }
                Spacer()
                Button("新しいコピーに保存…") { editor.save(model: model) }
                    .keyboardShortcut(.defaultAction).disabled(!editor.canSave || model.busy)
            }
        }
    }
}
