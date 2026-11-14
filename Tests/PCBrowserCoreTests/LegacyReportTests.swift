import XCTest
@testable import PCBrowserCore

/// Report rules of the original application, with synthetic frames. The expected strings follow the rules measured on CSV files
/// that the original exported from a real card (docs/report-format.md); no real values are used here.
final class LegacyReportTests: XCTestCase {
    struct Frame {
        var phase: UInt8 = 1
        var second = 0
        var speedRaw: UInt32 = 0
        var acceleration: [Int16] = [0, 0, 0]
        var fix: UInt8 = 1, satellites: UInt8 = 7
        var latitude: Int32 = 0, longitude: Int32 = 0
        var flags: UInt8 = 0, mask: UInt32 = 0
    }
    func packet(_ f: Frame) throws -> FramePacket {
        var h = FormatTests().packet()
        h[8] = f.phase
        h.replaceSubrange(10..<17, with: Data([26, 11, 11, 20, 25, UInt8(f.second), 0])); h[0x1d] = 30
        h.replaceSubrange(0x12..<0x18, with: Data([26, 11, 11, 20, 25, UInt8(f.second)]))
        h[0x26] = f.satellites; h[0x27] = f.fix
        FormatTests().put(UInt32(bitPattern: f.latitude), 0x28, &h); FormatTests().put(UInt32(bitPattern: f.longitude), 0x2C, &h)
        FormatTests().put(f.speedRaw, 0x32, &h)
        for (i, value) in f.acceleration.enumerated() {
            let u = UInt16(bitPattern: value)
            h[0x46 + 2 * i] = UInt8(u & 0xFF); h[0x47 + 2 * i] = UInt8(u >> 8)
        }
        h[0x40] = f.flags
        h[0x4C] = UInt8(f.mask & 0xFF); h[0x4D] = UInt8((f.mask >> 8) & 0xFF); h[0x4E] = UInt8((f.mask >> 16) & 0xFF)
        return try FramePacket.parse(h, sector: 10, diskBytes: 100 * 512)
    }
    func recording(_ id: String, _ frames: [Frame]) throws -> Recording {
        Recording(id: id, recordSector: 10, channel: frames[0].phase, packets: try frames.map(packet))
    }
    /// Two pre-roll frames, three frames of the trigger phase and four of the post phase; the trigger fields sit on the
    /// first post frame.
    func eventFrames() -> [Frame] {
        var frames = [Frame(phase: 5, second: 0, speedRaw: 5000), Frame(phase: 5, second: 0, speedRaw: 5000)]
        for (i, raw) in [UInt32(278), 556, 834].enumerated() { frames.append(Frame(phase: 2, second: 1 + i, speedRaw: raw)) }
        var first = Frame(phase: 3, second: 4, speedRaw: 1112, acceleration: [10, -25, 1000], flags: 1, mask: 1)
        first.latitude = 35 * 600000; first.longitude = 139 * 600000
        frames.append(first)
        for i in 1..<4 { frames.append(Frame(phase: 3, second: 4 + i)) }
        return frames
    }

