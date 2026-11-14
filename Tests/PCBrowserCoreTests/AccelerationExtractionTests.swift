import XCTest
@testable import PCBrowserCore

/// 映像抽出 rules with synthetic frames. The expected numbers follow the model measured on the running original
/// (docs/video-extraction-research.md); no card values are used here.
final class AccelerationExtractionTests: XCTestCase {
    /// 2026-11-08 10:00:00, an even minute: multiples of 120 seconds fall on whole even minutes.
    private let base = 10 * 3600

    private func clock(_ offset: Int) -> [UInt8] {
        let t: Int = base + offset
        let hour: UInt8 = UInt8(t / 3600)
        let minute: UInt8 = UInt8((t / 60) % 60)
        let second: UInt8 = UInt8(t % 60)
        var bytes: [UInt8] = [26, 11, 8]
        bytes.append(hour); bytes.append(minute); bytes.append(second)
        return bytes
    }
    private func frame(primary: Int, secondary: Int, intra: Bool = false, sequence: UInt32 = 0, acceleration: [Int16] = [0, 0, 0]) throws -> FramePacket {
        var h = FormatTests().packet()
        FormatTests().put(sequence, 4, &h); FormatTests().put(sequence, 0x1FC, &h)
        h[9] = intra ? 2 : 1
        var primaryBytes: [UInt8] = clock(primary)
        primaryBytes.append(0)
        h.replaceSubrange(10..<17, with: primaryBytes)
        h.replaceSubrange(0x12..<0x18, with: clock(secondary))
        h[0x1d] = 30
        for (c, value) in acceleration.enumerated() {
            let u: UInt16 = UInt16(bitPattern: value)
            let low: UInt8 = UInt8(u & 0xFF)
            let high: UInt8 = UInt8(u >> 8)
            let at: Int = 0x46 + 2 * c
            h[at] = low
            h[at + 1] = high
        }
        return try FramePacket.parse(h, sector: 10, diskBytes: 100 * 512)
    }
    /// One frame every ten seconds (frame 0 is always an intra frame); the secondary clock runs `secondaryAhead` seconds
    /// ahead of the primary one.
    private func steady(_ count: Int, intra: Set<Int>, startAt: Int = 0, secondaryAhead: Int = 0, firstSequence: UInt32 = 0,
                        acceleration: (Int) -> [Int16] = { _ in [0, 0, 0] }) throws -> [FramePacket] {
        var frames: [FramePacket] = []
        for i in 0..<count {
            let secondary: Int = startAt + 10 * i
            let primary: Int = secondary - secondaryAhead
            let isIntra: Bool = i == 0 || intra.contains(i)
            let sequence: UInt32 = firstSequence + UInt32(i)
            let values: [Int16] = acceleration(i)
            frames.append(try frame(primary: primary, secondary: secondary, intra: isIntra, sequence: sequence, acceleration: values))
        }
        return frames
    }
    private func recording(_ frames: [FramePacket]) -> Recording { Recording(id: "r", recordSector: 10, channel: 1, packets: frames) }

    func testEpochSecondsAreExactWholeSeconds() throws {
        let a = try XCTUnwrap(CardTimestamp.parse(Data([26, 11, 8, 10, 2, 0, 5]), offset: 0))
        let b = try XCTUnwrap(CardTimestamp.parse(Data([26, 11, 8, 10, 2, 1, 29]), offset: 0))
        let nextDay = try XCTUnwrap(CardTimestamp.parse(Data([26, 11, 9, 10, 2, 0, 0]), offset: 0))
        XCTAssertEqual(a.epochSeconds % 120, 0, "10:02:00 is a multiple of two minutes whatever the frame slot is")
        XCTAssertEqual(b.epochSeconds - a.epochSeconds, 1)
        XCTAssertEqual(nextDay.epochSeconds - a.epochSeconds, 86400)
    }

    func testScenesAreClosedByTheFirstIntraFrameAfterAnEvenMinuteBoundary() throws {
        // Boundaries at frames 12, 24, 36, 48, 60 and 72; the intra frames after them are 14, 26, 37, 50 and 62.
        let entries = AccelerationExtraction.entries(in: recording(try steady(80, intra: [14, 26, 37, 50, 62])))
        // [26, 37) lasts 110 s and is dropped, exactly 120 s is kept, and the scene from 62 is never closed.
        XCTAssertEqual(entries.map(\.firstFrame), [0, 14, 37, 50])
        XCTAssertEqual(entries.map(\.frameCount), [14, 12, 13, 12])
        XCTAssertEqual(entries[1].timeText, "2026/11/08 10:02")
        XCTAssertEqual(entries.map(\.points), [0, 0, 0, 0])
        XCTAssertEqual(entries.map(\.recordingID), ["r", "r", "r", "r"])
    }

    func testAnIntraFrameOnTheBoundaryItselfClosesTheSceneThere() throws {
        let entries = AccelerationExtraction.entries(in: recording(try steady(60, intra: [12, 25, 37])))
        XCTAssertEqual(entries.map(\.firstFrame), [0, 12, 25])
    }

