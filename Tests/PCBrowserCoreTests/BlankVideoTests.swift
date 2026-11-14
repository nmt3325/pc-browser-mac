import XCTest
@testable import PCBrowserCore

/// A frame whose video area is empty or zero-filled has no picture; the continuous recordings of the sample card are like that
/// (their frame headers still carry the clock, GPS and sensors). It must be told apart from damaged picture data.
final class BlankVideoTests: XCTestCase {
    private let delimiter: [UInt8] = [0, 0, 0, 1, 0x09, 0x10]
    private let parameterSets: [UInt8] = [0, 0, 0, 1, 0x67, 0x4D, 0, 0x33, 0, 0, 0, 1, 0x68, 0xEE, 0x3C]
    private let idrSlice: [UInt8] = [0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21]
    private let plainSlice: [UInt8] = [0, 0, 1, 0x41, 0x9A, 0x24]

    private func pictureless(_ bytes: [UInt8]) -> Bool {
        let data = Data(bytes)
        return AnnexB.isPictureless(data, units: AnnexB.units(data))
    }

    func testEmptyAndZeroFilledPayloadsAreBlank() {
        XCTAssertTrue(AnnexB.isBlankPayload(Data()))
        XCTAssertTrue(AnnexB.isBlankPayload(Data(count: 1)))
        XCTAssertTrue(AnnexB.isBlankPayload(Data(count: 512 * 250)))
        XCTAssertTrue(AnnexB.units(Data(count: 4096)).isEmpty)
        XCTAssertTrue(pictureless([]))
        XCTAssertTrue(pictureless([UInt8](repeating: 0, count: 4096)))
    }

    func testDelimiterAndParameterSetsAloneAreNotAPicture() {
        // Some frames of a zero-filled continuous recording keep an access-unit delimiter followed by zero bytes.
        XCTAssertTrue(pictureless(delimiter + [UInt8](repeating: 0, count: 2048)))
        XCTAssertTrue(pictureless(delimiter + parameterSets))
        XCTAssertFalse(AnnexB.hasPicture(AnnexB.units(Data(delimiter + parameterSets))))
        XCTAssertEqual(AnnexB.units(Data(delimiter + parameterSets)).count, 3)
    }

    func testCodedSlicesAreAPicture() {
        XCTAssertFalse(pictureless(delimiter + parameterSets + idrSlice))
        XCTAssertFalse(pictureless(plainSlice))
        XCTAssertFalse(pictureless(delimiter + plainSlice + [UInt8](repeating: 0, count: 600)))
        XCTAssertTrue(AnnexB.hasPicture(AnnexB.units(Data(parameterSets + idrSlice))))
    }

    func testOneNonZeroByteMakesAPayloadNonBlank() {
        var data = Data(count: 4096)
        data[100] = 0x55
        XCTAssertFalse(AnnexB.isBlankPayload(data))
        // Non-zero bytes without any start code are damaged data, not a blank area: the decoder must keep reporting them as such.
        XCTAssertTrue(AnnexB.units(data).isEmpty)
        XCTAssertFalse(AnnexB.isPictureless(data, units: AnnexB.units(data)))
    }
}
