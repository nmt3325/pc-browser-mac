import Foundation

/// The three lists of the original Windows viewer.
/// 履歴記録 = the playable video sessions found in the normal region (this app's session list),
/// イベント記録 = the three-block event recordings of the event region,
/// 常時録画 = the per-second E202 journal that the control sector places behind the event region.
public enum RecordListKind: String, CaseIterable, Sendable, Identifiable {
    case history, event, normal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .history: return "履歴記録"
        case .event: return "イベント記録"
        case .normal: return "常時録画"
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
    public init?(control: Data, firstRecordSector: UInt64, diskSectors: UInt64) {
        guard control.count == 512 else { return nil }
        let b = Bytes(control)
        func word(_ o: Int) -> UInt64? { (try? b.le32(o)).map { UInt64($0) } }
        guard let a = word(0x1C2), let e0 = word(0x1C6), let e1 = word(0x1CA),
              firstRecordSector < a, a <= e0, e0 < e1, e1 <= diskSectors else { return nil }
        var journal: Range<UInt64>?
        if let h0 = word(0x1CE), let h1 = word(0x1D2), h0 >= e1, h0 <= h1, h1 < diskSectors, h1 - h0 < 2_000_000 {
            journal = h0..<(h1 + 1)
        }
        self.init(normalEnd: a, eventStart: e0, eventEnd: e1, history: journal)
    }
}

public extension Recording {
    /// Event recordings are merged from their pre-roll, trigger and post blocks (see `RecordingSessions.group`).
    var isEvent: Bool { id.hasPrefix("event-") }
    /// The block that contains the trigger moment; a recording without type information starts at its first block.
    var eventTriggerBlock: RecordBlock? { blocks.first { $0.metadata?.blockType == EventBlockType.trigger } ?? blocks.first }
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

/// Trigger naming of the original event list, taken from the per-frame trigger bytes of the
/// trigger and post blocks (header bytes 0x40/0x41 select frames, 0x4C..0x4E name the cause).
public enum EventTrigger {
    public struct Sample: Sendable, Equatable {
        public var flags: UInt8, flags2: UInt8, mask: UInt32
        public init(flags: UInt8, flags2: UInt8, mask: UInt32) { self.flags = flags; self.flags2 = flags2; self.mask = mask }
        public var isCandidate: Bool { flags & 0x6D != 0 || flags2 & 0x0F != 0 }
    }
    public static let names: [(mask: UInt32, text: String)] = [
        (0x1, "衝撃"), (0x2, "急発進/急ブレーキ"), (0x4, "急ハンドル"), (0x8, "急旋回"), (0x10, "ワンタッチ"),
        (0x20, "急発進"), (0x40, "急ブレーキ"), (0x100, "外部トリガ1"), (0x200, "外部トリガ2"), (0x800, "近接近"),
        (0x1000, "弱衝撃"), (0x2000, "強衝撃"), (0x4000, "傾斜"), (0x8000, "ドア開"), (0x20000, "わき見"),
        (0x40000, "居眠り"), (0x80000, "ACCスイッチ"), (0x200000, "エリアA検知"), (0x400000, "エリアB検知"), (0x100000, "キーOFF忘れ")]
    public static func label(_ samples: [Sample]) -> String {
        var firstMask: UInt32?, flags: UInt8 = 0, mask: UInt32 = 0, withMask = 0
        for s in samples where s.isCandidate {
            if firstMask == nil { firstMask = s.mask }
            flags |= s.flags; mask |= s.mask
            if s.mask != 0 { withMask += 1 }
        }
        guard let first = firstMask else { return "イベント" }
        var text = names.first(where: { first & $0.mask != 0 })?.text ?? (flags & 4 != 0 ? "ワンタッチ" : "イベント")
        if withMask > 1 || (mask & 0xFFFF).nonzeroBitCount > 1 { text += ", など" }
        return text
    }
    /// Walks the packet chain of every block of type 2 and above (pre-roll, trigger, post) and reads only the 512-byte headers.
    public static func samples(of recording: Recording, source: any ByteSource, cancelled: () -> Bool = { false }) throws -> [Sample] {
        var result: [Sample] = []
        for block in recording.blocks {
            guard let type = block.metadata?.blockType, type >= EventBlockType.trigger else { continue }
            var sector = block.first.headerSector
            while sector <= block.last.headerSector {
                if cancelled() { throw BrowserError.io("イベント情報の取得をキャンセルしました") }
                guard let h = try? source.read(at: sector * 512, count: 512),
                      let ref = try? PacketReference(h, sector: sector, diskBytes: source.byteCount) else { break }
                let b = Bytes(h)
                let mask = UInt32((try? b.u8(0x4C)) ?? 0) | UInt32((try? b.u8(0x4D)) ?? 0) << 8 | UInt32((try? b.u8(0x4E)) ?? 0) << 16
                result.append(Sample(flags: (try? b.u8(0x40)) ?? 0, flags2: (try? b.u8(0x41)) ?? 0, mask: mask))
                sector = ref.tail + 1
            }
        }
        return result
    }
}

public struct EventEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let time: CardTimestamp?
    public let trigger: String
    public let deviceID: String?
    public let frames: Int, blocks: Int
    public var timeText: String { time.map { CivilTime.minuteText($0) } ?? "時刻不明" }
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

// MARK: - Per-second journal (常時録画)

public struct HistoryRow: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case session, marker }
    public let id: Int
    public let kind: Kind
    /// Seconds of the GPS-synchronised clock A (the time shown by the original list).
    public let start: Int64
    /// Seconds of the free-running clock B, which the video packets carry; used to find the matching video.
    public let videoClockStart: Int64
    public let duration: Int
    public let records: Int
    public let deviceID: String?
    public var startText: String { CivilTime.minuteText(start) }
    public var durationText: String { duration < 60 ? "\(duration)秒" : "\(duration / 60)分" }
    public var videoClockEnd: Int64 { videoClockStart + Int64(duration) }
}

