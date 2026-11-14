import XCTest
@testable import PCBrowserCore

/// Numbers of twelve decimals (the coordinates of a KML file) are compared with a tolerance, everything else exactly: the original
/// computes the datum shift with the FPU's extended precision, so the last printed digit of some coordinates differs by one.
enum KMLText {
    static let number = try! NSRegularExpression(pattern: "-?[0-9]+\\.[0-9]{12}")

    static func split(_ line: String) -> (template: String, values: [Double]) {
        let ns = line as NSString
        var template = "", values: [Double] = [], last = 0
        for m in number.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            template += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "#"
            values.append(Double(ns.substring(with: m.range)) ?? .nan)
            last = m.range.location + m.range.length
        }
        return (template + ns.substring(from: last), values)
    }

    /// The first line where two documents differ beyond `tolerance` degrees in a coordinate, or nil.
    static func firstDifference(_ actual: [String], _ expected: [String], tolerance: Double = 1e-10) -> String? {
        for i in 0..<min(actual.count, expected.count) where actual[i] != expected[i] {
            let a = split(actual[i]), e = split(expected[i])
            guard a.template == e.template, a.values.count == e.values.count else {
                return "line \(i + 1): actual [\(actual[i].prefix(160))] expected [\(expected[i].prefix(160))]"
            }
            for (x, y) in zip(a.values, e.values) where !(abs(x - y) <= tolerance) { return "line \(i + 1): coordinate \(x) against \(y)" }
        }
        return actual.count == expected.count ? nil : "line counts differ: actual \(actual.count) expected \(expected.count)"
    }

    static func lines(_ data: Data) -> [String] {
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 byte order mark")
        return String(decoding: data.dropFirst(3), as: UTF8.self).components(separatedBy: "\r\n")
    }
}

/// ログデータ変換: the Google Earth file of the journal for hand-built journals. The expected texts follow the layout measured on
/// the original's export (docs/kml-export.md); the numbers come from the standalone reference (tools/kml_reference.py); nothing here
/// comes from a card.
final class JournalKMLTests: XCTestCase {
    private let t0 = CivilTime.seconds(year: 2026, month: 5, day: 1, hour: 9, minute: 0, second: 0)
    private typealias Image = (data: Data, area: Range<UInt64>)
    private static let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    /// Entry n takes the data of sample n and the GPS clock t0 + n + 1 (the first sample is read twice, see docs/history-report.md).
    private func fixByte(_ n: Int) -> UInt8 {
        if (5...7).contains(n) { return 0 }
        if (20...22).contains(n) { return 1 }
        return n == 12 ? 2 : 3
    }
    private func hasFix(_ n: Int) -> Bool { fixByte(n) == 2 || fixByte(n) == 3 }

    /// 40 samples of a Friday morning: no fix in 5…7, a 2D fix in 12 and fix byte 1 (not a fix for the file) in 20…22. Speed, heading and
    /// position vary with the index; seven headings sit at the rounding borders.
    private func image() -> Image {
        let special: [Int: UInt32] = [0: 50_000, 1: 35_999_999, 2: 36_000_000, 3: 249_999, 4: 250_001, 10: 150_000, 30: 250_000]
        var seq: [JournalRecord] = []
        for i in 0..<40 {
            var r = JournalRecord(kind: 2, a: t0 + Int64(i), b: t0 + Int64(i), fix: fixByte(i))
            r.speed = UInt16(277 * i + 13)
            r.lat = Int32(21_000_000 + 40 * i); r.lon = Int32(83_400_000 + 90 * i)
            r.altitude = 12_000
            r.heading = special[i] ?? UInt32(900_000 * i)
            seq.append(r)
        }
        return JournalImage.make(ring: 40, firstSlot: 0, seq)
    }

