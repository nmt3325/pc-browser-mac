import Foundation

// MARK: - Journal records

/// One 256-byte record of the per-second journal (履歴記録), reduced to the fields that the list and the report read.
///
/// Little-endian layout: magic at 0 (0xFFFFE202 per-second sample, 0xFFFFE201 marker, 0 empty), clock A (GPS-synchronised)
/// at 0x0E and clock B (free running) at 0x1E as year-2000/month/day/hour/minute/second bytes, GPS fix flag at 0x25,
/// latitude/longitude at 0x2E/0x32 (1/600000 degree, Tokyo datum), speed at 0x36 (mm/s), heading at 0x3A (1e-5 degree),
/// altitude at 0x3E (mm), unit number at 0x9A, trigger bits at 0xA6 and acceleration X/Y/Z at 0xAC/0xAE/0xB0.
struct JournalSlot: Sendable {
    static let invalid = Int64.min
    /// 2000-01-01 00:00:00 in the civil seconds used here: the clock of a record that has no clock at all.
    static let epoch2000: Int64 = 946_684_800
    /// 0 empty, 1 marker (E201), 2 per-second sample (E202), 3 anything else.
    var kind: UInt8 = 0
    var fix: UInt8 = 0
    var trigger: UInt8 = 0
    var speedRaw: UInt16 = 0
    var accelerationX: Int16 = 0
    var accelerationY: Int16 = 0
    var accelerationZ: Int16 = 0
    var latitudeRaw: Int32 = 0
    var longitudeRaw: Int32 = 0
    var altitudeMillimetres: Int32 = 0
    var headingRaw: UInt32 = 0
    /// Seconds of clock A / clock B (only read from markers and samples), `invalid` when the bytes are not a date.
    var clockA: Int64 = JournalSlot.invalid
    var clockB: Int64 = JournalSlot.invalid
    var deviceHead: UInt64 = 0
    var deviceTail: UInt16 = 0

    /// Whole kilometres per hour of the speed word (the original truncates).
    var speed: Int { Int(speedRaw) * 36 / 1000 }
    var hasFix: Bool { fix == 2 || fix == 3 }
    /// The ten-character unit number when every byte is 0-9 or A-Z.
    var deviceID: String? {
        var bytes: [UInt8] = []
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: deviceHead >> UInt64(8 * i))) }
        bytes.append(UInt8(truncatingIfNeeded: deviceTail))
        bytes.append(UInt8(truncatingIfNeeded: deviceTail >> 8))
        guard bytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parses the record at byte offset `o` of `raw` (at least 256 bytes must follow).
    init(_ raw: UnsafeRawBufferPointer, at o: Int) {
        func u16(_ at: Int) -> UInt16 { raw.loadUnaligned(fromByteOffset: o + at, as: UInt16.self).littleEndian }
        func u32(_ at: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: o + at, as: UInt32.self).littleEndian }
        func u64(_ at: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: o + at, as: UInt64.self).littleEndian }
        switch u32(0) {
        case 0xFFFFE202: kind = 2
        case 0xFFFFE201: kind = 1
        case 0: kind = 0
        default: kind = 3
        }
        fix = raw[o + 0x25]
        trigger = raw[o + 0xA6]
        speedRaw = u16(0x36)
        accelerationX = Int16(bitPattern: u16(0xAC))
        accelerationY = Int16(bitPattern: u16(0xAE))
        accelerationZ = Int16(bitPattern: u16(0xB0))
        latitudeRaw = Int32(bitPattern: u32(0x2E))
        longitudeRaw = Int32(bitPattern: u32(0x32))
        altitudeMillimetres = Int32(bitPattern: u32(0x3E))
        headingRaw = u32(0x3A)
        deviceHead = u64(0x9A)
        deviceTail = u16(0xA2)
        if kind == 1 || kind == 2 {
            clockA = Self.clock(raw, o + 0x0E)
            clockB = Self.clock(raw, o + 0x1E)
        }
    }

    private static func clock(_ raw: UnsafeRawBufferPointer, _ o: Int) -> Int64 {
        let year = 2000 + Int(raw[o]), month = Int(raw[o + 1]), day = Int(raw[o + 2])
        let hour = Int(raw[o + 3]), minute = Int(raw[o + 4]), second = Int(raw[o + 5])
        guard CivilTime.isValid(year: year, month: month, day: day, hour: hour, minute: minute, second: second) else { return invalid }
        return CivilTime.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }
}

