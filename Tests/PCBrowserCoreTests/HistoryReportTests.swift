import XCTest
@testable import PCBrowserCore

/// 履歴記録レポート: the CSV pair, its summary figures and its file names for hand-built journals. The expected text of every
/// scenario was produced with the standalone reference implementation (tools/history_reference.py) from the same synthetic
/// records; nothing here comes from a card.
final class HistoryReportTests: XCTestCase {
    private let t0 = CivilTime.seconds(year: 2026, month: 5, day: 1, hour: 9, minute: 0, second: 0)
    private static let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
    private typealias Image = (data: Data, area: Range<UInt64>)

    private func sample(_ t: Int, fix: UInt8 = 3) -> JournalRecord {
        JournalRecord(kind: 2, a: t0 + Int64(t), b: t0 + Int64(t), fix: fix)
    }
    private func marker(_ t: Int) -> JournalRecord { JournalRecord(kind: 1, a: t0 + Int64(t), b: t0 + Int64(t), fix: 3) }
    private let empty = JournalRecord(kind: 0)

    private func report(_ image: Image, rows: Set<Int> = []) throws -> LegacyHistoryReport {
        let log = try XCTUnwrap(JournalImage.log(image))
        return try XCTUnwrap(LegacyHistoryReport(log: log, rows: rows))
    }
    /// Expected summary file: the header, the lines (a "~" stands for the full-width range mark) and a trailing LF.
    private func summary(_ lines: [String]) -> String {
        (LegacyHistoryReport.summaryHeader + "\n" + lines.joined(separator: "\n") + "\n").replacingOccurrences(of: "~", with: "\u{FF5E}")
    }
    private func dataLines(_ report: LegacyHistoryReport) throws -> [String] {
        let text = try XCTUnwrap(String(data: try report.dataCSV(), encoding: Self.cp932))
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: scenarios

    /// 80 slots written from slot 30: ten-second runs split by two markers, by a marker/empty/marker gap and by empty slots,
    /// then a marker triple and a marker followed by an empty slot. The ring end lies inside the third row.
    private func mergeImage() -> Image {
        var seq: [JournalRecord] = []
        for t in 0..<10 { seq.append(sample(t)) }
        seq += [marker(10), marker(11)]
        for t in 12..<22 { seq.append(sample(t)) }
        seq += [marker(22), empty, marker(24)]
        for t in 25..<45 { seq.append(sample(t)) }
        seq += [empty, empty]
        for t in 47..<57 { seq.append(sample(t)) }
        seq += [marker(57), marker(58), marker(59)]
        for t in 60..<70 { seq.append(sample(t)) }
        seq += [marker(70), empty]
        for t in 72..<80 { seq.append(sample(t)) }
        XCTAssertEqual(seq.count, 80)
        return JournalImage.make(ring: 80, firstSlot: 30, seq)
    }

    /// The five-row journal of RecordListTests: 192 slots from slot 100 with rows of 100, 20, 30 and 30 samples and a lone marker.
    private func fiveRowImage() -> Image {
        var seq: [JournalRecord] = []
        func samples(_ n: Int, base: Int64, fix: UInt8 = 3, offset: (Int) -> Int64) {
            for i in 0..<n { seq.append(JournalRecord(kind: 2, a: base + Int64(i) - offset(i), b: base + Int64(i), fix: fix)) }
        }
        func mark(_ a: Int64, _ b: Int64) -> JournalRecord { JournalRecord(kind: 1, a: a, b: b, fix: 0) }
        samples(100, base: t0 + 30) { _ in 61 }
        seq += [mark(t0 + 130 - 61, t0 + 130), empty, empty, mark(t0 + 5399, t0 + 5399)]
        samples(20, base: t0 + 5400, fix: 0) { _ in 0 }
        seq += [mark(t0 + 5420, t0 + 5420), empty, mark(t0 + 8999, t0 + 8999)]
        samples(30, base: t0 + 9000) { $0 < 15 ? 70 : 0 }
        seq += [mark(t0 + 9030, t0 + 9030), empty, mark(t0 + 9300 - 61, t0 + 9300), empty, mark(t0 + 12599, t0 + 12599)]
        samples(30, base: t0 + 12600) { $0 < 10 ? 61 : 161 }
        XCTAssertEqual(seq.count, 192)
        return JournalImage.make(ring: 192, firstSlot: 100, seq)
    }

    /// 20 samples without any fix, a trigger bit pattern on seven of them and a speed that grows with the index.
    private func counterImage() -> Image {
        let triggers: [Int: UInt8] = [3: 0x01, 5: 0x02, 7: 0x04, 9: 0x10, 11: 0x08, 13: 0x03, 15: 0x20]
        var seq: [JournalRecord] = []
        for i in 0..<20 {
            var r = sample(i, fix: 0)
            r.speed = UInt16(100 * i)
            r.trigger = triggers[i] ?? 0
            seq.append(r)
        }
        return JournalImage.make(ring: 20, firstSlot: 6, seq)
    }

    /// 16 samples whose first four carry unusual values: extreme accelerations, a 2D fix, a unit number that is not plain
    /// text and a trigger byte with an unnamed bit.
    private func formatImage() -> Image {
        var seq = (0..<16).map { sample($0) }
        seq[0].speed = 833; seq[0].accel = [-510, 1000, -5]; seq[0].lat = 21_000_000; seq[0].lon = 83_400_000
        seq[0].altitude = 10_000; seq[0].heading = 27_000_000; seq[0].trigger = 0x01
        seq[1].fix = 2; seq[1].speed = 1; seq[1].lat = 21_000_600; seq[1].lon = 83_400_600; seq[1].altitude = -1500
        seq[1].heading = 123_456; seq[1].trigger = 0x10; seq[1].accel = [32767, -32768, 1]
        seq[2].fix = 0; seq[2].speed = 65535; seq[2].device = "yqa-18762 "; seq[2].trigger = 0x08; seq[2].accel = [999, -999, 10]
        seq[3].fix = 1; seq[3].trigger = 0x84
        return JournalImage.make(ring: 16, firstSlot: 6, seq)
    }

    /// 40 samples that move east for 20 s and then north, with a 2D fix between the 31st and 35th.
    private func distanceImage() -> Image {
        var seq: [JournalRecord] = []
        for i in 0..<40 {
            var r = sample(i, fix: (i >= 30 && i < 35) ? 2 : 3)
            r.speed = UInt16(500 + (i % 2) * 500)
            r.lat = Int32(21_000_000 + (i < 20 ? 0 : 30 * (i - 19)))
            r.lon = Int32(83_400_000 + 60 * min(i, 19))
            seq.append(r)
        }
        return JournalImage.make(ring: 40, firstSlot: 0, seq)
    }

    // MARK: rows and summary

    func testShortGapsBesideTheRingEndAndMarkerTriplesDecideTheRows() throws {
        let r = try report(mergeImage())
        XCTAssertEqual(r.log.rows.map(\.records), [23, 20, 24, 9])
        XCTAssertEqual(r.summaryCSV(), summary([
            "2026/05/01,09:00:01~09:00:23,00:00:22,0.000,0.0,0,0,0,0,0,0,",
            "2026/05/01,09:00:25~09:00:44,00:00:19,0.000,0.0,0,0,0,0,0,0,",
            "2026/05/01,09:00:47~09:01:10,00:00:23,0.000,0.0,0,0,0,0,0,0,",
            "2026/05/01,09:01:12~09:01:20,00:00:08,0.000,0.0,0,0,0,0,0,0,",
            "合計,,00:01:12,0.000,,,0,0,0,0,0,"]))
        XCTAssertEqual(r.fileStem, "20260501090001_20260501090120_履歴記録レポート")
        XCTAssertEqual(r.summaryFileName, "20260501090001_20260501090120_履歴記録レポート_集計.csv")
        XCTAssertEqual(r.dataFileName, "20260501090001_20260501090120_履歴記録レポート_データ.csv")
    }

    func testSelectionIsTheContiguousRangeBetweenTheFirstAndLastSelectedRow() throws {
        let image = mergeImage()
        let middle = try report(image, rows: [2, 1])
        XCTAssertEqual([middle.first, middle.last, middle.rowCount], [1, 2, 2])
        XCTAssertEqual(middle.summaryCSV(), summary([
            "2026/05/01,09:00:25~09:00:44,00:00:19,0.000,0.0,0,0,0,0,0,0,",
            "2026/05/01,09:00:47~09:01:10,00:00:23,0.000,0.0,0,0,0,0,0,0,",
            "合計,,00:00:42,0.000,,,0,0,0,0,0,"]))
        XCTAssertEqual(middle.fileStem, "20260501090025_20260501090110_履歴記録レポート")
        XCTAssertEqual(middle.dataLineCount, 20 + 24)
        // Rows apart select everything between them; an empty or out-of-range selection selects every row.
        XCTAssertEqual(try report(image, rows: [0, 3]).summaryCSV(), try report(image).summaryCSV())
        XCTAssertEqual(try report(image, rows: [40, -1]).rowCount, 4)
        let single = try report(image, rows: [3])
        XCTAssertEqual(single.tableRows.count, 1)
        XCTAssertEqual(single.totalCells[2], "00:00:08")
    }

    func testFiveRowJournalReportsDurationsFromTheClockSpanOrTheEntryCount() throws {
        let r = try report(fiveRowImage())
        XCTAssertEqual(r.summaryCSV(), summary([
            "2026/05/01,08:59:30~09:02:10,00:01:41,0.000,0.0,0,0,0,0,0,0,",
            "2026/05/01,10:29:59~10:30:20,00:00:21,,,,0,0,0,0,0,",
            "2026/05/01,11:29:59~11:30:30,00:00:31,0.000,0.0,0,0,0,0,0,0,",
            "2026/05/01,11:35:00~11:35:00,00:00:01,,,,0,0,0,0,0,",
            "2026/05/01,12:29:59~12:27:49,00:00:31,0.000,0.0,0,0,0,0,0,0,",
            "合計,,00:03:05,0.000,,,0,0,0,0,0,"]))
        XCTAssertEqual(r.fileStem, "20260501085930_20260501122749_履歴記録レポート")
        XCTAssertEqual(r.dataLineCount, 187)
        let lines = try dataLines(r)
        XCTAssertEqual(lines.count, 1 + 187 + 1, "header, the lines and the empty piece behind the last LF")
        XCTAssertEqual(lines[0], LegacyHistoryReport.dataHeader)
        XCTAssertEqual(lines[1], "2026/05/01,08:59:30,2026/05/01,09:00:30,0,0.00,0.00,0.00,0.000000,0.000000,0.0,3D測位,,,YQA1018762")
        XCTAssertEqual(lines[100], "2026/05/01,09:01:09,2026/05/01,09:02:09,0,0.00,0.00,0.00,0.000000,0.000000,0.0,3D測位,,,YQA1018762")
        XCTAssertEqual(lines[101], "0000/00/00,00:00:00,2026/05/01,09:02:10,0,0.00,0.00,0.00,0.000000,0.000000,0.0,非測位,,,YQA1018762", "the closing entry of a row has no GPS clock")
        XCTAssertEqual(lines[102], "0000/00/00,00:00:00,2026/05/01,10:29:59,0,0.00,0.00,0.00,0.000000,0.000000,0.0,非測位,,,YQA1018762")
        XCTAssertEqual(lines[188], "")
    }

    func testRowsWithoutAnyFixLeaveDistanceAndSpeedsBlankAndCountTriggers() throws {
        let r = try report(counterImage())
        XCTAssertEqual(r.summaryCSV(), summary([
            "2026/05/01,09:00:00~09:00:19,00:00:19,,,,2,2,1,1,6,",
            "合計,,00:00:19,0.000,,,2,2,1,1,6,"]))
        XCTAssertEqual(r.cells(0).count, 11)
        XCTAssertEqual(LegacyHistoryReport.columnTitles.count, 11)
        let lines = try dataLines(r)
        XCTAssertEqual(lines[1], "0000/00/00,00:00:00,2026/05/01,09:00:00,0,0.00,0.00,0.00,0.000000,0.000000,0.0,非測位,,,YQA1018762")
        // The data of line k + 1 is the record of sample k; the first named bit gives the event, an unnamed bit gives none.
        let names = (0..<20).map { lines[$0 + 1].split(separator: ",", omittingEmptySubsequences: false)[12] }
        var expected = [String](repeating: "", count: 20)
        expected[3] = "衝撃"; expected[5] = "急発進/急ブレーキ"; expected[7] = "急ハンドル"; expected[9] = "ワンタッチ"
        expected[11] = "急旋回"; expected[13] = "衝撃"
        XCTAssertEqual(names.map(String.init), expected)
        XCTAssertEqual(LegacyHistoryReport.triggerText(0x20), "")
        XCTAssertEqual(LegacyHistoryReport.triggerText(0x84), "急ハンドル")
        XCTAssertEqual(LegacyHistoryReport.triggerText(0), "")
    }

    func testDataLinesFormatEveryFieldLikeTheOriginal() throws {
        let r = try report(formatImage())
        let lines = try dataLines(r)
        XCTAssertEqual(Array(lines[1...5]), [
            "2026/05/01,09:00:01,2026/05/01,09:00:00,29,-0.51,1.00,-0.00,35.003345,138.996873,270.0,3D測位,衝撃,,YQA1018762",
            "2026/05/01,09:00:02,2026/05/01,09:00:01,0,32.76,-32.76,0.00,35.004345,138.997873,1.2,2D測位,ワンタッチ,,YQA1018762",
            "0000/00/00,00:00:00,2026/05/01,09:00:02,2359,0.99,-0.99,0.01,0.000000,0.000000,0.0,非測位,急旋回,,",
            "0000/00/00,00:00:00,2026/05/01,09:00:03,0,0.00,0.00,0.00,0.000000,0.000000,0.0,非測位,急ハンドル,,YQA1018762",
            "2026/05/01,09:00:05,2026/05/01,09:00:04,0,0.00,0.00,0.00,0.000000,0.000000,0.0,3D測位,,,YQA1018762"])
        XCTAssertEqual(r.summaryCSV(), summary([
            "2026/05/01,09:00:01~09:00:16,00:00:15,0.000,149.2,2359,1,0,1,1,4,",
            "合計,,00:00:15,0.000,,,1,0,1,1,4,"]))
    }

    func testDistanceSumsOnlyConsecutiveThreeDimensionalFixes() throws {
        let r = try report(distanceImage())
        XCTAssertEqual(r.summaries[0].distanceMeters, 284.353949, accuracy: 0.001)
        XCTAssertEqual(r.summaryCSV(), summary([
            "2026/05/01,09:00:01~09:00:40,00:00:39,0.284,27.0,36,0,0,0,0,0,",
            "合計,,00:00:39,0.284,,,0,0,0,0,0,"]))
        let lines = try dataLines(r)
        XCTAssertEqual(lines[1], "2026/05/01,09:00:01,2026/05/01,09:00:00,18,0.00,0.00,0.00,35.003345,138.996873,0.0,3D測位,,,YQA1018762")
        XCTAssertEqual(lines[2], "2026/05/01,09:00:02,2026/05/01,09:00:01,36,0.00,0.00,0.00,35.003345,138.996973,0.0,3D測位,,,YQA1018762")
    }

    // MARK: files

    func testFilesAreCodePage932WithLFLineEndsAndTheFullWidthRangeMark() throws {
        let r = try report(mergeImage())
        let summaryData = try r.summaryCSVData()
        XCTAssertEqual(Array(summaryData.prefix(4)), [0x93, 0xFA, 0x95, 0x74], "日付")
        XCTAssertNotNil(summaryData.range(of: Data([0x81, 0x60])), "the range mark is U+FF5E in code page 932")
        XCTAssertFalse(summaryData.contains(0x0D), "LF only")
        XCTAssertEqual(summaryData.last, 0x0A)
        XCTAssertEqual(String(data: summaryData, encoding: Self.cp932), r.summaryCSV())
        let data = try r.dataCSV()
        XCTAssertFalse(data.contains(0x0D))
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(Array(data.prefix(4)), [0x47, 0x50, 0x53, 0x8E], "GPS時")
        XCTAssertEqual(try dataLines(r).count, r.dataLineCount + 2)
    }

    func testDataExportCanBeCancelled() throws {
        let r = try report(mergeImage())
        XCTAssertThrowsError(try r.dataCSV(cancelled: { true }))
        XCTAssertNoThrow(try r.dataCSV(cancelled: { false }))
    }

    func testHoursGrowBeyondTwoDigitsForLongTotals() {
        XCTAssertEqual(LegacyHistoryReport.clockText(seconds: 0), "00:00:00")
        XCTAssertEqual(LegacyHistoryReport.clockText(seconds: 3661), "01:01:01")
        XCTAssertEqual(LegacyHistoryReport.clockText(seconds: 100 * 3600 + 59), "100:00:59")
    }
}
