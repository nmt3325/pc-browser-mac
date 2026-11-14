import XCTest
@testable import PCBrowserCore

final class FrameDecodePlanTests: XCTestCase {
    private func plan(target: Int, last: Int, key: Int, decoder: Bool = true, cache: Int = 12) -> FrameDecodePlan {
        FrameDecodePlan.make(target: target, lastDecoded: last, keyframe: key, hasDecoder: decoder, cacheCapacity: cache)
    }

    func testNextFrameContinuesAndConvertsOnlyThatFrame() {
        XCTAssertEqual(plan(target: 11, last: 10, key: 0), FrameDecodePlan(restart: false, decodeFrom: 11, convertFrom: 11))
    }

    func testLateFrameSkipsConversionOfTheFramesInBetween() {
        // The sound is 5 frames ahead of the picture: frames 11...14 are decoded for the references of 15, only 15 is made into a picture.
        let p = plan(target: 15, last: 10, key: 0)
        XCTAssertEqual(p, FrameDecodePlan(restart: false, decodeFrom: 11, convertFrom: 15))
        XCTAssertEqual(Array(p.decodeFrom..<p.convertFrom), [11, 12, 13, 14])
    }

    func testFirstRequestDecodesFromTheKeyframe() {
        XCTAssertEqual(plan(target: 5, last: -1, key: 0, decoder: false), FrameDecodePlan(restart: true, decodeFrom: 0, convertFrom: 0))
    }

    func testLongRunFromAKeyframeConvertsOnlyWhatTheCacheKeeps() {
        // Seek to frame 39 of a 40-frame group: 39 frames are decoded, the last 12 (28...39) become pictures for reverse play.
        let p = plan(target: 39, last: 100, key: 0)
        XCTAssertEqual(p, FrameDecodePlan(restart: true, decodeFrom: 0, convertFrom: 28))
        XCTAssertEqual(p.decodeFrom..<p.convertFrom, 0..<28)
    }

    func testShortRunConvertsEveryFrame() {
        XCTAssertEqual(plan(target: 45, last: 90, key: 40).convertFrom, 40)
        XCTAssertEqual(plan(target: 51, last: 90, key: 40).convertFrom, 40)
        XCTAssertEqual(plan(target: 52, last: 90, key: 40).convertFrom, 41)
    }

    func testBackwardsOrRepeatedTargetRestartsAtTheKeyframe() {
        XCTAssertTrue(plan(target: 30, last: 35, key: 0).restart)
        // Same frame without a stored picture (an earlier frame of the run failed): decoded again, never an empty range.
        let again = plan(target: 35, last: 35, key: 0)
        XCTAssertTrue(again.restart)
        XCTAssertLessThanOrEqual(again.decodeFrom, 35)
    }

    func testKeyframeAheadOfTheDecoderSkipsTheFramesBeforeIt() {
        // The next group starts at 40; the decoder stands at 30 and the target is 44: continuing would decode 31...39 for nothing.
        XCTAssertEqual(plan(target: 44, last: 30, key: 40), FrameDecodePlan(restart: true, decodeFrom: 40, convertFrom: 40))
        // The keyframe directly after the last decoded frame is just the next frame.
        XCTAssertEqual(plan(target: 41, last: 39, key: 40), FrameDecodePlan(restart: false, decodeFrom: 40, convertFrom: 41))
    }

    func testCacheCapacityOfZeroOrOneStillConvertsTheTarget() {
        XCTAssertEqual(plan(target: 39, last: 100, key: 0, cache: 1).convertFrom, 39)
        XCTAssertEqual(plan(target: 39, last: 100, key: 0, cache: 0).convertFrom, 39)
        XCTAssertEqual(plan(target: 39, last: 100, key: 0, cache: Int.max).convertFrom, 0)
    }

    func testExtremeValuesDoNotOverflowOrProduceAnEmptyRange() {
        let p = plan(target: Int.max, last: Int.max, key: Int.max)
        XCTAssertTrue(p.restart)
        XCTAssertLessThanOrEqual(p.decodeFrom, Int.max)
        XCTAssertLessThanOrEqual(p.convertFrom, Int.max)
        let q = plan(target: 3, last: Int.min + 1, key: 7)
        XCTAssertEqual(q.decodeFrom, 3)   // a keyframe after the target cannot be used
        XCTAssertLessThanOrEqual(q.decodeFrom, 3)
    }
}