    func testABoundaryThatIsNotLaterThanTheEarlierOneIsIgnored() throws {
        var frames: [FramePacket] = []
        for i in 0..<60 {
            // The clock jumps back to 0 s at frame 14, so the multiples of 120 s at frames 14 and 26 (0 s and 120 s) are not later than the one at frame 12 (120 s).
            let second = i < 14 ? 10 * i : 10 * (i - 14)
            frames.append(try frame(primary: second, secondary: second, intra: [0, 13, 27, 40].contains(i)))
        }
        // Frame 27 is an intra frame but no boundary is waiting; the multiple of 120 s at frame 38 is later, frame 40 closes it.
        XCTAssertEqual(AccelerationExtraction.entries(in: recording(frames)).map(\.firstFrame), [0, 13])
    }

    func testOnlyChannelsFartherThanTheThresholdFromTheRecordingMeanScore() throws {
        // Scene 0 is frames 0…13 and scene 1 frames 14…25; over the whole recording the mean of every channel is exactly 0.
        var values = [[Int16]](repeating: [0, 0, 0], count: 40)
        values[1] = [100, 0, 0]; values[2] = [-100, 0, 0]        // exactly the threshold: not a movement point
        values[3] = [101, 0, 0]; values[4] = [-101, 0, 0]        // one channel each
        values[5] = [0, 500, -500]; values[6] = [0, -500, 500]   // two channels each
        values[20] = [300, 300, 300]; values[21] = [-300, -300, -300]   // three channels each
        let entries = AccelerationExtraction.entries(in: recording(try steady(40, intra: [14, 26]) { values[$0] }))
        XCTAssertEqual(entries.map(\.firstFrame), [0, 14])
        XCTAssertEqual(entries.map(\.points), [6, 6])
    }

    func testASteadyOffsetIsNotMovement() throws {
        let entries = AccelerationExtraction.entries(in: recording(try steady(40, intra: [14, 26]) { _ in [800, -900, 1000] }))
        XCTAssertEqual(entries.map(\.points), [0, 0], "the baseline is the recording's own mean")
    }

    func testFramesMissingAtTheStartOfTheFirstBlockScoreAsZeroSamplesOfTheFirstScene() throws {
        // Two channels sit farther than 100 from zero, so each of the 61 missing frames adds two points to the first scene only.
        let late = try steady(40, intra: [14, 26], firstSequence: 61) { _ in [300, -400, 0] }
        XCTAssertEqual(AccelerationExtraction.entries(in: recording(late)).map(\.points), [122, 0])
        let complete = try steady(40, intra: [14, 26]) { _ in [300, -400, 0] }
        XCTAssertEqual(AccelerationExtraction.entries(in: recording(complete)).map(\.points), [0, 0])
    }

    func testASceneShorterThanTwoMinutesIsDroppedUnlessTheClockLagMakesItLongEnough() throws {
        // The recording starts 50 s into a two-minute period: boundaries at frames 7, 19, 31…; intra frames 9, 21, 33.
        let short = try steady(60, intra: [9, 21, 33], startAt: 50)
        XCTAssertEqual(AccelerationExtraction.entries(in: recording(short)).map(\.firstFrame), [9, 21], "[0, 9) lasts 90 s")
        // With the primary clock 108 s behind the secondary one the first scene lasts 198 s.
        let lagging = try steady(60, intra: [9, 21, 33], startAt: 50, secondaryAhead: 108)
        XCTAssertEqual(AccelerationExtraction.entries(in: recording(lagging)).map(\.firstFrame), [0, 9, 21])
    }

    func testNothingIsListedWithoutAClosedScene() throws {
        XCTAssertTrue(AccelerationExtraction.entries(in: recording(try steady(30, intra: []))).isEmpty, "boundaries at 12 and 24, but no intra frame follows")
        XCTAssertTrue(AccelerationExtraction.entries(in: recording(try steady(1, intra: []))).isEmpty)
        XCTAssertTrue(AccelerationExtraction.entries(in: recording([])).isEmpty)
    }

    func testRankingSortsByPointsKeepsTheOrderOfTiesAndTruncates() {
        func entry(_ id: Int, _ points: Int) -> AccelerationEntry { AccelerationEntry(recordingID: "r", firstFrame: id, frameCount: 1, clock: nil, points: points) }
        let all = [entry(0, 5), entry(1, 9), entry(2, 5), entry(3, 0), entry(4, 9), entry(5, 12)]
        XCTAssertEqual(AccelerationExtraction.ranked(all, count: AccelerationExtraction.defaultCount).map(\.firstFrame), [5, 1, 4, 0, 2, 3], "scenes without movement are listed too")
        XCTAssertEqual(AccelerationExtraction.ranked(all, count: 3).map(\.firstFrame), [5, 1, 4])
        XCTAssertTrue(AccelerationExtraction.ranked(all, count: 0).isEmpty)
        XCTAssertTrue(AccelerationExtraction.ranked(all, count: -4).isEmpty)
        XCTAssertEqual(AccelerationExtraction.ranked(all, count: 1000).count, 6)
        XCTAssertEqual(AccelerationExtraction.defaultCount, 30)
        XCTAssertEqual(AccelerationExtraction.clampedCount(101), 100)
        XCTAssertEqual(AccelerationExtraction.clampedCount(-1), 0)
        XCTAssertEqual(entry(1, 1).timeText, "時刻不明")
    }
}
