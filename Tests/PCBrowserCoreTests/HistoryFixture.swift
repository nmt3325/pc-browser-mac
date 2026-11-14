import Foundation
@testable import PCBrowserCore

/// One 256-byte record of a synthetic per-second journal (履歴記録). Only the fields that the journal model reads are written;
/// every other byte is zero. Nothing here comes from a real card.
struct JournalRecord {
    /// 0 empty, 1 marker (E201), 2 per-second sample (E202), anything else an unknown magic.
    var kind = 2
    /// Clock A (GPS) and clock B (body) in civil seconds; nil leaves the six clock bytes zero (not a date).
    var a: Int64?
    var b: Int64?
    var fix: UInt8 = 3
    var speed: UInt16 = 0
    var lat: Int32 = 0
    var lon: Int32 = 0
    var altitude: Int32 = 0
    var heading: UInt32 = 0
    var trigger: UInt8 = 0
    var accel: [Int16] = [0, 0, 0]
    var device = "YQA1018762"

    func bytes() -> Data {
        var d = Data(count: 256)
        func put(_ value: UInt64, _ offset: Int, _ width: Int) {
            for i in 0..<width { d[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * i)) }
        }
        func clock(_ t: Int64?, _ offset: Int) {
            guard let t = t else { return }
            let c = CivilTime.components(t)
            d[offset] = UInt8(c.year - 2000); d[offset + 1] = UInt8(c.month); d[offset + 2] = UInt8(c.day)
            d[offset + 3] = UInt8(c.hour); d[offset + 4] = UInt8(c.minute); d[offset + 5] = UInt8(c.second)
        }
        switch kind {
        case 0: return d
        case 1: put(0xFFFFE201, 0, 4)
        case 2: put(0xFFFFE202, 0, 4)
        default: put(0xDEADBEEF, 0, 4)
        }
        clock(a, 0x0E)
        clock(b, 0x1E)
        d[0x25] = fix
        put(UInt64(speed), 0x36, 2)
        put(UInt64(UInt32(bitPattern: lat)), 0x2E, 4)
        put(UInt64(UInt32(bitPattern: lon)), 0x32, 4)
        put(UInt64(heading), 0x3A, 4)
        put(UInt64(UInt32(bitPattern: altitude)), 0x3E, 4)
        for (i, byte) in Array(device.utf8.prefix(10)).enumerated() { d[0x9A + i] = byte }
        d[0xA6] = trigger
        for (i, v) in accel.enumerated() { put(UInt64(UInt16(bitPattern: v)), 0xAC + 2 * i, 2) }
        return d
    }
}

enum JournalImage {
    /// The ring of `ring` slots (an even number) as sectors 20..<(20 + ring / 2) of an image, with `records` written from slot
    /// `firstSlot` on and wrapping at the ring end.
    static func make(ring: Int, firstSlot: Int, _ records: [JournalRecord]) -> (data: Data, area: Range<UInt64>) {
        var data = Data(count: 20 * 512 + ring * 256 + 512)
        for (k, record) in records.enumerated() where k < ring {
            let o = 20 * 512 + ((firstSlot + k) % ring) * 256
            data.replaceSubrange(o..<o + 256, with: record.bytes())
        }
        return (data, 20..<UInt64(20 + ring / 2))
    }
    static func log(_ image: (data: Data, area: Range<UInt64>)) throws -> HistoryLog? {
        try HistoryLog.read(source: MemorySource(image.data), area: image.area)
    }
}

/// Small deterministic generator (no dependence on the platform's random numbers).
struct TestRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x1234567 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

