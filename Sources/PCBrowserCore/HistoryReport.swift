import Foundation

/// 履歴記録レポート of the original: one summary line per selected row of the per-second journal and, behind it, one data
/// line per journal entry, written as the 集計 and データ CSV pair in Windows code page 932 (docs/history-report.md).
/// The rows are the contiguous range from the first to the last selected row (all rows when nothing is selected).
public struct LegacyHistoryReport: Sendable {
    public static let title = "履歴記録レポート"
    public static let summaryHeader = "日付,時刻,運転時間,走行距離[km],平均速度[km/h],最高速度[km/h],衝撃,急発進/急ブレーキ,急ハンドル,ワンタッチ,回数"
    public static let dataHeader = "GPS時計日付,GPS時計時刻,本体時計日付,本体時計時刻,速度[km/h],加速度X[G],加速度Y[G],加速度Z[G],緯度,経度,進行方向,GPS測位フラグ,イベント種類,SDカードID,機器ID"
    /// The eleven columns of the report list.
    public static let columnTitles: [String] = summaryHeader.split(separator: ",").map { String($0) }
    /// Trigger bits of the journal record in the order the original tests them; the first set bit names the line.
    static let triggerNames: [(mask: UInt8, text: String)] = [(0x01, "衝撃"), (0x02, "急発進/急ブレーキ"), (0x04, "急ハンドル"), (0x08, "急旋回"), (0x10, "ワンタッチ")]

    let log: HistoryLog
    /// First and last row (inclusive, indexes into `log.rows`).
    public let first: Int
    public let last: Int
    public let summaries: [HistorySummary]
    public var rowCount: Int { summaries.count }

    public init?(log: HistoryLog, rows selection: Set<Int> = []) {
        guard !log.rows.isEmpty else { return nil }
        let inside = selection.filter { $0 >= 0 && $0 < log.rows.count }
        let lo = inside.min() ?? 0, hi = inside.max() ?? (log.rows.count - 1)
        self.log = log
        self.first = lo
        self.last = hi
        self.summaries = (lo...hi).map { log.journal.summary(ofRow: $0) }
    }

    // MARK: Text

