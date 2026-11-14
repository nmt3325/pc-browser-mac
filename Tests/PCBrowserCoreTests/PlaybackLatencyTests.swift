import XCTest
@testable import PCBrowserCore

final class PlaybackLatencyTests: XCTestCase {
    func testStartsWithoutLead() {
        XCTAssertEqual(PlaybackLatency().lead(rate: 1), 0)
    }

    func testConvergesToTheMeasuredTime() {
        var latency = PlaybackLatency()
        for _ in 0..<40 { latency.record(0.22) }
        XCTAssertEqual(latency.seconds, 0.22, accuracy: 1e-4)
        XCTAssertEqual(latency.lead(rate: 1), 0.22, accuracy: 1e-4)
    }

    func testFirstSampleOnlyMovesTheAverageAPartOfTheWay() {
        var latency = PlaybackLatency()
        latency.record(0.4)
        XCTAssertEqual(latency.seconds, 0.4 * PlaybackLatency.smoothing, accuracy: 1e-12)
    }

    func testOneStallCannotExceedTheCap() {
        var latency = PlaybackLatency()
        for _ in 0..<60 { latency.record(30) }
        XCTAssertEqual(latency.seconds, PlaybackLatency.maximumSeconds, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(latency.seconds, PlaybackLatency.maximumSeconds)
    }

    func testAverageFallsAgainWhenTheMachineSpeedsUp() {
        var latency = PlaybackLatency()
        for _ in 0..<40 { latency.record(0.3) }
        for _ in 0..<40 { latency.record(0.02) }
        XCTAssertEqual(latency.seconds, 0.02, accuracy: 1e-3)
    }

    func testLeadScalesWithPlaybackSpeed() {
        var latency = PlaybackLatency()
        for _ in 0..<60 { latency.record(0.1) }
        XCTAssertEqual(latency.lead(rate: 2), 0.2, accuracy: 1e-4)
        XCTAssertEqual(latency.lead(rate: 0.5), 0.05, accuracy: 1e-4)
        XCTAssertEqual(latency.lead(rate: 16), 1.6, accuracy: 1e-3)
    }

    func testInvalidInputIsIgnored() {
        var latency = PlaybackLatency()
        latency.record(0.2)
        let before = latency
        latency.record(.nan); latency.record(.infinity); latency.record(-1); latency.record(-.infinity)
        XCTAssertEqual(latency, before)
        XCTAssertEqual(latency.lead(rate: .nan), 0)
        XCTAssertEqual(latency.lead(rate: 0), 0)
        XCTAssertEqual(latency.lead(rate: -1), 0)
        XCTAssertEqual(latency.lead(rate: .infinity), 0)
    }

    func testZeroTimeKeepsTheLeadAtZero() {
        var latency = PlaybackLatency()
        for _ in 0..<10 { latency.record(0) }
        XCTAssertEqual(latency.seconds, 0)
    }
}
