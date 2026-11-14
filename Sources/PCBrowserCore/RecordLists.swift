import Foundation

/// The three lists of the original Windows viewer, in the original's tab order (verified against the running original:
/// the tabs read イベント記録 | 常時録画 | 履歴記録).
/// イベント記録 = the three-block event recordings of the event region;
/// 常時録画 = the playable video sessions found in the normal region (this app's session list);
/// 履歴記録 = the per-second E202 journal that the control sector places behind the event region
/// (log only: the original enables 設定変更, バックアップ, ログ変換 and レポート表示 for it, never the video commands).
public enum RecordListKind: String, CaseIterable, Sendable, Identifiable {
    case event, continuous, history
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .event: return "イベント記録"
        case .continuous: return "常時録画"
        case .history: return "履歴記録"
        }
    }
}

extension RecordListKind {
    /// The original's File ▸ 読み込み commands: イベント記録 (301), 常時録画 (302) and 履歴記録 (303). Each one loads one of the three lists;
    /// this port reads all three from the same input, so the command selects the list instead.
    public init?(commandID: Int) {
        switch commandID {
        case 301: self = .event
        case 302: self = .continuous
        case 303: self = .history
        default: return nil
        }
    }
    public var commandID: Int {
        switch self {
        case .event: return 301
        case .continuous: return 302
        case .history: return 303
        }
    }
}

/// Header byte 0x0C of a D103/D105 record: the stream phase of an event block.
public enum EventBlockType {
    public static let preRoll: UInt8 = 5
    public static let trigger: UInt8 = 2
    public static let post: UInt8 = 3
}

/// Region table stored in the YP_FORMAT control sector. Offsets are unaligned little-endian words:
/// 0x1C2 end of the normal video region, 0x1C6/0x1CA event region, 0x1CE/0x1D2 first and last journal sector.
public struct DiskLayout: Sendable, Equatable {
    public let normalEnd: UInt64
    public let eventStart: UInt64
    public let eventEnd: UInt64
    public let history: Range<UInt64>?
    public var eventRegion: Range<UInt64> { eventStart..<eventEnd }
    /// Two 256-byte journal records per sector.
    public var historyRecordCount: Int { history.map { Int($0.upperBound - $0.lowerBound) * 2 } ?? 0 }
    public init(normalEnd: UInt64, eventStart: UInt64, eventEnd: UInt64, history: Range<UInt64>?) {
        self.normalEnd = normalEnd; self.eventStart = eventStart; self.eventEnd = eventEnd; self.history = history
    }
    /// Fails (and the caller keeps its generic whole-disk behaviour) unless every bound is ordered and inside the disk.
    /// A card set to 常時録画 only has no event region (start = end = 0); one set to イベント記録 only has no normal region (start = end = 0).
    public init?(control: Data, firstRecordSector: UInt64, diskSectors: UInt64) {
        guard control.count == 512 else { return nil }
        let b = Bytes(control)
        func word(_ o: Int) -> UInt64? { (try? b.le32(o)).map { UInt64($0) } }
        guard let n0 = word(0x1BE), let a = word(0x1C2), let e0 = word(0x1C6), let e1 = word(0x1CA) else { return nil }
        let normalEmpty = n0 == 0 && a == 0, eventEmpty = e0 == 0 && e1 == 0
        guard !(normalEmpty && eventEmpty) else { return nil }
        if !normalEmpty { guard firstRecordSector < a else { return nil } }
        var journalFloor = a
        if !eventEmpty {
            guard (normalEmpty ? firstRecordSector <= e0 : a <= e0), e0 < e1, e1 <= diskSectors else { return nil }
            journalFloor = e1
        } else {
            guard a <= diskSectors else { return nil }
        }
        var journal: Range<UInt64>?
        if let h0 = word(0x1CE), let h1 = word(0x1D2), h0 >= journalFloor, h0 <= h1, h1 < diskSectors, h1 - h0 < 2_000_000 {
            journal = h0..<(h1 + 1)
        }
        self.init(normalEnd: a, eventStart: e0, eventEnd: e1, history: journal)
    }
}

