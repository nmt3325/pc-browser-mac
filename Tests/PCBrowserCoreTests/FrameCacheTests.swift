import XCTest
@testable import PCBrowserCore

final class FrameCacheTests: XCTestCase {
    func testLookupMissAndStoredValue() {
        var cache = FrameCache<String>(maximumBytes: 20, maximumCount: 3)
        XCTAssertNil(cache.value(at: 1))
        cache.insert("frame", at: 1, bytes: 7)
        XCTAssertEqual(cache.value(at: 1), "frame")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalBytes, 7)
    }

    func testRecentlyUsedFrameSurvivesCountEviction() {
        var cache = FrameCache<Int>(maximumBytes: 100, maximumCount: 3)
        for i in 0..<3 { cache.insert(i, at: i, bytes: 10) }
        XCTAssertEqual(cache.value(at: 0), 0)
        cache.insert(3, at: 3, bytes: 10)
        XCTAssertNil(cache.value(at: 1))
        XCTAssertEqual(cache.value(at: 0), 0)
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.totalBytes, 30)
    }

    func testByteBudgetCanEvictMultipleFrames() {
        var cache = FrameCache<Int>(maximumBytes: 10, maximumCount: 12)
        cache.insert(1, at: 1, bytes: 4)
        cache.insert(2, at: 2, bytes: 4)
        cache.insert(3, at: 3, bytes: 7)
        XCTAssertNil(cache.value(at: 1))
        XCTAssertNil(cache.value(at: 2))
        XCTAssertEqual(cache.value(at: 3), 3)
        XCTAssertEqual(cache.totalBytes, 7)
    }

    func testReplacementAdjustsCostWithoutDuplicateKeys() {
        var cache = FrameCache<String>(maximumBytes: 10, maximumCount: 3)
        cache.insert("old", at: 0, bytes: 4)
        cache.insert("other", at: 1, bytes: 4)
        cache.insert("new", at: 0, bytes: 2)
        XCTAssertEqual(cache.value(at: 0), "new")
        XCTAssertEqual(cache.value(at: 1), "other")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalBytes, 6)
    }

    func testInvalidOrOversizedEntryDoesNotEvictOtherFrames() {
        var cache = FrameCache<Int>(maximumBytes: 10, maximumCount: 3)
        cache.insert(1, at: 1, bytes: 4)
        cache.insert(2, at: 2, bytes: 11)
        cache.insert(3, at: 3, bytes: 0)
        cache.insert(4, at: 4, bytes: -1)
        XCTAssertEqual(cache.value(at: 1), 1)
        XCTAssertNil(cache.value(at: 2))
        XCTAssertEqual(cache.count, 1)
        cache.insert(9, at: 1, bytes: 11)
        XCTAssertNil(cache.value(at: 1))
        XCTAssertEqual(cache.totalBytes, 0)
    }

    func testDisabledBudgetsNeverRetainFrames() {
        var bytes = FrameCache<Int>(maximumBytes: 0, maximumCount: 12)
        var count = FrameCache<Int>(maximumBytes: 100, maximumCount: 0)
        bytes.insert(1, at: 1, bytes: 1)
        count.insert(1, at: 1, bytes: 1)
        XCTAssertEqual(bytes.count, 0)
        XCTAssertEqual(count.count, 0)
    }

    func testLongRecordingNeverGrowsBeyondEitherBudget() {
        var cache = FrameCache<Int>(maximumBytes: 96, maximumCount: 12)
        for i in 0..<10_000 {
            cache.insert(i, at: i, bytes: 11)
            XCTAssertLessThanOrEqual(cache.totalBytes, 96)
            XCTAssertLessThanOrEqual(cache.count, 12)
        }
        XCTAssertNil(cache.value(at: 0))
        XCTAssertEqual(cache.value(at: 9_999), 9_999)
    }

    func testRecentFramesCanBeReadInReverseWithoutNewDecodes() {
        var cache = FrameCache<Int>(maximumBytes: 96, maximumCount: 12)
        for i in 60...68 { cache.insert(i, at: i, bytes: 10) }
        for i in stride(from: 68, through: 60, by: -1) {
            XCTAssertEqual(cache.value(at: i), i)
        }
        XCTAssertEqual(cache.count, 9)
        XCTAssertEqual(cache.totalBytes, 90)
    }

    func testCostAccountingCannotOverflowAtIntMax() {
        var cache = FrameCache<Int>(maximumBytes: Int.max, maximumCount: 3)
        cache.insert(1, at: 1, bytes: Int.max - 1)
        cache.insert(2, at: 2, bytes: 2)
        XCTAssertNil(cache.value(at: 1))
        XCTAssertEqual(cache.totalBytes, 2)
    }
}