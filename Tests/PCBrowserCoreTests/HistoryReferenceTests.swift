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

    /// A journal of 400 to 1198 slots written from a random slot: runs of samples whose clocks, fixes, positions and trigger
    /// bits vary, split by gaps of empty slots, markers, unknown records and clock jumps. Half of them fill the whole ring.
    private func randomJournal(seed: UInt64) -> Image {
        var g = TestRandom(seed)
        let ring = 400 + 2 * g.below(400)
        let firstSlot = g.below(ring)
        let target = g.chance(40) ? ring : ring / 2 + g.below(ring / 2)
        let devices = ["YQB2000001", "yqa-18762 ", "          ", "ABC"]
        var seq: [JournalRecord] = []
        var clock = t0 + Int64(g.below(100_000))
        var fix: UInt8 = 3
        var lat: Int32 = 21_000_000, lon: Int32 = 83_400_000

        func clocks() -> (a: Int64?, b: Int64?) {
            var a: Int64? = clock, b: Int64? = clock
            let pick = g.below(100)
            if pick >= 70 && pick < 80 { a = clock - 1 }
            else if pick >= 80 && pick < 85 { a = clock + 1 }
            else if pick >= 85 && pick < 90 { a = clock - 61 }
            else if pick >= 90 && pick < 95 { a = clock + Int64(g.below(601)) - 300 }
            else if pick >= 95 { a = nil }
            if g.chance(3) { b = nil }
            return (a, b)
        }
        func slot(kind: Int) -> JournalRecord {
            clock += 1
            if g.chance(2) { clock += Int64(1 + g.below(5000)) } else if g.chance(1) { clock -= Int64(1 + g.below(300)) }
            let (a, b) = clocks()
            if g.chance(6) {
                let pick = g.below(10)
                fix = pick < 6 ? 3 : (pick < 8 ? 2 : (pick == 8 ? 0 : 1))
            }
            var r = JournalRecord(kind: kind, a: a, b: b, fix: fix)
            r.speed = g.chance(3) ? 65535 : UInt16(g.below(3000))
            if g.chance(2) {
                r.lat = 0; r.lon = 0
            } else {
                if g.chance(2) {
                    lat = Int32(20_000_000 + g.below(2_000_000)); lon = Int32(83_000_000 + g.below(3_000_000))
                } else {
                    lat += Int32(g.below(121) - 60); lon += Int32(g.below(121) - 60)
                }
                r.lat = lat; r.lon = lon
            }
            r.altitude = Int32(g.below(300_000) - 20_000)
            r.heading = UInt32(g.below(36_000_000))
            r.trigger = g.chance(8) ? UInt8(g.below(256)) : 0
            var accel: [Int16] = []
            for _ in 0..<3 { accel.append(g.chance(3) ? Int16(truncatingIfNeeded: g.below(65536) - 32768) : Int16(g.below(2001) - 1000)) }
            r.accel = accel
            if g.chance(5) { r.device = devices[g.below(devices.count)] }
            return r
        }
        func blank() -> JournalRecord { clock += 1; return JournalRecord(kind: 0) }

        while seq.count < target {
            let length = g.chance(10) ? 100 + g.below(150) : 3 + g.below(60)
            for _ in 0..<length { seq.append(slot(kind: 2)) }
            let pick = g.below(100)
            var gap: [JournalRecord] = []
            if pick < 25 {
                let n = 1 + g.below(3)
                for _ in 0..<n { gap.append(g.chance(50) ? slot(kind: 1) : blank()) }
            } else if pick < 55 {
                let n = 4 + g.below(5)
                for _ in 0..<n { gap.append(g.chance(50) ? slot(kind: 1) : blank()) }
            } else if pick < 70 {
                let n = 3 + g.below(4)
                for _ in 0..<n { gap.append(slot(kind: 1)) }
                if g.chance(40) { gap.insert(blank(), at: g.below(gap.count)) }
            } else if pick < 80 {
                let n = 2 + g.below(5)
                for _ in 0..<n { gap.append(g.chance(50) ? slot(kind: 3) : (g.chance(50) ? slot(kind: 1) : blank())) }
            } else if pick < 90 {
                // no gap at all
            } else {
                let n = 1 + g.below(3)
                for _ in 0..<n { gap.append(slot(kind: 2)) }
            }
            seq += gap
            if g.chance(30) { clock += Int64(g.below(4000)) }
        }
        if seq.count > ring { seq.removeLast(seq.count - ring) }
        return JournalImage.make(ring: ring, firstSlot: firstSlot, seq)
    }

    func testRandomJournalsGiveByteIdenticalReportsToTheReference() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var compared = 0, selections = 0, rowTotal = 0, markerRows = 0
        for seed in 1...48 {
            let image = randomJournal(seed: UInt64(seed))
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
