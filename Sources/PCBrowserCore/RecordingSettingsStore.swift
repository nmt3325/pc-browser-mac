import Foundation
import CryptoKit
import Darwin

/// Where the recording settings live on a card image: the control sector, the channel-settings sector that follows it, and the
/// backup copies at the very end of the disk (second-to-last sector and the one before it).
public struct RecordingSettingsLocation: Equatable, Sendable {
    public let control: UInt64, channel: UInt64, backupControl: UInt64, backupChannel: UInt64
}
public struct RecordingSettingsState: Sendable {
    public let location: RecordingSettingsLocation
    public let snapshot: RecordingSettingsSnapshot
    public let backupControlMatches: Bool
    public let backupChannelMatches: Bool
}
public struct SettingsSectorPatch: Equatable, Sendable {
    public enum Role: String, Sendable { case control, channel, controlBackup, channelBackup }
    public let role: Role
    public let sector: UInt64
    public let old: Data, new: Data
    public var oldSHA256: String { RecordingSettingsStore.sha256(old) }
    public var newSHA256: String { RecordingSettingsStore.sha256(new) }
}
public struct RecordingSettingsPlan: Sendable {
    public let before: RecordingSettings
    public let after: RecordingSettings
    public let layoutChanged: Bool
    public let changes: [String]
    public let patches: [SettingsSectorPatch]
    public var changesAnything: Bool { patches.contains { $0.old != $0.new } }
}
public struct RecordingSettingsWriteSummary: Sendable {
    /// nil when only command files were written.
    public let plan: RecordingSettingsPlan?
    public let commandFiles: [CardCommandFile]
    public let usedClone: Bool
    public let verified: Bool
}

public enum RecordingSettingsStore {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func locate(in source: any ByteSource) throws -> RecordingSettingsLocation {
        let control = try ControlHeader.locate(in: source)
        let total = source.byteCount / 512
        guard total > control.sector + 6, total - 3 > control.sector + 1 else { throw BrowserError.unsupported("バックアップ管理セクターを置く余地がありません") }
        return RecordingSettingsLocation(control: control.sector, channel: control.sector + 1, backupControl: total - 2, backupChannel: total - 3)
    }

    public static func read(_ source: any ByteSource) throws -> RecordingSettingsState {
        let loc = try locate(in: source)
        let c = try source.read(at: loc.control * 512, count: 512), ch = try source.read(at: loc.channel * 512, count: 512)
        let snapshot = try RecordingSettingsCodec.decode(control: c, channel: ch)
        let bc = try source.read(at: loc.backupControl * 512, count: 512), bch = try source.read(at: loc.backupChannel * 512, count: 512)
        return RecordingSettingsState(location: loc, snapshot: snapshot, backupControlMatches: bc == c, backupChannelMatches: bch == ch)
    }

    /// State of CONFIG\TIME.INI and CONFIG\SELFADJ.INI, or nil when the image has no FAT16 volume with a CONFIG folder that this reader understands.
    public static func readCommandState(_ source: any ByteSource) -> CardCommandState? { try? CardCommandFiles.read(source) }

