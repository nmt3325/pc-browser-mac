import Foundation

/// The transport commands of the original viewer (PC Browser 1.9.60.0: 再生 0x42fdc0, 早送り 0x4306b0, 逆再生 0x430840, 早戻し 0x430bc0).
///
/// The original keeps one state byte per viewer: 0 stopped, 0x01 forward x0.5, 0x02 forward x1, 0x03...0x06 forward x2, x4, x8, x16 and the same
/// speeds backwards in the high nibble (0x10 x0.5, 0x20 x1, 0x30...0x60 x2...x16). Each command only looks at that byte:
/// - 再生 starts x1, and pressing it again while x1 runs switches to x0.5; from any other running state it stops when the recording has sound
///   (the sound cannot follow the other speeds) and starts x1 when it has none;
/// - 早送り / 早戻し cycle x2 → x4 → x8 → x16 → x2 in their own direction and start at x2 from any other state;
/// - 逆再生 starts x1 backwards and switches to x0.5 backwards when pressed again.
/// The labels shown next to the transport ("x2", "x0.5", …) are the strings of the original.
public enum PlaybackTransport {
    public struct State: Equatable, Sendable {
        /// Speed relative to the recording; 0 means stopped.
        public var rate: Double
        public var backwards: Bool
        public init(rate: Double, backwards: Bool) { self.rate = rate; self.backwards = backwards }
        public static let stopped = State(rate: 0, backwards: false)
        public var isStopped: Bool { rate == 0 }
    }
    public enum Command: Sendable { case play, fastForward, reversePlay, rewind }

    public static let slowRate = 0.5
    /// 早送り / 早戻し steps (original labels x2, x4, x8, x16).
    public static let fastRates: [Double] = [2, 4, 8, 16]

    public static func next(after state: State, command: Command, hasAudio: Bool) -> State {
        switch command {
        case .play:
            if state == State(rate: 1, backwards: false) { return State(rate: slowRate, backwards: false) }
            if !state.isStopped && hasAudio { return .stopped }
            return State(rate: 1, backwards: false)
        case .reversePlay:
            if state == State(rate: 1, backwards: true) { return State(rate: slowRate, backwards: true) }
            return State(rate: 1, backwards: true)
        case .fastForward: return cycle(state, backwards: false)
        case .rewind: return cycle(state, backwards: true)
        }
    }

    private static func cycle(_ state: State, backwards: Bool) -> State {
        if state.backwards == backwards, let i = fastRates.firstIndex(of: state.rate), i + 1 < fastRates.count {
            return State(rate: fastRates[i + 1], backwards: backwards)
        }
        return State(rate: fastRates[0], backwards: backwards)
    }

    /// The original's speed label ("x0.5", "x1", "x2", "x4", "x8", "x16"); nil for a speed the original does not have.
    public static func label(rate: Double) -> String? {
        if rate == slowRate { return "x0.5" }
        if rate == 1 { return "x1" }
        if fastRates.contains(rate) { return "x\(Int(rate))" }
        return nil
    }
}
