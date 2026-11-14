import XCTest
@testable import PCBrowserCore

/// The card password: its stored form in the control sector, the edit-box rules, the confirmation steps, the card-open gate and the
/// dialog's 「初期設定に戻す」. Every expectation comes from driving the original (Wine, writes swallowed); the sectors are SYNTHETIC
/// and the passwords are arbitrary examples.
final class CardPasswordTests: XCTestCase {
    func factory() -> (control: Data, channel: Data) { SettingsFixture.factory() }
    func offsets(_ a: Data, _ b: Data) -> [Int] {
        var result: [Int] = []
        for i in 0..<512 where i != 0x12 && i != 0x13 && a[a.startIndex + i] != b[b.startIndex + i] { result.append(i) }
        return result
    }
    func edit(_ f: (control: Data, channel: Data), _ change: (inout RecordingSettings) -> Void) throws -> RecordingSettingsEdit {
        var s = try RecordingSettingsCodec.decode(control: f.control, channel: f.channel).settings
        change(&s)
        return try RecordingSettingsCodec.apply(s, control: f.control, channel: f.channel)
    }
    func bytes(_ d: Data, _ range: ClosedRange<Int>) -> [UInt8] { range.map { d[d.startIndex + $0] } }

    // MARK: stored form
    func testStoredWordIsThreeTimesThePasswordPlus1639() {
        let expected: [Int: UInt16] = [1000: 4639, 1001: 4642, 1234: 5341, 2000: 7639, 5678: 18673, 9999: 31636]
        for (password, word) in expected { XCTAssertEqual(CardPassword.storedWord(for: password), word, "\(password)") }
        XCTAssertEqual(CardPassword.encode(1234), [1, 0xDD, 0x14])
        XCTAssertEqual(CardPassword.encode(1000), [1, 0x1F, 0x12])
        XCTAssertEqual(CardPassword.encode(9999), [1, 0x94, 0x7B])
        XCTAssertEqual(CardPassword.encode(nil), [0, 0, 0])
        for password in [1000, 1001, 4321, 9999] {
            let stored = CardPassword.encode(password)
            XCTAssertEqual(try CardPassword.decode(flag: stored[0], word: UInt16(stored[1]) | UInt16(stored[2]) << 8), password)
        }
    }
    func testSettingAPasswordChangesExactlyTheFlagAndTheWord() throws {
        let f = factory()
        let e = try edit(f) { $0.password = 1234 }
        XCTAssertEqual(offsets(f.control, e.control), [0x88, 0x89, 0x8A])
        XCTAssertEqual(bytes(e.control, 0x88...0x8A), [1, 0xDD, 0x14])
        XCTAssertEqual(e.channel, f.channel, "the channel sector does not take part")
        XCTAssertEqual(e.changes, ["パスワード"])
        XCTAssertFalse(e.layoutChanged)
        let again = try RecordingSettingsCodec.decode(control: e.control, channel: e.channel)
        XCTAssertEqual(again.settings.password, 1234)
        let sealed = SettingsFixture.seal([UInt8](e.control), [UInt8](e.channel))
        XCTAssertEqual(e.control, sealed.control, "the stored checksum must equal an independent computation")
    }
    func testChangingAndClearingGiveBackTheExactBytes() throws {
        let f = factory()
        let first = try edit(f) { $0.password = 5678 }
        let second = try edit((first.control, first.channel)) { $0.password = 1000 }
        XCTAssertEqual(offsets(first.control, second.control), [0x89, 0x8A])
        XCTAssertEqual(bytes(second.control, 0x88...0x8A), [1, 0x1F, 0x12])
        let cleared = try edit((second.control, second.channel)) { $0.password = nil }
        XCTAssertEqual(cleared.control, f.control, "clearing must give back the byte-identical sector")
        XCTAssertEqual(cleared.channel, f.channel)
    }
    func testCardIDAndPasswordDoNotOverlap() throws {
        let f = factory()
        let id = String(repeating: "Z", count: 24)
        let e = try edit(f) { $0.cardID = id; $0.password = 4321 }
        XCTAssertEqual(offsets(f.control, e.control), Array(0x66..<0x7E) + [0x88, 0x89, 0x8A])
        XCTAssertEqual(bytes(e.control, 0x7E...0x87), [UInt8](repeating: 0, count: 10))
        let back = try RecordingSettingsCodec.decode(control: e.control, channel: e.channel).settings
        XCTAssertEqual(back.cardID, id)
        XCTAssertEqual(back.password, 4321)
        let shorter = try edit((e.control, e.channel)) { $0.cardID = "Q" }
        XCTAssertEqual(bytes(shorter.control, 0x88...0x8A), CardPassword.encode(4321), "a shorter ID leaves the password alone")
        let withoutPassword = try edit((e.control, e.channel)) { $0.password = nil }
        XCTAssertEqual(bytes(withoutPassword.control, 0x66...0x7D), [UInt8](id.utf8), "clearing the password leaves the ID alone")
    }
    func testDecoderRefusesPasswordPatternsTheOriginalNeverWrites() {
        let base = SettingsFixture.factoryBytes()
        func refuse(_ name: String, _ mutate: (inout [UInt8]) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var c = base.control
            mutate(&c)
            let sealed = SettingsFixture.seal(c, base.channel)
            XCTAssertThrowsError(try RecordingSettingsCodec.decode(control: sealed.control, channel: sealed.channel), name, file: file, line: line)
        }
        refuse("flag 2", { $0[0x88] = 2; $0[0x89] = 0xDD; $0[0x8A] = 0x14 })
        refuse("word without a flag", { $0[0x89] = 0x01 })
        refuse("flag without a word", { $0[0x88] = 1 })
        refuse("word off the formula", { $0[0x88] = 1; $0[0x89] = 0xDE; $0[0x8A] = 0x14 })
        refuse("password 999", { $0[0x88] = 1; $0[0x89] = 0x1C; $0[0x8A] = 0x12 })
        refuse("password 10000", { $0[0x88] = 1; $0[0x89] = 0x97; $0[0x8A] = 0x7B })
        refuse("byte behind the password", { $0[0x8B] = 1 })
        refuse("last reserved byte", { $0[0x8F] = 9 })
    }
    func testRangeAndDifferences() throws {
        for bad in [0, 999, 10000, -1234] {
            var s = RecordingSettings()
            s.password = bad
            XCTAssertThrowsError(try s.validate(), "\(bad)")
        }
        for good in [1000, 9999] {
            var s = RecordingSettings()
            s.password = good
            XCTAssertNoThrow(try s.validate())
        }
        var s = RecordingSettings.factoryDefault
        XCTAssertNil(s.password)
        s.password = 1234
        XCTAssertEqual(s.differences(from: .factoryDefault), ["パスワード"])
        var t = s
        t.password = 1235
        XCTAssertEqual(t.differences(from: s), ["パスワード"])
        XCTAssertTrue(s.differences(from: s).isEmpty)
        // Saving the unchanged password rewrites nothing (observed: no message, no write).
        let f = factory()
        let locked = try edit(f) { $0.password = 1234 }
        let again = try edit((locked.control, locked.channel)) { $0.password = 1234 }
        XCTAssertEqual(again.control, locked.control)
        XCTAssertTrue(again.changes.isEmpty)
    }

