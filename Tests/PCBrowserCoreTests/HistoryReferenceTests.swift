import XCTest
@testable import PCBrowserCore

/// Differential test of the journal model and the report writer against the standalone reference implementation
/// (tools/history_reference.py, which shares no code with the app): deterministic random synthetic journals are written to an
/// image, both sides export it and the CSV files and the file stem have to be byte-identical.
final class HistoryReferenceTests: XCTestCase {
    private let t0 = CivilTime.seconds(year: 2026, month: 5, day: 1, hour: 9, minute: 0, second: 0)
    private static let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
    private typealias Image = (data: Data, area: Range<UInt64>)

    private static var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools").appendingPathComponent("history_reference.py")
    }

    private struct Exported { var summary: Data; var data: Data; var name: String }

    private func launch(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let text = out.fileHandleForReading.readDataToEndOfFile()
        let problems = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: text, as: UTF8.self) + String(decoding: problems, as: UTF8.self))
    }

    override func setUpWithError() throws {
        let probe = try? launch(["python3", "--version"])
        if probe?.status != 0 {
            if ProcessInfo.processInfo.environment["PCBROWSER_ALLOW_MISSING_PYTHON"] == "1" { throw XCTSkip("python3 is not available") }
            XCTFail("python3 is needed for the reference comparison (set PCBROWSER_ALLOW_MISSING_PYTHON=1 to skip it)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.script.path), "reference script missing: \(Self.script.path)")
    }

    /// Runs the reference on `image` (rows are 0-based and inclusive); nil when it finds no journal.
    private func reference(_ image: Image, rows: ClosedRange<Int>?, in folder: URL) throws -> Exported? {
        let file = folder.appendingPathComponent("journal.img")
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.removeItem(at: out)
        try image.data.write(to: file)
        var arguments = ["python3", Self.script.path, file.path, String(image.area.lowerBound), String(image.area.upperBound - 1), out.path]
        if let rows = rows { arguments += [String(rows.lowerBound), String(rows.upperBound)] }
        let result = try launch(arguments)
        if result.status == 1 && result.output.contains("no journal") { return nil }
        guard result.status == 0 else { throw BrowserError.io("reference failed (\(result.status)): \(result.output)") }
        return Exported(summary: try Data(contentsOf: out.appendingPathComponent("summary.csv")),
                        data: try Data(contentsOf: out.appendingPathComponent("data.csv")),
                        name: try String(contentsOf: out.appendingPathComponent("name.txt"), encoding: .utf8))
    }

    private func firstDifference(_ swift: Data, _ reference: Data) -> String? {
        if swift == reference { return nil }
        let a = swift.split(separator: 0x0A, omittingEmptySubsequences: false)
        let b = reference.split(separator: 0x0A, omittingEmptySubsequences: false)
        func text(_ d: Data) -> String { String(data: d, encoding: Self.cp932) ?? "<undecodable \(d.count) bytes>" }
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            return "line \(i): swift [\(text(Data(a[i])))] reference [\(text(Data(b[i])))]"
        }
        return "line counts differ: swift \(a.count) reference \(b.count)"
    }

    // MARK: random journals

    func testRandomJournalsGiveByteIdenticalReportsToTheReference() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var compared = 0, selections = 0, rowTotal = 0, markerRows = 0
        for seed in 1...48 {
            let image = JournalImage.random(seed: UInt64(seed))
            guard let log = try JournalImage.log(image) else {
                XCTAssertNil(try reference(image, rows: nil, in: folder), "seed \(seed): the reference found a journal, the app did not")
                continue
            }
            rowTotal += log.rows.count
            markerRows += log.rows.filter { $0.kind == .marker }.count
            var range: ClosedRange<Int>?
            if seed % 3 == 0 && log.rows.count > 1 {
                let lo = (seed * 7) % log.rows.count
                range = lo...(lo + (seed * 13) % (log.rows.count - lo))
                selections += 1
            }
            guard let report = LegacyHistoryReport(log: log, rows: range.map { Set($0) } ?? []) else {
                XCTFail("seed \(seed): no report for \(log.rows.count) rows")
                continue
            }
            guard let expected = try reference(image, rows: range, in: folder) else {
                XCTFail("seed \(seed): the app found a journal, the reference did not")
                continue
            }
            compared += 1
            if let d = firstDifference(try report.summaryCSVData(), expected.summary) { XCTFail("seed \(seed) rows \(String(describing: range)): summary \(d)") }
            if let d = firstDifference(try report.dataCSV(), expected.data) { XCTFail("seed \(seed) rows \(String(describing: range)): data \(d)") }
            XCTAssertEqual(report.fileStem, expected.name, "seed \(seed): file stem")
        }
        XCTAssertGreaterThanOrEqual(compared, 40, "the generator should give a journal nearly every time")
        XCTAssertGreaterThanOrEqual(selections, 8)
        XCTAssertGreaterThanOrEqual(rowTotal, 120, "the journals should split into many rows")
        XCTAssertGreaterThanOrEqual(markerRows, 3, "marker rows should occur")
    }

    func testJournalsWithoutAnyValidSampleAreNotReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let markers = (0..<30).map { JournalRecord(kind: 1, a: t0 + Int64($0), b: t0 + Int64($0)) }
        var unreadable = JournalRecord(kind: 2)
        unreadable.a = nil; unreadable.b = nil
        for records in [[], markers, markers + [unreadable]] {
            let image = JournalImage.make(ring: 400, firstSlot: 7, records)
            XCTAssertNil(try JournalImage.log(image))
            XCTAssertNil(try reference(image, rows: nil, in: folder))
        }
    }

    func testReferenceAgreesOnAHandBuiltJournalWithAllRowKinds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func sample(_ t: Int) -> JournalRecord { JournalRecord(kind: 2, a: t0 + Int64(t), b: t0 + Int64(t)) }
        func marker(_ t: Int) -> JournalRecord { JournalRecord(kind: 1, a: t0 + Int64(t), b: t0 + Int64(t)) }
        let blank = JournalRecord(kind: 0)
        var seq: [JournalRecord] = []
        for t in 0..<12 { seq.append(sample(t)) }
        seq += [marker(12), blank, blank, blank, marker(16), marker(17), marker(18), blank]
        for t in 20..<35 { seq.append(sample(t)) }
        seq += [blank, marker(36)]
        for t in 40..<52 { seq.append(sample(t)) }
        let image = JournalImage.make(ring: 100, firstSlot: 41, seq)
        let log = try XCTUnwrap(JournalImage.log(image))
        XCTAssertTrue(log.rows.contains { $0.kind == .marker }, "the three-marker gap gives a marker row")
        let report = try XCTUnwrap(LegacyHistoryReport(log: log))
        let expected = try XCTUnwrap(try reference(image, rows: nil, in: folder))
        XCTAssertNil(firstDifference(try report.summaryCSVData(), expected.summary))
        XCTAssertNil(firstDifference(try report.dataCSV(), expected.data))
        XCTAssertEqual(report.fileStem, expected.name)
    }
}
