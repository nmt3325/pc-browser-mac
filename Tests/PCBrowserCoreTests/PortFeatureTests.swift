import XCTest
@testable import PCBrowserCore

final class PortFeatureTests: XCTestCase {
    func clock(_ second: Int = 0, slot: Int = 0) throws -> CardTimestamp {
        try XCTUnwrap(CardTimestamp.parse(Data([26, 11, 11, 9, 0, UInt8(second), UInt8(slot)]), offset: 0, fps: 30))
    }
    func point(_ id: Int, time: Double?, latitude: Double = 35, longitude: Double = 139, speed: Double? = 40) -> GPSPoint {
        .init(id: id, latitude: latitude, longitude: longitude, speedKMH: speed, timestamp: time.map(Date.init(timeIntervalSince1970:)))
    }
    func testFrameSamplingEveryNAnchorsAtSelection() throws {
        XCTAssertEqual(try FrameSampling.indices(starts: [0, 1, 2, 3, 4, 5], range: 1..<6, everyFrames: 2), [1, 3, 5])
    }
    func testFrameSamplingSecondsSkipsGapCatchup() throws {
        XCTAssertEqual(try FrameSampling.indices(starts: [0, 0.2, 1.01, 5, 5.1, 6], range: 0..<6, everySeconds: 1), [0, 2, 3, 5])
    }
    func testFrameSamplingValidatesAndDoesNotOverflow() throws {
        XCTAssertEqual(try FrameSampling.indices(starts: [0, 1], range: 0..<2, everyFrames: Int.max), [0])
        XCTAssertEqual(try FrameSampling.indices(starts: [], range: 0..<0), [])
        XCTAssertThrowsError(try FrameSampling.indices(starts: [0], range: -1..<1))
        XCTAssertThrowsError(try FrameSampling.indices(starts: [0], range: 0..<2))
        XCTAssertThrowsError(try FrameSampling.indices(starts: [0], range: 0..<1, everyFrames: 0))
        XCTAssertThrowsError(try FrameSampling.indices(starts: [1, 0], range: 0..<2))
        XCTAssertThrowsError(try FrameSampling.indices(starts: [.nan], range: 0..<1))
        for n in [0.0, -1, .nan, .infinity] { XCTAssertThrowsError(try FrameSampling.indices(starts: [0], range: 0..<1, everySeconds: n)) }
    }
    func testAVISchedulePreservesGapsAndRange() throws {
        let s = try ConstantRateSchedule(starts: [0, 10, 10.5, 12], range: 1..<4, framesPerSecond: 2)
        XCTAssertEqual(s.duration, 2.5); XCTAssertEqual(s.outputFrameCount, 5)
        XCTAssertEqual((0..<5).map { s.sourceIndex(for: $0) }, [1, 2, 2, 2, 3])
        XCTAssertEqual(s.sourceIndex(for: -50), 1); XCTAssertEqual(s.sourceIndex(for: 999), 3)
    }
    func testAVIScheduleDoesNotAddRoundingFrame() throws {
        let s = try ConstantRateSchedule(starts: (0..<1200).map { Double($0) / 30 }, range: 0..<1200, framesPerSecond: 30)
        XCTAssertEqual(s.outputFrameCount, 1200); XCTAssertEqual(s.sourceIndex(for: 1199), 1199)
    }
    func testAVIScheduleRejectsInvalidTimes() {
        XCTAssertThrowsError(try ConstantRateSchedule(starts: [0], range: 0..<0, framesPerSecond: 30))
        XCTAssertThrowsError(try ConstantRateSchedule(starts: [0], range: 0..<1, framesPerSecond: .nan))
        XCTAssertThrowsError(try ConstantRateSchedule(starts: [1, 0], range: 0..<2, framesPerSecond: 30))
        XCTAssertThrowsError(try ConstantRateSchedule(starts: [0, Double(UInt32.max)], range: 0..<2, framesPerSecond: 120))
    }
    func testCardTimeRequiresExplicitZoneAndAddsSlot() throws {
        let c = try clock(slot: 15), utc = TimeZone(secondsFromGMT: 0)!, jst = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(try XCTUnwrap(c.date(in: utc)).timeIntervalSince(try XCTUnwrap(c.date(in: jst))), 32400, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.date(in: jst)).timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.5)
        let track = ExternalGPSTrack(points: [point(0, time: c.date(in: jst)!.timeIntervalSince1970)])
        XCTAssertNil(track.sample(clock: c, deviceTimeZone: nil))
    }
    func testExternalGPSInterpolatesAndOffsetIsExplicit() throws {
        let c = try clock(), zone = TimeZone(secondsFromGMT: 0)!, base = c.date(in: zone)!.timeIntervalSince1970
        let track = ExternalGPSTrack(points: [point(0, time: base, latitude: 35, speed: 20), point(1, time: base + 2, latitude: 37, speed: 40)])
        let fix = try XCTUnwrap(track.sample(clock: c, deviceTimeZone: zone, logOffsetSeconds: 1))
        XCTAssertTrue(fix.interpolated); XCTAssertEqual(fix.coordinate.latitude, 36); XCTAssertEqual(fix.speedKMH, 30)
        XCTAssertFalse(try XCTUnwrap(track.sample(clock: c, deviceTimeZone: zone)).interpolated)
    }
    func testExternalGPSNeverExtrapolatesOrBridgesOutage() throws {
        let c = try clock(), z = TimeZone(secondsFromGMT: 0)!, base = c.date(in: z)!.timeIntervalSince1970
        let track = ExternalGPSTrack(points: [point(0, time: base), point(1, time: base + 20)])
        XCTAssertNil(track.sample(clock: c, deviceTimeZone: z, logOffsetSeconds: -1))
        XCTAssertNil(track.sample(clock: c, deviceTimeZone: z, logOffsetSeconds: 21))
        XCTAssertNil(track.sample(clock: c, deviceTimeZone: z, logOffsetSeconds: 10))
        XCTAssertNil(track.sample(clock: c, deviceTimeZone: z, logOffsetSeconds: .nan))
    }
    func testExternalGPSSortsDeduplicatesAndFilters() {
        let track = ExternalGPSTrack(points: [point(0, time: 2), point(1, time: nil), point(2, time: 1), point(3, time: 1), point(4, time: .infinity), point(5, time: 3, latitude: 91)])
        XCTAssertEqual(track.points.map(\.id), [2, 0])
    }
    func testExternalGPSDatelineUsesShortArc() throws {
        let c = try clock(), z = TimeZone(secondsFromGMT: 0)!, b = c.date(in: z)!.timeIntervalSince1970
        let t = ExternalGPSTrack(points: [point(0, time: b, longitude: 179), point(1, time: b + 2, longitude: -179)])
        XCTAssertEqual(abs(try XCTUnwrap(t.sample(clock: c, deviceTimeZone: z, logOffsetSeconds: 1)).coordinate.longitude), 180)
    }
    func testNMEAFractionalUTCAndInvalidCalendar() throws {
        func parse(_ t: String, _ date: String) -> GPSPoint? { NMEAParser.parse("$GPRMC,\(t),A,3500.0,N,13900.0,E,10,0,\(date),,,").points.first }
        let p = try XCTUnwrap(parse("000000.250", "111126")), d = try XCTUnwrap(p.timestamp)
        XCTAssertEqual(d.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.25)
        XCTAssertNil(parse("240000", "111126")?.timestamp)
        XCTAssertNil(parse("120060", "111126")?.timestamp)
        XCTAssertNil(parse("120000", "300226")?.timestamp)
        XCTAssertNil(parse("120000.x", "111126")?.timestamp)
        XCTAssertNotNil(parse("120000", "290224")?.timestamp)
    }
    func testTrackStyleKMLUsesABGRAndClamps() {
        var s = TrackStyle(); s.lineRGB = "1234aB"; s.alpha = 128
        XCTAssertEqual(s.kmlColor(), "80ab3412")
        s.alpha = 999; s.width = .infinity; s.density = 0; s.lineRGB = "<bad>"
        XCTAssertEqual(s.clamped.alpha, 255); XCTAssertEqual(s.clamped.width, 4); XCTAssertEqual(s.clamped.density, 1); XCTAssertEqual(s.clamped.lineRGB, "2783DE")
    }
    func testKMLSelectablePointsRoutesAndEscaping() throws {
        let (_, _, r) = try ExtendedTests().recording()
        var s = TrackStyle(); s.showPoints = true; s.showRoute = false; s.lineRGB = "FF0000"; s.pointRGB = "00FF00"
        let text = TrackExport.kml([r], datum: .wgs84, name: "A<&\"", style: s)
        XCTAssertTrue(text.contains("<Point>")); XCTAssertFalse(text.contains("<LineString>"))
        XCTAssertTrue(text.contains("A&lt;&amp;&quot;")); XCTAssertTrue(text.contains("ff00ff00")); XCTAssertFalse(text.contains("<when>"))
        s.showPoints = false; XCTAssertFalse(TrackExport.kml([r], style: s).contains("<Placemark>"))
    }
    func testSubtitlesDefaultsAndRawLabels() throws {
        let (_, _, r) = try ExtendedTests().recording(), p = r.packets[0]
        let normal = SubtitleText.lines(packet: p, datum: .wgs84)
        XCTAssertEqual(normal.count, 1); XCTAssertTrue(normal[0].contains("36.0 km/h")); XCTAssertFalse(normal[0].contains("Accel"))
        let raw = SubtitleText.lines(packet: p, fields: .all).joined(separator: "\n")
        for label in ["Accel raw", "Gyro raw", "Inputs raw", "Event raw"] { XCTAssertTrue(raw.contains(label)) }
        XCTAssertFalse(raw.contains("brake")); XCTAssertTrue(SubtitleText.lines(packet: p, fields: []).isEmpty)
    }
    func testSubtitlesExternalNoFixDoesNotInventEmbeddedFix() throws {
        let (_, _, r) = try ExtendedTests().recording()
        let option = GPSLogSynchronization(track: .init(points: []), deviceTimeZone: TimeZone(secondsFromGMT: 0)!)
        let text = SubtitleText.lines(packet: r.packets[0], externalGPS: option).joined()
        XCTAssertTrue(text.contains("no fix")); XCTAssertFalse(text.contains("km/h"))
    }
    func temp() throws -> URL {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: p) }; return p
    }
    let jpeg = Data([0xff, 0xd8, 0xff, 0xd9]) // Container fixture only; native exports are decoded independently.
    func testAVIWriterSingleFrameHeadersAndIndexes() throws {
        let out = try temp().appendingPathComponent("one.avi")
        let w = try MJPEGAVIWriter(output: out, width: 640, height: 480, framesPerSecond: 30, expectedFrames: 1, maximumSegments: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        try w.append(jpeg: jpeg); let summary = try w.finish(), d = try Data(contentsOf: out), b = Bytes(d)
        XCTAssertEqual(summary.frames, 1); XCTAssertEqual(summary.segments, 1); XCTAssertEqual(summary.bytes, UInt64(d.count))
        XCTAssertEqual(try b.ascii(0, 4), "RIFF"); XCTAssertEqual(try b.ascii(8, 4), "AVI "); XCTAssertEqual(try b.le32(4), UInt32(d.count - 8))
        let avih = try XCTUnwrap(d.range(of: Data("avih".utf8))).lowerBound
        XCTAssertEqual(try b.le32(avih + 8 + 16), 1); XCTAssertEqual(try b.le32(avih + 8 + 32), 640)
        let idx = try XCTUnwrap(d.range(of: Data("idx1".utf8))).lowerBound
        XCTAssertEqual(try b.le32(idx + 8 + 8), 4)
        let movi = try XCTUnwrap(d.range(of: Data("movi".utf8))).lowerBound
        XCTAssertEqual(try b.ascii(movi + 4, 4), "00dc"); XCTAssertEqual(try b.le32(movi + 8), 4)
        XCTAssertThrowsError(try w.append(jpeg: jpeg)); XCTAssertThrowsError(try w.finish())
    }
    func testAVIWriterForcedOpenDMLSegmentsAndPCMSamples() throws {
        let out = try temp().appendingPathComponent("split.avi"), pcm = PCMFormat()
        let w = try MJPEGAVIWriter(output: out, width: 640, height: 480, framesPerSecond: 30, expectedFrames: 5, audioFormat: pcm, segmentLimit: 262144, maximumSegments: 10)
        var large = Data([0xff, 0xd8]); large.append(Data(count: 150000)); large.append(contentsOf: [0xff, 0xd9])
        for _ in 0..<5 { try w.append(jpeg: large, pcm: Data(repeating: 128, count: 267)) }
        let s = try w.finish(), d = try Data(contentsOf: out)
        XCTAssertEqual(s.segments, 5); XCTAssertEqual(s.audioSampleFrames, 1335)
        var at = 0, riffs = 0
        while at < d.count {
            let b = Bytes(d); XCTAssertEqual(try b.ascii(at, 4), "RIFF"); XCTAssertEqual(try b.ascii(at + 8, 4), riffs == 0 ? "AVI " : "AVIX")
            at += Int(try b.le32(at + 4)) + 8; riffs += 1
        }
        XCTAssertEqual(at, d.count); XCTAssertEqual(riffs, 5)
    }
    func testAVIWriterIncompleteCancellationRemovesStaging() throws {
        let dir = try temp(), out = dir.appendingPathComponent("incomplete.avi")
        do { let w = try MJPEGAVIWriter(output: out, width: 1, height: 1, framesPerSecond: 30, expectedFrames: 2); try w.append(jpeg: jpeg); XCTAssertThrowsError(try w.finish()) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
    func testAVIWriterRefusesOverwriteBadJPEGAndMisalignedAudio() throws {
        let dir = try temp(), out = dir.appendingPathComponent("existing.avi")
        try Data([1, 2, 3]).write(to: out)
        XCTAssertThrowsError(try MJPEGAVIWriter(output: out, width: 1, height: 1, framesPerSecond: 30, expectedFrames: 1))
        XCTAssertEqual(try Data(contentsOf: out), Data([1, 2, 3]))
        let w = try MJPEGAVIWriter(output: dir.appendingPathComponent("new.avi"), width: 2, height: 2, framesPerSecond: 30, expectedFrames: 1, audioFormat: PCMFormat(channels: 2, bitsPerSample: 16))
        XCTAssertThrowsError(try w.append(jpeg: Data([0xff, 0xd8])))
        XCTAssertThrowsError(try w.append(jpeg: jpeg, pcm: Data(count: 1)))
        try w.append(jpeg: jpeg, pcm: Data(count: 4)); XCTAssertEqual(try w.finish().audioSampleFrames, 1)
    }
}