    static func dateText(_ t: Int64) -> String {
        let c = CivilTime.components(t)
        return String(format: "%04d/%02d/%02d", c.year, c.month, c.day)
    }
    static func timeText(_ t: Int64) -> String {
        let c = CivilTime.components(t)
        return String(format: "%02d:%02d:%02d", c.hour, c.minute, c.second)
    }
    static func compactText(_ t: Int64) -> String {
        let c = CivilTime.components(t)
        return String(format: "%04d%02d%02d%02d%02d%02d", c.year, c.month, c.day, c.hour, c.minute, c.second)
    }
    /// Hours, minutes and seconds; the hours grow beyond two digits for long totals.
    public static func clockText(seconds s: Int) -> String { String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
    /// `%.nf` of the C library: the decimal expansion of the exact binary value, rounded half-even. A `locale:` argument would
    /// make Foundation round the shortest decimal form instead (1.85 gives 1.8, the original prints 1.9).
    static func decimal(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
    static func triggerText(_ bits: UInt8) -> String { triggerNames.first { bits & $0.mask != 0 }?.text ?? "" }

    /// `<first row start>_<last row end>_履歴記録レポート` (yyyyMMddHHmmss clocks).
    public var fileStem: String {
        Self.compactText(summaries[0].start) + "_" + Self.compactText(summaries[summaries.count - 1].end) + "_" + Self.title
    }
    public var summaryFileName: String { fileStem + "_集計.csv" }
    public var dataFileName: String { fileStem + "_データ.csv" }

    // MARK: Summary

    /// The eleven cells of row `i` (0-based inside the report). Distance and speeds stay empty for a row without any fix.
    public func cells(_ i: Int) -> [String] {
        let s = summaries[i]
        var out = [Self.dateText(s.start), Self.timeText(s.start) + "\u{FF5E}" + Self.timeText(s.end), Self.clockText(seconds: s.duration)]
        if s.hasFix {
            out += [Self.decimal(s.distanceMeters / 1000, 3), Self.decimal(s.averageSpeed, 1), String(s.maximumSpeed)]
        } else {
            out += ["", "", ""]
        }
        out += [String(s.shock), String(s.sudden), String(s.steering), String(s.oneTouch), String(s.events)]
        return out
    }
    public var tableRows: [[String]] { (0..<rowCount).map { cells($0) } }
    /// The 合計 line: the summed driving time and distance and the summed counters.
    public var totalCells: [String] {
        var seconds = 0, meters = 0.0
        var counters = [0, 0, 0, 0, 0]
        for s in summaries {
            seconds += s.duration
            meters += s.distanceMeters
            counters[0] += s.shock; counters[1] += s.sudden; counters[2] += s.steering; counters[3] += s.oneTouch; counters[4] += s.events
        }
        return ["合計", "", Self.clockText(seconds: seconds), Self.decimal(meters / 1000, 3), "", ""] + counters.map { String($0) }
    }
    /// Header, one line per row (each ending with a comma like the original's) and the 合計 line; LF line ends.
    public func summaryCSV() -> String {
        var out = Self.summaryHeader + "\n"
        for i in 0..<rowCount { out += cells(i).joined(separator: ",") + ",\n" }
        out += totalCells.joined(separator: ",") + ",\n"
        return out
    }
    public func summaryCSVData() throws -> Data { try LegacyReport.encodeCP932(summaryCSV()) }

    // MARK: Data

    /// Number of data lines (journal entries of the selected rows).
    public var dataLineCount: Int {
        let rows = log.journal.rows
        return rows[last].entryStart + rows[last].entryCount - rows[first].entryStart
    }

    /// One line per entry: both clocks, speed, acceleration, position (WGS84 from the device's Tokyo datum), heading,
    /// fix flag, trigger name, the (empty) SD card ID and the unit number. Encoded in 1 MiB steps.
    public func dataCSV(cancelled: () -> Bool = { false }) throws -> Data {
        var out = try LegacyReport.encodeCP932(Self.dataHeader + "\n")
        var chunk = ""
        chunk.reserveCapacity(1 << 20)
        let rows = log.journal.rows
        let begin = rows[first].entryStart, end = begin + dataLineCount
        for n in begin..<end {
            if (n - begin) & 0x3FFF == 0 && cancelled() { throw BrowserError.io("CSV出力をキャンセルしました") }
            chunk += dataLine(n)
            if chunk.utf8.count >= 1 << 20 {
                out.append(try LegacyReport.encodeCP932(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { out.append(try LegacyReport.encodeCP932(chunk)) }
        return out
    }

    func dataLine(_ n: Int) -> String {
        let journal = log.journal
        let s = journal.dataSlot(n)
        let invalid = JournalSlot.invalid
        let g = journal.gps[n], b = journal.body[n]
        var latitude = "0.000000", longitude = "0.000000"
        if let c = DeviceGeodesy.coordinate(latitude: s.latitudeRaw, longitude: s.longitudeRaw, altitudeMillimetres: s.altitudeMillimetres, datum: .deviceTokyo) {
            latitude = Self.decimal(c.latitude, 6)
            longitude = Self.decimal(c.longitude, 6)
        }
        var fields: [String] = []
        fields.reserveCapacity(15)
        if g != invalid { fields += [Self.dateText(g), Self.timeText(g)] } else { fields += ["0000/00/00", "00:00:00"] }
        if b != invalid { fields += [Self.dateText(b), Self.timeText(b)] } else { fields += ["0000/00/00", "00:00:00"] }
        fields.append(String(s.speed))
        fields.append(LegacyReport.accelerationText(s.accelerationX))
        fields.append(LegacyReport.accelerationText(s.accelerationY))
        fields.append(LegacyReport.accelerationText(s.accelerationZ))
        fields.append(latitude)
        fields.append(longitude)
        fields.append(Self.decimal(Double(s.headingRaw) * 1e-5, 1))
        fields.append(s.fix == 3 ? "3D測位" : (s.fix == 2 ? "2D測位" : "非測位"))
        fields.append(Self.triggerText(s.trigger))
        fields.append("")
        fields.append(s.deviceID ?? "")
        return fields.joined(separator: ",") + "\n"
    }
}
