import Foundation
import Darwin

/// The two actions of the original's 「録画データ削除」 dialog (radio buttons 録画データ削除 / 記録設定データ初期化).
/// Neither erases recorded data: the original writes four sectors (control, channel, and their two backups) that raise the card
/// generation and the region counters, which hides every recording older than the operation from its readers.
/// This port performs them only on a NEW image copy (`RecordingDataEraser.writeCopy`); see docs/recording-data-operations.md.
public enum RecordingDataOperation: String, Sendable, CaseIterable {
    case deleteRecordings = "delete"
    case initializeSettings = "initialize"

    public var title: String {
        switch self {
        case .deleteRecordings: return "録画データ削除"
        case .initializeSettings: return "記録設定データ初期化"
        }
    }
    /// The original's first confirmation (title 記録設定, OK／キャンセル).
    public var confirmation: String {
        switch self {
        case .deleteRecordings: return "録画データの削除を行います。\nよろしいですか？"
        case .initializeSettings: return "録画データの削除、\n記録設定データの初期化を行います。\nよろしいですか？"
        }
    }
    /// The second confirmation the original raises when the operation changes the stored settings (title 録画データ削除, はい／いいえ).
    public var settingsChangedWarning: String? {
        switch self {
        case .deleteRecordings: return nil
        case .initializeSettings: return "設定が変更されたため録画データが削除されます。続行しますか？"
        }
    }
    /// The completion message (title 記録設定).
    public var completion: String {
        switch self {
        case .deleteRecordings: return "録画データの削除が完了しました。"
        case .initializeSettings: return "記録設定データの初期化が完了しました。"
        }
    }
    public init?(name: String) {
        switch name.lowercased() {
        case "delete", "deleterecordings", "削除": self = .deleteRecordings
        case "initialize", "initialise", "init", "初期化": self = .initializeSettings
        default: return nil
        }
    }
}

public struct RecordingDataPlan: Sendable {
    public let operation: RecordingDataOperation
    public let before: GenerationState
    public let after: GenerationState
    /// Regions whose newest generation was read from a visible head: their counter becomes that generation + 1.
    public let loadedRegions: [RecordingRegionKind]
    /// Regions that were hidden before the operation (older operation or stale data).
    public let hiddenBefore: [HiddenRegion]
    public let settingsBefore: RecordingSettings
    public let settingsAfter: RecordingSettings
    public let changes: [String]
    public let patches: [SettingsSectorPatch]
    public var changesAnything: Bool { patches.contains { $0.old != $0.new } }
}

public struct RecordingDataWriteSummary: Sendable {
    public let plan: RecordingDataPlan
    public let usedClone: Bool
    public let verified: Bool
}

public enum RecordingDataEraser {
    /// Computes the four sectors the original would write, without writing anything.
    public static func plan(_ source: any ByteSource, operation: RecordingDataOperation) throws -> RecordingDataPlan {
        let state = try RecordingSettingsStore.read(source), loc = state.location
        let c = try source.read(at: loc.control * 512, count: 512), ch = try source.read(at: loc.channel * 512, count: 512)
        let bc = try source.read(at: loc.backupControl * 512, count: 512), bch = try source.read(at: loc.backupChannel * 512, count: 512)
        let marker = Data(RecordingSettingsCodec.marker)
        guard bc.subdata(in: 1..<18) == marker, bc.subdata(in: 0x1EC..<0x1FD) == marker else {
            throw BrowserError.unsupported("バックアップ管理セクターが見つからないため、書き込み先を特定できません")
        }
        let block = RecordingSettingsCodec.Offset.recordBlockStart..<RecordingSettingsCodec.Offset.recordBlockEnd
        guard bch.subdata(in: block) == ch.subdata(in: block) else { throw BrowserError.unsupported("バックアップのチャンネル設定セクターが一致しないため書き込めません") }
        guard let before = RecordingGeneration.state(control: [UInt8](c), channel: [UInt8](ch)) else {
            throw BrowserError.unsupported("世代番号を読み取れません（管理セクターの世代番号またはチェックサムが、この版の確認した形式ではありません）")
        }
        guard before.generation < 255 else { throw BrowserError.unsupported("世代番号が上限（255）に達しているため処理できません") }
        let heads = RecordingGeneration.heads(in: source, control: [UInt8](c))
        let hidden = RecordingGeneration.evaluate(state: before, heads: heads)
        let loaded = heads.filter { head in !hidden.contains { $0.kind == head.kind } }
        let nextGeneration = before.generation + 1
        var counters = before.counters
        for kind in RecordingRegionKind.allCases {
            if let head = loaded.first(where: { $0.kind == kind }) {
                counters[kind.rawValue] = head.generation &+ 1
            } else {
                // Nothing was loaded there: the counter only has to catch up with the new generation, never go backwards.
                counters[kind.rawValue] = max(before.counter(kind), UInt32(nextGeneration))
            }
        }
        let after = GenerationState(generation: nextGeneration, counters: counters)

        var newControl = [UInt8](c), newChannel = [UInt8](ch)
        var settingsAfter = state.snapshot.settings
        var changes: [String] = []
        if operation == .initializeSettings {
            settingsAfter = state.snapshot.settings.resettingForInitialization()
            let edit = try RecordingSettingsCodec.apply(settingsAfter, control: c, channel: ch, forceStandardLayout: true)
            newControl = [UInt8](edit.control); newChannel = [UInt8](edit.channel)
            // The original leaves the second multi-battery byte alone while it resets the first.
            newControl[RecordingSettingsCodec.Offset.batteryB] = [UInt8](c)[RecordingSettingsCodec.Offset.batteryB]
            settingsAfter = edit.settings
            changes = edit.changes
        }
        newControl[RecordingSettingsCodec.Offset.generation] = nextGeneration
        newControl[RecordingSettingsCodec.Offset.generationTail] = nextGeneration
        for (index, offset) in RecordingSettingsCodec.Offset.generationCounters.enumerated() { RecordingSettingsCodec.setCounter(counters[index], offset, into: &newControl) }
        let sum = RecordingSettingsCodec.checksum(control: newControl, channels: [newChannel])
        newControl[RecordingSettingsCodec.Offset.checksum] = UInt8(sum & 0xFF); newControl[RecordingSettingsCodec.Offset.checksum + 1] = UInt8(sum >> 8)
        changes.append("世代番号 \(before.generation)→\(nextGeneration)")

        let patches = [SettingsSectorPatch(role: .control, sector: loc.control, old: c, new: Data(newControl)),
                       SettingsSectorPatch(role: .channel, sector: loc.channel, old: ch, new: Data(newChannel)),
                       SettingsSectorPatch(role: .controlBackup, sector: loc.backupControl, old: bc, new: Data(newControl)),
                       SettingsSectorPatch(role: .channelBackup, sector: loc.backupChannel, old: bch, new: Data(newChannel))]
        return RecordingDataPlan(operation: operation, before: before, after: after, loadedRegions: loaded.map(\.kind), hiddenBefore: hidden,
                                 settingsBefore: state.snapshot.settings, settingsAfter: settingsAfter, changes: changes, patches: patches)
    }