public struct HistoryLog: Sendable, Equatable {
    public let rows: [HistoryRow]
    public let newestSlot: Int
    public let sampleRecords: Int, markerRecords: Int, emptyRecords: Int, otherRecords: Int
    public var slotCount: Int { sampleRecords + markerRecords + emptyRecords + otherRecords }

    static let invalid = Int64.min
    struct Slot { var kind: UInt8; var a: Int64; var b: Int64 }

    /// Rules measured on a full 604,800-record journal against the original list
    /// (514 of 516 runs give the identical start and 511 of 512 the identical duration; see docs/validation-history.md):
    /// - the newest record has the greatest clock B; the ring is read oldest-first from the slot after it;
    /// - a row is a run of consecutive per-second (E202) records;
    /// - start = clock A of the first record, one second earlier when A equals B (unsynchronised clock);
    /// - duration = (A last - A first) + 2 seconds, or n + 1 (+1 if more backward than forward jumps) when A jumps;
    /// - a four- or five-slot gap holding one lone marker is a one-second row.
    static func build(slots: [Slot], device: (Int) -> String?) -> HistoryLog? {
        let n = slots.count
        guard n > 1 else { return nil }
        var newest = -1, best = invalid
        for i in 0..<n where slots[i].kind == 2 && slots[i].b != invalid && slots[i].b > best { best = slots[i].b; newest = i }
        guard newest >= 0 else { return nil }
        func at(_ p: Int) -> Slot { slots[(newest + 1 + p) % n] }
        var runs: [(first: Int, last: Int)] = []
        var p = 0
        while p < n {
            if at(p).kind == 2 {
                var q = p
                while q + 1 < n && at(q + 1).kind == 2 { q += 1 }
                runs.append((p, q)); p = q + 1
            } else { p += 1 }
        }
        var rows: [HistoryRow] = []
        for (k, run) in runs.enumerated() {
            if k > 0 {
                let lo = runs[k - 1].last + 1, hi = run.first - 1
                let end = at(lo)
                if hi - lo + 1 >= 4, end.kind == 1, end.a != invalid, end.b != invalid,
                   let lone = (lo + 1..<hi).map({ at($0) }).first(where: { $0.kind == 1 && $0.a != invalid && $0.b != invalid }) {
                    let time = lone.a != lone.b ? lone.a : lone.b - (end.b - end.a)
                    rows.append(HistoryRow(id: rows.count, kind: .marker, start: time, videoClockStart: lone.b, duration: 1, records: 1, deviceID: device((newest + 1 + runs[k - 1].last) % n)))
                }
            }
            let f = at(run.first), l = at(run.last), count = run.last - run.first + 1
            guard f.a != invalid else { continue }
            var backward = 0, forward = 0
            if count > 1 {
                for j in (run.first + 1)...run.last {
                    let x = at(j - 1).a, y = at(j).a
                    guard x != invalid, y != invalid else { continue }
                    if y < x { backward += 1 } else if y - x >= 60 { forward += 1 }
                }
            }
            let duration = backward == 0 && forward == 0 && l.a != invalid ? Int(l.a - f.a) + 2 : count + 1 + (backward > forward ? 1 : 0)
            rows.append(HistoryRow(id: rows.count, kind: .session, start: f.a != f.b ? f.a : f.a - 1, videoClockStart: f.b != invalid ? f.b : f.a,
                                   duration: duration, records: count, deviceID: device((newest + 1 + run.first) % n)))
        }
        return HistoryLog(rows: rows, newestSlot: newest, sampleRecords: slots.filter { $0.kind == 2 }.count,
                          markerRecords: slots.filter { $0.kind == 1 }.count, emptyRecords: slots.filter { $0.kind == 0 }.count,
                          otherRecords: slots.filter { $0.kind == 3 }.count)
    }

