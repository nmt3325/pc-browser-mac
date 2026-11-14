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