// MARK: - Rows and summaries

public struct HistoryRow: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case session, marker }
    public let id: Int
    public let kind: Kind
    /// Seconds of the clock the original shows for the first entry (GPS clock when it has a fix, else the body clock).
    public let start: Int64
    /// Seconds of the free-running body clock B, which the video packets carry; used to find the matching video.
    public let videoClockStart: Int64
    public let duration: Int
    /// Entries of the row (= data lines of its CSV).
    public let records: Int
    public let deviceID: String?
    /// Displayed clock of the last entry.
    public var end: Int64 = 0
    /// Index of the row's first entry inside the journal.
    var entryStart: Int = 0
    public var startText: String { CivilTime.minuteText(start) }
    public var durationText: String { duration < 60 ? "\(duration)秒" : "\(duration / 60)分" }
    public var videoClockEnd: Int64 { videoClockStart + Int64(duration) }
}

/// The figures of one row of the 履歴記録レポート summary.
public struct HistorySummary: Sendable, Equatable {
    public var start: Int64 = 0
    public var end: Int64 = 0
    public var entries = 0
    /// Seconds, at least one.
    public var duration = 1
    public var distanceMeters = 0.0
    public var averageSpeed = 0.0
    public var maximumSpeed = 0
    /// False when no entry of the row had a 2D or 3D fix: the original leaves distance and speeds blank then.
    public var hasFix = false
    public var shock = 0, sudden = 0, steering = 0, oneTouch = 0
    /// Entries carrying any of the five trigger bits.
    public var events = 0
}

// MARK: - Journal model

/// The journal reconstructed from the ring of records: the scan order, the rows, and the clocks of every entry.
/// The rules are those measured on a full card against the original's exports (docs/history-report.md).
final class HistoryJournal: @unchecked Sendable {
    struct RowInfo {
        var marker: Bool
        var entryStart: Int
        var entryCount: Int
        var first: Int64
        var last: Int64
        var duration: Int
    }

    /// One week of one-second records; the journal area carries four reserved slots behind them.
    static let ringLimit = 604_800
    /// A span within this many seconds of (entries - 1) is the row's duration, otherwise the entry count is.
    static let tolerance = 5

    let slots: [JournalSlot]
    let ring: Int
    let startSlot: Int
    let newestSlot: Int
    /// Scan position of every entry in row order; -1 for the closing entry of the last row.
    let scan: [Int32]
    /// GPS clock, body clock and displayed clock of every entry.
    let gps: [Int64]
    let body: [Int64]
    let shown: [Int64]
    let rows: [RowInfo]

