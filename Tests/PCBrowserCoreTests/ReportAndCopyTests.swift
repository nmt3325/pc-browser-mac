import XCTest
import CryptoKit
@testable import PCBrowserCore

final class ReportAndCopyTests: XCTestCase {
    func temp() throws -> URL {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: p) }; return p
    }
    final class Partial: ByteSource, @unchecked Sendable {
        let byteCount: UInt64 = 512
        var isPartialCopy: Bool { true }
        func read(at: UInt64, count: Int) throws -> Data { Data(count: count) }
    }
    func testImageCopyMatchesBytesAndIndependentSHA() throws {
        let data = Data((0..<196629).map { UInt8(truncatingIfNeeded: $0) }), out = try temp().appendingPathComponent("copy.img")
        let report = try ImageCopy.write(source: MemorySource(data), to: out, chunkBytes: 4096)
        XCTAssertEqual(try Data(contentsOf: out), data); XCTAssertEqual(report.bytes, UInt64(data.count)); XCTAssertTrue(report.readbackVerified)
        XCTAssertEqual(report.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    func testImageCopyRefusesPartialAndExistingDestinations() throws {
        let out = try temp().appendingPathComponent("copy.img")
        XCTAssertThrowsError(try ImageCopy.write(source: Partial(), to: out))
        try Data([9]).write(to: out)
        XCTAssertThrowsError(try ImageCopy.write(source: MemorySource(Data(count: 512)), to: out))
        XCTAssertEqual(try Data(contentsOf: out), Data([9]))
        XCTAssertThrowsError(try ImageCopy.write(source: MemorySource(Data(count: 512)), to: URL(fileURLWithPath: "/dev/pcbrowser-test-do-not-create")))
    }
    func testImageCopyPreflightsClearlyInsufficientFreeSpace() throws {
        final class Huge: ByteSource, @unchecked Sendable {
            let byteCount = UInt64(Int64.max)
            func read(at: UInt64, count: Int) throws -> Data { XCTFail("Must refuse before any read"); return Data(count: count) }
        }
        let dir = try temp(), out = dir.appendingPathComponent("huge.img")
        XCTAssertThrowsError(try ImageCopy.write(source: Huge(), to: out))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
    func testImageCopyCancellationRemovesStagingBeforeCommit() throws {
        let dir = try temp(), out = dir.appendingPathComponent("copy.img")
        var calls = 0
        XCTAssertThrowsError(try ImageCopy.write(source: MemorySource(Data(count: 8192)), to: out, chunkBytes: 512, cancelled: { calls += 1; return calls > 2 }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
    func testImageCopyCancellationDuringReadbackRemovesStaging() throws {
        let dir = try temp(), out = dir.appendingPathComponent("copy.img")
        var stop = false
        XCTAssertThrowsError(try ImageCopy.write(source: MemorySource(Data(count: 8192)), to: out, chunkBytes: 1024, cancelled: { stop }, progress: { if $0 >= 0.8 { stop = true } }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
    func testReportSingleFrameUsesNominalTailAndRawLabels() throws {
        let (_, _, recording) = try ExtendedTests().recording(), r = try RecordingReport.make(recording, notes: "備考")
        XCTAssertEqual(r.frames, 1); XCTAssertEqual(r.gpsFrames, 1); XCTAssertEqual(r.audioBytes, 320)
        XCTAssertEqual(r.durationSeconds, 1.0 / 30, accuracy: 1e-8); XCTAssertEqual(r.speedCoverageSeconds, r.durationSeconds, accuracy: 1e-8)
        XCTAssertEqual(r.meanSpeedKMH, 36); XCTAssertEqual(r.maximumSpeedKMH, 36)
        XCTAssertEqual(try XCTUnwrap(r.distanceEstimateKM), 36 / 30.0 / 3600, accuracy: 1e-12)
        XCTAssertEqual(r.accelerationRaw[0].minimum, -1); XCTAssertEqual(r.eventRawDistribution.reduce(0) { $0 + $1.frames }, 1); XCTAssertEqual(r.notes, "備考")
    }
    func testReportExcludesMissingFixesAndLongTimeGaps() throws {
        let clocks = [(0, 0), (1, 0), (20, 0)], packets = try ExtendedTests().clockPackets(clocks)
        // Fill known valid coordinates/speeds using independent header bytes.
        var valid: [FramePacket] = []
        for (second, slot) in clocks {
            var h = FormatTests().packet()
            h.replaceSubrange(10..<17, with: Data([26, 11, 11, 20, 25, UInt8(second), UInt8(slot)])); h[0x1d] = 30
            ExtendedTests().put(35 * 600000, 0x28, &h); ExtendedTests().put(139 * 600000, 0x2c, &h); ExtendedTests().put(1000, 0x32, &h)
            valid.append(try FramePacket.parse(h, sector: 10, diskBytes: 100 * 512))
        }
        let r = try RecordingReport.make(.init(id: "test", recordSector: 10, channel: 1, packets: valid))
        XCTAssertEqual(r.durationSeconds, 20 + 1.0 / 30, accuracy: 1e-8)
        XCTAssertEqual(r.speedCoverageSeconds, 1 + 1.0 / 30, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(r.meanSpeedKMH), 36, accuracy: 1e-12)
        let noFix = try RecordingReport.make(.init(id: "nofix", recordSector: 10, channel: 1, packets: packets))
        XCTAssertEqual(noFix.gpsFrames, 0); XCTAssertEqual(noFix.speedCoverageSeconds, 0); XCTAssertNil(noFix.meanSpeedKMH); XCTAssertNil(noFix.distanceEstimateKM)
    }
    func testReportCSVQuotesNotesAndAvoidsSpreadsheetFormula() throws {
        let (_, _, recording) = try ExtendedTests().recording(), r = try RecordingReport.make(recording, notes: "=1+1,\"note\"\nline")
        let csv = RecordingReport.csv([r])
        XCTAssertTrue(csv.contains("\"'=1+1,\"\"note\"\"\nline\"")); XCTAssertTrue(csv.contains("event_raw_distribution"))
        XCTAssertThrowsError(try RecordingReport.make(.init(id: "empty", recordSector: 1, channel: 1, packets: [])))
    }
}

final class RawSensorQueryTests: XCTestCase {
    func packet(acceleration: Int16 = -32768, gyro: Int16 = 1234, event: UInt8 = 0x80, input: UInt8 = 3) throws -> FramePacket {
        var h = FormatTests().packet()
        for (at, value) in [(0x46, acceleration), (0x54, gyro)] { let v = UInt16(bitPattern: value); h[at] = UInt8(truncatingIfNeeded: v); h[at + 1] = UInt8(truncatingIfNeeded: v >> 8) }
        h[0x18] = event; h[0x3a] = input
        return try FramePacket.parse(h, sector: 10, diskBytes: 100 * 512)
    }
    func testRawSensorQueryDisabledMatchesWithoutHidingUnknown() throws {
        let q = RawSensorQuery(); XCTAssertFalse(q.hasConditions); XCTAssertTrue(q.matches(try packet()))
    }
    func testRawThresholdIncludesInt16MinimumWithoutOverflow() throws {
        var q = RawSensorQuery(); q.enabled = true; q.minimumAbsoluteAcceleration = 32768
        XCTAssertTrue(q.matches(try packet())); XCTAssertFalse(q.matches(try packet(acceleration: 32767)))
    }
    func testAllRawConditionsMustMatchSameFrame() throws {
        var q = RawSensorQuery(); q.enabled = true; q.minimumAbsoluteAcceleration = 2000; q.minimumAbsoluteGyro = 1000; q.eventByte = 0x80; q.inputIndex = 0; q.inputValue = 3
        XCTAssertTrue(q.matches(try packet()))
        XCTAssertFalse(q.matches(try packet(gyro: 999))); XCTAssertFalse(q.matches(try packet(event: 0))); XCTAssertFalse(q.matches(try packet(input: 2)))
        let a = try packet(acceleration: 3000, gyro: 0), b = try packet(acceleration: 0, gyro: 2000)
        XCTAssertFalse([a, b].contains(where: q.matches))
    }
    func testRawQueryBoundsCannotIndexOutsideTelemetry() throws {
        var q = RawSensorQuery(); q.enabled = true; q.accelerationAxis = Int.max; q.gyroAxis = -999; q.inputIndex = 999; q.eventByte = 999; q.inputValue = -999
        XCTAssertEqual(q.clamped.accelerationAxis, 2); XCTAssertEqual(q.clamped.gyroAxis, 0); XCTAssertEqual(q.clamped.inputIndex, 5)
        XCTAssertFalse(q.matches(try packet()))
    }
}
