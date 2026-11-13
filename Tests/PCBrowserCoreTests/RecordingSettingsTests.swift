import XCTest
import CryptoKit
@testable import PCBrowserCore

/// Byte-level tests of the 記録設定 codec. Every expected delta below was observed by driving the original dialog (writes swallowed)
/// on a factory-fresh single-channel card; the fixtures are SYNTHETIC sectors made of generic bytes only.
final class RecordingSettingsTests: XCTestCase {
    static let journalEnd: UInt32 = SettingsFixture.journalEnd

    // MARK: fixtures (shared with the store tests: see SettingsFixture)
    func word(_ v: UInt32, _ at: Int, _ d: inout [UInt8]) { SettingsFixture.word(v, at, &d) }
    func readWord(_ d: Data, _ at: Int) -> UInt32 { SettingsFixture.readWord(d, at) }
    func seal(_ control: [UInt8], _ channel: [UInt8]) -> (control: Data, channel: Data) { SettingsFixture.seal(control, channel) }
    func factoryBytes(first: UInt32 = 10) -> (control: [UInt8], channel: [UInt8]) { SettingsFixture.factoryBytes(first: first) }
    func factory(first: UInt32 = 10) -> (control: Data, channel: Data) { SettingsFixture.factory(first: first) }
    func changedOffsets(_ a: Data, _ b: Data) -> [Int] {
        var result: [Int] = []
        for i in 0..<512 where i != 0x12 && i != 0x13 && a[a.startIndex + i] != b[b.startIndex + i] { result.append(i) }
        return result
    }
    func apply(_ change: (inout RecordingSettings) -> Void) throws -> (before: (control: Data, channel: Data), edit: RecordingSettingsEdit) {
        let f = factory()
        var s = try RecordingSettingsCodec.decode(control: f.control, channel: f.channel).settings
        change(&s)
        return (f, try RecordingSettingsCodec.apply(s, control: f.control, channel: f.channel))
    }
    func expectDelta(_ name: String, _ expected: [Int: UInt8], _ change: (inout RecordingSettings) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try apply(change)
        XCTAssertEqual(changedOffsets(r.before.control, r.edit.control), expected.keys.sorted(), name, file: file, line: line)
        for (offset, value) in expected { XCTAssertEqual(r.edit.control[offset], value, "\(name) +0x\(String(offset, radix: 16))", file: file, line: line) }
        for i in 0x20..<0x39 { XCTAssertEqual(r.edit.channel[i], r.edit.control[i], "\(name) channel mirror +0x\(String(i, radix: 16))", file: file, line: line) }
        let again = try RecordingSettingsCodec.decode(control: r.edit.control, channel: r.edit.channel)
        XCTAssertEqual(again.settings, r.edit.settings, name, file: file, line: line)
    }

    // MARK: decoding and the identity edit
    func testFactorySectorsDecodeToFactoryDefaults() throws {
        let f = factory()
        let snapshot = try RecordingSettingsCodec.decode(control: f.control, channel: f.channel)
        XCTAssertEqual(snapshot.settings, RecordingSettings.factoryDefault)
        XCTAssertTrue(snapshot.regionsAreStandard)
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(snapshot.regions.journalEnd, RecordingSettingsTests.journalEnd)
        XCTAssertEqual(snapshot.regions.firstRecordSector, 10)
    }
    func testReapplyingTheDecodedSettingsReproducesTheSectorsExactly() throws {
        let f = factory()
        let snapshot = try RecordingSettingsCodec.decode(control: f.control, channel: f.channel)
        let edit = try RecordingSettingsCodec.apply(snapshot.settings, control: f.control, channel: f.channel)
        XCTAssertEqual(edit.control, f.control)
        XCTAssertEqual(edit.channel, f.channel)
        XCTAssertTrue(edit.changes.isEmpty)
        XCTAssertFalse(edit.layoutChanged)
    }
    func testChecksumIsTwiceTheByteSumWithoutTheChecksumField() throws {
        let f = factory()
        XCTAssertEqual(UInt16(f.control[0x12]) | UInt16(f.control[0x13]) << 8, RecordingSettingsCodec.checksum(control: [UInt8](f.control), channels: [[UInt8](f.channel)]))
        let r = try apply { $0.beepEnabled = false; $0.cardID = "Zz" }
        let sealed = seal([UInt8](r.edit.control), [UInt8](r.edit.channel))
        XCTAssertEqual(r.edit.control, sealed.control, "the codec must store the same checksum an independent computation gives")
    }