public extension Recording {
    /// Event recordings are merged from their pre-roll, trigger and post blocks (see `RecordingSessions.group`).
    var isEvent: Bool { id.hasPrefix("event-") }
    /// The block that carries the trigger moment. The first frame of the post phase is the packet whose header holds the
    /// trigger fields, and the original names an event by that frame's clock (its trigger list and the report files).
    /// A recording without a post block falls back to the trigger block, and one without type information to its first block.
    var eventTriggerBlock: RecordBlock? {
        blocks.first { $0.metadata?.blockType == EventBlockType.post }
            ?? blocks.first { $0.metadata?.blockType == EventBlockType.trigger } ?? blocks.first
    }
    var eventTime: CardTimestamp? { eventTriggerBlock?.first.telemetry.clock }
}

public extension ImageIndex {
    var eventRecordings: [Recording] { recordings.filter(\.isEvent) }
    var continuousRecordings: [Recording] { recordings.filter { !$0.isEvent } }
}

/// Calendar arithmetic without TimeZone: the card clock is a device wall clock.
public enum CivilTime {
    public static func seconds(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int64 {
        let y = year - (month <= 2 ? 1 : 0), era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400
        let mp = month + (month > 2 ? -3 : 9), doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy, days = era * 146097 + doe - 719468
        return Int64(days) * 86400 + Int64(hour * 3600 + minute * 60 + second)
    }
    public static func components(_ t: Int64) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let days = t >= 0 ? t / 86400 : -((-t + 86399) / 86400)
        let rem = Int(t - days * 86400), z = Int(days) + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097, doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365, y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1, m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d, rem / 3600, rem % 3600 / 60, rem % 60)
    }
    public static func isValid(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Bool {
        guard (1...12).contains(month), hour < 24, minute < 60, second < 60, day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }
    /// `yyyy/MM/dd HH:mm`, the minute-resolution form of the original lists.
    public static func minuteText(_ t: Int64) -> String {
        let c = components(t)
        return String(format: "%04d/%02d/%02d %02d:%02d", c.year, c.month, c.day, c.hour, c.minute)
    }
    public static func minuteText(_ c: CardTimestamp) -> String {
        String(format: "%04d/%02d/%02d %02d:%02d", c.year, c.month, c.day, c.hour, c.minute)
    }
    /// `yyyy/MM/dd HH:mm:ss`, the second-resolution form of the original event list.
    public static func secondText(_ c: CardTimestamp) -> String {
        String(format: "%04d/%02d/%02d %02d:%02d:%02d", c.year, c.month, c.day, c.hour, c.minute, c.second)
    }
}

// MARK: - Device identity