    private func make(_ image: Image? = nil) throws -> JournalKML {
        let log = try XCTUnwrap(JournalImage.log(image ?? self.image()))
        return try XCTUnwrap(JournalKML(log: log))
    }
    private func lines(_ kml: JournalKML, _ options: JournalKMLOptions = JournalKMLOptions()) throws -> [String] {
        KMLText.lines(try kml.data(options: options))
    }
    private func clockText(_ t: Int64) -> String {
        let c = CivilTime.components(t)
        return String(format: "%02d:%02d:%02d", c.hour, c.minute, c.second)
    }
    /// The names of the point placemarks (those with a time of day; the route's placemark carries a date).
    private func pointNames(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            guard line.hasPrefix("<Placemark><name>"), line.hasSuffix("</name>") else { return nil }
            let name = String(line.dropFirst("<Placemark><name>".count).dropLast("</name>".count))
            return name.contains(":") ? name : nil
        }
    }
    private func routeCoordinates(_ lines: [String]) -> [String] {
        guard let line = lines.first(where: { $0.hasPrefix("<coordinates>") }) else { return [] }
        return line.dropFirst("<coordinates>".count).split(separator: " ").map(String.init)
    }

    // MARK: layout

    func testDefaultFileHasTheOriginalsLayoutLineForLine() throws {
        let kml = try make()
        let data = try kml.data()
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\r\n"))
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no lone LF")
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\r"), "no lone CR")
        let lines = KMLText.lines(data)
        XCTAssertEqual(lines.last, "", "every line, the last one too, ends with CRLF")
        XCTAssertEqual(Array(lines[0...4]), [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><kml xmlns=\"http://earth.google.com/kml/2.1\">",
            "<Document><name>2026年 05月 01日(金)</name>",
            "<Style id=\"line_style\">",
            "<LineStyle><color>64000000</color><width>5</width></LineStyle></Style>",
            "<Folder><name>ポイント</name>"])
        // Entries 0, 10 and 30 are the points of density 10 (20 has no fix): their placemarks, line for line.
        let icon = "<Style><IconStyle><color>FF00FF00</color><scale>0.8</scale><Icon><href>http://map.yupiteru-itymap.com/icon/arrow_r_2.png</href></Icon><heading>%d</heading></IconStyle></Style>"
        let table = "<description><![CDATA[<table><tr><td>日付</td><td>2026年05月01日(金)</td></tr><tr><td>時刻</td><td>%@</td></tr><tr><td>速度(GPS値)</td><td>%@km/h</td></tr><tr><td>進行方向</td><td>%@度</td></tr></table>]]></description>"
        let points: [(name: String, clock: String, heading: Int, speed: String, direction: String, lon: Double, lat: Double)] = [
            ("09:00:01", "09時00分01秒", 0, "0.5", "0.5", 138.9968730700, 35.0033452250),
            ("09:00:11", "09時00分11秒", 2, "100.2", "1.5", 138.9983729176, 35.0040118554),
            ("09:00:31", "09時00分31秒", 2, "299.6", "2.5", 139.0013726129, 35.0053451161)]
        var cursor = 5
        for p in points {
            XCTAssertEqual(lines[cursor], "<Placemark><name>\(p.name)</name>")
            XCTAssertEqual(lines[cursor + 1], String(format: icon, p.heading))
            let point = KMLText.split(lines[cursor + 2])
            XCTAssertEqual(point.template, "<Point><coordinates>#,#,0</coordinates></Point>")
            XCTAssertEqual(point.values[0], p.lon, accuracy: 1e-9)
            XCTAssertEqual(point.values[1], p.lat, accuracy: 1e-9)
            XCTAssertEqual(lines[cursor + 3], String(format: table, p.clock, p.speed, p.direction))
            let look = KMLText.split(lines[cursor + 4])
            XCTAssertEqual(look.template, "<LookAt><longitude>#</longitude><latitude>#</latitude><tilt>50</tilt><range>400</range><heading>\(p.heading)</heading></LookAt>")
            XCTAssertEqual(look.values, point.values, "the view looks at the point")
            XCTAssertEqual(lines[cursor + 5], "</Placemark>")
            cursor += 6
        }
        XCTAssertEqual(lines[cursor], "</Folder>")
        XCTAssertEqual(Array(lines[(cursor + 1)...(cursor + 4)]), [
            "<Folder><name>ルート</name>",
            "<Placemark><name>2026年05月01日 09時00分01秒</name>",
            "<styleUrl>#line_style</styleUrl>",
            "<LineString id=\"CarRoute\"><tessellate>1</tessellate>"])
        // One triple per fix entry, each followed by a space, all on one line; the closing tags follow on their own lines.
        let route = lines[cursor + 5]
        XCTAssertTrue(route.hasPrefix("<coordinates>") && route.hasSuffix(" "))
        let triples = routeCoordinates(lines)
        XCTAssertEqual(triples.count, (0..<40).filter(hasFix).count)
        XCTAssertEqual(triples.count, 34)
        for t in triples { XCTAssertEqual(KMLText.split(t).template, "#,#,0", t) }
        XCTAssertEqual(Array(lines[(cursor + 6)...]), [
            "</coordinates></LineString>", "</Placemark>", "</Folder>", "</Document>", "</kml>", ""])
        XCTAssertEqual(KMLText.split(triples[0]).values[0], 138.9968730700, accuracy: 1e-9)
        XCTAssertEqual(KMLText.split(triples[7]).values[1], 35.0040118554, accuracy: 1e-9, "the fix entries are 0…4, 8…19 and 23…39: entry 10 is the eighth")
    }

    func testFileNameAndTitleFollowTheFirstRow() throws {
        let kml = try make()
        XCTAssertEqual(kml.defaultStem, "YP_20260501_090001")
        XCTAssertEqual(kml.defaultFileName, "YP_20260501_090001.kml")
        XCTAssertEqual(kml.entryCount, 40)
        XCTAssertEqual(JournalKML.title, "ログデータ変換")
        XCTAssertEqual(JournalKML.completionText, "完了しました")
    }

    func testWeekdaysAreNamedInKanjiFromMondayToSunday() {
        func day(_ y: Int, _ m: Int, _ d: Int) -> Character { JournalKML.weekday(CivilTime.seconds(year: y, month: m, day: d, hour: 12, minute: 0, second: 0)) }
        XCTAssertEqual(String(day(2026, 5, 4)), "月")
        XCTAssertEqual(String(day(2026, 5, 5)), "火")
        XCTAssertEqual(String(day(2026, 5, 6)), "水")
        XCTAssertEqual(String(day(2024, 2, 29)), "木")
        XCTAssertEqual(String(day(2026, 5, 1)), "金")
        XCTAssertEqual(String(day(2000, 1, 1)), "土")
        XCTAssertEqual(String(day(2026, 5, 3)), "日")
        XCTAssertEqual(String(day(1970, 1, 1)), "木")
        XCTAssertEqual(String(JournalKML.weekday(CivilTime.seconds(year: 1969, month: 12, day: 31, hour: 23, minute: 59, second: 59))), "水")
    }

    // MARK: options

    func testEveryDensityPicksTheMultiplesOfItAmongTheFixEntries() throws {
        let kml = try make()
        for density in [1, 2, 4, 7, 10, 13, 30] {
            var o = JournalKMLOptions(); o.density = density; o.showRoute = false
            let expected = (0..<40).filter { $0 % density == 0 && hasFix($0) }.map { clockText(t0 + Int64($0) + 1) }
            XCTAssertEqual(pointNames(try lines(kml, o)), expected, "density \(density)")
        }
        var every = JournalKMLOptions(); every.density = 1; every.showRoute = false
        XCTAssertEqual(pointNames(try lines(kml, every)).count, 34)
        var seven = JournalKMLOptions(); seven.density = 7; seven.showRoute = false
        XCTAssertEqual(pointNames(try lines(kml, seven)), ["09:00:01", "09:00:15", "09:00:29", "09:00:36"], "entries 7 and 21 have no fix")
    }

    func testRouteAndPointFoldersCanBeLeftOut() throws {
        let kml = try make()
        var pointsOnly = JournalKMLOptions(); pointsOnly.showRoute = false
        var routeOnly = JournalKMLOptions(); routeOnly.showPoints = false
        var neither = JournalKMLOptions(); neither.showPoints = false; neither.showRoute = false
        let a = try lines(kml, pointsOnly), b = try lines(kml, routeOnly), c = try lines(kml, neither)
        XCTAssertTrue(a.contains("<Folder><name>ポイント</name>")); XCTAssertFalse(a.contains("<Folder><name>ルート</name>"))
        XCTAssertFalse(b.contains("<Folder><name>ポイント</name>")); XCTAssertTrue(b.contains("<Folder><name>ルート</name>"))
        XCTAssertEqual(a.last, ""); XCTAssertEqual(a[a.count - 2], "</kml>"); XCTAssertEqual(a[a.count - 3], "</Document>")
        XCTAssertEqual(Array(b[0...3]), Array(a[0...3]))
        XCTAssertEqual(b[4], "<Folder><name>ルート</name>")
        XCTAssertEqual(c, [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><kml xmlns=\"http://earth.google.com/kml/2.1\">",
            "<Document><name>2026年 05月 01日(金)</name>",
            "<Style id=\"line_style\">",
            "<LineStyle><color>64000000</color><width>5</width></LineStyle></Style>",
            "</Document>", "</kml>", ""], "a file without points and route keeps the header, like the original's")
    }

    func testLineColourIsWrittenAsAlphaBlueGreenRedAndSettingsStayInRange() throws {
        let kml = try make()
        var o = JournalKMLOptions(); o.alpha = 200; o.rgb = 0x102030; o.width = 3; o.showPoints = false; o.showRoute = false
        XCTAssertEqual(try lines(kml, o)[3], "<LineStyle><color>C8302010</color><width>3</width></LineStyle></Style>")
        XCTAssertEqual(o.colourText, "C8302010")
        o.alpha = 0; o.rgb = 0xFF0080; o.width = 10
        XCTAssertEqual(try lines(kml, o)[3], "<LineStyle><color>008000FF</color><width>10</width></LineStyle></Style>")
        // The spin boxes of the dialog stop at their ends; values outside are brought back to them.
        var wild = JournalKMLOptions(); wild.density = 0; wild.width = 99; wild.alpha = 300; wild.rgb = 0xAB_CDEF12
        XCTAssertEqual([wild.clamped.density, wild.clamped.width, wild.clamped.alpha, Int(wild.clamped.rgb)], [1, 10, 255, 0xCDEF12])
        wild.density = 99; wild.width = -4; wild.alpha = -1
        XCTAssertEqual([wild.clamped.density, wild.clamped.width, wild.clamped.alpha], [30, 1, 0])
        wild.showRoute = false
        XCTAssertEqual(pointNames(try lines(kml, wild)), ["09:00:01", "09:00:31"], "density 99 is 30")
        let d = JournalKMLOptions()
        XCTAssertEqual([d.showPoints, d.showRoute, d.launchEarth], [true, true, true])
        XCTAssertEqual([d.density, d.width, d.alpha, Int(d.rgb)], [10, 5, 100, 0], "the defaults of the dialog")
        XCTAssertEqual(d.colourText, "64000000")
    }

    func testHeadingsRoundHalfToEvenOnTheBinaryValue() throws {
        let kml = try make()
        var o = JournalKMLOptions(); o.density = 1; o.showRoute = false
        let lines = try self.lines(kml, o)
        let headings = lines.compactMap { l -> Int? in
            guard l.hasPrefix("<Style><IconStyle>"), let r = l.range(of: "<heading>"), let e = l.range(of: "</heading>") else { return nil }
            return Int(l[r.upperBound..<e.lowerBound])
        }
        let directions = lines.compactMap { l -> String? in
            guard let r = l.range(of: "<td>進行方向</td><td>"), let e = l.range(of: "度</td>") else { return nil }
            return String(l[r.upperBound..<e.lowerBound])
        }
        // 0.5 gives 0 and 2.5 gives 2 (ties to even), 359.99999 and 360 give 360, 2.49999 gives 2 and 2.50001 gives 3 (entries 0…4).
        XCTAssertEqual(Array(headings.prefix(5)), [0, 360, 360, 2, 3])
        XCTAssertEqual(Array(directions.prefix(5)), ["0.5", "360.0", "360.0", "2.5", "2.5"])
        XCTAssertEqual(headings[5], 72, "the sixth fix entry is entry 8 (5…7 have no fix): 8 x 9 degrees")
        XCTAssertEqual(headings.count, 34)
    }

    // MARK: whole journal

    func testTheFileCoversEveryJournalEntryAndAgreesWithTheDataCSV() throws {
        var compared = 0
        for seed in 1...12 {
            guard let log = try JournalImage.log(JournalImage.random(seed: UInt64(seed))) else { continue }
            compared += 1
            let kml = try XCTUnwrap(JournalKML(log: log))
            let report = try XCTUnwrap(LegacyHistoryReport(log: log))
            XCTAssertEqual(kml.entryCount, report.dataLineCount, "seed \(seed): all rows, whatever is selected")
            // The data lines carry the same entries: fix flag, GPS clock and position as the file's points and route.
            let csv = try XCTUnwrap(String(data: try report.dataCSV(), encoding: Self.cp932))
            let rows = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            let fixRows = rows.filter { $0.count == 15 && ($0[11] == "3D測位" || $0[11] == "2D測位") }
            var every = JournalKMLOptions(); every.density = 1
            let l = KMLText.lines(try kml.data(options: every))
            XCTAssertEqual(routeCoordinates(l).count, fixRows.filter { $0[8] != "0.000000" || $0[9] != "0.000000" }.count, "seed \(seed): route")
            let withClock = fixRows.filter { $0[0] != "0000/00/00" }
            XCTAssertEqual(pointNames(l), withClock.map { $0[1] }, "seed \(seed): the points carry the GPS clock of the data lines")
        }
        XCTAssertGreaterThanOrEqual(compared, 8, "the generator should give a journal nearly every time")
    }

    func testTheFileIsWellFormedXML() throws {
        final class Counter: NSObject, XMLParserDelegate {
            var elements: [String: Int] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                elements[name, default: 0] += 1
            }
        }
        let kml = try make()
        var o = JournalKMLOptions(); o.density = 3
        let parser = XMLParser(data: try kml.data(options: o))
        let counter = Counter()
        parser.delegate = counter
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "")
        let points = (0..<40).filter { $0 % 3 == 0 && hasFix($0) }.count
        XCTAssertEqual(counter.elements["Placemark"], points + 1)
        XCTAssertEqual(counter.elements["Point"], points)
        XCTAssertEqual(counter.elements["LookAt"], points)
        XCTAssertEqual(counter.elements["LineString"], 1)
        XCTAssertEqual(counter.elements["Folder"], 2)
        XCTAssertEqual(counter.elements["kml"], 1)
    }

    func testTheExportCanBeCancelled() throws {
        let kml = try make()
        var pointsOnly = JournalKMLOptions(); pointsOnly.showRoute = false
        var routeOnly = JournalKMLOptions(); routeOnly.showPoints = false
        for o in [JournalKMLOptions(), pointsOnly, routeOnly] { XCTAssertThrowsError(try kml.data(options: o, cancelled: { true })) }
        XCTAssertNoThrow(try kml.data(cancelled: { false }))
    }

    func testAJournalWithoutRowsGivesNoFile() throws {
        XCTAssertNil(try JournalImage.log(JournalImage.make(ring: 40, firstSlot: 0, [])), "no per-second record, no rows, no file")
    }
}
