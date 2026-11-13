import XCTest
@testable import PCBrowserCore

/// The state behind the 記録設定 sheet: how it opens and which command files a save produces (generic synthetic values only).
final class RecordingSettingsDraftTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func time(_ h: Int, _ mi: Int, _ s: Int) throws -> CardLocalTime {
        try CardLocalTime(year: 2026, month: 3, day: 4, hour: h, minute: mi, second: s)
    }

    func testOpeningWithoutCommandFilesShowsTheCurrentTimeUnticked() throws {
        let draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: CardCommandState.absent, now: now, timeZone: utc)
        XCTAssertFalse(draft.timeEnabled)
        XCTAssertFalse(draft.angleDetection)
        XCTAssertEqual(draft.time.text, "2027.01.15;08:00:00")
        XCTAssertTrue(draft.commandFiles(from: CardCommandState.absent).isEmpty)
        let tokyoDraft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: nil, now: now, timeZone: tokyo)
        XCTAssertEqual(tokyoDraft.time.text, "2027.01.15;17:00:00")
    }

    func testOpeningWithExistingFilesTicksTheRowsAndShowsTheStoredTime() throws {
        let stored = try time(9, 8, 7)
        let state = CardCommandState(timeFileExists: true, time: stored, angleDetectionRequested: true)
        let draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: state, now: now, timeZone: utc)
        XCTAssertTrue(draft.timeEnabled)
        XCTAssertTrue(draft.angleDetection)
        XCTAssertEqual(draft.time, stored)
        XCTAssertTrue(draft.commandFiles(from: state).isEmpty, "opening and saving without a change must not touch the card")
    }

    func testAnUnreadableTimeFileStillTicksTheRowAndShowsTheCurrentTime() throws {
        let state = CardCommandState(timeFileExists: true, time: nil, angleDetectionRequested: false)
        let draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: state, now: now, timeZone: utc)
        XCTAssertTrue(draft.timeEnabled)
        XCTAssertEqual(draft.time.text, "2027.01.15;08:00:00")
        // The stored time is unknown, so ticking-and-saving rewrites the file with the picker's time.
        XCTAssertEqual(draft.commandFiles(from: state), [CardCommandFile.writeTime(draft.time)])
    }

    func testTickingTheDateRowWritesThePickersTime() throws {
        var draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: CardCommandState.absent, now: now, timeZone: utc)
        draft.timeEnabled = true
        draft.time = try time(1, 2, 3)
        XCTAssertEqual(draft.commandFiles(from: CardCommandState.absent), [CardCommandFile.writeTime(draft.time)])
    }

    func testChangingTheTimeRewritesAndKeepingItDoesNot() throws {
        let stored = try time(9, 8, 7)
        let state = CardCommandState(timeFileExists: true, time: stored, angleDetectionRequested: false)
        var draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: state, now: now, timeZone: utc)
        draft.time = try time(10, 0, 0)
        XCTAssertEqual(draft.commandFiles(from: state), [CardCommandFile.writeTime(try time(10, 0, 0))])
        draft.time = stored
        XCTAssertTrue(draft.commandFiles(from: state).isEmpty)
    }

    func testUntickingTheDateRowDeletesTheFileOnlyWhenItExists() throws {
        let state = CardCommandState(timeFileExists: true, time: try time(9, 8, 7), angleDetectionRequested: false)
        var draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: state, now: now, timeZone: utc)
        draft.timeEnabled = false
        XCTAssertEqual(draft.commandFiles(from: state), [CardCommandFile.removeTime])
        XCTAssertTrue(draft.commandFiles(from: CardCommandState.absent).isEmpty)
    }

    func testAngleDetectionCreatesAndRemovesTheEmptyFile() throws {
        var draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: CardCommandState.absent, now: now, timeZone: utc)
        draft.angleDetection = true
        XCTAssertEqual(draft.commandFiles(from: CardCommandState.absent), [CardCommandFile.requestAngleDetection])
        let requested = CardCommandState(timeFileExists: false, time: nil, angleDetectionRequested: true)
        XCTAssertTrue(draft.commandFiles(from: requested).isEmpty)
        draft.angleDetection = false
        XCTAssertEqual(draft.commandFiles(from: requested), [CardCommandFile.cancelAngleDetection])
    }

    func testBothRowsAtOnceKeepTimeFirst() throws {
        var draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: CardCommandState.absent, now: now, timeZone: utc)
        draft.timeEnabled = true
        draft.angleDetection = true
        let files = draft.commandFiles(from: CardCommandState.absent)
        XCTAssertEqual(files, [CardCommandFile.writeTime(draft.time), CardCommandFile.requestAngleDetection])
    }

    func testNoFat16VolumeMeansNoCommandFiles() throws {
        var draft = try RecordingSettingsDraft(opening: RecordingSettings(), commands: nil, now: now, timeZone: utc)
        draft.timeEnabled = true
        draft.angleDetection = true
        XCTAssertTrue(draft.commandFiles(from: nil).isEmpty)
    }

    func testSummaryNamesRecordingAndCommandChanges() throws {
        let original = RecordingSettings()
        var draft = try RecordingSettingsDraft(opening: original, commands: CardCommandState.absent, now: now, timeZone: utc)
        XCTAssertTrue(draft.summary(against: original, commands: CardCommandState.absent).isEmpty)
        draft.settings.audioEnabled = false
        draft.settings.setMode(.eventOnly)
        draft.timeEnabled = true
        draft.time = try time(1, 2, 3)
        draft.angleDetection = true
        let lines = draft.summary(against: original, commands: CardCommandState.absent)
        XCTAssertTrue(lines.contains("音声記録"))
        XCTAssertTrue(lines.contains("記録モード"))
        XCTAssertTrue(lines.contains("日時設定: 2026.03.04;01:02:03（CONFIG/TIME.INI）"))
        XCTAssertTrue(lines.contains("設置角度検出: 実行（CONFIG/SELFADJ.INI を作成）"))
        let stored = CardCommandState(timeFileExists: true, time: try time(1, 2, 3), angleDetectionRequested: true)
        draft.timeEnabled = false
        draft.angleDetection = false
        let removal = draft.summary(against: original, commands: stored)
        XCTAssertTrue(removal.contains("日時設定: 解除（CONFIG/TIME.INI を削除）"))
        XCTAssertTrue(removal.contains("設置角度検出: 解除（CONFIG/SELFADJ.INI を削除）"))
    }

    func testPickerDateRoundTripsThroughTheCalendarFields() throws {
        let t = try time(23, 59, 58)
        for zone in [utc, tokyo, TimeZone(identifier: "America/Los_Angeles")!] {
            let date = try XCTUnwrap(t.date(timeZone: zone))
            XCTAssertEqual(try CardLocalTime(date: date, timeZone: zone), t, zone.identifier)
        }
        let a = try XCTUnwrap(t.date(timeZone: utc)), b = try XCTUnwrap(t.date(timeZone: tokyo))
        XCTAssertEqual(a.timeIntervalSince(b), 9 * 3600, accuracy: 0.001)
    }
}
