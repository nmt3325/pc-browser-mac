import Foundation
import PCBrowserCore

/// Command-line twin of the 記録設定 sheet.
///
/// `--settings-show <image> [--report <new.json>]` prints the recording settings stored in a card IMAGE (read-only).
/// `--settings-apply <image> --out <new.img> [--set key=value …] [--report <new.json>]` writes a NEW copy of the image with the changed
/// settings (and/or command files); `--plan-only <new.json>` writes the plan instead (four sector hashes, no copy).
/// The input is never opened for writing, and cards or mounted volumes are never written.
/// `--password-check <image> [--card-password <text>]` runs the card-open gate of the app on an image (exit 0 = would load, 1 = refused).
/// `--set reset=defaults` is the dialog's 「初期設定に戻す」 (card ID, password and multi-battery are kept; later `--set` keys override).
/// A new or changed password needs `--confirm-password <same>` and clearing one needs `--confirm-clear-password`, like the dialog's prompts.
enum SettingsCLI {
    struct Failure: Error { let message: String }

    static func values(_ name: String, in args: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == name, i + 1 < args.count { result.append(args[i + 1]); i += 2 } else { i += 1 }
        }
        return result
    }
    static func flag(_ text: String, _ key: String) throws -> Bool {
        switch text.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: throw Failure(message: "\(key) には on / off を指定してください（\(text)）")
        }
    }
    static func integer(_ text: String, _ key: String) throws -> Int {
        guard let v = Int(text) else { throw Failure(message: "\(key) には整数を指定してください（\(text)）") }
        return v
    }
    static func modeName(_ m: RecordingSettings.Mode) -> String {
        switch m {
        case .continuousOnly: return "continuous"
        case .eventOnly: return "event"
        case .continuousAndEvent: return "both"
        }
    }
    static func parseMode(_ text: String) throws -> RecordingSettings.Mode {
        switch text.lowercased() {
        case "continuous", "continuous-only", "0": return .continuousOnly
        case "event", "event-only", "1": return .eventOnly
        case "both", "continuous-event", "2": return .continuousAndEvent
        default: throw Failure(message: "mode には continuous / event / both を指定してください（\(text)）")
        }
    }
    static func parseTime(_ text: String, now: Date) throws -> CardTimeRequest {
        switch text.lowercased() {
        case "keep": return .keep
        case "none", "off", "remove": return .remove
        case "now": return .set(try CardLocalTime(date: now))
        default:
            let normalized = text.replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "T", with: ";").replacingOccurrences(of: " ", with: ";")
            guard let t = CardLocalTime.parse(normalized) else {
                throw Failure(message: "time には now / none / YYYY-MM-DDTHH:MM:SS を指定してください（\(text)）")
            }
            return .set(t)
        }
    }

    struct Request {
        var settings: RecordingSettings
        var time: CardTimeRequest = .keep
        var angle: CardAngleRequest = .keep
        /// `reset=defaults` was given: like 「初期設定に戻す」 it also unticks the date and angle rows (where the image has a CONFIG folder).
        var resetRows = false
    }
    static func apply(_ pairs: [String], to base: RecordingSettings, now: Date) throws -> Request {
        var request = Request(settings: base)
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else { throw Failure(message: "--set には key=value を指定してください（\(pair)）") }
            let key = String(pair[pair.startIndex..<eq])
            let value = String(pair[pair.index(after: eq)...])
            switch key {
            case "mode": request.settings.setMode(try parseMode(value))
            case "fps": request.settings.frameRateIndex = try integer(value, key)
            case "event": request.settings.eventWindowIndex = try integer(value, key)
            case "audio": request.settings.audioEnabled = try flag(value, key)
            case "history-hours":
                let v = try integer(value, key)
                request.settings.historyHoursIndex = RecordingSettingsTables.historyHours.firstIndex(of: v) ?? v
            case "history-rate":
                switch value.lowercased() {
                case "normal", "0": request.settings.historyDoubleRate = false
                case "double", "1": request.settings.historyDoubleRate = true
                default: throw Failure(message: "history-rate には normal / double を指定してください（\(value)）")
                }
            case "overwrite-continuous": request.settings.overwriteContinuous = try flag(value, key)
            case "overwrite-event": request.settings.overwriteEvent = try flag(value, key)
            case "overwrite-history": request.settings.overwriteHistory = try flag(value, key)
            case "beep": request.settings.beepEnabled = try flag(value, key)
            case "gsensor": request.settings.gSensorEnabled = try flag(value, key)
            case "battery": request.settings.multiBatteryConnected = try flag(value, key)
            case "easy": request.settings.easyMode = try flag(value, key)
            case "sensitivity": request.settings.setEasySensitivity(try integer(value, key))
            case "shock": request.settings.shockSensitivity = try integer(value, key)
            case "accel": request.settings.accelerationSensitivity = try integer(value, key)
            case "steering": request.settings.steeringSensitivity = try integer(value, key)
            case "id": request.settings.cardID = value
            case "reset":
                guard value.lowercased() == "defaults" else { throw Failure(message: "reset には defaults を指定してください（\(value)）") }
                request.settings = request.settings.resettingToDialogDefaults()
                request.resetRows = true
            case "password":
                let entry = CardPassword.parse(["none", "off", "clear"].contains(value.lowercased()) ? "" : value)
                if let message = entry.message { throw Failure(message: message) }
                request.settings.password = entry.value
            case "time": request.time = try parseTime(value, now: now)
            case "angle": request.angle = try flag(value, key) ? .request : .cancel
            default: throw Failure(message: "未対応のキーです: \(key)")
            }
        }
        return request
    }

    static func describe(_ s: RecordingSettings) -> [String: Any] {
        var d: [String: Any] = [
            "mode": modeName(s.mode), "frameRateIndex": s.frameRateIndex, "eventWindowIndex": s.eventWindowIndex, "audio": s.audioEnabled,
            "historyHoursIndex": s.historyHoursIndex, "historyDoubleRate": s.historyDoubleRate,
            "overwriteContinuous": s.overwriteContinuous, "overwriteEvent": s.overwriteEvent, "overwriteHistory": s.overwriteHistory,
            "beep": s.beepEnabled, "gSensor": s.gSensorEnabled, "multiBattery": s.multiBatteryConnected, "easyMode": s.easyMode,
            "shockSensitivity": s.shockSensitivity, "accelerationSensitivity": s.accelerationSensitivity, "steeringSensitivity": s.steeringSensitivity,
            "cardID": s.cardID]
        if let password = s.password { d["password"] = password } else { d["password"] = NSNull() }
        if RecordingSettingsTables.frameRates.indices.contains(s.frameRateIndex) { d["frameRate"] = RecordingSettingsTables.frameRates[s.frameRateIndex].label }
        if RecordingSettingsTables.eventWindows.indices.contains(s.eventWindowIndex) { d["eventWindow"] = RecordingSettingsTables.eventWindows[s.eventWindowIndex].label }
        if RecordingSettingsTables.historyHours.indices.contains(s.historyHoursIndex) { d["historyHours"] = RecordingSettingsTables.historyHours[s.historyHoursIndex] }
        return d
    }
    static func describe(_ state: CardCommandState?, source: any ByteSource) -> [String: Any] {
        guard let s = state else { return ["available": false, "reason": RecordingSettingsStore.commandFilesUnavailableReason(source) ?? "理由不明"] }
        var d: [String: Any] = ["available": true, "timeFileExists": s.timeFileExists, "angleDetectionRequested": s.angleDetectionRequested]
        if let t = s.time { d["time"] = t.text }
        return d
    }
    static func describe(_ files: [CardCommandFile]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for file in files {
            var row: [String: Any] = ["action": file.action, "path": file.path]
            if let c = file.contents { row["bytes"] = c.count; row["text"] = String(decoding: c, as: UTF8.self) }
            rows.append(row)
        }
        return rows
    }
    static func describe(_ patches: [SettingsSectorPatch]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for p in patches {
            let row: [String: Any] = ["role": p.role.rawValue, "sector": p.sector, "changed": p.old != p.new, "oldSHA256": p.oldSHA256, "newSHA256": p.newSHA256]
            rows.append(row)
        }
        return rows
    }
    static func write(_ payload: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }
    static func fail(_ error: Error) -> Int32 {
        let text = (error as? Failure)?.message ?? error.localizedDescription
        FileHandle.standardError.write(Data((text + "\n").utf8))
        return 1
    }

    static func show(_ args: [String]) -> Int32 {
        do {
            guard let path = InspectionCLI.value("--settings-show", in: args) else { return 64 }
            let source = try FileByteSource(url: URL(fileURLWithPath: path))
            let state = try RecordingSettingsStore.read(source)
            var payload: [String: Any] = [
                "settings": describe(state.snapshot.settings), "regionsAreStandard": state.snapshot.regionsAreStandard,
                "generation": Int(state.snapshot.generation), "backupControlMatches": state.backupControlMatches,
                "backupChannelMatches": state.backupChannelMatches, "commandFiles": describe(RecordingSettingsStore.readCommandState(source), source: source)]
            payload["locationSectors"] = [state.location.control, state.location.channel, state.location.backupControl, state.location.backupChannel]
            let s = state.snapshot.settings
            print("mode=\(modeName(s.mode)) fps=\(s.frameRateIndex) event=\(s.eventWindowIndex) audio=\(s.audioEnabled) history=\(s.historyHoursIndex)/\(s.historyDoubleRate ? "double" : "normal") id=\(s.cardID) password=\(s.password == nil ? "none" : "set")")
            if let report = InspectionCLI.value("--report", in: args) { try write(payload, to: report) }
            return 0
        } catch { return fail(error) }
    }

    /// The app's card-open gate on an image: a card with a password loads only with the right `--card-password`.
    static func passwordCheck(_ args: [String]) -> Int32 {
        do {
            guard let path = InspectionCLI.value("--password-check", in: args) else { return 64 }
            let source = try FileByteSource(url: URL(fileURLWithPath: path))
            guard let stored = CardPassword.required(in: source) else { print("locked=false load=allowed"); return 0 }
            guard let typed = InspectionCLI.value("--card-password", in: args) else { print("locked=true load=refused (no password given)"); return 1 }
            if CardPassword.unlocks(typed, stored: stored) { print("locked=true load=allowed"); return 0 }
            print("locked=true load=refused (" + CardPassword.Message.wrong + ")")
            return 1
        } catch { return fail(error) }
    }

    static func run(_ args: [String]) -> Int32 {
        do {
            guard let path = InspectionCLI.value("--settings-apply", in: args) else { return 64 }
            let input = URL(fileURLWithPath: path)
            let now = Date()
            let source = try FileByteSource(url: input)
            let state = try RecordingSettingsStore.read(source)
            var request = try apply(values("--set", in: args), to: state.snapshot.settings, now: now)
            let commandState = RecordingSettingsStore.readCommandState(source)
            if request.resetRows, commandState != nil {
                if request.time == .keep { request.time = .remove }
                if request.angle == .keep { request.angle = .cancel }
            }
            var actions: [CardCommandFile] = []
            if request.time != .keep || request.angle != .keep {
                guard let current = commandState else { throw Failure(message: "このイメージのFAT16設定領域（CONFIGフォルダー）を読めないため、日時・角度検出の指定はできません（\(RecordingSettingsStore.commandFilesUnavailableReason(source) ?? "理由不明")）") }
                actions = CardCommandFile.actions(from: current, time: request.time, angle: request.angle)
            }
            let plan = try RecordingSettingsStore.plan(source, new: request.settings)
            var payload: [String: Any] = [
                "input": input.lastPathComponent, "before": describe(plan.before), "after": describe(plan.after), "changes": plan.changes,
                "layoutChanged": plan.layoutChanged, "regionsAreStandard": state.snapshot.regionsAreStandard, "generationBefore": Int(state.snapshot.generation),
                "changesSectors": plan.changesAnything, "patches": describe(plan.patches), "commandState": describe(commandState, source: source), "commandActions": describe(actions)]
            if let planPath = InspectionCLI.value("--plan-only", in: args) {
                try write(payload, to: planPath)
                print(plan.changesAnything || !actions.isEmpty ? "plan written" : "nothing to change")
                return 0
            }
            switch CardPassword.Change.required(old: state.snapshot.settings.password, new: request.settings.password) {
            case .none: break
            case .reenter(let expected):
                guard let typed = InspectionCLI.value("--confirm-password", in: args) else {
                    throw Failure(message: CardPassword.Message.reenter.replacingOccurrences(of: "\n", with: " ") + "（--confirm-password に同じパスワードを指定）")
                }
                guard CardPassword.confirms(typed, expected: expected) else { throw Failure(message: CardPassword.Message.wrong) }
            case .confirmClear:
                guard args.contains("--confirm-clear-password") else {
                    throw Failure(message: CardPassword.Message.confirmClear.replacingOccurrences(of: "\n", with: " ") + "（--confirm-clear-password で確認）")
                }
            }
            guard let out = InspectionCLI.value("--out", in: args) else { throw Failure(message: "--out <新しいイメージ> を指定してください（入力は書き換えません）") }
            let summary = try RecordingSettingsStore.writeCopy(of: input, to: URL(fileURLWithPath: out), new: request.settings, commandFiles: actions, now: now)
            let outputInfo: [String: Any] = ["name": URL(fileURLWithPath: out).lastPathComponent, "usedClone": summary.usedClone, "verified": summary.verified]
            payload["output"] = outputInfo
            if let report = InspectionCLI.value("--report", in: args) { try write(payload, to: report) }
            print("written (clone=\(summary.usedClone), verified=\(summary.verified))")
            return 0
        } catch { return fail(error) }
    }
}
