import XCTest
@testable import PCBrowserCore

/// Geometry and text of the report dialog and page, with synthetic frames (clock 2026/11/11 20:25:ss).
final class LegacyReportLayoutTests: XCTestCase {
    private let helper = LegacyReportTests()
    private func report(_ frames: [LegacyReportTests.Frame], kind: LegacyReportKind = .continuous, eventFrame: Int? = nil, label: String = "") throws -> LegacyReport {
        let rows = try frames.map { LegacyReportFrame(try helper.packet($0)) }
        return LegacyReport(kind: kind, frames: rows, packetIndices: Array(rows.indices), deviceID: "ZZZ0000000", eventLabel: label, eventFrame: eventFrame)
    }
    /// A frame whose whole-km/h speed is exactly `speed` (the raw value is cut, so it is rounded up here).
    private func frame(second: Int, speed: Int = 0, acceleration: [Int16] = [0, 0, 0], position: (Int32, Int32)? = nil, flags: UInt8 = 0) -> LegacyReportTests.Frame {
        var f = LegacyReportTests.Frame(phase: 1, second: second, speedRaw: UInt32((speed * 1000 + 35) / 36), acceleration: acceleration)
        if let position {
            f.fix = 1; f.satellites = 7; f.latitude = position.0; f.longitude = position.1
        } else {
            f.fix = 0; f.satellites = 0
        }
        f.flags = flags; f.mask = flags == 0 ? 0 : 1
        return f
    }

