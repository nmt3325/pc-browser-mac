import XCTest
@testable import PCBrowserCore

/// Differential test of the journal KML writer against the standalone reference (tools/kml_reference.py, which shares no code with
/// the app): deterministic random synthetic journals are written to an image, both sides export the Google Earth file with the same
/// settings and the files have to agree line for line. Coordinates may differ by 1e-10 degree (the last decimals of a computation
/// done with different libraries); everything else, the sizes included, has to be identical.
final class KMLReferenceTests: XCTestCase {
    private typealias Image = (data: Data, area: Range<UInt64>)

    private static var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools").appendingPathComponent("kml_reference.py")
    }

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

    /// Runs the reference; nil when it finds no journal.
    private func reference(_ image: Image, _ options: JournalKMLOptions, in folder: URL) throws -> (data: Data, name: String)? {
        let file = folder.appendingPathComponent("journal.img"), out = folder.appendingPathComponent("out.kml")
        try? FileManager.default.removeItem(at: out)
        try image.data.write(to: file)
        var arguments = ["python3", Self.script.path, file.path, String(image.area.lowerBound), String(image.area.upperBound - 1), out.path,
                         "--density", String(options.density), "--width", String(options.width), "--alpha", String(options.alpha),
                         "--rgb", String(format: "%06X", options.rgb)]
        if !options.showPoints { arguments.append("--no-points") }
        if !options.showRoute { arguments.append("--no-route") }
        let result = try launch(arguments)
        if result.status == 1 && result.output.contains("no journal") { return nil }
        guard result.status == 0 else { throw BrowserError.io("reference failed (\(result.status)): \(result.output)") }
        return (try Data(contentsOf: out), result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func options(for seed: Int) -> JournalKMLOptions {
        var o = JournalKMLOptions()
        switch seed % 6 {
        case 1: o.density = 1
        case 2: o.density = 7; o.width = 3; o.alpha = 200; o.rgb = 0x12A4E0; o.showRoute = false
        case 3: o.showPoints = false; o.width = 10; o.alpha = 0; o.rgb = 0xFFFFFF
        case 4: o.density = 30; o.alpha = 255; o.rgb = 0x0000FF
        case 5: o.showPoints = false; o.showRoute = false
        default: break
        }
        return o
    }

    func testRandomJournalsGiveTheSameFileAsTheReference() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kml-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var compared = 0, points = 0, routeCoordinates = 0, headerOnly = 0
        for seed in 1...30 {
            let image = JournalImage.random(seed: UInt64(seed))
            let o = options(for: seed)
            guard let log = try JournalImage.log(image) else {
                XCTAssertNil(try reference(image, o, in: folder), "seed \(seed): the reference found a journal, the app did not")
                continue
            }
            let kml = try XCTUnwrap(JournalKML(log: log), "seed \(seed)")
            guard let expected = try reference(image, o, in: folder) else {
                XCTFail("seed \(seed): the app found a journal, the reference did not")
                continue
            }
            compared += 1
            let actual = try kml.data(options: o)
            if let d = KMLText.firstDifference(KMLText.lines(actual), KMLText.lines(expected.data)) { XCTFail("seed \(seed) density \(o.density): \(d)") }
            XCTAssertEqual(actual.count, expected.data.count, "seed \(seed): file size")
            XCTAssertEqual(kml.defaultStem, expected.name, "seed \(seed): default file name")
            let text = String(decoding: actual, as: UTF8.self)
            points += text.components(separatedBy: "<Point>").count - 1
            if o.showRoute { routeCoordinates += text.components(separatedBy: ",0 ").count - 1 }
            if !o.showPoints && !o.showRoute { headerOnly += 1 }
        }
        XCTAssertGreaterThanOrEqual(compared, 25, "the generator should give a journal nearly every time")
        XCTAssertGreaterThanOrEqual(points, 300, "points should occur")
        XCTAssertGreaterThanOrEqual(routeCoordinates, 3000, "routes should occur")
        XCTAssertGreaterThanOrEqual(headerOnly, 3, "header-only files should occur")
    }

    func testReferenceAgreesOnAHandBuiltJournal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kml-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let t0 = CivilTime.seconds(year: 2026, month: 5, day: 1, hour: 9, minute: 0, second: 0)
        var seq: [JournalRecord] = []
        for i in 0..<60 {
            var r = JournalRecord(kind: 2, a: t0 + Int64(i), b: t0 + Int64(i), fix: i % 17 == 5 ? 0 : (i % 11 == 3 ? 2 : 3))
            r.speed = UInt16(i * 311 % 65000); r.heading = UInt32(i * 612_345 % 36_000_001)
            r.lat = Int32(21_000_000 + 33 * i); r.lon = Int32(83_400_000 - 47 * i); r.altitude = Int32(1000 * i)
            seq.append(r)
        }
        let image = JournalImage.make(ring: 80, firstSlot: 13, seq)
        let log = try XCTUnwrap(JournalImage.log(image))
        let kml = try XCTUnwrap(JournalKML(log: log))
        for density in [1, 3, 10, 30] {
            var o = JournalKMLOptions(); o.density = density
            let expected = try XCTUnwrap(try reference(image, o, in: folder))
            XCTAssertNil(KMLText.firstDifference(KMLText.lines(try kml.data(options: o)), KMLText.lines(expected.data)), "density \(density)")
        }
    }
}
