import XCTest
@testable import PCBrowserCore

/// Expected texts are the readings of the original program for controlled synthetic raw values.
final class SensorReadoutTests: XCTestCase {
    func testAccelerationReadoutMatchesTheOriginalForControlledValues() {
        let cases: [(Int, String)] = [(250, "0.25"), (500, "0.50"), (-250, "-0.25"), (15, "0.01"), (45, "0.04"),
                                      (-5, "-0.00"), (1999, "1.99"), (-19, "-0.01"), (999, "0.99"), (0, "0.00"), (10, "0.01"), (9, "0.00")]
        for (raw, text) in cases { XCTAssertEqual(SensorReadout.accelerationText(raw: raw), text, "raw \(raw)") }
    }
    func testReadoutIsTruncatedNotRounded() {
        XCTAssertEqual(SensorReadout.accelerationText(raw: 19), "0.01")
        XCTAssertEqual(SensorReadout.accelerationText(raw: 99), "0.09")
        XCTAssertEqual(SensorReadout.accelerationText(raw: -99), "-0.09")
        XCTAssertEqual(SensorReadout.accelerationHundredths(raw: 1999), 199)
        XCTAssertEqual(SensorReadout.accelerationHundredths(raw: -1999), -199)
    }
    func testReadoutRangeEdges() {
        XCTAssertEqual(SensorReadout.accelerationText(raw: Int(Int16.max)), "32.76")
        XCTAssertEqual(SensorReadout.accelerationText(raw: Int(Int16.min)), "-32.76")
    }
    func testGraphValueIsRawOverOneThousand() {
        XCTAssertEqual(SensorReadout.accelerationCountsPerG, 1000)
        XCTAssertEqual(SensorReadout.accelerationG(raw: 1000), 1.0, accuracy: 1e-12)
        XCTAssertEqual(SensorReadout.accelerationG(raw: -250), -0.25, accuracy: 1e-12)
    }
    func testTextsFollowTheHeaderAxisOrder() {
        XCTAssertEqual(SensorReadout.axisNames, ["X", "Y", "Z"])
        XCTAssertEqual(SensorReadout.accelerationTexts([1999, -19, 999]), ["1.99", "-0.01", "0.99"])
        XCTAssertEqual(SensorReadout.accelerationTexts([]), [])
    }
    func testUserCalibrationStaysOptionalAndSeparate() {
        XCTAssertFalse(SensorCalibration().isCalibrated)
        XCTAssertNil(SensorCalibration().acceleration(raw: 1000))
    }
}