    func testSpeedAndAccelerationSeriesFitTheirBoxes() throws {
        let r = try report([frame(second: 0, speed: 0, acceleration: [1000, -1000, 0]),
                            frame(second: 30, speed: 55, acceleration: [0, 500, -500]),
                            frame(second: 59, speed: 20, acceleration: [-250, 0, 250])])
        XCTAssertEqual(r.speedAxisTop, 60)
        let speed = r.speedSeries()
        XCTAssertEqual(speed.map(\.x), [0, 30.0 / 59, 1])
        XCTAssertEqual(speed[0].y, 1, accuracy: 1e-9)
        XCTAssertEqual(speed[1].y, 1 - 55.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(r.accelerationAxisLimit, 1000)
        XCTAssertEqual(r.accelerationSeries(axis: 0).map(\.y), [0, 0.5, 0.625])
        XCTAssertEqual(r.accelerationSeries(axis: 1).map(\.y), [1, 0.25, 0.5])
        XCTAssertEqual(r.accelerationSeries(axis: 2).map(\.y), [0.5, 0.75, 0.375])
    }

    func testAxisLabels() throws {
        let r = try report([frame(second: 0, speed: 55, acceleration: [900, 0, 0]), frame(second: 1, speed: 3)])
        XCTAssertEqual(r.speedAxisLabels, ["60", "30", "0"])
        XCTAssertEqual(r.accelerationAxisLabels, ["1.0", "0.5", "0.0", "-0.5", "-1.0"])
        let wide = try report([frame(second: 0, speed: 8, acceleration: [1500, 0, 0]), frame(second: 1)])
        XCTAssertEqual(wide.speedAxisLabels, ["10", "5", "0"])
        XCTAssertEqual(wide.accelerationAxisLabels, ["2.0", "1.0", "0.0", "-1.0", "-2.0"])
    }

    func testTimeLabelsAreStartMiddleAndEnd() throws {
        let r = try report([frame(second: 4), frame(second: 34), frame(second: 59)])
        XCTAssertEqual(r.timeAxisLabels, ["20:25:04", "20:25:32", "20:25:59"])
        XCTAssertEqual(try report([]).timeAxisLabels, ["00:00:00", "00:00:00", "00:00:00"])
    }

    func testEventMarkerSitsAtTheTriggerRow() throws {
        let r = try report([frame(second: 0), frame(second: 20, flags: 4), frame(second: 40)], kind: .event, eventFrame: 1, label: "衝撃")
        XCTAssertEqual(r.eventMarkerPosition ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.eventMarkerLabel, "20:25:20")
        XCTAssertNil(try report([frame(second: 0), frame(second: 30)]).eventMarkerPosition)
    }

    func testRowsOfEventAndContinuousReports() throws {
        let event = try report([frame(second: 0, speed: 10), frame(second: 30, speed: 20, flags: 4), frame(second: 59)], kind: .event, eventFrame: 1, label: "衝撃")
        XCTAssertEqual(event.rows.map(\.label), ["発生日時", "速度", "イベント種類"])
        XCTAssertEqual(event.rows[0].lines, ["2026/11/11 20:25:30"])
        XCTAssertEqual(event.rows[1].lines, ["平均速度 10.0 km/h", "最高速度 20 km/h"])
        XCTAssertEqual(event.rows[2].lines, ["衝撃"])
        let continuous = try report([frame(second: 0, speed: 8), frame(second: 58, speed: 12)])
        XCTAssertEqual(continuous.rows.map(\.label), ["日時", "運転時間", "速度", "走行距離", "イベント回数"])
        XCTAssertEqual(continuous.rows[0].lines, ["2026/11/11 20:25:00～2026/11/11 20:25:58"])
        XCTAssertEqual(continuous.rows[1].lines, ["58秒"])
        XCTAssertEqual(continuous.rows[2].lines, ["平均速度 10.0 km/h", "最高速度 12 km/h"])
        XCTAssertEqual(continuous.rows[3].lines, ["0 m"])
        XCTAssertEqual(continuous.rows[4].lines, ["0"])
    }

    func testThumbnailCaptionsFollowTheOriginalOrder() {
        XCTAssertEqual(LegacyReport.eventThumbnailCaptions, ["開始", "イベント2秒前", "イベント発生時", "イベント2秒後", "終了"])
    }

    func testDecimationKeepsExtremesAndOrder() {
        var points: [ReportPoint] = []
        for i in 0..<1000 { points.append(ReportPoint(x: Double(i) / 999, y: i == 500 ? 0.9 : (i == 501 ? 0.05 : 0.5))) }
        let out = ReportGraph.decimate(points, columns: 20)
        XCTAssertLessThan(out.count, 20 * 4 + 1)
        XCTAssertTrue(out.contains(ReportPoint(x: 500.0 / 999, y: 0.9)))
        XCTAssertTrue(out.contains(ReportPoint(x: 501.0 / 999, y: 0.05)))
        XCTAssertEqual(out.map(\.x), out.map(\.x).sorted())
        XCTAssertEqual(ReportGraph.decimate(Array(points.prefix(10)), columns: 20).count, 10)
    }

    func testRouteFitsTheBoxAndKeepsNorthUp() throws {
        // 1/600000 degree units: a track heading north-east.
        let lat: Int32 = 21_000_000, lon: Int32 = 83_400_000
        let r = try report([frame(second: 0, position: (lat, lon)), frame(second: 1, position: (lat + 60_000, lon + 60_000)),
                            frame(second: 2, position: (lat + 120_000, lon + 90_000)), frame(second: 3)])
        let route = r.route(aspect: 1.5)
        XCTAssertEqual(route.points.count, 3)
        XCTAssertGreaterThan(route.points[0].y, route.points[2].y, "north is up")
        XCTAssertLessThan(route.points[0].x, route.points[2].x, "east is right")
        for p in route.points { XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y)) }
        XCTAssertNil(route.event)
        XCTAssertEqual(try report([frame(second: 0)]).route(aspect: 1).points.count, 0)
    }

    func testEventRouteMarksTheTriggerRow() throws {
        let lat: Int32 = 21_000_000, lon: Int32 = 83_400_000
        let r = try report([frame(second: 0, position: (lat, lon)), frame(second: 20, position: (lat + 30_000, lon + 30_000), flags: 4),
                            frame(second: 40, position: (lat + 60_000, lon + 60_000))], kind: .event, eventFrame: 1, label: "衝撃")
        let route = r.route(aspect: 1)
        XCTAssertEqual(route.points.count, 3)
        XCTAssertEqual(route.event, route.points[1])
    }
}