    // MARK: the edit box
    func testEditBoxRulesMatchTheOriginal() {
        XCTAssertEqual(CardPassword.parse(""), .none)
        XCTAssertEqual(CardPassword.parse("1000"), .password(1000))
        XCTAssertEqual(CardPassword.parse("9999"), .password(9999))
        for text in ["999", "0999", "0", "12a4", " 123", "+123", "-123", "１２３４", "12.5", "abcd"] {
            XCTAssertEqual(CardPassword.parse(text), .outOfRange, text)
        }
        for text in ["10000", "12345", "abcde", "0000000"] { XCTAssertEqual(CardPassword.parse(text), .tooLong, text) }
        XCTAssertEqual(CardPassword.Entry.outOfRange.message, "パスワードは1000～9999の範囲で入力してください。")
        XCTAssertEqual(CardPassword.Entry.tooLong.message, "4 文字以内で入力してください。")
        XCTAssertNil(CardPassword.Entry.none.message)
        XCTAssertNil(CardPassword.Entry.password(1234).message)
        XCTAssertEqual(CardPassword.Entry.password(1234).value, 1234)
        XCTAssertNil(CardPassword.Entry.outOfRange.value)
        XCTAssertEqual(CardPassword.Message.wrong, "パスワードが間違っています。")
    }
    func testConfirmationStepsFollowTheOriginal() throws {
        XCTAssertEqual(CardPassword.Change.required(old: nil, new: nil), .none)
        XCTAssertEqual(CardPassword.Change.required(old: 1234, new: 1234), .none)
        XCTAssertEqual(CardPassword.Change.required(old: nil, new: 1234), .reenter(1234))
        XCTAssertEqual(CardPassword.Change.required(old: 1234, new: 5678), .reenter(5678))
        XCTAssertEqual(CardPassword.Change.required(old: 1234, new: nil), .confirmClear)
        XCTAssertTrue(CardPassword.confirms("1234", expected: 1234))
        for typed in ["", "1235", "12345", " 1234", "1234 ", "0", "abcd"] { XCTAssertFalse(CardPassword.confirms(typed, expected: 1234), typed) }
        XCTAssertTrue(CardPassword.unlocks("4321", stored: 4321))
        XCTAssertFalse(CardPassword.unlocks("4322", stored: 4321))
        XCTAssertFalse(CardPassword.unlocks("", stored: 4321))
        let t = try CardLocalTime(year: 2026, month: 3, day: 4, hour: 5, minute: 6, second: 7)
        var draft = RecordingSettingsDraft(settings: RecordingSettings(), timeEnabled: false, time: t, angleDetection: false)
        XCTAssertEqual(draft.passwordCheck(against: RecordingSettings()), .none)
        draft.settings.password = 2468
        XCTAssertEqual(draft.passwordCheck(against: RecordingSettings()), .reenter(2468))
        var locked = RecordingSettings()
        locked.password = 2468
        XCTAssertEqual(draft.passwordCheck(against: locked), .none)
        draft.settings.password = nil
        XCTAssertEqual(draft.passwordCheck(against: locked), .confirmClear)
    }