    // MARK: byte deltas observed on the original
    func testSingleSettingDeltasMatchTheOriginal() throws {
        try expectDelta("beep off", [0x50: 0]) { $0.beepEnabled = false }
        try expectDelta("audio off", [0x3F: 2]) { $0.audioEnabled = false }
        try expectDelta("overwrite continuous off", [0x3A: 1]) { $0.overwriteContinuous = false }
        try expectDelta("overwrite event off", [0x3B: 1]) { $0.overwriteEvent = false }
        try expectDelta("overwrite history off", [0x3C: 1]) { $0.overwriteHistory = false }
        try expectDelta("multi battery", [0x54: 1, 0x97: 2]) { $0.multiBatteryConnected = true }
        try expectDelta("g sensor off", [0x46: 4, 0x47: 0, 0x48: 0, 0x49: 0, 0x4A: 0]) { $0.gSensorEnabled = false }
        try expectDelta("easy slider 8", [0x48: 8, 0x49: 8, 0x4A: 8]) { $0.setEasySensitivity(8) }
        try expectDelta("easy slider 1", [0x48: 1, 0x49: 1, 0x4A: 1]) { $0.setEasySensitivity(1) }
        try expectDelta("easy off, three sliders", [0x47: 1, 0x48: 7, 0x49: 2, 0x4A: 4]) {
            $0.easyMode = false; $0.shockSensitivity = 7; $0.accelerationSensitivity = 2; $0.steeringSensitivity = 4
        }
        try expectDelta("card id", [0x66: 0x61, 0x67: 0x62, 0x68: 0x43, 0x69: 0x64, 0x6A: 0x2D, 0x6B: 0x39]) { $0.cardID = "abCd-9" }
    }
    func testFrameRateAndEventWindowDeltasMatchTheOriginal() throws {
        // 15 frames/s: parameter 11000, count 15, event windows 30 s x 15 = 450 frames.
        try expectDelta("15 fps", [0x22: 0xF8, 0x23: 0x2A, 0x25: 0x0F, 0x2A: 0xF8, 0x2B: 0x2A, 0x2D: 0x0F, 0x2F: 0xC2, 0x30: 0x01,
                                   0x32: 0xF8, 0x33: 0x2A, 0x35: 0x0F, 0x37: 0xC2, 0x38: 0x01]) { $0.frameRateIndex = 1 }
        // 2 frames/minute with 25 s + 25 s: the event records stay at 1 frame/s.
        try expectDelta("2 per minute, 25+25", [0x22: 0xB0, 0x23: 0x36, 0x24: 0x02, 0x25: 0x02, 0x2A: 0xB0, 0x2B: 0x36, 0x2D: 0x01, 0x2F: 0x19, 0x30: 0x00,
                                                0x32: 0xB0, 0x33: 0x36, 0x35: 0x01, 0x37: 0x19, 0x38: 0x00]) { $0.frameRateIndex = 5; $0.eventWindowIndex = 9 }
        // 6 frames/hour keeps the default 30 s + 30 s.
        try expectDelta("6 per hour", [0x22: 0xB0, 0x23: 0x36, 0x24: 0x03, 0x25: 0x06, 0x2A: 0xB0, 0x2B: 0x36, 0x2D: 0x01, 0x2F: 0x1E, 0x30: 0x00,
                                       0x32: 0xB0, 0x33: 0x36, 0x35: 0x01, 0x37: 0x1E, 0x38: 0x00]) { $0.frameRateIndex = 8 }
        try expectDelta("window 12+8", [0x2F: 0x68, 0x30: 0x01, 0x37: 0xF0, 0x38: 0x00]) { $0.eventWindowIndex = 1 }
        try expectDelta("window 15+5", [0x2F: 0xC2, 0x30: 0x01, 0x37: 0x96, 0x38: 0x00]) { $0.eventWindowIndex = 2 }
        try expectDelta("window 20+10", [0x2F: 0x58, 0x30: 0x02, 0x37: 0x2C, 0x38: 0x01]) { $0.eventWindowIndex = 4 }
        try expectDelta("window 20+20", [0x2F: 0x58, 0x30: 0x02, 0x37: 0x58, 0x38: 0x02]) { $0.eventWindowIndex = 5 }
        try expectDelta("window 30+10", [0x37: 0x2C, 0x38: 0x01]) { $0.eventWindowIndex = 7 }
        try expectDelta("window 30+20", [0x37: 0x58, 0x38: 0x02]) { $0.eventWindowIndex = 8 }
    }
    func testEveryFrameRateAndEventWindowRoundTripsAndFollowsTheTables() throws {
        let rates: [(UInt16, UInt8, UInt8, UInt8)] = [(10000, 1, 30, 30), (11000, 1, 15, 15), (12000, 1, 10, 10), (12000, 1, 5, 5), (14000, 1, 1, 1),
                                                       (14000, 2, 2, 1), (14000, 2, 1, 1), (14000, 3, 12, 1), (14000, 3, 6, 1)]
        let windows: [(Int, Int)] = [(10, 10), (12, 8), (15, 5), (18, 12), (20, 10), (20, 20), (25, 15), (30, 10), (30, 20), (25, 25), (30, 30)]
        for (fi, rate) in rates.enumerated() {
            for (wi, window) in windows.enumerated() {
                let r = try apply { $0.frameRateIndex = fi; $0.eventWindowIndex = wi }
                let c = [UInt8](r.edit.control)
                XCTAssertEqual(UInt16(c[0x22]) | UInt16(c[0x23]) << 8, rate.0)
                XCTAssertEqual(c[0x24], rate.1); XCTAssertEqual(c[0x25], rate.2)
                XCTAssertEqual(UInt16(c[0x2F]) | UInt16(c[0x30]) << 8, UInt16(window.0 * Int(rate.3)))
                XCTAssertEqual(UInt16(c[0x37]) | UInt16(c[0x38]) << 8, UInt16(window.1 * Int(rate.3)))
                XCTAssertEqual(c[0x2D], rate.3); XCTAssertEqual(c[0x35], rate.3)
                let back = try RecordingSettingsCodec.decode(control: r.edit.control, channel: r.edit.channel)
                XCTAssertEqual(back.settings.frameRateIndex, fi); XCTAssertEqual(back.settings.eventWindowIndex, wi)
            }
        }
    }