    init?(slots: [JournalSlot]) {
        let ring = slots.count
        guard ring > 1 else { return nil }
        let invalid = JournalSlot.invalid
        var newest = -1
        var newestClock = invalid
        for i in 0..<ring where slots[i].kind == 2 && slots[i].clockB != invalid {
            if newest < 0 || slots[i].clockB > newestClock { newest = i; newestClock = slots[i].clockB }
        }
        guard newest >= 0 else { return nil }
        // The ring is read from the even slot after the newest sample, oldest first.
        let start = ((newest / 2) + 1) * 2 % ring
        let wrap = ring - start
        func index(_ p: Int) -> Int { let s = start + p; return s >= ring ? s - ring : s }
        func kind(_ p: Int) -> UInt8 { slots[index(p)].kind }

        // Maximal runs of per-second samples in scan order.
        var runs: [(first: Int, last: Int)] = []
        var p = 0
        while p < ring {
            if kind(p) == 2 {
                var q = p
                while q + 1 < ring && kind(q + 1) == 2 { q += 1 }
                runs.append((first: p, last: q))
                p = q + 1
            } else { p += 1 }
        }
        guard !runs.isEmpty else { return nil }

        // The first short gap on each side of the physical ring end does not split a row.
        var merged = Set<Int>()
        var sawBefore = false, sawAfter = false
        for k in 1..<runs.count {
            let lo = runs[k - 1].last + 1, hi = runs[k].first - 1
            if hi < wrap && !sawBefore {
                sawBefore = true
                if hi - lo + 1 <= 3 { merged.insert(k) }
            }
            if lo >= wrap && !sawAfter {
                sawAfter = true
                if hi - lo + 1 <= 3 { merged.insert(k) }
            }
        }

        struct Plan {
            var marker: Bool
            var firstRun: Int
            var lastRun: Int
            var tail: [Int]
            var emit: [Int]
        }
        var plans: [Plan] = []
        for k in 0..<runs.count {
            if k > 0 && merged.contains(k) { plans[plans.count - 1].lastRun = k; continue }
            if k > 0 {
                let lo = runs[k - 1].last + 1, hi = runs[k].first - 1
                var nonEmpty: [Int] = []
                var markers = 0
                for x in lo...hi {
                    let kd = kind(x)
                    if kd == 1 || kd == 2 { nonEmpty.append(x) }
                    if kd == 1 { markers += 1 }
                }
                if hi - lo + 1 >= 4 && markers >= 3 {
                    // Three or more markers in a gap of four or more slots: two close the previous row, the rest is a one-second row.
                    plans[plans.count - 1].tail = Array(nonEmpty.prefix(2))
                    plans.append(Plan(marker: true, firstRun: -1, lastRun: -1, tail: [], emit: Array(nonEmpty.dropFirst(2))))
                } else {
                    plans[plans.count - 1].tail = nonEmpty
                }
            }
            plans.append(Plan(marker: false, firstRun: k, lastRun: k, tail: [], emit: []))
        }
        var closing: [Int] = []
        var x = runs[runs.count - 1].last + 1
        while x < ring {
            let kd = kind(x)
            if kd == 1 || kd == 2 { closing.append(x) }
            x += 1
        }
        plans[plans.count - 1].tail = closing

        // The entries of every row in scan order; a row that would write nothing is dropped, except the last.
        var scanList: [Int32] = []
        var starts: [Int] = []
        var markerFlags: [Bool] = []
        for (n, plan) in plans.enumerated() {
            var emit: [Int] = []
            if plan.marker {
                emit = plan.emit
            } else {
                let p0 = runs[plan.firstRun].first
                let e0 = p0 == 0 ? 1 : p0
                let pl = runs[plan.lastRun].last
                if e0 <= pl {
                    for y in e0...pl {
                        let kd = kind(y)
                        if kd == 1 || kd == 2 { emit.append(y) }
                    }
                }
                emit.append(contentsOf: plan.tail)
            }
            if emit.isEmpty && n != plans.count - 1 { continue }
            starts.append(scanList.count)
            markerFlags.append(plan.marker)
            for y in emit { scanList.append(Int32(y)) }
        }
        scanList.append(-1)
        starts.append(scanList.count)

        // Clocks of every entry. The data of entry n is read from the slot of entry n - 1 (the first one from scan position 0).
        let count = scanList.count
        var gpsList = [Int64](repeating: invalid, count: count)
        var bodyList = [Int64](repeating: invalid, count: count)
        var shownList = [Int64](repeating: invalid, count: count)
        func ownClockA(_ n: Int) -> Int64 {
            guard n >= 0 && n < count else { return invalid }
            let q = Int(scanList[n])
            return q < 0 ? invalid : slots[index(q)].clockA
        }
        var lastGPS = invalid, lastBody = invalid, previousShown = invalid
        var lag = 0
        for n in 0..<count {
            let q = Int(scanList[n])
            let lagSlot = slots[index(lag)]
            let a = q >= 0 ? slots[index(q)].clockA : invalid
            var g = invalid
            if lagSlot.hasFix {
                if q < 0 || slots[index(q)].kind == 1 {
                    g = lastGPS != invalid ? lastGPS + 1 : a
                } else if a != invalid && ownClockA(n - 1) == a && ownClockA(n + 1) == a && lastGPS != invalid {
                    g = lastGPS + 1
                } else {
                    g = a
                }
            }
            let bd = lagSlot.clockB
            let b: Int64
            if bd == invalid {
                b = lastBody == invalid ? invalid : lastBody + 1
            } else if lastBody == invalid || bd >= lastBody {
                b = bd
            } else {
                b = lastBody + 1
            }
            var s = g != invalid ? g : b
            if s == invalid {
                var own = invalid
                if q >= 0 {
                    let o = slots[index(q)]
                    own = o.clockB != invalid ? o.clockB : o.clockA
                }
                s = own != invalid ? own - 1 : (previousShown != invalid ? previousShown + 1 : JournalSlot.epoch2000)
            }
            gpsList[n] = g
            bodyList[n] = b
            shownList[n] = s
            lastGPS = g
            lastBody = b
            previousShown = s
            if q >= 0 { lag = q }
        }

        var infos: [RowInfo] = []
        for i in 0..<markerFlags.count {
            let lo = starts[i], hi = starts[i + 1]
            let entries = hi - lo
            let first = shownList[lo], last = shownList[hi - 1]
            let span = Int(last - first)
            let duration = max(abs(span - (entries - 1)) <= HistoryJournal.tolerance ? span : entries, 1)
            infos.append(RowInfo(marker: markerFlags[i], entryStart: lo, entryCount: entries, first: first, last: last, duration: duration))
        }

        self.slots = slots
        self.ring = ring
        self.startSlot = start
        self.newestSlot = newest
        self.scan = scanList
        self.gps = gpsList
        self.body = bodyList
        self.shown = shownList
        self.rows = infos
    }