    /// Creates a NEW image that is a copy of `input` with the four sectors of the operation replaced. The input is never opened for
    /// writing; cards, mounted volumes and existing files are refused (`WriteGuard`). The copy is read back and verified, including that every
    /// region that was listed before is now hidden by the generation rule.
    public static func writeCopy(of input: URL, to output: URL, operation: RecordingDataOperation, preferClone: Bool = true,
                                 cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> RecordingDataWriteSummary {
        let decision = WriteGuard.checkNewOutput(output, protecting: [input])
        guard decision.isAllowed else { throw BrowserError.invalid(decision.reason ?? "書き出し先が不正です") }
        let source = try FileByteSource(url: input)
        let plan = try RecordingDataEraser.plan(source, operation: operation)
        var usedClone = false
        if preferClone, Darwin.clonefile(input.path, output.path, 0) == 0 {
            usedClone = true
        } else {
            _ = try ImageCopy.write(source: source, to: output, cancelled: cancelled, progress: progress)
        }
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: output) } }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let fd = Darwin.open(output.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BrowserError.io("コピーを書き込み用に開けません: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        for patch in plan.patches {
            let current = try RecordingSettingsStore.preadExactly(fd: fd, offset: patch.sector * 512, count: 512)
            guard current == patch.old else { throw BrowserError.io("コピー内の管理セクターが読み取り時と異なります。処理を中止しました") }
        }
        for patch in plan.patches where patch.old != patch.new { try RecordingSettingsStore.pwriteAll(fd: fd, data: patch.new, offset: patch.sector * 512) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw BrowserError.io("コピーの書き込みを確定できません") }
        let written = try FileByteSource(url: output)
        for patch in plan.patches { guard try written.read(at: patch.sector * 512, count: 512) == patch.new else { throw BrowserError.io("コピーの読み戻し検証に失敗しました") } }
        let reread = try RecordingSettingsStore.read(written)
        guard reread.snapshot.settings == plan.settingsAfter else { throw BrowserError.io("コピーから読み直した録画設定が想定と一致しません") }
        let control = try written.read(at: reread.location.control * 512, count: 512), channel = try written.read(at: reread.location.channel * 512, count: 512)
        guard RecordingGeneration.state(control: [UInt8](control), channel: [UInt8](channel)) == plan.after else { throw BrowserError.io("コピーから読み直した世代番号が想定と一致しません") }
        if let report = RecordingGeneration.report(in: written, controlSector: reread.location.control) {
            for head in report.heads where plan.loadedRegions.contains(head.kind) {
                guard report.hidden.contains(where: { $0.kind == head.kind }) else { throw BrowserError.io("コピー内の\(head.kind.label)が削除されていません") }
            }
        }
        for patch in plan.patches { guard try source.read(at: patch.sector * 512, count: 512) == patch.old else { throw BrowserError.io("入力側の管理セクターが変化しています") } }
        committed = true
        return RecordingDataWriteSummary(plan: plan, usedClone: usedClone, verified: true)
    }
}