    // MARK: layout changes (region table, backup prompts, generation counters)
    func testEventOnlyModeMovesTheNormalRegionIntoTheEventRegion() throws {
        let r = try apply { $0.mode = .eventOnly }
        XCTAssertTrue(r.edit.layoutChanged)
        let c = r.edit.control
        XCTAssertEqual([0x1BE, 0x1C2, 0x1C6, 0x1CA, 0x1CE, 0x1D2].map { readWord(c, $0) }, [0, 0, 10, 59_697_600, 59_697_601, 60_000_000])
        XCTAssertEqual(c[0x3E], 2)
        XCTAssertEqual(c[0x3A], 1, "the continuous overwrite switch is forced off")
        let g = RecordingSettingsCodec.generationAfterLayoutChange(1)
        XCTAssertEqual(g, 2)
        XCTAssertEqual([0x1E0, 0x1E4, 0x1E8].map { readWord(c, $0) }, [g, g, g])
        XCTAssertEqual(c[0x00], UInt8(g)); XCTAssertEqual(c[0x1FF], UInt8(g))
        XCTAssertEqual(c[0x1D6 + 3], 0xA4, "the format date/time bytes are never touched")
    }
    func testLayoutChangeRaisesGenerationOneToTwoAndKeepsHigherValues() throws {
        XCTAssertEqual(RecordingSettingsCodec.generationAfterLayoutChange(1), 2)
        for baseline in [UInt32(2), 5, 200] {
            var f = factoryBytes()
            f.control[0x00] = UInt8(baseline); f.control[0x1FF] = UInt8(baseline)
            for o in [0x1E0, 0x1E4, 0x1E8] { word(baseline, o, &f.control) }
            let sealed = seal(f.control, f.channel)
            let snapshot = try RecordingSettingsCodec.decode(control: sealed.control, channel: sealed.channel)
            XCTAssertEqual(snapshot.generation, baseline)
            var s = snapshot.settings
            s.setMode(.eventOnly)
            let edit = try RecordingSettingsCodec.apply(s, control: sealed.control, channel: sealed.channel)
            XCTAssertTrue(edit.layoutChanged)
            XCTAssertEqual([0x1E0, 0x1E4, 0x1E8].map { readWord(edit.control, $0) }, [baseline, baseline, baseline])
            XCTAssertEqual(edit.control[0x00], UInt8(baseline))
            XCTAssertEqual(edit.control[0x1FF], UInt8(baseline))
            let again = seal([UInt8](edit.control), [UInt8](edit.channel))
            XCTAssertEqual(edit.control, again.control)
        }
    }
    func testContinuousOnlyModeRemovesTheEventRegionAndResetsTheEventWindow() throws {
        let r = try apply { $0.mode = .continuousOnly; $0.eventWindowIndex = 6 }
        let c = r.edit.control
        XCTAssertEqual([0x1BE, 0x1C2, 0x1C6, 0x1CA, 0x1CE, 0x1D2].map { readWord(c, $0) }, [10, 59_697_600, 0, 0, 59_697_601, 60_000_000])
        XCTAssertEqual(c[0x3E], 1)
        XCTAssertEqual(c[0x3B], 1, "the event overwrite switch is forced off")
        XCTAssertEqual(UInt16(c[0x2F]) | UInt16(c[0x30]) << 8, 300, "10 s at 30 frames/s: the event window is back at its default")
        XCTAssertEqual(UInt16(c[0x37]) | UInt16(c[0x38]) << 8, 300)
        XCTAssertEqual(r.edit.settings.eventWindowIndex, 0)
    }
    func testHistoryLengthAndRateMoveTheJournalAndTheNormalRegion() throws {
        let cases: [(Int, Bool, [UInt32])] = [
            (0, false, [10, 42_569_328, 42_569_329, 59_956_800, 59_956_801, 60_000_000]),
            (0, true, [10, 42_538_656, 42_538_657, 59_913_600, 59_913_601, 60_000_000]),
            (2, false, [10, 41_986_560, 41_986_561, 59_136_000, 59_136_001, 60_000_000]),
            (2, true, [10, 41_373_120, 41_373_121, 58_272_000, 58_272_001, 60_000_000]),
            (1, true, [10, 42_170_592, 42_170_593, 59_395_200, 59_395_201, 60_000_000])]
        for (hours, doubled, words) in cases {
            let r = try apply { $0.historyHoursIndex = hours; $0.historyDoubleRate = doubled }
            XCTAssertEqual([0x1BE, 0x1C2, 0x1C6, 0x1CA, 0x1CE, 0x1D2].map { readWord(r.edit.control, $0) }, words, "hours \(hours) doubled \(doubled)")
            XCTAssertEqual(r.edit.control[0x90], doubled ? 1 : 0)
            let back = try RecordingSettingsCodec.decode(control: r.edit.control, channel: r.edit.channel)
            XCTAssertTrue(back.regionsAreStandard)
            XCTAssertEqual(back.settings.historyHoursIndex, hours); XCTAssertEqual(back.settings.historyDoubleRate, doubled)
        }
    }
    func testEveryModeHistoryCombinationRoundTripsAndStaysStandard() throws {
        let f = factory()
        for mode in RecordingSettings.Mode.allCases {
            for hours in 0..<RecordingSettingsTables.historyHours.count {
                for doubled in [false, true] {
                    var s = try RecordingSettingsCodec.decode(control: f.control, channel: f.channel).settings
                    s.mode = mode; s.historyHoursIndex = hours; s.historyDoubleRate = doubled
                    let edit = try RecordingSettingsCodec.apply(s, control: f.control, channel: f.channel)
                    let back = try RecordingSettingsCodec.decode(control: edit.control, channel: edit.channel)
                    XCTAssertEqual(back.settings, s.normalized())
                    XCTAssertTrue(back.regionsAreStandard)
                    // A second layout change starts from the new table, not from the factory one.
                    var t = back.settings
                    t.mode = .continuousAndEvent; t.historyHoursIndex = 1; t.historyDoubleRate = false
                    let restored = try RecordingSettingsCodec.apply(t, control: edit.control, channel: edit.channel)
                    XCTAssertEqual([0x1BE, 0x1C2, 0x1C6, 0x1CA, 0x1CE, 0x1D2].map { readWord(restored.control, $0) }, [10, 42_385_296, 42_385_297, 59_697_600, 59_697_601, 60_000_000])
                }
            }
        }
    }
    func testLayoutChangeFlagsFollowTheOriginalPrompts() {
        var a = RecordingSettings.factoryDefault
        XCTAssertFalse(a.changesLayout(from: .factoryDefault))
        a.beepEnabled = false; a.frameRateIndex = 3; a.eventWindowIndex = 2
        XCTAssertFalse(a.changesLayout(from: .factoryDefault))
        a.historyDoubleRate = true; XCTAssertTrue(a.changesLayout(from: .factoryDefault))
        a = .factoryDefault; a.mode = .eventOnly; XCTAssertTrue(a.changesLayout(from: .factoryDefault))
        a = .factoryDefault; a.historyHoursIndex = 0; XCTAssertTrue(a.changesLayout(from: .factoryDefault))
    }

