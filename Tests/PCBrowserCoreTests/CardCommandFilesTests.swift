import XCTest
@testable import PCBrowserCore

/// CONFIG\TIME.INI / SELFADJ.INI handling on SYNTHETIC FAT16 images (generic bytes only).
final class CardCommandFilesTests: XCTestCase {
    let geometry = SettingsFixture.withFAT
    let timeName = Array("TIME    INI".utf8)
    let angleName = Array("SELFADJ INI".utf8)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var diskBytes: UInt64 { UInt64(geometry.byteCount) }
    func storage() -> MemoryFatStorage { MemoryFatStorage(SettingsFixture.image(geometry, fat: true)) }
    func volume(_ s: MemoryFatStorage) throws -> Fat16Volume { try Fat16Volume(storage: s, diskBytes: diskBytes) }
    func time(_ y: Int = 2026, _ mo: Int = 1, _ d: Int = 2, _ h: Int = 3, _ mi: Int = 4, _ s: Int = 5) throws -> CardLocalTime {
        try CardLocalTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }
    /// Indexes of the live entries called `name` in the CONFIG folder (cluster 2) of the fixture.
    func slots(named name: [UInt8], in disk: Data) -> [Int] {
        var result: [Int] = []
        for i in 0..<16 {
            let o = SettingsFixture.fat16Data + i * 32
            let entry = disk.subdata(in: o..<(o + 32))
            let first = entry[entry.startIndex]
            if first != 0xE5 && first != 0 && Array(entry.prefix(11)) == name { result.append(i) }
        }
        return result
    }
    func changedSectors(_ a: Data, _ b: Data) -> Set<Int> {
        var result = Set<Int>()
        for n in 0..<(a.count / 512) where SettingsFixture.sector(a, n) != SettingsFixture.sector(b, n) { result.insert(n) }
        return result
    }

    // MARK: values
    func testLocalTimeTextAndParsing() throws {
        let t = try time()
        XCTAssertEqual(t.text, "2026.01.02;03:04:05")
        XCTAssertEqual(CardLocalTime.parse("2026.01.02;03:04:05"), t)
        let bad = ["2026-01-02;03:04:05", "2026.13.02;03:04:05", "2026.02.30;03:04:05", "2026.01.02;24:04:05", "2026.01.02;03:04", "", "2026.01.02;03:04:0x", "1999.01.02;03:04:05"]
        for text in bad { XCTAssertNil(CardLocalTime.parse(text), text) }
        XCTAssertThrowsError(try CardLocalTime(year: 2026, month: 2, day: 29, hour: 0, minute: 0, second: 0))
        XCTAssertNoThrow(try CardLocalTime(year: 2028, month: 2, day: 29, hour: 0, minute: 0, second: 0))
    }
    func testFileContentsAndNamesMatchTheOriginal() throws {
        let t = try time()
        let contents = try XCTUnwrap(CardCommandFile.writeTime(t).contents)
        XCTAssertEqual(contents.count, 36)
        XCTAssertEqual(String(decoding: contents, as: UTF8.self), "[SET]\r\nLOCALTIME=2026.01.02;03:04:05")
        XCTAssertEqual(CardLocalTime.parseIni(contents), t)
        XCTAssertEqual(CardCommandFile.requestAngleDetection.contents, Data())
        XCTAssertNil(CardCommandFile.removeTime.contents)
        XCTAssertNil(CardCommandFile.cancelAngleDetection.contents)
        XCTAssertTrue(CardCommandFile.removeTime.isRemoval)
        XCTAssertFalse(CardCommandFile.requestAngleDetection.isRemoval)
        XCTAssertEqual(CardCommandFile.writeTime(t).path, "CONFIG/TIME.INI")
        XCTAssertEqual(CardCommandFile.cancelAngleDetection.path, "CONFIG/SELFADJ.INI")
        XCTAssertEqual(CardCommandFile.writeTime(t).action, "writeTime")
        XCTAssertEqual(CardCommandFile.cancelAngleDetection.action, "cancelAngleDetection")
        XCTAssertNil(CardLocalTime.parseIni(Data("[SET]\r\nLOCALTIME=garbage".utf8)))
        XCTAssertEqual(CardLocalTime.parseIni(Data("[SET]\nlocaltime=2026.01.02;03:04:05\n".utf8)), t)
    }
    func testActionsFollowTheOriginalsCheckboxes() throws {
        let t = try time(), other = try time(2027, 5, 6, 7, 8, 9)
        let empty = CardCommandState.absent
        let both = CardCommandState(timeFileExists: true, time: t, angleDetectionRequested: true)
        XCTAssertEqual(CardCommandFile.actions(from: empty, time: .keep, angle: .keep), [])
        XCTAssertEqual(CardCommandFile.actions(from: empty, time: .set(t), angle: .request), [.writeTime(t), .requestAngleDetection])
        XCTAssertEqual(CardCommandFile.actions(from: empty, time: .remove, angle: .cancel), [])
        XCTAssertEqual(CardCommandFile.actions(from: both, time: .remove, angle: .cancel), [.removeTime, .cancelAngleDetection])
        XCTAssertEqual(CardCommandFile.actions(from: both, time: .set(t), angle: .request), [])
        XCTAssertEqual(CardCommandFile.actions(from: both, time: .set(other), angle: .keep), [.writeTime(other)])
        let unreadable = CardCommandState(timeFileExists: true, time: nil, angleDetectionRequested: false)
        XCTAssertEqual(CardCommandFile.actions(from: unreadable, time: .set(t), angle: .keep), [.writeTime(t)])
        XCTAssertEqual(CardCommandFile.actions(from: unreadable, time: .keep, angle: .keep), [])
    }