    func testAccelerationIsCutToTwoDecimalsNotRounded() {
        let raws: [Int16] = [1000, -510, -5, 999, 1999, 0, 5, -1000, 15]
        XCTAssertEqual(raws.map { LegacyReport.accelerationText($0) }, ["1.00", "-0.51", "-0.00", "0.99", "1.99", "0.00", "0.00", "-1.00", "0.01"])
        XCTAssertEqual(LegacyReport.accelerationText(Int16.min), "-32.76")
    }
    func testSpeedIsTheRawValueTimesPointZeroThreeSixCut() throws {
        for (raw, kmh) in [(UInt32(0), 0), (277, 9), (278, 10), (1000, 36), (2000, 72), (1527, 54)] {
            XCTAssertEqual(LegacyReportFrame(try packet(Frame(speedRaw: raw))).speed, kmh, "raw \(raw)")
        }
    }
    func testGPSFlagText() {
        XCTAssertEqual(LegacyGPSFlag(fixRaw: 1, satellites: 7).text, "3D測位", "established on the original's export")
        XCTAssertEqual(LegacyGPSFlag(fixRaw: 0, satellites: 7).text, "非測位", "inferred")
        XCTAssertEqual(LegacyGPSFlag(fixRaw: 1, satellites: 0).text, "非測位", "inferred")
        XCTAssertEqual(LegacyGPSFlag(fixRaw: 1, satellites: 3).text, "2D測位", "inferred")
    }
    func testEventReportDropsPreRollFramesAndNamesTheEventOnTheTriggerRow() throws {
        let r = try recording("event-5-9", eventFrames())
        let report = try LegacyReport.make(r, deviceID: "YQA0000001")
        XCTAssertEqual(report.kind, .event)
        XCTAssertEqual(report.frames.count, 7)
        XCTAssertEqual(report.packetIndices, [2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(report.eventFrame, 3)
        XCTAssertEqual(report.eventLabel, "衝撃")
        XCTAssertEqual(LegacyReport.timeText(report.eventClock), "20:25:04")
        XCTAssertEqual(report.fileStem, "20261111202504_イベント記録レポート")
        XCTAssertEqual(report.dataFileName, "20261111202504_イベント記録レポート_データ.csv")
        XCTAssertEqual(report.summaryFileName, "20261111202504_イベント記録レポート_集計.csv")
        XCTAssertEqual(report.summaryCSV(), "日付,発生時刻,平均速度[km/h],最高速度[km/h],イベント種類\n2026/11/11,20:25:04,14.3,40,衝撃\n")
        let lines = report.dataCSV().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines[0], "日付,時刻,本体時計日付,本体時計時刻,速度[km/h],加速度X[G],加速度Y[G],加速度Z[G],緯度,経度,GPS測位フラグ,イベント種類,SDカードID,機器ID")
        XCTAssertEqual(lines[1], "2026/11/11,20:25:01,2026/11/11,20:25:01,10,0.00,0.00,0.00,,,3D測位,,,YQA0000001")
        XCTAssertEqual(lines[4], "2026/11/11,20:25:04,2026/11/11,20:25:04,40,0.01,-0.02,1.00,,,3D測位,衝撃,,YQA0000001")
        XCTAssertEqual(lines[7], "2026/11/11,20:25:07,2026/11/11,20:25:07,0,0.00,0.00,0.00,,,3D測位,,,YQA0000001")
        XCTAssertEqual(lines[8], "", "the file ends with one line feed")
        XCTAssertFalse(report.dataCSV().contains("\r"))
    }
    func testSummaryLabelCanComeFromTheEventList() throws {
        let report = try LegacyReport.make(try recording("event-5-9", eventFrames()), eventLabel: "ワンタッチ")
        XCTAssertEqual(report.eventLabel, "ワンタッチ")
        XCTAssertTrue(report.summaryCSV().hasSuffix(",ワンタッチ\n"))
        XCTAssertEqual(report.rowLabel(3), "衝撃", "the rows keep naming the cause from their own header")
        let lines = report.dataCSV().split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].hasSuffix(",3D測位,,,"), "an empty device id column is still written")
    }
    func testEventWithoutHeaderTriggerFieldsUsesTheFirstPostFrame() throws {
        var frames = eventFrames(); frames[5].flags = 0; frames[5].mask = 0
        let report = try LegacyReport.make(try recording("event-5-9", frames))
        XCTAssertEqual(report.eventFrame, 3)
        XCTAssertEqual(report.eventLabel, "イベント")
        XCTAssertEqual(report.eventCount, 0)
    }
    func testContinuousReportSummaryAndDistance() throws {
        let base = Int32(35 * 600000), lon = Int32(139 * 600000)
        let frames = [Frame(second: 0, speedRaw: 0, latitude: base, longitude: lon),
                      Frame(second: 1, speedRaw: 1000, latitude: base + 600, longitude: lon),
                      Frame(second: 2, speedRaw: 1000, latitude: base + 600, longitude: lon),
                      Frame(second: 3, speedRaw: 2000, latitude: base + 1200, longitude: lon)]
        let report = try LegacyReport.make(try recording("session-1-2-1", frames))
        XCTAssertEqual(report.kind, .continuous)
        XCTAssertEqual(report.frames.count, 4)
        XCTAssertEqual(report.distanceMeters, 221.9, accuracy: 0.6)
        XCTAssertEqual(report.fileStem, "20261111202500_20261111202503_常時録画レポート")
        XCTAssertEqual(report.summaryCSV(), "日付,時刻,運転時間,平均速度[km/h],最高速度[km/h],走行距離[km],イベント回数\n2026/11/11,20:25:00\u{FF5E}20:25:03,03秒,36.0,72,0.222,0\n")
        XCTAssertEqual(report.averageSpeedText, "平均速度 36.0 km/h")
        XCTAssertEqual(report.maximumSpeedText, "最高速度 72 km/h")
        XCTAssertEqual(report.distanceText(), "222 m")
        XCTAssertEqual(report.distanceText(knots: true), "0.120 nm")
        XCTAssertTrue(report.thumbnailPacketIndices().isEmpty, "only event reports carry reference images")
    }
    func testDistanceSkipsRowsThatAreNotThreeDimensionalFixes() throws {
        let base = Int32(35 * 600000), lon = Int32(139 * 600000)
        let frames = [Frame(second: 0, latitude: base, longitude: lon),
                      Frame(second: 1, fix: 0, satellites: 0, latitude: base + 60000, longitude: lon),
                      Frame(second: 2, satellites: 3, latitude: base + 60000, longitude: lon),
                      Frame(second: 3, latitude: base + 600, longitude: lon)]
        let report = try LegacyReport.make(try recording("session-1-2-1", frames))
        XCTAssertEqual(report.distanceMeters, 110.9, accuracy: 0.6, "only the first and the last row are 3D fixes")
    }
    func testNoRowsHavePlaceholders() throws {
        let report = try LegacyReport.make(try recording("session-1-2-1", [Frame(second: 0)]))
        XCTAssertEqual(report.drivingSeconds, 0)
        XCTAssertEqual(report.distanceText(), "0 m")
        let none = LegacyReport(kind: .continuous, frames: [], packetIndices: [], deviceID: "", eventLabel: "", eventFrame: nil)
        XCTAssertEqual(none.averageSpeedText, "平均速度 --.- km/h")
        XCTAssertEqual(none.maximumSpeedText, "最高速度 -- km/h")
    }
    func testDurationFormats() {
        XCTAssertEqual(LegacyReport.durationText(seconds: 5), "05秒")
        XCTAssertEqual(LegacyReport.durationText(seconds: 238), "03分58秒")
        XCTAssertEqual(LegacyReport.durationText(seconds: 3600), "01時間00分00秒")
        XCTAssertEqual(LegacyReport.durationText(seconds: 3661), "01時間01分01秒")
        XCTAssertEqual(LegacyReport.durationText(seconds: 90061), "1日01時間01分01秒")
    }
    func testFilesAreWrittenInWindowsCodePage() throws {
        XCTAssertEqual(try LegacyReport.encodeCP932("3D測位"), Data([0x33, 0x44, 0x91, 0xAA, 0x88, 0xCA]))
        XCTAssertEqual(try LegacyReport.encodeCP932("衝撃"), Data([0x8F, 0xD5, 0x8C, 0x82]))
        XCTAssertEqual(try LegacyReport.encodeCP932("\u{FF5E}"), Data([0x81, 0x60]), "the range separator needs the DOS Japanese mapping")
        XCTAssertEqual(try LegacyReport.encodeCP932("a,b\n"), Data("a,b\n".utf8))
    }
    func testGraphScales() throws {
        var frames = [Frame(second: 0, speedRaw: 1000, acceleration: [900, -900, 1000])]
        var report = try LegacyReport.make(try recording("session-1-2-1", frames))
        XCTAssertEqual(report.speedAxisTop, 40)
        XCTAssertEqual(report.accelerationAxisLimit, 1000)
        frames[0].acceleration = [1001, 0, 0]; frames[0].speedRaw = 2500
        report = try LegacyReport.make(try recording("session-1-2-1", frames))
        XCTAssertEqual(report.speedAxisTop, 90)
        XCTAssertEqual(report.accelerationAxisLimit, 2000)
        frames[0].speedRaw = 0
        report = try LegacyReport.make(try recording("session-1-2-1", frames))
        XCTAssertEqual(report.speedAxisTop, 10, "never below ten")
    }
    func testEventThumbnailsAreStartTwoSecondsBeforeTheTriggerTheTriggerTwoSecondsAfterAndEnd() throws {
        var frames: [Frame] = []
        for i in 0..<10 { frames.append(Frame(phase: 2, second: i)) }
        frames.append(Frame(phase: 3, second: 10, flags: 1, mask: 1))
        for i in 11..<20 { frames.append(Frame(phase: 3, second: i)) }
        let report = try LegacyReport.make(try recording("event-5-9", frames))
        XCTAssertEqual(report.eventFrame, 10)
        XCTAssertEqual(report.thumbnailPacketIndices(), [0, 8, 10, 12, 19])
    }
    func testTriggerFieldsAreReadFromThePacketHeader() throws {
        let p = try packet(Frame(flags: 4, mask: 0x010203))
        XCTAssertEqual(p.telemetry.triggerFlags, 4)
        XCTAssertEqual(p.telemetry.triggerMask, 0x010203)
        XCTAssertFalse(p.telemetry.trigger.isEmpty)
        XCTAssertTrue(try packet(Frame()).telemetry.trigger.isEmpty)
    }
}
