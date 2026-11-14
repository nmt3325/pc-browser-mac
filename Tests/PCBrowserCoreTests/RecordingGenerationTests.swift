import XCTest
@testable import PCBrowserCore

/// 録画データ削除 / 記録設定データ初期化 and the reader rule behind them, on SYNTHETIC images: generic bytes and made-up generation values only.
final class RecordingGenerationTests: XCTestCase {
    let plain = SettingsFixture.plain

    // MARK: fixtures
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
        XCTAssertEqual(a.count, b.count)
        var result: [Int] = []
        a.withUnsafeBytes { (pa: UnsafeRawBufferPointer) in
            b.withUnsafeBytes { (pb: UnsafeRawBufferPointer) in
                for n in 0..<(min(a.count, b.count) / 512) where memcmp(pa.baseAddress! + n * 512, pb.baseAddress! + n * 512, 512) != 0 { result.append(n) }
            }
        }
        return result
    }

    struct Head { let stamp: UInt8; let generation: UInt32 }
    /// First header of a recording area: stream magic, its own sector number at 0x1E0, the card generation stamp at 0xA0, the ring generation at 0x1F8.
    func streamHeader(magic: UInt32, sector: Int, _ head: Head) -> Data {
        var d = [UInt8](repeating: 0, count: 512)
        SettingsFixture.word(magic, 0, &d)
        SettingsFixture.word(UInt32(sector), 0x1E0, &d)
        d[0xA0] = head.stamp
        SettingsFixture.word(head.generation, 0x1F8, &d)
        return Data(d)
    }
    /// First record of the journal: its magic and the ring lap in the upper half of the dword at 0xC4.
    func journalHead(magic: UInt32 = 0xFFFF_E202, lap: UInt32) -> Data {
        var d = [UInt8](repeating: 0, count: 512)
        SettingsFixture.word(magic, 0, &d)
        SettingsFixture.word(lap << 16 | 0x0123, 0xC4, &d)
        return Data(d)
    }
    func put(_ bytes: Data, _ sector: Int, _ d: inout Data) { SettingsFixture.put(bytes, sector: sector, into: &d) }

    /// The `plain` image (control 8, channel 9, regions 12–13 / 14–15 / journal 16–60, backups 61 and 62) with a sealed control sector of the
    /// given generation state and head headers at the three region starts.
    func card(generation: UInt8 = 4, counters: [UInt32] = [2, 2, 2], normal: Head? = nil, event: Head? = nil, lap: UInt32? = nil) -> Data {
        let g = plain
        var d = SettingsFixture.image(g)
        let f = SettingsFixture.factoryBytes(first: UInt32(g.firstRecordSector), table: g.regionWords)
        var control = f.control
        control[0x00] = generation; control[0x1FF] = generation
        for (i, c) in counters.enumerated() { SettingsFixture.word(c, 0x1E0 + i * 4, &control) }
        let sealed = SettingsFixture.seal(control, f.channel)
        put(sealed.control, g.controlSector, &d); put(sealed.channel, g.channelSector, &d)
        put(sealed.channel, g.backupChannelSector, &d); put(sealed.control, g.backupControlSector, &d)
        let words = g.regionWords
        if let h = normal { put(streamHeader(magic: 0xFFFF_D105, sector: Int(words[0]), h), Int(words[0]), &d) }
        if let h = event { put(streamHeader(magic: 0xFFFF_D103, sector: Int(words[2]), h), Int(words[2]), &d) }
        if let l = lap { put(journalHead(lap: l), Int(words[4]), &d) }
        return d
    }
    func report(_ d: Data) -> GenerationReport? {
        RecordingGeneration.report(in: MemorySource(d), controlSector: UInt64(plain.controlSector))
    }

    // MARK: generation state and the reader rule
    func testStateNeedsASealedSingleChannelControlWithMatchingTailGeneration() throws {
        let f = SettingsFixture.factoryBytes()
        let sealed = SettingsFixture.seal(f.control, f.channel)
        XCTAssertEqual(RecordingGeneration.state(control: [UInt8](sealed.control), channel: [UInt8](sealed.channel)), GenerationState(generation: 1, counters: [1, 1, 1]))
        func refuse(_ name: String, _ mutate: (inout [UInt8], inout [UInt8]) -> Void) {
            var c = f.control, ch = f.channel
            mutate(&c, &ch)
            let s = SettingsFixture.seal(c, ch)
            XCTAssertNil(RecordingGeneration.state(control: [UInt8](s.control), channel: [UInt8](s.channel)), name)
        }
        refuse("generation zero", { c, _ in c[0x00] = 0; c[0x1FF] = 0 })
        refuse("tail differs from the generation", { c, _ in c[0x1FF] = 2 })
        refuse("two channels", { c, _ in c[0x14] = 2 })
        refuse("marker", { c, _ in c[3] = 0x58 })
        refuse("tail marker", { c, _ in c[0x1F0] = 0x58 })
        var broken = [UInt8](sealed.control)
        broken[0x1E4] ^= 0x01
        XCTAssertNil(RecordingGeneration.state(control: broken, channel: [UInt8](sealed.channel)), "a stored checksum that does not match")
        XCTAssertNil(RecordingGeneration.state(control: [UInt8](sealed.control), channel: [UInt8](repeating: 0, count: 100)))
    }
    func testAHeadIsVisibleOnlyWithTheCardStampAndAGenerationAboveTheCounter() throws {
        let visible = try XCTUnwrap(report(card(normal: Head(stamp: 4, generation: 9), event: Head(stamp: 4, generation: 3), lap: 3)))
        XCTAssertEqual(visible.state, GenerationState(generation: 4, counters: [2, 2, 2]))
        XCTAssertEqual(visible.heads.map { $0.kind }, [.normal, .event, .history])
        XCTAssertEqual(visible.heads.map { $0.generation }, [9, 3, 3])
        XCTAssertEqual(visible.heads.map { $0.stamp }, [4, 4, nil])
        XCTAssertEqual(visible.heads.map { $0.sector }, [12, 14, 16])
        XCTAssertTrue(visible.hidden.isEmpty)
        XCTAssertEqual(visible.loaded.count, 3)

        let hidden = try XCTUnwrap(report(card(normal: Head(stamp: 3, generation: 9), event: Head(stamp: 4, generation: 2), lap: 1)))
        XCTAssertEqual(hidden.hidden.map { $0.kind }, [.normal, .event, .history])
        XCTAssertEqual(hidden.hidden[0].reason, .staleStamp(stamp: 3, generation: 4), "a stamp that is not the card generation")
        XCTAssertEqual(hidden.hidden[1].reason, .notNewerThanCounter(generation: 2, counter: 2), "a generation equal to the counter is not newer")
        XCTAssertEqual(hidden.hidden[2].reason, .notNewerThanCounter(generation: 1, counter: 2), "a journal lap below the counter")
        XCTAssertTrue(hidden.loaded.isEmpty)
        XCTAssertTrue(hidden.hidden[0].text.contains("常時録画"))
        XCTAssertTrue(hidden.hidden[2].text.contains("履歴記録"))

        let mixed = try XCTUnwrap(report(card(normal: Head(stamp: 4, generation: 9), event: Head(stamp: 3, generation: 9), lap: 2)))
        XCTAssertEqual(mixed.hidden.map { $0.kind }, [.event, .history])
        XCTAssertEqual(mixed.loaded.map { $0.kind }, [.normal])
    }
    func testWhatCannotBeJudgedStaysVisible() throws {
        let none = try XCTUnwrap(report(card()))
        XCTAssertTrue(none.heads.isEmpty)
        XCTAssertTrue(none.hidden.isEmpty, "only positive evidence hides recordings")

        var d = card()
        put(streamHeader(magic: 0xFFFF_D105, sector: 99, Head(stamp: 1, generation: 0)), 12, &d)   // names another sector as its own
        put(streamHeader(magic: 0xFFFF_D102, sector: 14, Head(stamp: 1, generation: 0)), 14, &d)   // a packet header, not the head of an area
        put(journalHead(magic: 0xFFFF_E203, lap: 0), 16, &d)                                        // not a journal record
        XCTAssertTrue(try XCTUnwrap(report(d)).heads.isEmpty)

        var unsealed = card(normal: Head(stamp: 1, generation: 0))
        unsealed[plain.controlSector * 512 + 0x20] ^= 0x01
        XCTAssertNil(report(unsealed), "a control sector whose checksum does not match is not judged")
        XCTAssertNil(RecordingGeneration.report(in: MemorySource(Data(count: 512)), controlSector: 8))
    }

    // MARK: delete plan and copy
    func testDeletePlanRaisesTheGenerationAndPutsEveryCounterAboveWhatWasLoaded() throws {
        let d = card(normal: Head(stamp: 4, generation: 9), event: Head(stamp: 4, generation: 7), lap: 6)
        let plan = try RecordingDataEraser.plan(MemorySource(d), operation: .deleteRecordings)
        XCTAssertEqual(plan.before, GenerationState(generation: 4, counters: [2, 2, 2]))
        XCTAssertEqual(plan.after, GenerationState(generation: 5, counters: [10, 8, 7]))
        XCTAssertEqual(plan.loadedRegions, [.normal, .event, .history])
        XCTAssertTrue(plan.hiddenBefore.isEmpty)
        XCTAssertEqual(plan.settingsAfter, plan.settingsBefore)
        XCTAssertEqual(plan.changes, ["世代番号 4→5"])
        XCTAssertEqual(plan.patches.map { $0.role }, [.control, .channel, .controlBackup, .channelBackup])
        XCTAssertEqual(plan.patches.map { $0.sector }, [8, 9, 62, 61])
        XCTAssertEqual(plan.patches.map { $0.old != $0.new }, [true, false, true, false], "the channel sector and its backup are rewritten unchanged")
        XCTAssertEqual(plan.patches[0].new, plan.patches[2].new)
        XCTAssertEqual(plan.patches[1].new, plan.patches[3].new)
        let old = [UInt8](plan.patches[0].old), new = [UInt8](plan.patches[0].new)
        let differing = (0..<512).filter { old[$0] != new[$0] && $0 != 0x12 && $0 != 0x13 }
        XCTAssertEqual(differing, [0x00, 0x1E0, 0x1E4, 0x1E8, 0x1FF], "generation, tail copy and the three counters; nothing else but the checksum")
        XCTAssertEqual([new[0x00], new[0x1FF]], [5, 5])
        XCTAssertEqual([0x1E0, 0x1E4, 0x1E8].map { SettingsFixture.readWord(plan.patches[0].new, $0) }, [10, 8, 7])
        XCTAssertEqual(SettingsFixture.seal(new, [UInt8](plan.patches[1].new)).control, plan.patches[0].new, "checksum recomputed")
        XCTAssertTrue(plan.changesAnything)
    }
    func testRegionsThatWereNotLoadedOnlyCatchUpWithTheNewGeneration() throws {
        let d = card(generation: 4, counters: [2, 8, 2], normal: Head(stamp: 4, generation: 9))
        let plan = try RecordingDataEraser.plan(MemorySource(d), operation: .deleteRecordings)
        XCTAssertEqual(plan.loadedRegions, [.normal])
        XCTAssertEqual(plan.after, GenerationState(generation: 5, counters: [10, 8, 5]), "a counter never goes backwards and never stays below the generation")
        let hiddenOnly = try RecordingDataEraser.plan(MemorySource(card(normal: Head(stamp: 1, generation: 9))), operation: .deleteRecordings)
        XCTAssertTrue(hiddenOnly.loadedRegions.isEmpty)
        XCTAssertEqual(hiddenOnly.hiddenBefore.map { $0.kind }, [.normal])
        XCTAssertEqual(hiddenOnly.after, GenerationState(generation: 5, counters: [5, 5, 5]))
    }
    func testDeleteCopyChangesOnlyTheControlSectorAndItsBackupAndLeavesTheInputAlone() throws {
        let d = card(normal: Head(stamp: 4, generation: 9), event: Head(stamp: 4, generation: 7), lap: 6)
        let input = try temp(d), out = output()
        let summary = try RecordingDataEraser.writeCopy(of: input, to: out, operation: .deleteRecordings, preferClone: false)
        XCTAssertTrue(summary.verified)
        XCTAssertFalse(summary.usedClone)
        let result = try Data(contentsOf: out)
        XCTAssertEqual(changedSectors(d, result), [8, 62], "no recorded data is touched")
        XCTAssertEqual(try Data(contentsOf: input), d)
        XCTAssertEqual(SettingsFixture.sector(result, 8), SettingsFixture.sector(result, 62))
        let state = try RecordingSettingsStore.read(MemorySource(result))
        XCTAssertEqual(state.snapshot.settings, RecordingSettings.factoryDefault, "deleting recordings leaves every setting alone")
        XCTAssertTrue(state.backupControlMatches)
        XCTAssertTrue(state.backupChannelMatches)
        let after = try XCTUnwrap(report(result))
        XCTAssertEqual(after.state, GenerationState(generation: 5, counters: [10, 8, 7]))
        XCTAssertEqual(after.hidden.map { $0.kind }, [.normal, .event, .history])
        XCTAssertEqual(summary.plan.after, after.state)
        let mode = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testDeleteCopyMayUseAnAPFSCloneAndGivesTheSameResult() throws {
        let d = card(normal: Head(stamp: 4, generation: 9), lap: 6)
        let input = try temp(d), cloned = output(), copied = output()
        _ = try RecordingDataEraser.writeCopy(of: input, to: cloned, operation: .deleteRecordings)
        _ = try RecordingDataEraser.writeCopy(of: input, to: copied, operation: .deleteRecordings, preferClone: false)
        XCTAssertEqual(try Data(contentsOf: cloned), try Data(contentsOf: copied))
        XCTAssertEqual(try Data(contentsOf: input), d)
    }
    func testDeletingAgainKeepsRaisingTheGenerationAndLeavesTheCounters() throws {
        let d = card(normal: Head(stamp: 4, generation: 9), event: Head(stamp: 4, generation: 7), lap: 6)
        let input = try temp(d), first = output(), second = output()
        _ = try RecordingDataEraser.writeCopy(of: input, to: first, operation: .deleteRecordings, preferClone: false)
        let again = try RecordingDataEraser.writeCopy(of: first, to: second, operation: .deleteRecordings, preferClone: false)
        XCTAssertEqual(again.plan.hiddenBefore.map { $0.kind }, [.normal, .event, .history])
        XCTAssertTrue(again.plan.loadedRegions.isEmpty)
        XCTAssertEqual(again.plan.after, GenerationState(generation: 6, counters: [10, 8, 7]))
        XCTAssertEqual(try XCTUnwrap(report(try Data(contentsOf: second))).state, again.plan.after)
    }
    func testRecordingsMadeAfterTheDeletionAreListedAgain() throws {
        let d = card(normal: Head(stamp: 4, generation: 9), event: Head(stamp: 4, generation: 7), lap: 6)
        let input = try temp(d), out = output()
        _ = try RecordingDataEraser.writeCopy(of: input, to: out, operation: .deleteRecordings, preferClone: false)
        var result = try Data(contentsOf: out)
        XCTAssertEqual(try XCTUnwrap(report(result)).hidden.count, 3)
        // The recorder starts a new ring lap in the normal area under the new generation, above the counter.
        put(streamHeader(magic: 0xFFFF_D105, sector: 12, Head(stamp: 5, generation: 11)), 12, &result)
        let later = try XCTUnwrap(report(result))
        XCTAssertEqual(later.hidden.map { $0.kind }, [.event, .history])
        XCTAssertEqual(later.loaded.map { $0.kind }, [.normal])
        // Same stamp but a lap that does not exceed the counter stays hidden.
        put(streamHeader(magic: 0xFFFF_D105, sector: 12, Head(stamp: 5, generation: 10)), 12, &result)
        XCTAssertEqual(try XCTUnwrap(report(result)).hidden.map { $0.kind }, [.normal, .event, .history])
    }
    func testWriteCopyRefusesUnsafeOutputsAndCardsItCannotJudge() throws {
        let d = card(normal: Head(stamp: 4, generation: 9))
        let input = try temp(d)
        XCTAssertThrowsError(try RecordingDataEraser.writeCopy(of: input, to: input, operation: .deleteRecordings), "the input is never the output")
        let existing = output()
        try Data([1]).write(to: existing)
        XCTAssertThrowsError(try RecordingDataEraser.writeCopy(of: input, to: existing, operation: .deleteRecordings), "no overwriting")
        XCTAssertEqual(try Data(contentsOf: existing), Data([1]))
        XCTAssertThrowsError(try RecordingDataEraser.writeCopy(of: input, to: URL(fileURLWithPath: "/dev/null"), operation: .deleteRecordings), "no device files")
        let missingFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("x.img")
        XCTAssertThrowsError(try RecordingDataEraser.writeCopy(of: input, to: missingFolder, operation: .deleteRecordings))
        XCTAssertEqual(try Data(contentsOf: input), d)
        XCTAssertThrowsError(try RecordingDataEraser.plan(MemorySource(card(generation: 0)), operation: .deleteRecordings)) { error in
            XCTAssertTrue(error.localizedDescription.contains("世代番号"), "\(error)")
        }
        XCTAssertThrowsError(try RecordingDataEraser.plan(MemorySource(card(generation: 255)), operation: .deleteRecordings)) { error in
            XCTAssertTrue(error.localizedDescription.contains("255"), "\(error)")
        }
        var noBackup = card()
        put(Data(count: 512), plain.backupControlSector, &noBackup)
        XCTAssertThrowsError(try RecordingDataEraser.plan(MemorySource(noBackup), operation: .deleteRecordings)) { error in
            XCTAssertTrue(error.localizedDescription.contains("バックアップ"), "\(error)")
        }
        XCTAssertThrowsError(try RecordingDataEraser.plan(MemorySource(Data(count: 64 * 512)), operation: .deleteRecordings))
    }

    // MARK: initialization
    func testInitializationNeedsRoomForTheStandardLayout() throws {
        XCTAssertThrowsError(try RecordingDataEraser.plan(MemorySource(card()), operation: .initializeSettings), "64 sectors cannot hold the 24 hour history of the default layout")
        XCTAssertNoThrow(try RecordingDataEraser.plan(MemorySource(card()), operation: .deleteRecordings))
    }
    /// A large synthetic card whose settings all differ from the defaults: 2 / event-only / double-rate 24 h history / password / multi-battery.
    func customCard(lap: UInt32? = nil) throws -> (image: Data, settings: RecordingSettings) {
        let big = SettingsFixture.large
        var d = SettingsFixture.image(big)
        var custom = RecordingSettings()
        custom.setMode(.eventOnly)
        custom.frameRateIndex = 2; custom.eventWindowIndex = 3; custom.audioEnabled = false
        custom.historyHoursIndex = 0; custom.historyDoubleRate = true
        custom.overwriteEvent = false; custom.overwriteHistory = false; custom.beepEnabled = false
        custom.easyMode = false; custom.shockSensitivity = 2; custom.accelerationSensitivity = 3; custom.steeringSensitivity = 4
        custom.multiBatteryConnected = true; custom.cardID = "SYNTH-ID-1"; custom.password = 1234
        let base = SettingsFixture.factory(first: UInt32(big.firstRecordSector), table: big.regionWords)
        let edit = try RecordingSettingsCodec.apply(custom, control: base.control, channel: base.channel)
        put(edit.control, big.controlSector, &d); put(edit.channel, big.channelSector, &d)
        put(edit.channel, big.backupChannelSector, &d); put(edit.control, big.backupControlSector, &d)
        if let l = lap {
            let table = RecordingRegionTable(sector: [UInt8](edit.control))
            put(journalHead(lap: l), Int(table.journalStart), &d)
        }
        return (d, edit.settings)
    }
    func testInitializationResetsTheSettingsPasswordAndLayoutButKeepsTheCardID() throws {
        let built = try customCard(lap: 7)
        let start = try RecordingSettingsStore.read(MemorySource(built.image))
        XCTAssertEqual(start.snapshot.settings, built.settings)
        XCTAssertEqual(start.snapshot.generation, 2, "the settings save that built the card raised the generation")
        let plan = try RecordingDataEraser.plan(MemorySource(built.image), operation: .initializeSettings)
        var expected = RecordingSettings()
        expected.eventWindowIndex = 0; expected.historyHoursIndex = 0; expected.cardID = "SYNTH-ID-1"
        XCTAssertEqual(plan.settingsAfter, expected)
        XCTAssertEqual(plan.settingsBefore, built.settings)
        XCTAssertEqual(plan.loadedRegions, [.history])
        XCTAssertEqual(plan.after, GenerationState(generation: 3, counters: [3, 3, 8]))
        XCTAssertEqual(plan.patches.map { $0.old != $0.new }, [true, true, true, true])
        let control = [UInt8](plan.patches[0].new), channel = [UInt8](plan.patches[1].new)
        let decoded = try RecordingSettingsCodec.decode(control: plan.patches[0].new, channel: plan.patches[1].new)
        XCTAssertEqual(decoded.settings, expected)
        XCTAssertTrue(decoded.regionsAreStandard)
        XCTAssertEqual(decoded.regions, RecordingRegionTable(normalStart: 12, normalEnd: 217_824, eventStart: 217_825, eventEnd: 306_800, journalStart: 306_801, journalEnd: 350_000))
        XCTAssertEqual([0x3A, 0x3B, 0x3C].map { control[$0] }, [2, 2, 2], "overwrite flags")
        XCTAssertEqual([control[0x3E], control[0x3F]], [3, 1], "record mode and audio")
        XCTAssertEqual([0x46, 0x47, 0x48, 0x49, 0x4A].map { control[$0] }, [5, 2, 5, 5, 5], "G sensor and sensitivities")
        XCTAssertEqual(control[0x50], 3, "beep")
        XCTAssertEqual([control[0x54], control[0x97]], [0, 2], "only the first multi-battery byte is reset")
        XCTAssertEqual(Array(control[0x88..<0x8B]), [0, 0, 0], "password cleared")
        XCTAssertEqual(Array(control[0x66..<0x71]), Array("SYNTH-ID-1".utf8) + [0], "the card ID stays")
        XCTAssertEqual([control[0x00], control[0x1FF]], [3, 3])
        XCTAssertEqual([0x1E0, 0x1E4, 0x1E8].map { SettingsFixture.readWord(plan.patches[0].new, $0) }, [3, 3, 8])
        XCTAssertEqual(Array(channel[0x20..<0x39]), Array(control[0x20..<0x39]), "the channel sector mirrors the record block")
        XCTAssertEqual(SettingsFixture.seal(control, channel).control, plan.patches[0].new)
        XCTAssertEqual(plan.patches[0].new, plan.patches[2].new)
        XCTAssertEqual(plan.patches[1].new, plan.patches[3].new)
        XCTAssertTrue(plan.changes.contains("世代番号 2→3"))
    }
    func testInitializationCopyWritesTheFourManagementSectorsAndVerifiesThem() throws {
        let built = try customCard()
        let input = try temp(built.image), out = output()
        let summary = try RecordingDataEraser.writeCopy(of: input, to: out, operation: .initializeSettings, preferClone: false)
        XCTAssertTrue(summary.verified)
        let big = SettingsFixture.large
        let result = try Data(contentsOf: out)
        XCTAssertEqual(changedSectors(built.image, result), [big.controlSector, big.channelSector, big.backupChannelSector, big.backupControlSector])
        XCTAssertEqual(try Data(contentsOf: input), built.image)
        let state = try RecordingSettingsStore.read(MemorySource(result))
        XCTAssertEqual(state.snapshot.settings, summary.plan.settingsAfter)
        XCTAssertTrue(state.snapshot.regionsAreStandard)
        XCTAssertTrue(state.backupControlMatches)
        XCTAssertTrue(state.backupChannelMatches)
        XCTAssertNil(state.snapshot.settings.password)
        XCTAssertEqual(state.snapshot.settings.cardID, "SYNTH-ID-1")
        let control = SettingsFixture.sector(result, big.controlSector), channel = SettingsFixture.sector(result, big.channelSector)
        XCTAssertEqual(RecordingGeneration.state(control: [UInt8](control), channel: [UInt8](channel)), summary.plan.after)
        // A second initialization finds the default card: nothing but the generation moves.
        let second = output()
        let again = try RecordingDataEraser.writeCopy(of: out, to: second, operation: .initializeSettings, preferClone: false)
        XCTAssertEqual(again.plan.settingsAfter, again.plan.settingsBefore)
        XCTAssertEqual(again.plan.after.generation, 4)
        XCTAssertEqual(again.plan.patches.map { $0.old != $0.new }, [true, false, true, false])
    }

    // MARK: settings model and codec
    func testInitializationDefaultsKeepTheCardIDOnly() {
        var s = RecordingSettings()
        s.cardID = "SYNTH"; s.password = 4321; s.multiBatteryConnected = true; s.setMode(.eventOnly); s.historyHoursIndex = 2
        let dialog = s.resettingToDialogDefaults(), initial = s.resettingForInitialization()
        XCTAssertEqual(dialog.password, 4321, "「初期設定に戻す」 keeps the password")
        XCTAssertTrue(dialog.multiBatteryConnected)
        XCTAssertNil(initial.password)
        XCTAssertFalse(initial.multiBatteryConnected)
        XCTAssertEqual(initial.cardID, "SYNTH")
        XCTAssertEqual(initial.mode, .continuousAndEvent)
        XCTAssertEqual(initial.eventWindowIndex, 0)
        XCTAssertEqual(initial.historyHoursIndex, 0)
        XCTAssertEqual(initial.frameRateIndex, 0)
    }
    func testBatteryBytesFollowTheOriginalsRules() throws {
        let f = SettingsFixture.factory()
        var connected = RecordingSettings()
        connected.multiBatteryConnected = true
        let on = try RecordingSettingsCodec.apply(connected, control: f.control, channel: f.channel)
        XCTAssertEqual([on.control[0x54], on.control[0x97]], [1, 2])
        let off = try RecordingSettingsCodec.apply(RecordingSettings(), control: on.control, channel: on.channel)
        XCTAssertEqual([off.control[0x54], off.control[0x97]], [0, 0], "unticking from the connected state resets both")
        // 記録設定データ初期化 leaves (0, 2): that reads as not connected, and later saves keep the second byte until the setting changes again.
        var odd = [UInt8](on.control)
        odd[0x54] = 0
        let sealed = SettingsFixture.seal(odd, [UInt8](on.channel))
        let decoded = try RecordingSettingsCodec.decode(control: sealed.control, channel: sealed.channel)
        XCTAssertFalse(decoded.settings.multiBatteryConnected)
        var beep = decoded.settings
        beep.beepEnabled = false
        let kept = try RecordingSettingsCodec.apply(beep, control: sealed.control, channel: sealed.channel)
        XCTAssertEqual([kept.control[0x54], kept.control[0x97]], [0, 2])
        let again = try RecordingSettingsCodec.apply(connected, control: kept.control, channel: kept.channel)
        XCTAssertEqual([again.control[0x54], again.control[0x97]], [1, 2])
        // Pairs the original never writes are still refused.
        let fb = SettingsFixture.factoryBytes()
        for pair in [(UInt8(1), UInt8(0)), (0, 1), (0, 3), (2, 2), (1, 1)] {
            var c = fb.control
            c[0x54] = pair.0; c[0x97] = pair.1
            let s = SettingsFixture.seal(c, fb.channel)
            XCTAssertThrowsError(try RecordingSettingsCodec.decode(control: s.control, channel: s.channel), "battery pair \(pair)")
        }
    }
    func testOperationTextsMatchTheOriginalsDialogs() {
        XCTAssertEqual(RecordingDataOperation.deleteRecordings.title, "録画データ削除")
        XCTAssertEqual(RecordingDataOperation.initializeSettings.title, "記録設定データ初期化")
        XCTAssertEqual(RecordingDataOperation.deleteRecordings.confirmation, "録画データの削除を行います。\nよろしいですか？")
        XCTAssertEqual(RecordingDataOperation.initializeSettings.confirmation, "録画データの削除、\n記録設定データの初期化を行います。\nよろしいですか？")
        XCTAssertNil(RecordingDataOperation.deleteRecordings.settingsChangedWarning)
        XCTAssertEqual(RecordingDataOperation.initializeSettings.settingsChangedWarning, "設定が変更されたため録画データが削除されます。続行しますか？")
        XCTAssertEqual(RecordingDataOperation.deleteRecordings.completion, "録画データの削除が完了しました。")
        XCTAssertEqual(RecordingDataOperation.initializeSettings.completion, "記録設定データの初期化が完了しました。")
        XCTAssertEqual(RecordingDataOperation(name: "Delete"), .deleteRecordings)
        XCTAssertEqual(RecordingDataOperation(name: "initialize"), .initializeSettings)
        XCTAssertEqual(RecordingDataOperation(name: "init"), .initializeSettings)
        XCTAssertEqual(RecordingDataOperation(name: "初期化"), .initializeSettings)
        XCTAssertNil(RecordingDataOperation(name: "format"))
        XCTAssertEqual(RecordingDataOperation.allCases.map { $0.rawValue }, ["delete", "initialize"])
    }

    // MARK: catalog
    /// The three blocks of the catalog fixture (sectors 10, 22 and 34) inside a normal area 10–50 of a 100-sector image whose control sector is
    /// sealed. The first block is the head of the area: it carries `stamp` and ring generation `ring`.
    func catalogCard(generation: UInt8 = 3, counters: [UInt32] = [1, 1, 1], stamp: UInt8 = 3, ring: UInt32 = 5, lap: UInt32? = nil) -> Data {
        let specs = [CatalogTests.Spec(record: 10, generation: ring, start: true), CatalogTests.Spec(record: 22, ordinal: 2, generation: ring),
                     CatalogTests.Spec(record: 34, ordinal: 4, generation: ring)]
        var d = CatalogTests().fixture(specs)
        d[10 * 512 + 0xA0] = stamp
        let f = SettingsFixture.factoryBytes(first: 10, table: [10, 50, 51, 80, 81, 96])
        var control = f.control
        control[0x00] = generation; control[0x1FF] = generation
        for (i, c) in counters.enumerated() { SettingsFixture.word(c, 0x1E0 + i * 4, &control) }
        let sealed = SettingsFixture.seal(control, f.channel)
        put(sealed.control, 8, &d); put(sealed.channel, 9, &d); put(sealed.channel, 97, &d); put(sealed.control, 98, &d)
        if let l = lap { put(journalHead(lap: l), 81, &d) }
        return d
    }
    func testCatalogListsAVisibleAreaAndSkipsOneThatWasDeleted() throws {
        let visible = try CatalogScanner.scan(MemorySource(catalogCard()))
        XCTAssertEqual(visible.recordings.count, 1)
        XCTAssertEqual(visible.frameCount, 6)
        XCTAssertTrue(visible.hiddenRegions.isEmpty)

        let stale = try CatalogScanner.scan(MemorySource(catalogCard(stamp: 2)))
        XCTAssertEqual(stale.recordings.count, 0, "head stamp is not the card generation")
        XCTAssertEqual(stale.hiddenRegions.map { $0.kind }, [.normal])
        XCTAssertEqual(stale.frameCount, 0)

        let counted = try CatalogScanner.scan(MemorySource(catalogCard(counters: [5, 1, 1])))
        XCTAssertEqual(counted.recordings.count, 0, "ring generation equal to the counter")
        let newer = try CatalogScanner.scan(MemorySource(catalogCard(counters: [4, 1, 1])))
        XCTAssertEqual(newer.recordings.count, 1, "ring generation above the counter")

        let raw = try CatalogScanner.scan(MemorySource(catalogCard(stamp: 2)), honorDeletion: false)
        XCTAssertEqual(raw.recordings.count, 1, "the gate can be switched off")
        XCTAssertTrue(raw.hiddenRegions.isEmpty)
        let recovery = try ImageScanner.scan(MemorySource(catalogCard(stamp: 2)))
        XCTAssertEqual(recovery.frameCount, 6, "the recovery scan does not look at generations")
    }
    func testDeleteCopyHidesTheCatalogAndTheJournalButNotTheRecoveryScan() throws {
        let d = catalogCard(lap: 4)
        let before = try CatalogScanner.scan(MemorySource(d))
        XCTAssertEqual(before.recordings.count, 1)
        XCTAssertNotNil(before.historyArea)
        XCTAssertEqual(before.historyArea, before.layout?.history)
        let input = try temp(d), out = output()
        let summary = try RecordingDataEraser.writeCopy(of: input, to: out, operation: .deleteRecordings, preferClone: false)
        XCTAssertEqual(summary.plan.loadedRegions, [.normal, .history])
        XCTAssertEqual(summary.plan.after, GenerationState(generation: 4, counters: [6, 4, 5]))
        let result = try Data(contentsOf: out)
        XCTAssertEqual(changedSectors(d, result), [8, 98], "recorded data stays where it was")
        let source = MemorySource(result)
        let after = try CatalogScanner.scan(source)
        XCTAssertEqual(after.recordings.count, 0)
        XCTAssertEqual(after.blockCount, 0)
        XCTAssertEqual(after.hiddenRegions.map { $0.kind }, [.normal, .history])
        XCTAssertNil(after.historyArea, "the journal is hidden")
        XCTAssertNotNil(after.layout?.history, "the table itself is unchanged")
        XCTAssertEqual(try CatalogScanner.scan(source, honorDeletion: false).recordings.count, 1)
        XCTAssertEqual(try ImageScanner.scan(source).frameCount, 6)
    }
}
