import Foundation

extension CardLocalTime {
    /// A `Date` for a date picker (the calendar fields are read in `timeZone`); nil if the fields do not form a date.
    public func date(timeZone: TimeZone = TimeZone.current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        parts.hour = hour; parts.minute = minute; parts.second = second
        return calendar.date(from: parts)
    }
}

/// Everything the 記録設定 dialog edits, independent of the user interface: the recording settings plus the two rows that only manage
/// command files in the card's CONFIG folder (日時設定 and 設置角度検出).
public struct RecordingSettingsDraft: Equatable, Sendable {
    public var settings: RecordingSettings
    /// 「設定する」 ticked: the picker's time is written to CONFIG\TIME.INI on save; unticked: the file is removed.
    public var timeEnabled: Bool
    public var time: CardLocalTime
    /// 「設置角度検出を実行」 ticked: an empty CONFIG\SELFADJ.INI is created; unticked: it is removed.
    public var angleDetection: Bool

    public init(settings: RecordingSettings, timeEnabled: Bool, time: CardLocalTime, angleDetection: Bool) {
        self.settings = settings; self.timeEnabled = timeEnabled; self.time = time; self.angleDetection = angleDetection
    }

    /// Opens the way the original's dialog does: the date row is ticked (showing the file's LOCALTIME) when CONFIG\TIME.INI exists
    /// and otherwise shows `now` unticked; the angle box is ticked when CONFIG\SELFADJ.INI exists.
    public init(opening settings: RecordingSettings, commands: CardCommandState?, now: Date, timeZone: TimeZone = TimeZone.current) throws {
        let state = commands ?? CardCommandState.absent
        let initial: CardLocalTime
        if state.timeFileExists, let stored = state.time {
            initial = stored
        } else {
            initial = try CardLocalTime(date: now, timeZone: timeZone)
        }
        self.init(settings: settings, timeEnabled: state.timeFileExists, time: initial, angleDetection: state.angleDetectionRequested)
    }

    /// Files to create, rewrite or delete so that the card's CONFIG folder matches the two rows. Empty when the card has no readable
    /// FAT16 volume (`commands == nil`) or when the rows already match.
    public func commandFiles(from commands: CardCommandState?) -> [CardCommandFile] {
        guard let state = commands else { return [] }
        let timeRequest: CardTimeRequest = timeEnabled ? CardTimeRequest.set(time) : CardTimeRequest.remove
        let angleRequest: CardAngleRequest = angleDetection ? CardAngleRequest.request : CardAngleRequest.cancel
        return CardCommandFile.actions(from: state, time: timeRequest, angle: angleRequest)
    }

    /// Human-readable list of what saving would change (recording settings, then command files), for the confirmation text.
    public func summary(against original: RecordingSettings, commands: CardCommandState?) -> [String] {
        var lines: [String] = settings.normalized().differences(from: original.normalized())
        for file in commandFiles(from: commands) {
            switch file {
            case .writeTime(let t): lines.append("日時設定: " + t.text + "（CONFIG/TIME.INI）")
            case .removeTime: lines.append("日時設定: 解除（CONFIG/TIME.INI を削除）")
            case .requestAngleDetection: lines.append("設置角度検出: 実行（CONFIG/SELFADJ.INI を作成）")
            case .cancelAngleDetection: lines.append("設置角度検出: 解除（CONFIG/SELFADJ.INI を削除）")
            }
        }
        return lines
    }
}