    /// Reads the whole journal area in 4 MiB steps. Returns nil when the source does not contain all of it
    /// (partial copies, Windows BAK) or when no per-second record has a valid clock.
    public static func read(source: any ByteSource, area: Range<UInt64>, cancelled: () -> Bool = { false }) throws -> HistoryLog? {
        let sectors = area.upperBound - area.lowerBound
        guard sectors > 0, sectors < 2_000_000 else { return nil }
        let total = Int(sectors) * 2
        let begin = area.lowerBound * 512, end = area.upperBound * 512
        guard total > 1, end <= source.byteCount else { return nil }
        if let ranges = source.scanRanges, !ranges.contains(where: { $0.lowerBound <= begin && $0.upperBound >= end }) { return nil }
        var slots: [Slot] = []
        slots.reserveCapacity(total)
        var offset = begin
        while offset < end {
            if cancelled() { throw BrowserError.io("常時録画の読み込みをキャンセルしました") }
            let count = Int(min(UInt64(4 * 1024 * 1024), end - offset))
            let data = try source.read(at: offset, count: count)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var o = 0
                while o + 256 <= raw.count {
                    let magic = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian
                    switch magic {
                    case 0xFFFFE202, 0xFFFFE201:
                        let a = clock(raw, o + 0x0E), b = clock(raw, o + 0x1E)
                        slots.append(Slot(kind: magic == 0xFFFFE202 ? 2 : 1, a: a != invalid ? a : b, b: b != invalid ? b : a))
                    case 0: slots.append(Slot(kind: 0, a: invalid, b: invalid))
                    default: slots.append(Slot(kind: 3, a: invalid, b: invalid))
                    }
                    o += 256
                }
            }
            offset += UInt64(count)
        }
        return build(slots: slots) { slot in
            guard let d = try? source.read(at: begin + UInt64(slot) * 256 + 0x9A, count: 10), d.count == 10,
                  d.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
    }

    private static func clock(_ raw: UnsafeRawBufferPointer, _ o: Int) -> Int64 {
        let year = 2000 + Int(raw[o]), month = Int(raw[o + 1]), day = Int(raw[o + 2])
        let hour = Int(raw[o + 3]), minute = Int(raw[o + 4]), second = Int(raw[o + 5])
        guard CivilTime.isValid(year: year, month: month, day: day, hour: hour, minute: minute, second: second) else { return invalid }
        return CivilTime.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }
}

public extension HistoryLog {
    /// The video session whose clock-B span overlaps the row (small tolerance for second rounding), if any.
    func matchingRecording(for row: HistoryRow, in recordings: [Recording]) -> Recording? {
        let lo = row.videoClockStart - 2, hi = row.videoClockEnd + 2
        return recordings.first { r in
            guard !r.isEvent, let a = r.blocks.first?.first.telemetry.clock, let b = r.blocks.last?.last.telemetry.clock else { return false }
            let s = CivilTime.seconds(year: a.year, month: a.month, day: a.day, hour: a.hour, minute: a.minute, second: a.second)
            let e = CivilTime.seconds(year: b.year, month: b.month, day: b.day, hour: b.hour, minute: b.minute, second: b.second)
            return s <= hi && e >= lo
        }
    }
}