    // MARK: card-open gate
    func lockedImage(password: Int?, modelCode: UInt8 = 0x14) throws -> Data {
        let g = SettingsFixture.plain
        var d = SettingsFixture.image(g)
        var c = [UInt8](SettingsFixture.sector(d, g.controlSector))
        let ch = [UInt8](SettingsFixture.sector(d, g.channelSector))
        c[DeviceModelTable.codeOffset] = modelCode
        let sealed = SettingsFixture.seal(c, ch)
        var s = try RecordingSettingsCodec.decode(control: sealed.control, channel: sealed.channel).settings
        s.password = password
        let e = try RecordingSettingsCodec.apply(s, control: sealed.control, channel: sealed.channel)
        SettingsFixture.put(e.control, sector: g.controlSector, into: &d)
        SettingsFixture.put(e.control, sector: g.backupControlSector, into: &d)
        return d
    }
    func testTheGateAsksOnlyForARecognisedPasswordOnAQ01FamilyCard() throws {
        let locked = try lockedImage(password: 1234)
        XCTAssertEqual(CardPassword.required(in: MemorySource(locked)), 1234)
        let open = try lockedImage(password: nil)
        XCTAssertNil(CardPassword.required(in: MemorySource(open)))
        let otherClass = try lockedImage(password: 1234, modelCode: 0x01)
        XCTAssertNil(CardPassword.required(in: MemorySource(otherClass)), "the other dialog classes were not observed, so they are not gated")
        let unknownModel = try lockedImage(password: 1234, modelCode: 0xEE)
        XCTAssertNil(CardPassword.required(in: MemorySource(unknownModel)))
        for code in [UInt8(0x14), 0x1E, 0x23, 0x2D, 0x30] {
            let image = try lockedImage(password: 9876, modelCode: code)
            XCTAssertEqual(CardPassword.required(in: MemorySource(image)), 9876, "class 81 model code \(code)")
        }
    }
    func testGateIgnoresSectorsItCannotRead() throws {
        XCTAssertNil(CardPassword.required(controlSector: Data(count: 100)))
        XCTAssertNil(CardPassword.required(in: MemorySource(Data(count: 4096))))
        // A flag with a word that does not follow the formula is not treated as a password (nothing to verify against).
        var c = SettingsFixture.factoryBytes().control
        c[DeviceModelTable.codeOffset] = 0x14
        c[0x88] = 1; c[0x89] = 0xDE; c[0x8A] = 0x14
        XCTAssertNil(CardPassword.required(controlSector: Data(c)))
        c[0x89] = 0xDD
        XCTAssertEqual(CardPassword.required(controlSector: Data(c)), 1234)
    }