public enum DeviceIdentity {
    /// The ten-character unit number stored at 0x6E of the sector after the control table.
    /// Partial copies that do not contain it return nil.
    public static func read(from source: any ByteSource, control: ControlHeader) -> String? {
        guard let d = try? source.read(at: (control.sector + 4) * 512 + 0x6E, count: 10), d.count == 10,
              d.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Event trigger

/// Trigger naming of the original event list.
///
/// The original takes the cause of an event from the post block (phase 3). The second sector of a block's
/// trailer pair (D106 between the parts of a long block, D104 at its end) repeats the two trigger fields of the
/// trigger packet: flags at 0xDB and the 24-bit cause mask at 0xE7...0xE9, i.e. header bytes 0x40 and
/// 0x4C...0x4E moved by 0x9B. When the first trailer of the post phase names no cause, the original falls back
/// to the D102 mirror of the first post packet, which holds the same two fields (once per event).
/// Per-packet headers, other phases and the D101 header copy are not consulted.
/// Established by editing those sectors on a copy of a real card and reading the original application's list.
public enum EventTrigger {
    public struct Sample: Sendable, Equatable {
        public var flags: UInt8, mask: UInt32
        public init(flags: UInt8, mask: UInt32) { self.flags = flags; self.mask = mask }
        public var isEmpty: Bool { flags == 0 && mask == 0 }
        /// `shift` is 0 for a packet header or mirror and 0x9B inside a block trailer.
        init(sector: Data, shift: Int) {
            let b = Bytes(sector)
            let low = UInt32((try? b.u8(0x4C + shift)) ?? 0)
            let middle = UInt32((try? b.u8(0x4D + shift)) ?? 0)
            let high = UInt32((try? b.u8(0x4E + shift)) ?? 0)
            self.flags = (try? b.u8(0x40 + shift)) ?? 0
            self.mask = low | (middle << 8) | (high << 16)
        }
    }
    /// In the order the original tests the cause bits; the first set bit names the event.
    public static let names: [(mask: UInt32, text: String)] = [
        (0x1, "衝撃"), (0x2, "急発進/急ブレーキ"), (0x4, "急ハンドル"), (0x8, "急旋回"), (0x10, "ワンタッチ"),
        (0x20, "急発進"), (0x40, "急ブレーキ"), (0x100, "外部トリガ1"), (0x200, "外部トリガ2"), (0x800, "近接近"),
        (0x1000, "弱衝撃"), (0x2000, "強衝撃"), (0x4000, "傾斜"), (0x8000, "ドア開"), (0x20000, "わき見"),
        (0x40000, "居眠り"), (0x80000, "ACCスイッチ"), (0x200000, "エリアA検知"), (0x400000, "エリアB検知"), (0x100000, "キーOFF忘れ")]
    /// Every sample is one trigger record. The causes and flags accumulate; a cause-less record with flag bit 2
    /// is a one-touch event and without any information the event is just "イベント". ", など" follows when more than
    /// one record named a cause or one mask has several of the low 16 cause bits.
    public static func label(_ samples: [Sample]) -> String {
        var flags: UInt8 = 0, mask: UInt32 = 0, causes = 0
        for s in samples {
            flags |= s.flags; mask |= s.mask
            if s.mask != 0 { causes += 1 }
        }
        var text = "イベント"
        if let named = names.first(where: { mask & $0.mask != 0 }) { text = named.text }
        else if flags & 4 != 0 { text = "ワンタッチ" }
        if causes > 1 || (mask & 0xFFFF).nonzeroBitCount > 1 { text += ", など" }
        return text
    }
    /// Reads two sectors per post block (its trailer pair) and, only when the first post trailer carries nothing, the
    /// mirror of that block's first packet. Records without any information are dropped.
    public static func samples(of recording: Recording, source: any ByteSource, cancelled: () -> Bool = { false }) throws -> [Sample] {
        var result: [Sample] = []
        var first = true
        for block in recording.blocks where block.metadata?.blockType == EventBlockType.post {
            if cancelled() { throw BrowserError.io("イベント情報の取得をキャンセルしました") }
            var sample = trailerSample(after: block, source: source)
            if first, sample?.isEmpty ?? true, let mirror = try? source.read(at: block.first.trailerSector * 512, count: 512), mirror.count == 512 {
                sample = Sample(sector: mirror, shift: 0)
            }
            first = false
            if let found = sample, !found.isEmpty { result.append(found) }
        }
        return result
    }
    /// The trailer pair directly behind the block's last packet: matching D106/D104 magic and the mirrored identifier word.
    private static func trailerSample(after block: RecordBlock, source: any ByteSource) -> Sample? {
        let sector = block.last.trailerSector + 1
        guard let head = try? source.read(at: sector * 512, count: 512), head.count == 512,
              let data = try? source.read(at: (sector + 1) * 512, count: 512), data.count == 512 else { return nil }
        let h = Bytes(head), d = Bytes(data)
        guard let magic = try? h.le32(0), magic == 0xFFFFD104 || magic == 0xFFFFD106,
              let second = try? d.le32(0), second == magic,
              let identifier = try? d.le32(4), let mirrored = try? d.le32(0x1FC), identifier == mirrored else { return nil }
        return Sample(sector: data, shift: 0x9B)
    }
}

public struct EventEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let time: CardTimestamp?
    public let trigger: String
    public let deviceID: String?
    public let frames: Int, blocks: Int
    public var timeText: String { time.map { CivilTime.secondText($0) } ?? "時刻不明" }
}

public enum EventList {
    /// One row per merged event recording, oldest first like the original list.
    public static func entries(_ index: ImageIndex, source: any ByteSource, cancelled: () -> Bool = { false }) throws -> [EventEntry] {
        let device = DeviceIdentity.read(from: source, control: index.control)
        var rows: [EventEntry] = []
        for r in index.eventRecordings {
            let label = EventTrigger.label(try EventTrigger.samples(of: r, source: source, cancelled: cancelled))
            rows.append(EventEntry(id: r.id, time: r.eventTime, trigger: label, deviceID: device, frames: r.frameCount, blocks: r.blockCount))
        }
        return rows.enumerated().sorted { a, b in
            let x = a.element.time?.linearSeconds ?? .infinity, y = b.element.time?.linearSeconds ?? .infinity
            return x == y ? a.offset < b.offset : x < y
        }.map { $0.element }
    }
}