    func slotIndex(_ p: Int) -> Int { let s = startSlot + p; return s >= ring ? s - ring : s }

    /// The record the data of entry `n` is taken from: the previous entry's own record (scan position 0 for the first).
    func dataSlot(_ n: Int) -> JournalSlot { slots[slotIndex(n == 0 ? 0 : Int(scan[n - 1]))] }

    func deviceID(ofRow i: Int) -> String? {
        let n = rows[i].entryStart
        let q = Int(scan[n])
        return (q >= 0 ? slots[slotIndex(q)] : dataSlot(n)).deviceID
    }

    func summary(ofRow i: Int) -> HistorySummary {
        let info = rows[i]
        var result = HistorySummary()
        result.start = info.first
        result.end = info.last
        result.entries = info.entryCount
        result.duration = info.duration
        var previous: GeoCoordinate?
        var speedSum = 0
        for n in info.entryStart..<(info.entryStart + info.entryCount) {
            let s = dataSlot(n)
            let speed = s.speed
            speedSum += speed
            result.maximumSpeed = max(result.maximumSpeed, speed)
            if s.hasFix { result.hasFix = true }
            if s.fix == 3, let c = DeviceGeodesy.coordinate(latitude: s.latitudeRaw, longitude: s.longitudeRaw,
                                                           altitudeMillimetres: s.altitudeMillimetres, datum: .deviceTokyo) {
                if let p = previous, p != c { result.distanceMeters += Hubeny.distance(from: p, to: c) }
                previous = c
            }
            let t = s.trigger
            if t & 0x01 != 0 { result.shock += 1 }
            if t & 0x02 != 0 { result.sudden += 1 }
            if t & 0x04 != 0 { result.steering += 1 }
            if t & 0x10 != 0 { result.oneTouch += 1 }
            if t & 0x1F != 0 { result.events += 1 }
        }
        result.averageSpeed = Double(speedSum) / Double(max(1, info.entryCount))
        return result
    }
}

