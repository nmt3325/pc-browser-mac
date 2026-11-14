import Foundation
@testable import PCBrowserCore

/// A synthetic card image with the FAT16 geometry of a recorder-formatted card (generic values only; no names or data of a real card):
/// the partition starts at sector 63, 8 KB clusters, ONE FAT copy, 512 root entries, long-name and deleted slots plus a volume label in the
/// root directory, hidden folders, and the CONFIG folder in cluster 5 holding one generic file. Behind the partition come the control and
/// channel sectors and, behind a tiny journal, their backups.
enum RealisticFatFixture {
    static let partitionStart = 63
    static let partitionSectors = 70_000
    static let sectorsPerCluster = 16
    static let fatSectors = 18
    static let rootEntries = 512
    static let configCluster = 5
    static let versionCluster = 6
    static let controlSector = partitionStart + partitionSectors
    static let firstRecordSector = controlSector + 4
    static let journalEnd = controlSector + 16
    static let totalSectors = controlSector + 20

    static var fatSector: Int { partitionStart + 1 }
    static var rootSector: Int { fatSector + fatSectors }
    static var dataSector: Int { rootSector + rootEntries / 16 }
    static func clusterSector(_ n: Int) -> Int { dataSector + (n - 2) * sectorsPerCluster }
    static func fatEntry(_ d: Data, _ n: Int) -> Int { SettingsFixture.readHalf(d, fatSector * 512 + n * 2) }

