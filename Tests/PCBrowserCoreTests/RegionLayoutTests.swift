import XCTest
@testable import PCBrowserCore

/// Cards set to イベント記録のみ / 常時録画のみ have an empty event or normal region; the browser must still locate and lay them out.
final class RegionLayoutTests: XCTestCase {
    func control(_ words: [UInt32]) -> Data {
        var c = [UInt8](repeating: 0, count: 512)
        for (i, w) in words.enumerated() { SettingsFixture.word(w, 0x1BE + i * 4, &c) }
        return Data(c)
    }
    func testEventOnlyTableHasNoNormalRegion() throws {
        let c = control([0, 0, 100, 200, 201, 300])
        XCTAssertEqual(try ControlHeader.firstRecordSector(inControl: c), 100)
        let layout = try XCTUnwrap(DiskLayout(control: c, firstRecordSector: 100, diskSectors: 1000))
        XCTAssertEqual(layout.normalEnd, 0)
        XCTAssertEqual(layout.eventStart, 100)
        XCTAssertEqual(layout.eventEnd, 200)
        XCTAssertEqual(layout.history, 201..<301)
        XCTAssertEqual(layout.historyRecordCount, 200)
    }
    func testContinuousOnlyTableHasNoEventRegion() throws {
        let c = control([10, 99, 0, 0, 100, 199])
        XCTAssertEqual(try ControlHeader.firstRecordSector(inControl: c), 10)
        let layout = try XCTUnwrap(DiskLayout(control: c, firstRecordSector: 10, diskSectors: 1000))
        XCTAssertEqual(layout.normalEnd, 99)
        XCTAssertEqual(layout.eventStart, 0)
        XCTAssertEqual(layout.eventEnd, 0)
        XCTAssertEqual(layout.history, 100..<200)
    }
    func testBothRegionsEmptyOrDisorderedTablesAreRefused() {
        XCTAssertNil(DiskLayout(control: control([0, 0, 0, 0, 201, 300]), firstRecordSector: 100, diskSectors: 1000))
        XCTAssertNil(DiskLayout(control: control([10, 99, 150, 120, 200, 300]), firstRecordSector: 10, diskSectors: 1000))
        XCTAssertNil(DiskLayout(control: control([0, 0, 100, 2000, 2001, 2100]), firstRecordSector: 100, diskSectors: 1000), "event region beyond the disk")
        XCTAssertNil(DiskLayout(control: control([10, 99, 0, 0, 100, 199]), firstRecordSector: 99, diskSectors: 1000), "first record sector must precede the normal region's end")
    }
    func testStandardLayoutStillWorks() throws {
        let c = control([10, 99, 100, 199, 200, 299])
        let layout = try XCTUnwrap(DiskLayout(control: c, firstRecordSector: 10, diskSectors: 1000))
        XCTAssertEqual(layout.eventRegion, 100..<199)
        XCTAssertEqual(layout.history, 200..<300)
    }
    func testLocateAcceptsAnEventOnlyAndAContinuousOnlyImage() throws {
        let g = SettingsFixture.plain
        var d = SettingsFixture.image(g)
        let base = g.controlSector * 512 + 0x1BE
        var table = [UInt8](repeating: 0, count: 24)
        for (i, w) in [UInt32(0), 0, 12, 40, 41, 60].enumerated() { SettingsFixture.word(w, i * 4, &table) }
        d.replaceSubrange(base..<(base + 24), with: Data(table))
        let eventOnly = try ControlHeader.locate(in: MemorySource(d))
        XCTAssertEqual(eventOnly.sector, UInt64(g.controlSector))
        XCTAssertEqual(eventOnly.firstRecordSector, 12)
        for (i, w) in [UInt32(12), 40, 0, 0, 41, 60].enumerated() { SettingsFixture.word(w, i * 4, &table) }
        d.replaceSubrange(base..<(base + 24), with: Data(table))
        let continuousOnly = try ControlHeader.locate(in: MemorySource(d))
        XCTAssertEqual(continuousOnly.firstRecordSector, 12)
    }
}
