import XCTest
@testable import PCBrowserCore

/// Constants come from the original's volume handlers (static analysis of 1.9.60.0).
final class PlaybackVolumeTests: XCTestCase {
    typealias V = PlaybackVolume
    func testCommandsMoveByTenInsideEightToFiftyEight() {
        XCTAssertEqual(V.defaultLevel, 33)
        var level = V.defaultLevel, down: [Int] = []
        for _ in 0..<4 { level = V.down(level); down.append(level) }
        XCTAssertEqual(down, [23, 13, 8, 8])
        level = V.defaultLevel
        var up: [Int] = []
        for _ in 0..<4 { level = V.up(level); up.append(level) }
        XCTAssertEqual(up, [43, 53, 58, 58])
    }
    func testPercentIsTwiceTheSliderPosition() {
        XCTAssertEqual([8, 13, 23, 33, 43, 53, 58].map { V.percent(level: $0) }, [0, 10, 30, 50, 70, 90, 100])
        XCTAssertEqual(V.percent(level: 3), 0, "levels are clamped like the original")
        XCTAssertEqual(V.percent(level: 99), 100)
    }
    func testAttenuationIsTenTimesLog10OfThePercentageInHundredthsOfADecibel() {
        XCTAssertEqual(V.attenuationHundredthsOfDecibel(level: 58), 0)
        XCTAssertEqual(V.attenuationHundredthsOfDecibel(level: 33), -301)
        XCTAssertEqual(Double(V.attenuationHundredthsOfDecibel(level: 13)), -1000, accuracy: 1, "truncation of log10(0.1) may land on -999")
        XCTAssertEqual(V.attenuationHundredthsOfDecibel(level: 8), -10_000)
    }
    func testAmplitudeFollowsTheSameAttenuation() {
        XCTAssertEqual(V.amplitude(level: 58), 1, accuracy: 1e-12)
        XCTAssertEqual(V.amplitude(level: 33), 0.7071, accuracy: 0.001)
        XCTAssertEqual(V.amplitude(level: 13), 0.3162, accuracy: 0.001)
        XCTAssertEqual(V.amplitude(level: 8), 0)
        XCTAssertGreaterThan(V.amplitude(level: 43), V.amplitude(level: 33))
    }
    func testFractionAndLevelRoundTrip() {
        for level in V.minimumLevel...V.maximumLevel { XCTAssertEqual(V.level(fraction: V.fraction(level: level)), level) }
        XCTAssertEqual(V.fraction(level: V.defaultLevel), 0.5, accuracy: 1e-12)
        XCTAssertEqual(V.level(fraction: -3), 8); XCTAssertEqual(V.level(fraction: 7), 58); XCTAssertEqual(V.level(fraction: .nan), 8)
    }
}