    // MARK: 「初期設定に戻す」
    func testResetFollowsTheOriginalsDialogDefaults() {
        var s = RecordingSettings()
        s.mode = .eventOnly; s.frameRateIndex = 3; s.eventWindowIndex = 5; s.audioEnabled = false; s.historyHoursIndex = 2; s.historyDoubleRate = true
        s.overwriteContinuous = false; s.overwriteEvent = false; s.overwriteHistory = false; s.beepEnabled = false
        s.gSensorEnabled = false; s.easyMode = false; s.shockSensitivity = 2; s.accelerationSensitivity = 3; s.steeringSensitivity = 9
        s.cardID = "KEEP-ME"; s.password = 4321; s.multiBatteryConnected = true
        let r = s.resettingToDialogDefaults()
        XCTAssertEqual(r.mode, .continuousAndEvent)
        XCTAssertEqual(r.frameRateIndex, 0)
        XCTAssertEqual(r.eventWindowIndex, 0, "10+10 s: the dialog's default, not the factory card's 30+30 s")
        XCTAssertEqual(r.historyHoursIndex, 0, "24 h: the dialog's default, not the factory card's 168 h")
        XCTAssertEqual(RecordingSettings.factoryDefault.eventWindowIndex, 10)
        XCTAssertEqual(RecordingSettings.factoryDefault.historyHoursIndex, 1)
        XCTAssertTrue(r.audioEnabled)
        XCTAssertFalse(r.historyDoubleRate)
        XCTAssertTrue(r.overwriteContinuous && r.overwriteEvent && r.overwriteHistory && r.beepEnabled && r.gSensorEnabled && r.easyMode)
        XCTAssertEqual([r.shockSensitivity, r.accelerationSensitivity, r.steeringSensitivity], [5, 5, 5])
        XCTAssertEqual(r.cardID, "KEEP-ME", "the SDカードID box is not touched")
        XCTAssertEqual(r.password, 4321, "the パスワード box is not touched")
        XCTAssertTrue(r.multiBatteryConnected, "マルチバッテリー is not touched")
        XCTAssertNoThrow(try r.validate())
        XCTAssertEqual(r.resettingToDialogDefaults(), r)
    }
    func testDraftResetUntickBothCommandRowsAndKeepsThePickerTime() throws {
        let t = try CardLocalTime(year: 2026, month: 3, day: 4, hour: 5, minute: 6, second: 7)
        let draft = RecordingSettingsDraft(settings: RecordingSettings(), timeEnabled: true, time: t, angleDetection: true)
        let reset = draft.resettingToDialogDefaults()
        XCTAssertFalse(reset.timeEnabled)
        XCTAssertFalse(reset.angleDetection)
        XCTAssertEqual(reset.time, t)
        let state = CardCommandState(timeFileExists: true, time: t, angleDetectionRequested: true)
        let files = reset.commandFiles(from: state)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains(CardCommandFile.removeTime))
        XCTAssertTrue(files.contains(CardCommandFile.cancelAngleDetection))
        XCTAssertTrue(reset.commandFiles(from: CardCommandState.absent).isEmpty)
    }
    func testResetSettingsEncodeAndDecodeBack() throws {
        let f = factory()
        let current = try RecordingSettingsCodec.decode(control: f.control, channel: f.channel).settings
        let reset = current.resettingToDialogDefaults()
        let e = try RecordingSettingsCodec.apply(reset, control: f.control, channel: f.channel)
        XCTAssertTrue(e.layoutChanged, "168 h → 24 h rewrites the region table, which is what makes the original ask about the recordings")
        let back = try RecordingSettingsCodec.decode(control: e.control, channel: e.channel)
        XCTAssertEqual(back.settings, reset.normalized())
        XCTAssertEqual(back.settings.eventWindowIndex, 0)
        XCTAssertEqual(back.settings.historyHoursIndex, 0)
        XCTAssertTrue(back.regionsAreStandard)
        XCTAssertEqual(e.changes, ["イベント記録時間", "履歴記録時間"])
    }
}
