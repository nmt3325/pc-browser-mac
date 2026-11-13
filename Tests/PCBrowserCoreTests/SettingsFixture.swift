import Foundation
@testable import PCBrowserCore

/// Synthetic card images for the settings tests. Generic bytes only: nothing here comes from a real card.
enum SettingsFixture {
    static let journalEnd: UInt32 = 60_000_000
    static let versionText = "[SYNTHETIC]\r\nKEY=1\r\n"

    // MARK: byte helpers
    static func word(_ v: UInt32, _ at: Int, _ d: inout [UInt8]) {
        for i in 0..<4 { d[at + i] = UInt8(truncatingIfNeeded: v >> UInt32(i * 8)) }
    }
    static func half(_ v: Int, _ at: Int, _ d: inout [UInt8]) {
        d[at] = UInt8(v & 0xFF)
        d[at + 1] = UInt8((v >> 8) & 0xFF)
    }
    static func readWord(_ d: Data, _ at: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(d[d.startIndex + at + i]) << UInt32(i * 8) }
        return v
    }
    static func readHalf(_ d: Data, _ at: Int) -> Int {
        Int(d[d.startIndex + at]) | Int(d[d.startIndex + at + 1]) << 8
    }

    // MARK: control and channel sectors
    /// Independent re-implementation of the stored checksum: 2 × (every control byte except the checksum + every channel byte).
    static func seal(_ control: [UInt8], _ channel: [UInt8]) -> (control: Data, channel: Data) {
        var c = control
        var sum = 0
        for (i, b) in c.enumerated() where i != 0x12 && i != 0x13 { sum += Int(b) }
        for b in channel { sum += Int(b) }
        let value = (sum * 2) & 0xFFFF
        c[0x12] = UInt8(value & 0xFF)
        c[0x13] = UInt8(value >> 8)
        return (Data(c), Data(channel))
    }
    /// Region table literals computed independently (168 h, single-rate history, journal end 60,000,000).
    static func factoryBytes(first: UInt32 = 10) -> (control: [UInt8], channel: [UInt8]) {
        var c = [UInt8](repeating: 0, count: 512)
        let marker = Array("YP_FORMAT_1.01__\0".utf8)
        for (i, b) in marker.enumerated() { c[1 + i] = b; c[0x1EC + i] = b }
        c[0x00] = 1; c[0x14] = 1; c[0x20] = 2
        let first8: [UInt8] = [0x0B, 0x10, 0x27, 0x01, 0x1E, 0x00, 0x00, 0x00]
        let event8: [UInt8] = [0x0B, 0x10, 0x27, 0x01, 0x1E, 0x00, 0x84, 0x03]
        c.replaceSubrange(0x21..<0x29, with: first8)
        c.replaceSubrange(0x29..<0x31, with: event8)
        c.replaceSubrange(0x31..<0x39, with: event8)
        c[0x3A] = 2; c[0x3B] = 2; c[0x3C] = 2; c[0x3D] = 1; c[0x3E] = 3; c[0x3F] = 1
        c[0x46] = 5; c[0x47] = 2; c[0x48] = 5; c[0x49] = 5; c[0x4A] = 5; c[0x50] = 3; c[0x51] = 1
        word(first, 0x1BE, &c); word(42_385_296, 0x1C2, &c); word(42_385_297, 0x1C6, &c)
        word(59_697_600, 0x1CA, &c); word(59_697_601, 0x1CE, &c); word(SettingsFixture.journalEnd, 0x1D2, &c)
        for i in 0..<8 { c[0x1D6 + i] = UInt8(0xA1 + i) }
        word(1, 0x1E0, &c); word(1, 0x1E4, &c); word(1, 0x1E8, &c)
        c[0x1FF] = 1
        var ch = [UInt8](repeating: 0, count: 512)
        ch[0x14] = 1; ch[0x15] = 1; ch[0x16] = 1
        for i in 0x20..<0x39 { ch[i] = c[i] }
        return (c, ch)
    }
    static func factory(first: UInt32 = 10) -> (control: Data, channel: Data) {
        let f = factoryBytes(first: first)
        return seal(f.control, f.channel)
    }

    // MARK: whole-disk images
    struct Geometry {
        let totalSectors: Int
        let partitionSectors: Int
        var controlSector: Int { 1 + partitionSectors }
        var channelSector: Int { controlSector + 1 }
        var firstRecordSector: Int { controlSector + 4 }
        var backupChannelSector: Int { totalSectors - 3 }
        var backupControlSector: Int { totalSectors - 2 }
        var byteCount: Int { totalSectors * 512 }
    }
    /// 64 sectors: MBR, a 7-sector partition without a file system, the settings sectors and their backups.
    static let plain = Geometry(totalSectors: 64, partitionSectors: 7)
    /// 4150 sectors: MBR, a FAT16 partition of 4137 sectors (4100 clusters of one sector) with a CONFIG folder, the settings sectors and their backups.
    static let withFAT = Geometry(totalSectors: 4150, partitionSectors: 4137)

    static func put(_ bytes: Data, sector: Int, into d: inout Data) {
        let start = sector * 512
        d.replaceSubrange(start..<(start + bytes.count), with: bytes)
    }
    static func image(_ g: Geometry, fat: Bool = false) -> Data {
        var d = Data(count: g.byteCount)
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[0x1BE + 4] = 0x06
        word(1, 0x1BE + 8, &mbr)
        word(UInt32(g.partitionSectors), 0x1BE + 12, &mbr)
        mbr[510] = 0x55; mbr[511] = 0xAA
        put(Data(mbr), sector: 0, into: &d)
        if fat { put(fat16Partition(sectors: g.partitionSectors), sector: 1, into: &d) }
        let f = factory(first: UInt32(g.firstRecordSector))
        put(f.control, sector: g.controlSector, into: &d)
        put(f.channel, sector: g.channelSector, into: &d)
        put(f.channel, sector: g.backupChannelSector, into: &d)
        put(f.control, sector: g.backupControlSector, into: &d)
        return d
    }
    static func sector(_ d: Data, _ n: Int) -> Data { d.subdata(in: (n * 512)..<((n + 1) * 512)) }

    // MARK: FAT16 volume
    /// A FAT16 volume of `sectors` sectors: one sector per cluster, 17-sector FATs (two copies), 32 root entries, a CONFIG folder in
    /// cluster 2 holding one generic file in cluster 3.
    static func fat16Partition(sectors: Int, fatSectors: Int = 17) -> Data {
        var p = [UInt8](repeating: 0, count: sectors * 512)
        p[0] = 0xEB; p[1] = 0x3C; p[2] = 0x90
        for (i, b) in Array("MSDOS5.0".utf8).enumerated() { p[3 + i] = b }
        half(512, 11, &p); p[13] = 1; half(1, 14, &p); p[16] = 2; half(32, 17, &p)
        half(sectors, 19, &p); p[21] = 0xF8; half(fatSectors, 22, &p)
        p[510] = 0x55; p[511] = 0xAA
        let fatStart = 512, fatBytes = fatSectors * 512
        let rootStart = fatStart + 2 * fatBytes, dataStart = rootStart + 32 * 32
        for copy in 0..<2 {
            let base = fatStart + copy * fatBytes
            half(0xFFF8, base, &p); half(0xFFFF, base + 2, &p); half(0xFFFF, base + 4, &p); half(0xFFFF, base + 6, &p)
        }
        put83("CONFIG     ", attribute: 0x10, cluster: 2, size: 0, at: rootStart, into: &p)
        put83(".          ", attribute: 0x10, cluster: 2, size: 0, at: dataStart, into: &p)
        put83("..         ", attribute: 0x10, cluster: 0, size: 0, at: dataStart + 32, into: &p)
        let text = Array(versionText.utf8)
        put83("VERSION INI", attribute: 0x20, cluster: 3, size: text.count, at: dataStart + 64, into: &p)
        for (i, b) in text.enumerated() { p[dataStart + 512 + i] = b }
        return Data(p)
    }
    static func put83(_ name: String, attribute: UInt8, cluster: Int, size: Int, at offset: Int, into p: inout [UInt8]) {
        for (i, b) in Array(name.utf8).enumerated() { p[offset + i] = b }
        p[offset + 11] = attribute
        half(cluster, offset + 26, &p)
        word(UInt32(size), offset + 28, &p)
    }
    /// Byte offsets inside the whole-disk image of the 17-sector FAT16 fixture (partition starts at sector 1).
    static let fat16FirstFAT = 512 + 512
    static let fat16SecondFAT = 512 + 512 + 17 * 512
    static let fat16Root = 512 + 512 + 2 * 17 * 512
    static let fat16Data = fat16Root + 32 * 32
    static func fatEntry(_ disk: Data, copy: Int, index: Int) -> Int {
        readHalf(disk, (copy == 0 ? fat16FirstFAT : fat16SecondFAT) + index * 2)
    }

    // MARK: temporary files
    static func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcb-settings-" + UUID().uuidString + ".img")
        try data.write(to: url)
        return url
    }
    static func freshOutputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pcb-settings-out-" + UUID().uuidString + ".img")
    }
}

/// In-memory `Fat16Storage` over a whole-disk image that remembers which sectors were written.
final class MemoryFatStorage: Fat16Storage {
    var data: Data
    private(set) var writtenSectors = Set<Int>()
    init(_ data: Data) { self.data = data }
    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset + UInt64(count) <= UInt64(data.count) else { throw BrowserError.truncated("範囲外の読み取り") }
        return data.subdata(in: Int(offset)..<(Int(offset) + count))
    }
    func write(_ bytes: Data, at offset: UInt64) throws {
        guard offset + UInt64(bytes.count) <= UInt64(data.count), bytes.count > 0 else { throw BrowserError.io("範囲外の書き込み") }
        let start = Int(offset)
        data.replaceSubrange(start..<(start + bytes.count), with: bytes)
        for s in (start / 512)...((start + bytes.count - 1) / 512) { writtenSectors.insert(s) }
    }
}