    // MARK: normalisation and validation
    func testNormalizationMirrorsTheDisabledControlsOfTheDialog() {
        var s = RecordingSettings.factoryDefault
        s.mode = .eventOnly; XCTAssertFalse(s.normalized().overwriteContinuous)
        s = .factoryDefault; s.mode = .continuousOnly; s.eventWindowIndex = 4
        XCTAssertFalse(s.normalized().overwriteEvent); XCTAssertEqual(s.normalized().eventWindowIndex, 0)
        s = .factoryDefault; s.shockSensitivity = 8
        XCTAssertEqual(s.normalized().accelerationSensitivity, 8); XCTAssertEqual(s.normalized().steeringSensitivity, 8)
        s = .factoryDefault; s.gSensorEnabled = false; s.shockSensitivity = 8
        let n = s.normalized()
        XCTAssertFalse(n.easyMode); XCTAssertEqual([n.shockSensitivity, n.accelerationSensitivity, n.steeringSensitivity], [5, 5, 5])
    }
    func testValidationRefusesWhatTheOriginalDialogCannotExpress() {
        var s = RecordingSettings.factoryDefault
        s.frameRateIndex = 9; XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.eventWindowIndex = 11; XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.historyHoursIndex = 3; XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.shockSensitivity = 0; XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.steeringSensitivity = 10; XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.cardID = String(repeating: "A", count: 25); XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.cardID = String(repeating: "A", count: 24); XCTAssertNoThrow(try s.validate())
        s = .factoryDefault; s.cardID = "has space"; XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.cardID = "全角"; XCTAssertThrowsError(try s.validate())
        s = .factoryDefault; s.mode = .eventOnly; s.frameRateIndex = 5
        XCTAssertThrowsError(try s.validate(), "event-only recording offers 1 frame/s at the slowest")
        s.frameRateIndex = 4; XCTAssertNoThrow(try s.validate())
        s.mode = .continuousOnly; s.frameRateIndex = 8; XCTAssertNoThrow(try s.validate())
    }
    func testChoosingEventOnlyMovesASlowerRateToOneFramePerSecondLikeTheDialog() {
        var s = RecordingSettings.factoryDefault
        s.frameRateIndex = 8
        s.setMode(.eventOnly)
        XCTAssertEqual(s.frameRateIndex, 4)
        XCTAssertEqual(RecordingSettingsTables.availableFrameRateIndices(for: .eventOnly), [0, 1, 2, 3, 4])
        XCTAssertEqual(RecordingSettingsTables.availableFrameRateIndices(for: .continuousOnly).count, 9)
        XCTAssertEqual(RecordingSettingsTables.availableFrameRateIndices(for: .continuousAndEvent).count, 9)
        s.setMode(.continuousOnly)
        XCTAssertEqual(s.frameRateIndex, 4, "leaving event-only keeps the clamped rate")
        var t = RecordingSettings.factoryDefault
        t.frameRateIndex = 3
        t.setMode(.eventOnly)
        XCTAssertEqual(t.frameRateIndex, 3, "a rate that is offered stays")
        XCTAssertNoThrow(try t.validate())
    }
    func testEventOnlyModeWithTheSlowestAllowedRateMatchesTheOriginal() throws {
        // Observed: the original clamps 6 frames/hour to 1 frame/s when イベント記録 only is chosen.
        let r = try apply { $0.mode = .eventOnly; $0.frameRateIndex = 4 }
        let c = [UInt8](r.edit.control)
        XCTAssertEqual(UInt16(c[0x22]) | UInt16(c[0x23]) << 8, 14000); XCTAssertEqual(c[0x24], 1); XCTAssertEqual(c[0x25], 1)
        XCTAssertEqual(UInt16(c[0x2F]) | UInt16(c[0x30]) << 8, 30); XCTAssertEqual(UInt16(c[0x37]) | UInt16(c[0x38]) << 8, 30)
    }
    func testContinuousOnlyModeAcceptsSlowRatesAndDefaultsTheEventRecordsLikeTheOriginal() throws {
        let r = try apply { $0.mode = .continuousOnly; $0.frameRateIndex = 8 }
        let c = [UInt8](r.edit.control)
        XCTAssertEqual(c[0x24], 3); XCTAssertEqual(c[0x25], 6)
        XCTAssertEqual(c[0x2D], 1); XCTAssertEqual(UInt16(c[0x2F]) | UInt16(c[0x30]) << 8, 10, "10 s at 1 frame/s")
        XCTAssertEqual(UInt16(c[0x37]) | UInt16(c[0x38]) << 8, 10)
    }