    // MARK: FAT16 writer
    func testCreatingTimeIniWritesThirtySixBytesAndTouchesOnlyTheExpectedSectors() throws {
        let s = storage()
        let before = s.data
        let v = try volume(s)
        let contents = try XCTUnwrap(CardCommandFile.writeTime(try time()).contents)
        try v.writeConfigFile(timeName, contents: contents, now: now)
        XCTAssertEqual(try v.readConfigFile(timeName), contents)
        XCTAssertEqual(SettingsFixture.fatEntry(s.data, copy: 0, index: 4), 0xFFFF)
        XCTAssertEqual(SettingsFixture.fatEntry(s.data, copy: 1, index: 4), 0xFFFF)
        let entryOffset = SettingsFixture.fat16Data + 96
        let entry = s.data.subdata(in: entryOffset..<(entryOffset + 32))
        XCTAssertEqual(Array(entry.prefix(11)), timeName)
        XCTAssertEqual(entry[entry.startIndex + 11], 0x20)
        XCTAssertEqual(SettingsFixture.readHalf(entry, 26), 4)
        XCTAssertEqual(SettingsFixture.readWord(entry, 28), 36)
        let dataOffset = SettingsFixture.fat16Data + 2 * 512
        XCTAssertEqual(s.data.subdata(in: dataOffset..<(dataOffset + 36)), contents)
        let expected: Set<Int> = [SettingsFixture.fat16FirstFAT / 512, SettingsFixture.fat16SecondFAT / 512, SettingsFixture.fat16Data / 512, dataOffset / 512]
        XCTAssertEqual(s.writtenSectors, expected)
        XCTAssertEqual(changedSectors(before, s.data), expected)
    }
    func testReplacingAFileFreesTheOldClustersAndKeepsOneEntry() throws {
        let s = storage()
        let v = try volume(s)
        try v.writeConfigFile(timeName, contents: Data(repeating: 0x41, count: 1300), now: now)
        XCTAssertEqual(try v.chain(from: 4), [4, 5, 6])
        try v.writeConfigFile(timeName, contents: Data("short".utf8), now: now)
        XCTAssertEqual(try v.readConfigFile(timeName), Data("short".utf8))
        XCTAssertEqual(try v.chain(from: 4), [4])
        for copy in 0..<2 {
            XCTAssertEqual(SettingsFixture.fatEntry(s.data, copy: copy, index: 5), 0)
            XCTAssertEqual(SettingsFixture.fatEntry(s.data, copy: copy, index: 6), 0)
        }
        XCTAssertEqual(slots(named: timeName, in: s.data), [3])
        try v.writeConfigFile(timeName, contents: Data(repeating: 0x42, count: 600), now: now)
        XCTAssertEqual(try v.readConfigFile(timeName), Data(repeating: 0x42, count: 600))
        XCTAssertEqual(try v.chain(from: 4), [4, 5])
        XCTAssertEqual(slots(named: timeName, in: s.data), [3])
    }
    func testRemovingAFileMarksTheEntryDeletedFreesTheChainAndTheSlotIsReused() throws {
        let s = storage()
        let v = try volume(s)
        try v.writeConfigFile(timeName, contents: Data(repeating: 0x42, count: 700), now: now)
        XCTAssertTrue(try v.deleteConfigFile(timeName))
        XCTAssertNil(try v.readConfigFile(timeName))
        XCTAssertEqual(slots(named: timeName, in: s.data), [])
        for copy in 0..<2 {
            for index in [4, 5] { XCTAssertEqual(SettingsFixture.fatEntry(s.data, copy: copy, index: index), 0) }
        }
        XCTAssertFalse(try v.deleteConfigFile(timeName), "removing a file that does not exist changes nothing")
        try v.writeConfigFile(angleName, contents: Data(), now: now)
        XCTAssertEqual(try v.readConfigFile(angleName), Data())
        XCTAssertEqual(slots(named: angleName, in: s.data), [3])
        XCTAssertEqual(try v.chain(from: 0), [])
    }
    func testTheVersionFileIsNeverTouched() throws {
        let s = storage()
        let before = s.data
        let v = try volume(s)
        try v.writeConfigFile(timeName, contents: Data("x".utf8), now: now)
        try v.deleteConfigFile(timeName)
        let versionCluster = SettingsFixture.fat16Data + 512
        XCTAssertEqual(s.data.subdata(in: versionCluster..<(versionCluster + 512)), before.subdata(in: versionCluster..<(versionCluster + 512)))
        let files = try CardSettingsReader.read(MemorySource(s.data))
        XCTAssertEqual(files.map { $0.path }, ["CONFIG/VERSION.INI"])
    }
    func testAFullConfigFolderIsRefusedWithoutTouchingTheImage() throws {
        let s = storage()
        let v = try volume(s)
        for i in 0..<13 {
            try v.writeConfigFile(Array(String(format: "F%02d     TXT", i).utf8), contents: Data("x".utf8), now: now)
        }
        let before = s.data
        XCTAssertThrowsError(try v.writeConfigFile(timeName, contents: Data("y".utf8), now: now)) { error in
            XCTAssertTrue(error.localizedDescription.contains("空き"), "\(error)")
        }
        XCTAssertEqual(s.data, before)
    }
    func testVolumeGeometryAndCopiesAreValidatedBeforeAnyWrite() throws {
        let tinyGeometry = SettingsFixture.Geometry(totalSectors: 700, partitionSectors: 600)
        let tiny = SettingsFixture.image(tinyGeometry, fat: true)
        XCTAssertThrowsError(try Fat16Volume(storage: MemoryFatStorage(tiny), diskBytes: UInt64(tiny.count)), "FAT12-sized volumes are not written")

        var mismatch = SettingsFixture.image(geometry, fat: true)
        mismatch[SettingsFixture.fat16SecondFAT + 20] = 0x77
        XCTAssertThrowsError(try Fat16Volume(storage: MemoryFatStorage(mismatch), diskBytes: diskBytes), "differing FAT copies are not written")

        let noFat = SettingsFixture.image(geometry, fat: false)
        XCTAssertThrowsError(try Fat16Volume(storage: MemoryFatStorage(noFat), diskBytes: diskBytes))
        XCTAssertThrowsError(try CardCommandFiles.read(MemorySource(noFat)))
    }
    func testMissingConfigFolderAndProtectedFilesAreRefused() throws {
        var noConfig = SettingsFixture.image(geometry, fat: true)
        noConfig.replaceSubrange(SettingsFixture.fat16Root..<(SettingsFixture.fat16Root + 32), with: Data(count: 32))
        let s1 = MemoryFatStorage(noConfig)
        let v1 = try volume(s1)
        XCTAssertThrowsError(try v1.writeConfigFile(timeName, contents: Data("x".utf8), now: now))
        XCTAssertThrowsError(try v1.deleteConfigFile(timeName))
        XCTAssertThrowsError(try CardCommandFiles.read(MemorySource(noConfig)))
        XCTAssertEqual(s1.data, noConfig)

        let s2 = storage()
        let v2 = try volume(s2)
        try v2.writeConfigFile(timeName, contents: Data("x".utf8), now: now)
        s2.data[SettingsFixture.fat16Data + 96 + 11] = 0x21
        let before = s2.data
        XCTAssertThrowsError(try v2.writeConfigFile(timeName, contents: Data("y".utf8), now: now))
        XCTAssertThrowsError(try v2.deleteConfigFile(timeName))
        XCTAssertEqual(s2.data, before)
    }
    func testReaderReportsTheStateOfBothFiles() throws {
        let s = storage()
        XCTAssertEqual(try CardCommandFiles.read(MemorySource(s.data)), CardCommandState.absent)
        let v = try volume(s)
        let t = try time()
        try v.writeConfigFile(timeName, contents: try XCTUnwrap(CardCommandFile.writeTime(t).contents), now: now)
        try v.writeConfigFile(angleName, contents: Data(), now: now)
        XCTAssertEqual(try CardCommandFiles.read(MemorySource(s.data)), CardCommandState(timeFileExists: true, time: t, angleDetectionRequested: true))
        try v.writeConfigFile(timeName, contents: Data("[SET]\r\nLOCALTIME=garbage".utf8), now: now)
        let odd = try CardCommandFiles.read(MemorySource(s.data))
        XCTAssertTrue(odd.timeFileExists)
        XCTAssertNil(odd.time)
    }
    func testWriteAppliesEveryActionAndVerifiesIt() throws {
        let s = storage()
        let t = try time()
        try CardCommandFiles.write([.writeTime(t), .requestAngleDetection], to: s, diskBytes: diskBytes, now: now)
        XCTAssertEqual(try CardCommandFiles.read(MemorySource(s.data)), CardCommandState(timeFileExists: true, time: t, angleDetectionRequested: true))
        let files = try CardSettingsReader.read(MemorySource(s.data))
        XCTAssertEqual(files.map { $0.path }.sorted(), ["CONFIG/TIME.INI", "CONFIG/VERSION.INI"], "the empty SELFADJ.INI has no readable content")
        try CardCommandFiles.write([.removeTime, .cancelAngleDetection], to: s, diskBytes: diskBytes, now: now)
        XCTAssertEqual(try CardCommandFiles.read(MemorySource(s.data)), CardCommandState.absent)
        XCTAssertThrowsError(try CardCommandFiles.write([.writeTime(t), .removeTime], to: s, diskBytes: diskBytes, now: now))
        let n = 17 * 512
        XCTAssertEqual(s.data.subdata(in: SettingsFixture.fat16FirstFAT..<(SettingsFixture.fat16FirstFAT + n)),
                       s.data.subdata(in: SettingsFixture.fat16SecondFAT..<(SettingsFixture.fat16SecondFAT + n)), "both FAT copies stay identical")
    }
}