extension JournalImage {
    /// A journal of 400 to 1198 slots written from a random slot: runs of samples whose clocks, fixes, positions and trigger
    /// bits vary, split by gaps of empty slots, markers, unknown records and clock jumps. Half of them fill the whole ring.
    static func random(seed: UInt64) -> (data: Data, area: Range<UInt64>) {
        let t0 = CivilTime.seconds(year: 2026, month: 5, day: 1, hour: 9, minute: 0, second: 0)
        var g = TestRandom(seed)
        let ring = 400 + 2 * g.below(400)
        let firstSlot = g.below(ring)
        let target = g.chance(40) ? ring : ring / 2 + g.below(ring / 2)
        let devices = ["YQB2000001", "yqa-18762 ", "          ", "ABC"]
        var seq: [JournalRecord] = []
        var clock = t0 + Int64(g.below(100_000))
        var fix: UInt8 = 3
        var lat: Int32 = 21_000_000, lon: Int32 = 83_400_000

        func clocks() -> (a: Int64?, b: Int64?) {
            var a: Int64? = clock, b: Int64? = clock
            let pick = g.below(100)
            if pick >= 70 && pick < 80 { a = clock - 1 }
            else if pick >= 80 && pick < 85 { a = clock + 1 }
            else if pick >= 85 && pick < 90 { a = clock - 61 }
            else if pick >= 90 && pick < 95 { a = clock + Int64(g.below(601)) - 300 }
            else if pick >= 95 { a = nil }
            if g.chance(3) { b = nil }
            return (a, b)
        }
        func slot(kind: Int) -> JournalRecord {
            clock += 1
            if g.chance(2) { clock += Int64(1 + g.below(5000)) } else if g.chance(1) { clock -= Int64(1 + g.below(300)) }
            let (a, b) = clocks()
            if g.chance(6) {
                let pick = g.below(10)
                fix = pick < 6 ? 3 : (pick < 8 ? 2 : (pick == 8 ? 0 : 1))
            }
            var r = JournalRecord(kind: kind, a: a, b: b, fix: fix)
            r.speed = g.chance(3) ? 65535 : UInt16(g.below(3000))
            if g.chance(2) {
                r.lat = 0; r.lon = 0
            } else {
                if g.chance(2) {
                    lat = Int32(20_000_000 + g.below(2_000_000)); lon = Int32(83_000_000 + g.below(3_000_000))
                } else {
                    lat += Int32(g.below(121) - 60); lon += Int32(g.below(121) - 60)
                }
                r.lat = lat; r.lon = lon
            }
            r.altitude = Int32(g.below(300_000) - 20_000)
            r.heading = UInt32(g.below(36_000_000))
            r.trigger = g.chance(8) ? UInt8(g.below(256)) : 0
            var accel: [Int16] = []
            for _ in 0..<3 { accel.append(g.chance(3) ? Int16(truncatingIfNeeded: g.below(65536) - 32768) : Int16(g.below(2001) - 1000)) }
            r.accel = accel
            if g.chance(5) { r.device = devices[g.below(devices.count)] }
            return r
        }
        func blank() -> JournalRecord { clock += 1; return JournalRecord(kind: 0) }

        while seq.count < target {
            let length = g.chance(10) ? 100 + g.below(150) : 3 + g.below(60)
            for _ in 0..<length { seq.append(slot(kind: 2)) }
            let pick = g.below(100)
            var gap: [JournalRecord] = []
            if pick < 25 {
                let n = 1 + g.below(3)
                for _ in 0..<n { gap.append(g.chance(50) ? slot(kind: 1) : blank()) }
            } else if pick < 55 {
                let n = 4 + g.below(5)
                for _ in 0..<n { gap.append(g.chance(50) ? slot(kind: 1) : blank()) }
            } else if pick < 70 {
                let n = 3 + g.below(4)
                for _ in 0..<n { gap.append(slot(kind: 1)) }
                if g.chance(40) { gap.insert(blank(), at: g.below(gap.count)) }
            } else if pick < 80 {
                let n = 2 + g.below(5)
                for _ in 0..<n { gap.append(g.chance(50) ? slot(kind: 3) : (g.chance(50) ? slot(kind: 1) : blank())) }
            } else if pick < 90 {
                // no gap at all
            } else {
                let n = 1 + g.below(3)
                for _ in 0..<n { gap.append(slot(kind: 2)) }
            }
            seq += gap
            if g.chance(30) { clock += Int64(g.below(4000)) }
        }
        if seq.count > ring { seq.removeLast(seq.count - ring) }
        return JournalImage.make(ring: ring, firstSlot: firstSlot, seq)
    }
}
