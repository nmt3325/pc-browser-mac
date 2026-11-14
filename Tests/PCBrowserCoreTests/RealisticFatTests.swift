import XCTest
@testable import PCBrowserCore

/// The command-file writer on the geometry a recorder-formatted card really has (8 KB clusters, one FAT, long-name slots in the root).
/// A first version only knew 1-sector clusters and two FAT copies; the real card exposed that gap.
final class RealisticFatTests: XCTestCase {
    typealias F = RealisticFatFixture
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func localTime() throws -> CardLocalTime { try CardLocalTime(year: 2026, month: 3, day: 4, hour: 5, minute: 6, second: 7) }
    func clusterSectors(_ n: Int) -> Set<Int> { Set((0..<F.sectorsPerCluster).map { F.clusterSector(n) + $0 }) }
    func changedSectors(_ a: Data, _ b: Data) -> [Int] {
        XCTAssertEqual(a.count, b.count)
        var result: [Int] = []
        for n in 0..<(a.count / 512) where SettingsFixture.sector(a, n) != SettingsFixture.sector(b, n) { result.append(n) }
        return result
    }

    func testTheRecorderGeometryIsReadAndHasNoCommandFiles() throws {
        let d = F.disk()
        XCTAssertEqual(try CardCommandFiles.read(MemorySource(d)), CardCommandState.absent)
        XCTAssertEqual(try CardSettingsReader.read(MemorySource(d)).map { $0.path }, ["CONFIG/VERSION.INI"])
        let location = try RecordingSettingsStore.locate(in: MemorySource(d))
        XCTAssertEqual(location, RecordingSettingsLocation(control: UInt64(F.controlSector), channel: UInt64(F.controlSector + 1),
                                                           backupControl: UInt64(F.journalEnd + 2), backupChannel: UInt64(F.journalEnd + 1)))
    }
    func testCommandFilesGoIntoTheFirstFreeSlotAndClusterAndNothingElseMoves() throws {
        let d = F.disk()
        let storage = MemoryFatStorage(d)
        let t = try localTime()
        try CardCommandFiles.write([.writeTime(t), .requestAngleDetection], to: storage, diskBytes: UInt64(d.count), now: now)
        XCTAssertEqual(try CardCommandFiles.read(MemorySource(storage.data)), CardCommandState(timeFileExists: true, time: t, angleDetectionRequested: true))
        XCTAssertEqual(F.fatEntry(storage.data, 10), 0xFFFF, "clusters 2-9 are taken, so the 36-byte file gets cluster 10")
        XCTAssertEqual(F.fatEntry(storage.data, 11), 0, "the empty file takes no cluster")
        let allowed = Set([F.fatSector]).union(clusterSectors(F.configCluster)).union(clusterSectors(10))
        XCTAssertTrue(storage.writtenSectors.isSubset(of: allowed), "\(storage.writtenSectors.sorted())")
        XCTAssertTrue(storage.writtenSectors.contains(F.fatSector))
        XCTAssertTrue(storage.writtenSectors.contains(F.clusterSector(F.configCluster)))
        let others = [F.partitionStart, F.rootSector, F.rootSector + 1, F.clusterSector(2), F.clusterSector(3), F.clusterSector(4),
                      F.clusterSector(F.versionCluster), F.clusterSector(7), F.clusterSector(8), F.clusterSector(9)]
        for n in others { XCTAssertEqual(SettingsFixture.sector(storage.data, n), SettingsFixture.sector(d, n), "sector \(n)") }
    }
    func testRemovingTheFilesFreesTheClusterAndKeepsTheVersionFile() throws {
        let d = F.disk()
        let storage = MemoryFatStorage(d)
        let t = try localTime()
        try CardCommandFiles.write([.writeTime(t), .requestAngleDetection], to: storage, diskBytes: UInt64(d.count), now: now)
        try CardCommandFiles.write([.removeTime, .cancelAngleDetection], to: storage, diskBytes: UInt64(d.count), now: now)
        XCTAssertEqual(try CardCommandFiles.read(MemorySource(storage.data)), CardCommandState.absent)
        XCTAssertEqual(F.fatEntry(storage.data, 10), 0)
        XCTAssertEqual(try CardSettingsReader.read(MemorySource(storage.data)).map { $0.path }, ["CONFIG/VERSION.INI"])
    }
    func testWriteCopyCombinesSettingsAndCommandFilesOnTheRecorderGeometry() throws {
        let d = F.disk()
        let input = try SettingsFixture.writeTemp(d)
        let out = SettingsFixture.freshOutputURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: out) }
        var wanted = try RecordingSettingsStore.read(MemorySource(d)).snapshot.settings
        wanted.beepEnabled = false
        let t = try localTime()
        let summary = try RecordingSettingsStore.writeCopy(of: input, to: out, new: wanted, commandFiles: [.writeTime(t), .requestAngleDetection], now: now, preferClone: false)
        XCTAssertTrue(summary.verified)
        let result = try Data(contentsOf: out)
        XCTAssertEqual(try RecordingSettingsStore.read(MemorySource(result)).snapshot.settings, wanted)
        XCTAssertEqual(RecordingSettingsStore.readCommandState(MemorySource(result)), CardCommandState(timeFileExists: true, time: t, angleDetectionRequested: true))
        let allowed = Set([F.controlSector, F.journalEnd + 2, F.fatSector]).union(clusterSectors(F.configCluster)).union(clusterSectors(10))
        XCTAssertTrue(Set(changedSectors(d, result)).isSubset(of: allowed), "\(changedSectors(d, result))")
        XCTAssertEqual(try Data(contentsOf: input), d)
    }
}
