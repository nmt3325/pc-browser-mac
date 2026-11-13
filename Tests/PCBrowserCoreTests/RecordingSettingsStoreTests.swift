import XCTest
@testable import PCBrowserCore

/// Planning and writing settings on SYNTHETIC card images (generic bytes only). The originals' exact byte results are covered by RecordingSettingsTests.
final class RecordingSettingsStoreTests: XCTestCase {
    let plain = SettingsFixture.plain
    let fat = SettingsFixture.withFAT

    func temp(_ data: Data) throws -> URL {
        let url = try SettingsFixture.writeTemp(data)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func output() -> URL {
        let url = SettingsFixture.freshOutputURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func changedSectors(_ a: Data, _ b: Data) -> [Int] {
        var result: [Int] = []
        for n in 0..<(a.count / 512) where SettingsFixture.sector(a, n) != SettingsFixture.sector(b, n) { result.append(n) }
        return result
    }
    func current(_ d: Data, _ change: (inout RecordingSettings) -> Void) throws -> RecordingSettings {
        var s = try RecordingSettingsStore.read(MemorySource(d)).snapshot.settings
        change(&s)
        return s
    }
    func localTime() throws -> CardLocalTime { try CardLocalTime(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5) }

    // MARK: locate / read / plan
    func testLocateFindsTheSettingsSectorsAndTheirBackups() throws {
        let location = try RecordingSettingsStore.locate(in: MemorySource(SettingsFixture.image(plain)))
        XCTAssertEqual(location, RecordingSettingsLocation(control: 8, channel: 9, backupControl: 62, backupChannel: 61))
    }
    func testReadDecodesTheFactorySettingsAndNoticesDifferingBackups() throws {
        let d = SettingsFixture.image(plain)
        let state = try RecordingSettingsStore.read(MemorySource(d))
        XCTAssertEqual(state.snapshot.settings, RecordingSettings.factoryDefault)
        XCTAssertTrue(state.backupControlMatches)
        XCTAssertTrue(state.backupChannelMatches)
        var broken = d
        broken[plain.backupControlSector * 512 + 100] ^= 0x55
        let after = try RecordingSettingsStore.read(MemorySource(broken))
        XCTAssertFalse(after.backupControlMatches)
        XCTAssertTrue(after.backupChannelMatches)
    }
    func testPlanReturnsTheFourSectorsTheOriginalWritesWithHashes() throws {
        let d = SettingsFixture.image(plain)
        let wanted = try current(d) { $0.frameRateIndex = 2; $0.beepEnabled = false }
        let plan = try RecordingSettingsStore.plan(MemorySource(d), new: wanted)
        XCTAssertEqual(plan.patches.map { $0.role }, [.control, .channel, .controlBackup, .channelBackup])
        XCTAssertEqual(plan.patches.map { $0.sector }, [8, 9, 62, 61])
        XCTAssertTrue(plan.changesAnything)
        XCTAssertFalse(plan.layoutChanged)
        XCTAssertEqual(plan.changes.count, 2)
        XCTAssertEqual(plan.patches[0].new, plan.patches[2].new)
        XCTAssertEqual(plan.patches[1].new, plan.patches[3].new)
        for patch in plan.patches {
            XCTAssertEqual(patch.oldSHA256.count, 64)
            XCTAssertEqual(patch.newSHA256.count, 64)
            XCTAssertEqual(patch.oldSHA256, RecordingSettingsStore.sha256(SettingsFixture.sector(d, Int(patch.sector))))
            XCTAssertNotEqual(patch.oldSHA256, patch.newSHA256)
        }
    }
    func testAChangeOutsideTheChannelBlockLeavesTheChannelSectorsAlone() throws {
        let d = SettingsFixture.image(plain)
        let wanted = try current(d) { $0.beepEnabled = false }
        let plan = try RecordingSettingsStore.plan(MemorySource(d), new: wanted)
        XCTAssertNotEqual(plan.patches[0].old, plan.patches[0].new)
        XCTAssertEqual(plan.patches[1].old, plan.patches[1].new)
        XCTAssertEqual(plan.patches[3].old, plan.patches[3].new)
    }
    func testIdenticalSettingsPlanNothing() throws {
        let d = SettingsFixture.image(plain)
        let same = try current(d) { _ in }
        let plan = try RecordingSettingsStore.plan(MemorySource(d), new: same)
        XCTAssertFalse(plan.changesAnything)
        XCTAssertTrue(plan.changes.isEmpty)
    }
    func testPlanRefusesBackupsItDoesNotUnderstand() throws {
        let clean = SettingsFixture.image(plain)
        let wanted = try current(clean) { $0.beepEnabled = false }
        var noMarker = clean
        noMarker[plain.backupControlSector * 512 + 1] = 0
        XCTAssertThrowsError(try RecordingSettingsStore.plan(MemorySource(noMarker), new: wanted))
        var otherChannel = clean
        otherChannel[plain.backupChannelSector * 512 + 0x30] ^= 0x01
        XCTAssertThrowsError(try RecordingSettingsStore.plan(MemorySource(otherChannel), new: wanted))
    }
    func testCommandStateIsOptionalForImagesWithoutAFATVolume() throws {
        XCTAssertNil(RecordingSettingsStore.readCommandState(MemorySource(SettingsFixture.image(plain))))
        XCTAssertEqual(RecordingSettingsStore.readCommandState(MemorySource(SettingsFixture.image(fat, fat: true))), CardCommandState.absent)
    }

    // MARK: writeCopy
    func checkWriteCopy(preferClone: Bool) throws {
        let d = SettingsFixture.image(plain)
        let input = try temp(d)
        let out = output()
        let wanted = try current(d) { $0.frameRateIndex = 2; $0.beepEnabled = false }
        let summary = try RecordingSettingsStore.writeCopy(of: input, to: out, new: wanted, preferClone: preferClone)
        XCTAssertTrue(summary.verified)
        if !preferClone { XCTAssertFalse(summary.usedClone) }
        XCTAssertEqual(try Data(contentsOf: input), d, "the input is never modified")
        let result = try Data(contentsOf: out)
        XCTAssertEqual(result.count, d.count)
        XCTAssertEqual(changedSectors(d, result), [8, 9, 61, 62])
        let state = try RecordingSettingsStore.read(MemorySource(result))
        XCTAssertEqual(state.snapshot.settings, summary.plan?.after)
        XCTAssertEqual(state.snapshot.generation, 1, "a save that keeps the layout never touches the generation")
        XCTAssertTrue(state.backupControlMatches)
        XCTAssertTrue(state.backupChannelMatches)
        let attributes = try FileManager.default.attributesOfItem(atPath: out.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testWriteCopyWithoutCloneChangesOnlyTheFourSettingsSectors() throws { try checkWriteCopy(preferClone: false) }
    func testWriteCopyWithCloneChangesOnlyTheFourSettingsSectors() throws { try checkWriteCopy(preferClone: true) }

    func testWriteCopyRefusesExistingOutputsSameFileAndNoChange() throws {
        let d = SettingsFixture.image(plain)
        let input = try temp(d)
        let wanted = try current(d) { $0.beepEnabled = false }
        let existing = output()
        try Data("x".utf8).write(to: existing)
        XCTAssertThrowsError(try RecordingSettingsStore.writeCopy(of: input, to: existing, new: wanted))
        XCTAssertEqual(try Data(contentsOf: existing), Data("x".utf8))
        let out = output()
        XCTAssertThrowsError(try RecordingSettingsStore.writeCopy(of: input, to: out, new: try current(d) { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains("変更がない"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertThrowsError(try RecordingSettingsStore.writeCopy(of: input, to: input, new: wanted))
        XCTAssertEqual(try Data(contentsOf: input), d)
    }
    func testLayoutChangeCopyHasAConsistentStandardRegionTable() throws {
        let d = SettingsFixture.image(plain)
        let input = try temp(d)
        let out = output()
        let wanted = try current(d) { $0.setMode(.eventOnly); $0.historyHoursIndex = 0 }
        let summary = try RecordingSettingsStore.writeCopy(of: input, to: out, new: wanted, preferClone: false)
        XCTAssertEqual(summary.plan?.layoutChanged, true)
        let result = try Data(contentsOf: out)
        let state = try RecordingSettingsStore.read(MemorySource(result))
        XCTAssertTrue(state.snapshot.regionsAreStandard)
        XCTAssertEqual(state.snapshot.settings.mode, .eventOnly)
        XCTAssertEqual(state.snapshot.regions.normalStart, 0)
        XCTAssertEqual(state.snapshot.regions.eventStart, UInt32(plain.firstRecordSector))
        XCTAssertEqual(state.snapshot.generation, 2)
        XCTAssertEqual(SettingsFixture.sector(result, plain.controlSector), SettingsFixture.sector(result, plain.backupControlSector))
        let header = try ControlHeader.locate(in: MemorySource(result))
        XCTAssertEqual(header.firstRecordSector, UInt64(plain.firstRecordSector))
        XCTAssertEqual(changedSectors(d, result), [8, 62], "a pure layout change leaves the channel sectors as they are, like the original")
    }

    // MARK: command files through writeCopy
    func testWriteCopyAddsAndRemovesCommandFilesOnAFATImage() throws {
        let d = SettingsFixture.image(fat, fat: true)
        let input = try temp(d)
        let first = output()
        let t = try localTime()
        let summary = try RecordingSettingsStore.writeCopy(of: input, to: first, new: nil, commandFiles: [.writeTime(t), .requestAngleDetection], preferClone: false)
        XCTAssertNil(summary.plan)
        XCTAssertEqual(summary.commandFiles, [.writeTime(t), .requestAngleDetection])
        let written = try Data(contentsOf: first)
        XCTAssertEqual(RecordingSettingsStore.readCommandState(MemorySource(written)), CardCommandState(timeFileExists: true, time: t, angleDetectionRequested: true))
        for n in 0..<(d.count / 512) where n == 0 || n > fat.partitionSectors {
            XCTAssertEqual(SettingsFixture.sector(written, n), SettingsFixture.sector(d, n), "sector \(n) is outside the FAT16 partition")
        }
        XCTAssertEqual(try Data(contentsOf: input), d)
        let second = output()
        _ = try RecordingSettingsStore.writeCopy(of: first, to: second, new: nil, commandFiles: [.removeTime, .cancelAngleDetection], preferClone: false)
        XCTAssertEqual(RecordingSettingsStore.readCommandState(MemorySource(try Data(contentsOf: second))), CardCommandState.absent)
    }
    func testWriteCopyCombinesSettingsAndCommandFiles() throws {
        let d = SettingsFixture.image(fat, fat: true)
        let input = try temp(d)
        let out = output()
        let t = try localTime()
        let wanted = try current(d) { $0.frameRateIndex = 1 }
        let summary = try RecordingSettingsStore.writeCopy(of: input, to: out, new: wanted, commandFiles: [.writeTime(t)], preferClone: false)
        let result = try Data(contentsOf: out)
        XCTAssertEqual(try RecordingSettingsStore.read(MemorySource(result)).snapshot.settings, wanted)
        XCTAssertEqual(RecordingSettingsStore.readCommandState(MemorySource(result))?.time, t)
        XCTAssertEqual(summary.plan?.changesAnything, true)
        // identical settings plus a command file is still a valid request
        let again = output()
        _ = try RecordingSettingsStore.writeCopy(of: out, to: again, new: wanted, commandFiles: [.requestAngleDetection], preferClone: false)
        XCTAssertEqual(RecordingSettingsStore.readCommandState(MemorySource(try Data(contentsOf: again)))?.angleDetectionRequested, true)
    }
    func testCommandFilesAreRefusedWhenTheImageHasNoFAT16Volume() throws {
        let d = SettingsFixture.image(plain)
        let input = try temp(d)
        let out = output()
        XCTAssertThrowsError(try RecordingSettingsStore.writeCopy(of: input, to: out, new: nil, commandFiles: [.requestAngleDetection], preferClone: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a failed run leaves no partial copy")
        XCTAssertEqual(try Data(contentsOf: input), d)
    }
}