    static func entry(_ name: String, attribute: UInt8, cluster: Int, size: Int) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 32)
        for (i, b) in Array(name.utf8).enumerated() where i < 11 { e[i] = b }
        e[11] = attribute
        SettingsFixture.half(cluster, 26, &e)
        SettingsFixture.word(UInt32(size), 28, &e)
        return e
    }
    static func longNameSlot(_ sequence: UInt8) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 32)
        e[0] = sequence
        e[11] = 0x0F
        for i in 0..<5 { e[1 + i * 2] = 0x41 }
        for i in 0..<6 { e[14 + i * 2] = 0x42 }
        for i in 0..<2 { e[28 + i * 2] = 0x43 }
        return e
    }
    static func directoryCluster(selfCluster: Int, parent: Int, children: [[UInt8]]) -> Data {
        var d = [UInt8](repeating: 0, count: sectorsPerCluster * 512)
        let slots = [entry(".          ", attribute: 0x10, cluster: selfCluster, size: 0),
                     entry("..         ", attribute: 0x10, cluster: parent, size: 0)] + children
        for (i, e) in slots.enumerated() { d.replaceSubrange((i * 32)..<(i * 32 + 32), with: e) }
        return Data(d)
    }
    static func filled(_ byte: UInt8, count: Int) -> Data {
        var d = Data(repeating: byte, count: sectorsPerCluster * 512)
        for i in count..<d.count { d[i] = 0 }
        return d
    }

    static func disk() -> Data {
        var d = Data(count: totalSectors * 512)
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[0x1BE + 4] = 0x06
        SettingsFixture.word(UInt32(partitionStart), 0x1BE + 8, &mbr)
        SettingsFixture.word(UInt32(partitionSectors), 0x1BE + 12, &mbr)
        mbr[510] = 0x55; mbr[511] = 0xAA
        SettingsFixture.put(Data(mbr), sector: 0, into: &d)

        var boot = [UInt8](repeating: 0, count: 512)
        boot[0] = 0xEB; boot[1] = 0xFE; boot[2] = 0x90
        for (i, b) in Array("MSDOS5.0".utf8).enumerated() { boot[3 + i] = b }
        SettingsFixture.half(512, 11, &boot); boot[13] = UInt8(sectorsPerCluster); SettingsFixture.half(1, 14, &boot); boot[16] = 1
        SettingsFixture.half(rootEntries, 17, &boot); SettingsFixture.half(0, 19, &boot); boot[21] = 0xF8; SettingsFixture.half(fatSectors, 22, &boot)
        SettingsFixture.word(UInt32(partitionSectors), 32, &boot)
        boot[510] = 0x55; boot[511] = 0xAA
        SettingsFixture.put(Data(boot), sector: partitionStart, into: &d)

        var fat = [UInt8](repeating: 0, count: fatSectors * 512)
        SettingsFixture.half(0xFFF8, 0, &fat); SettingsFixture.half(0xFFFF, 2, &fat)
        for n in 2...9 { SettingsFixture.half(0xFFFF, n * 2, &fat) }
        SettingsFixture.put(Data(fat), sector: fatSector, into: &d)

        var root = [UInt8](repeating: 0, count: rootEntries * 32)
        var deleted = entry("DELETEDTXT", attribute: 0x20, cluster: 0, size: 0)
        deleted[0] = 0xE5
        let slots: [(Int, [UInt8])] = [
            (0, longNameSlot(0x41)), (1, deleted),
            (2, entry("FOLDERA    ", attribute: 0x16, cluster: 2, size: 0)),
            (3, entry("NO NAME    ", attribute: 0x08, cluster: 0, size: 0)),
            (4, longNameSlot(0x41)),
            (5, entry("CONFIG     ", attribute: 0x10, cluster: configCluster, size: 0)),
            (6, longNameSlot(0x41)),
            (7, entry("FOLDERB    ", attribute: 0x12, cluster: 7, size: 0)),
            (8, longNameSlot(0x42)), (9, longNameSlot(0x41)),
            (10, entry("FOLDERC    ", attribute: 0x12, cluster: 9, size: 0))]
        for (i, e) in slots { root.replaceSubrange((i * 32)..<(i * 32 + 32), with: e) }
        SettingsFixture.put(Data(root), sector: rootSector, into: &d)

        let text = Array(SettingsFixture.versionText.utf8)
        SettingsFixture.put(directoryCluster(selfCluster: 2, parent: 0, children: [entry("DATA1   BIN", attribute: 0x20, cluster: 3, size: 100),
                                                                                  entry("DATA2   BIN", attribute: 0x20, cluster: 4, size: 200)]), sector: clusterSector(2), into: &d)
        SettingsFixture.put(directoryCluster(selfCluster: configCluster, parent: 0, children: [entry("VERSION INI", attribute: 0x20, cluster: versionCluster, size: text.count)]),
                            sector: clusterSector(configCluster), into: &d)
        SettingsFixture.put(directoryCluster(selfCluster: 7, parent: 0, children: [entry("DATA3   BIN", attribute: 0x20, cluster: 8, size: 300)]), sector: clusterSector(7), into: &d)
        SettingsFixture.put(directoryCluster(selfCluster: 9, parent: 0, children: []), sector: clusterSector(9), into: &d)
        SettingsFixture.put(filled(0x61, count: 100), sector: clusterSector(3), into: &d)
        SettingsFixture.put(filled(0x62, count: 200), sector: clusterSector(4), into: &d)
        var versionData = Data(count: sectorsPerCluster * 512)
        versionData.replaceSubrange(0..<text.count, with: text)
        SettingsFixture.put(versionData, sector: clusterSector(versionCluster), into: &d)
        SettingsFixture.put(filled(0x63, count: 300), sector: clusterSector(8), into: &d)

        let table = [UInt32(firstRecordSector), UInt32(firstRecordSector + 1), UInt32(firstRecordSector + 2), UInt32(firstRecordSector + 3), UInt32(firstRecordSector + 4), UInt32(journalEnd)]
        let f = SettingsFixture.factory(first: UInt32(firstRecordSector), table: table)
        SettingsFixture.put(f.control, sector: controlSector, into: &d)
        SettingsFixture.put(f.channel, sector: controlSector + 1, into: &d)
        SettingsFixture.put(f.channel, sector: journalEnd + 1, into: &d)
        SettingsFixture.put(f.control, sector: journalEnd + 2, into: &d)
        return d
    }
}