// MARK: - Per-second journal (履歴記録)

public struct HistoryLog: Sendable, Equatable {
    public let rows: [HistoryRow]
    public let newestSlot: Int
    public let sampleRecords: Int, markerRecords: Int, emptyRecords: Int, otherRecords: Int
    public var slotCount: Int { sampleRecords + markerRecords + emptyRecords + otherRecords }
    let journal: HistoryJournal

    public static func == (a: HistoryLog, b: HistoryLog) -> Bool {
        a.rows == b.rows && a.newestSlot == b.newestSlot && a.sampleRecords == b.sampleRecords && a.markerRecords == b.markerRecords
            && a.emptyRecords == b.emptyRecords && a.otherRecords == b.otherRecords
    }

    /// Rows, durations and clocks follow the rules measured on a full 604,800-record journal against the original's list and
    /// its report exports (docs/history-report.md): the ring is read oldest first from the slot after the newest sample, a row is
    /// a run of per-second records (short gaps beside the ring end do not split it), the shown clock is the GPS clock while there
    /// is a fix and the body clock otherwise, and the duration is the clock span unless that disagrees with the entry count.
    static func build(slots: [JournalSlot]) -> HistoryLog? {
        guard let journal = HistoryJournal(slots: slots) else { return nil }
        var rows: [HistoryRow] = []
        rows.reserveCapacity(journal.rows.count)
        for (i, info) in journal.rows.enumerated() {
            let body = journal.body[info.entryStart]
            rows.append(HistoryRow(id: i, kind: info.marker ? .marker : .session, start: info.first,
                                   videoClockStart: body != JournalSlot.invalid ? body : info.first, duration: info.duration,
                                   records: info.entryCount, deviceID: journal.deviceID(ofRow: i), end: info.last, entryStart: info.entryStart))
        }
        var counts = [0, 0, 0, 0]
        for s in slots { counts[Int(s.kind)] += 1 }
        return HistoryLog(rows: rows, newestSlot: journal.newestSlot, sampleRecords: counts[2], markerRecords: counts[1],
                          emptyRecords: counts[0], otherRecords: counts[3], journal: journal)
    }

    /// The figures of a row of this log (nil for a row that is not from it).
    public func summary(of row: HistoryRow) -> HistorySummary? {
        guard row.id >= 0, row.id < rows.count, rows[row.id] == row else { return nil }
        return journal.summary(ofRow: row.id)
    }

    /// Reads the journal area (at most one week of records) in 4 MiB steps. Returns nil when the source does not contain all of it
    /// (partial copies, Windows BAK) or when no per-second record has a valid clock.
    public static func read(source: any ByteSource, area: Range<UInt64>, cancelled: () -> Bool = { false }) throws -> HistoryLog? {
        let sectors = area.upperBound - area.lowerBound
        guard sectors > 0, sectors < 2_000_000 else { return nil }
        let total = min(Int(sectors) * 2, HistoryJournal.ringLimit)
        let begin = area.lowerBound * 512, end = begin + UInt64(total) * 256
        guard total > 1, end <= source.byteCount else { return nil }
        if let ranges = source.scanRanges, !ranges.contains(where: { $0.lowerBound <= begin && $0.upperBound >= end }) { return nil }
        var slots: [JournalSlot] = []
        slots.reserveCapacity(total)
        var offset = begin
        while offset < end {
            if cancelled() { throw BrowserError.io("履歴記録の読み込みをキャンセルしました") }
            let count = Int(min(UInt64(4 * 1024 * 1024), end - offset))
            let data = try source.read(at: offset, count: count)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var o = 0
                while o + 256 <= raw.count {
                    slots.append(JournalSlot(raw, at: o))
                    o += 256
                }
            }
            offset += UInt64(count)
        }
        return build(slots: slots)
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