    // MARK: refusals
    func testDecoderRefusesSectorsItDoesNotUnderstand() throws {
        let f = factoryBytes()
        func refuse(_ name: String, _ mutate: (inout [UInt8], inout [UInt8]) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var c = f.control, ch = f.channel
            mutate(&c, &ch)
            let sealed = seal(c, ch)
            XCTAssertThrowsError(try RecordingSettingsCodec.decode(control: sealed.control, channel: sealed.channel), name, file: file, line: line)
        }
        refuse("marker", { c, _ in c[3] = 0x58 })
        refuse("tail marker", { c, _ in c[0x1F0] = 0x58 })
        refuse("two channels", { c, _ in c[0x14] = 2 })
        refuse("unknown frame rate", { c, ch in c[0x22] = 0x39; c[0x23] = 0x30; for i in 0x20..<0x39 { ch[i] = c[i] } })
        refuse("unknown event window", { c, ch in c[0x2F] = 0x01; c[0x30] = 0x00; for i in 0x20..<0x39 { ch[i] = c[i] } })
        refuse("record tag", { c, ch in c[0x29] = 0x0C; for i in 0x20..<0x39 { ch[i] = c[i] } })
        refuse("mode", { c, _ in c[0x3E] = 7 })
        refuse("overwrite flag", { c, _ in c[0x3A] = 7 })
        refuse("beep flag", { c, _ in c[0x50] = 1 })
        refuse("g sensor flag", { c, _ in c[0x46] = 9 })
        refuse("sensitivity", { c, _ in c[0x49] = 12 })
        refuse("battery pair", { c, _ in c[0x54] = 1 })
        refuse("card id garbage", { c, _ in c[0x66] = 0x07 })
        refuse("card id after a gap", { c, _ in c[0x66] = 0x41; c[0x68] = 0x42 })
        refuse("channel record mirror", { c, ch in ch[0x22] = 0x00 })
        var bad = factory()
        var corrupted = [UInt8](bad.control)
        corrupted[0x100] ^= 0x10
        bad.control = Data(corrupted)
        XCTAssertThrowsError(try RecordingSettingsCodec.decode(control: bad.control, channel: bad.channel), "checksum")
        XCTAssertThrowsError(try RecordingSettingsCodec.decode(control: Data(count: 100), channel: factory().channel), "size")
    }
    func testNonStandardRegionTableAllowsPlainEditsButNeverLayoutChanges() throws {
        var f = factoryBytes()
        word(42_385_296 + 12, 0x1C2, &f.control)
        let sealed = seal(f.control, f.channel)
        let snapshot = try RecordingSettingsCodec.decode(control: sealed.control, channel: sealed.channel)
        XCTAssertFalse(snapshot.regionsAreStandard)
        var plain = snapshot.settings
        plain.beepEnabled = false
        let edit = try RecordingSettingsCodec.apply(plain, control: sealed.control, channel: sealed.channel)
        XCTAssertEqual([0x1BE, 0x1C2, 0x1C6, 0x1CA, 0x1CE, 0x1D2].map { readWord(edit.control, $0) }, [10, 42_385_308, 42_385_297, 59_697_600, 59_697_601, 60_000_000])
        var layout = snapshot.settings
        layout.mode = .eventOnly
        XCTAssertThrowsError(try RecordingSettingsCodec.apply(layout, control: sealed.control, channel: sealed.channel))
    }
    func testBytesTheCodecDoesNotModelSurviveEveryEdit() throws {
        var f = factoryBytes()
        for (offset, value) in [(0x15, 0x7F), (0x60, 0x5A), (0xA0, 0x33), (0x1DE, 0x44), (0x1DF, 0x45), (0x3D, 0x09), (0x51, 0x08)] { f.control[offset] = UInt8(value) }
        let sealed = seal(f.control, f.channel)
        var s = try RecordingSettingsCodec.decode(control: sealed.control, channel: sealed.channel).settings
        s.mode = .eventOnly; s.beepEnabled = false; s.frameRateIndex = 2; s.historyDoubleRate = true; s.cardID = "X1"
        let edit = try RecordingSettingsCodec.apply(s, control: sealed.control, channel: sealed.channel)
        for offset in [0x15, 0x60, 0xA0, 0x1D6, 0x1D7, 0x1D8, 0x1D9, 0x1DA, 0x1DB, 0x1DC, 0x1DD, 0x1DE, 0x1DF, 0x3D, 0x51, 0x1E0 + 1, 0x1EC] {
            if [0x1E1].contains(offset) { continue }
            XCTAssertEqual(edit.control[offset], sealed.control[offset], "+0x\(String(offset, radix: 16))")
        }
        XCTAssertEqual(edit.channel[0x14], sealed.channel[0x14])
        XCTAssertEqual(edit.channel[0x15], sealed.channel[0x15])
        XCTAssertEqual(edit.channel[0x16], sealed.channel[0x16])
    }
    func testDifferencesNameWhatChanged() {
        var s = RecordingSettings.factoryDefault
        XCTAssertTrue(s.differences(from: .factoryDefault).isEmpty)
        s.mode = .eventOnly; s.cardID = "A"; s.beepEnabled = false
        XCTAssertEqual(s.differences(from: .factoryDefault), ["記録モード", "ビープ音", "SDカードID"])
    }
}