    /// Computes the four sectors the original would write, without writing anything.
    public static func plan(_ source: any ByteSource, new settings: RecordingSettings) throws -> RecordingSettingsPlan {
        let state = try read(source), loc = state.location
        let c = try source.read(at: loc.control * 512, count: 512), ch = try source.read(at: loc.channel * 512, count: 512)
        let bc = try source.read(at: loc.backupControl * 512, count: 512), bch = try source.read(at: loc.backupChannel * 512, count: 512)
        let marker = Data(RecordingSettingsCodec.marker)
        guard bc.subdata(in: 1..<18) == marker, bc.subdata(in: 0x1EC..<0x1FD) == marker else {
            throw BrowserError.unsupported("バックアップ管理セクターが見つからないため、書き込み先を特定できません")
        }
        let block = RecordingSettingsCodec.Offset.recordBlockStart..<RecordingSettingsCodec.Offset.recordBlockEnd
        guard bch.subdata(in: block) == ch.subdata(in: block) else { throw BrowserError.unsupported("バックアップのチャンネル設定セクターが一致しないため書き込めません") }
        let edit = try RecordingSettingsCodec.apply(settings, control: c, channel: ch)
        let patches = [SettingsSectorPatch(role: .control, sector: loc.control, old: c, new: edit.control),
                       SettingsSectorPatch(role: .channel, sector: loc.channel, old: ch, new: edit.channel),
                       SettingsSectorPatch(role: .controlBackup, sector: loc.backupControl, old: bc, new: edit.control),
                       SettingsSectorPatch(role: .channelBackup, sector: loc.backupChannel, old: bch, new: edit.channel)]
        return RecordingSettingsPlan(before: state.snapshot.settings, after: edit.settings, layoutChanged: edit.layoutChanged, changes: edit.changes, patches: patches)
    }

    /// Creates a NEW image that is a copy of `input` with the four settings sectors replaced and/or command files added to its CONFIG folder.
    /// The input is never opened for writing. On APFS the copy is a copy-on-write clone (instant, no extra space until sectors differ);
    /// otherwise it is a full copy.
    public static func writeCopy(of input: URL, to output: URL, new settings: RecordingSettings?, commandFiles: [CardCommandFile] = [], now: Date = Date(),
                                 preferClone: Bool = true, cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> RecordingSettingsWriteSummary {
        let decision = WriteGuard.checkNewOutput(output, protecting: [input])
        guard decision.isAllowed else { throw BrowserError.invalid(decision.reason ?? "書き出し先が不正です") }
        let source = try FileByteSource(url: input)
        var planned: RecordingSettingsPlan?
        if let requested = settings { planned = try RecordingSettingsStore.plan(source, new: requested) }
        let patches: [SettingsSectorPatch] = planned?.patches ?? []
        let sectorsChange = planned?.changesAnything ?? false
        guard sectorsChange || !commandFiles.isEmpty else { throw BrowserError.invalid("変更がないため、コピーを作成しません") }
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
        for patch in patches {
            let current = try preadExactly(fd: fd, offset: patch.sector * 512, count: 512)
            guard current == patch.old else { throw BrowserError.io("コピー内の管理セクターが読み取り時と異なります。処理を中止しました") }
        }
        for patch in patches where patch.old != patch.new { try pwriteAll(fd: fd, data: patch.new, offset: patch.sector * 512) }
        if !commandFiles.isEmpty {
            try CardCommandFiles.write(commandFiles, to: FileFat16Storage(fd: fd), diskBytes: source.byteCount, now: now)
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw BrowserError.io("コピーの書き込みを確定できません") }
        let written = try FileByteSource(url: output)
        for patch in patches { guard try written.read(at: patch.sector * 512, count: 512) == patch.new else { throw BrowserError.io("コピーの読み戻し検証に失敗しました") } }
        if let plan = planned {
            let reread = try read(written)
            guard reread.snapshot.settings == plan.after else { throw BrowserError.io("コピーから読み直した録画設定が指定内容と一致しません") }
        }
        for patch in patches { guard try source.read(at: patch.sector * 512, count: 512) == patch.old else { throw BrowserError.io("入力側の管理セクターが変化しています") } }
        committed = true
        return RecordingSettingsWriteSummary(plan: planned, commandFiles: commandFiles, usedClone: usedClone, verified: true)
    }

    static func preadExactly(fd: Int32, offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var done = 0
            while done < count {
                let n = pread(fd, raw.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BrowserError.io("コピーを読み取れません: \(String(cString: strerror(errno)))") }
                done += n
            }
        }
        return data
    }
    static func pwriteAll(fd: Int32, data: Data, offset: UInt64) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, raw.baseAddress!.advanced(by: done), raw.count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BrowserError.io("コピーへの書き込みに失敗しました: \(String(cString: strerror(errno)))") }
                done += n
            }
        }
    }
}
