import XCTest
@testable import PCBrowserCore

/// Expected sequences come from the state machine of the original's four transport handlers (static analysis of 1.9.60.0).
final class PlaybackTransportTests: XCTestCase {
    typealias T = PlaybackTransport
    func press(_ command: T.Command, _ times: Int, from start: T.State = .stopped, audio: Bool) -> [T.State] {
        var s = start, out: [T.State] = []
        for _ in 0..<times { s = T.next(after: s, command: command, hasAudio: audio); out.append(s) }
        return out
    }
    func rates(_ states: [T.State]) -> [Double] { states.map(\.rate) }

    func testFastForwardCyclesTwoFourEightSixteenAndWraps() {
        let seq = press(.fastForward, 6, audio: true)
        XCTAssertEqual(rates(seq), [2, 4, 8, 16, 2, 4])
        XCTAssertTrue(seq.allSatisfy { !$0.backwards })
    }
    func testRewindCyclesTheSameSpeedsBackwards() {
        let seq = press(.rewind, 5, audio: false)
        XCTAssertEqual(rates(seq), [2, 4, 8, 16, 2])
        XCTAssertTrue(seq.allSatisfy { $0.backwards })
    }
    func testFastForwardFromRewindStartsAtTwoTimes() {
        XCTAssertEqual(T.next(after: T.State(rate: 8, backwards: true), command: .fastForward, hasAudio: false), T.State(rate: 2, backwards: false))
        XCTAssertEqual(T.next(after: T.State(rate: 8, backwards: false), command: .rewind, hasAudio: false), T.State(rate: 2, backwards: true))
    }
    func testPlayStartsAtNormalSpeedThenHalfSpeed() {
        XCTAssertEqual(T.next(after: .stopped, command: .play, hasAudio: true), T.State(rate: 1, backwards: false))
        XCTAssertEqual(T.next(after: T.State(rate: 1, backwards: false), command: .play, hasAudio: true), T.State(rate: 0.5, backwards: false))
        XCTAssertEqual(T.next(after: T.State(rate: 1, backwards: false), command: .play, hasAudio: false), T.State(rate: 0.5, backwards: false))
    }
    func testPlayFromAnyOtherRunningStateStopsWithSoundAndRestartsWithout() {
        for s in [T.State(rate: 0.5, backwards: false), T.State(rate: 4, backwards: false), T.State(rate: 1, backwards: true), T.State(rate: 16, backwards: true)] {
            XCTAssertEqual(T.next(after: s, command: .play, hasAudio: true), .stopped, "\(s)")
            XCTAssertEqual(T.next(after: s, command: .play, hasAudio: false), T.State(rate: 1, backwards: false), "\(s)")
        }
    }
    func testReversePlayStartsBackwardsThenHalfSpeedThenKeepsToggling() {
        let seq = press(.reversePlay, 4, audio: true)
        XCTAssertEqual(seq, [T.State(rate: 1, backwards: true), T.State(rate: 0.5, backwards: true), T.State(rate: 1, backwards: true), T.State(rate: 0.5, backwards: true)])
        XCTAssertEqual(T.next(after: T.State(rate: 4, backwards: false), command: .reversePlay, hasAudio: true), T.State(rate: 1, backwards: true))
    }
    func testLabelsAreTheOriginalStrings() {
        XCTAssertEqual([0.5, 1, 2, 4, 8, 16].map { T.label(rate: $0) }, ["x0.5", "x1", "x2", "x4", "x8", "x16"])
        XCTAssertNil(T.label(rate: 1.5))
        XCTAssertNil(T.label(rate: 3))
    }
}
