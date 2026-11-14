import Foundation

/// One line of the original player's 映像抽出 result: a scene of a recording and its 動きポイント.
public struct AccelerationEntry: Sendable, Equatable, Identifiable {
    public var id: String { recordingID + "#" + String(firstFrame) }
    public let recordingID: String
    /// Index into `Recording.packets` of the frame the scene starts with; choosing the line seeks there.
    public let firstFrame: Int
    public let frameCount: Int
    /// Primary clock of the first frame (the original's 時刻 column shows its minute).
    public let clock: CardTimestamp?
    public let points: Int
    /// `yyyy/MM/dd HH:mm`, the form of the original's 時刻 column.
    public var timeText: String { clock.map { CivilTime.minuteText($0) } ?? "時刻不明" }
    public init(recordingID: String, firstFrame: Int, frameCount: Int, clock: CardTimestamp?, points: Int) {
        self.recordingID = recordingID; self.firstFrame = firstFrame; self.frameCount = frameCount; self.clock = clock; self.points = points
    }
}

/// 映像抽出 of the original: the recordings that are checked in the list are cut into scenes, every scene is scored by how
/// often the acceleration leaves a band around the recording's own mean (動きポイント), and the highest-scoring scenes are
/// listed (個数 of them).
///
/// The rules were measured on the running original 1.9.60.0 (FDR-820, continuous recordings of one card) and are written
/// down in docs/video-extraction-research.md together with what is NOT established: the phantom-frame rule rests on one
/// recording, the order of equal scores across recordings, a fourth (gyro) channel, other models and event recordings.
/// Only the three acceleration channels at packet offsets 0x46/0x48/0x4A are used; the gyro, event and trigger bytes were
/// zero in every measured recording, so their role could not be observed.
public enum AccelerationExtraction {
    /// A sample is a movement point of its channel when it is farther than this (raw units) from the channel's mean.
    public static let threshold = 100.0
    /// A scene ends at the first intra frame after the secondary clock reaches a multiple of this many seconds
    /// (an even minute, second 0) that lies beyond every earlier such moment.
    public static let boundaryPeriod: Int64 = 120
    /// A scene is listed only when the secondary clock of the intra frame that closes it is at least this many whole seconds
    /// after the primary clock of its first frame.
    public static let minimumSpan: Int64 = 120
    /// The slider of 「加速度抽出パラメータ調整」 (個数): default and range.
    public static let defaultCount = 30
    public static let countRange = 0...100
    /// Packet offsets 0x46, 0x48 and 0x4A (`PacketTelemetry.accelerationRaw`).
    public static let channelCount = 3

    public static func clampedCount(_ value: Int) -> Int { min(countRange.upperBound, max(countRange.lowerBound, value)) }

    /// The scenes of one recording that the original lists, in time order.
    ///
    /// * Baseline: the mean of every channel over all frames of the recording (orphan frames included).
    /// * Points of a frame: the number of channels farther than `threshold` from their mean; a scene adds its frames up.
    /// * Cutting: the first scene starts at frame 0. After the secondary clock hits a multiple of `boundaryPeriod` (later
    ///   than the previous hit) the next intra frame closes the scene and starts the next one.
    /// * The scene that is never closed (the end of the recording) is not listed. A closed scene is dropped when it is
    ///   shorter than `minimumSpan` (secondary clock of the closing frame minus primary clock of its first frame).
    /// * Frames missing at the start of the first block (the first packet carries `sequence` n > 0 because the block's
    ///   head was overwritten) count as n zero-valued samples of the first scene — not in the mean. (One recording only.)
    public static func entries(in recording: Recording) -> [AccelerationEntry] {
        let packets = recording.packets, n = packets.count
        guard n > 1 else { return [] }
        var sums = [Int](repeating: 0, count: channelCount)
        for packet in packets {
            let values = packet.telemetry.accelerationRaw
            for c in 0..<channelCount where c < values.count { sums[c] += Int(values[c]) }
        }
        let mean = sums.map { Double($0) / Double(n) }
        var exceeding = [Int](repeating: 0, count: n)
        for (i, packet) in packets.enumerated() {
            let values = packet.telemetry.accelerationRaw
            var count = 0
            for c in 0..<channelCount where c < values.count && abs(Double(values[c]) - mean[c]) > threshold { count += 1 }
            exceeding[i] = count
        }
        let secondary = packets.map { $0.telemetry.secondaryClock?.epochSeconds }
        var starts = [0], waiting = false, reference: Int64? = nil
        for i in 0..<n {
            if !waiting {
                guard i > 0, let t = secondary[i], t % boundaryPeriod == 0, reference.map({ t > $0 }) ?? true else { continue }
                waiting = true; reference = t
                if packets[i].isIntra { starts.append(i); waiting = false }
            } else if packets[i].isIntra {
                starts.append(i); waiting = false
            }
        }
        let edges = starts + [n]
        let offCentre = (0..<channelCount).filter { abs(mean[$0]) > threshold }.count
        let missingLeading = Int(packets[0].sequence)
        var result: [AccelerationEntry] = []
        for k in 0..<(edges.count - 2) {
            let first = edges[k], closing = edges[k + 1]
            if let opened = packets[first].telemetry.clock?.epochSeconds, let closed = secondary[closing], closed - opened < minimumSpan { continue }
            var points = 0
            for i in first..<closing { points += exceeding[i] }
            if k == 0 { points += missingLeading * offCentre }
            result.append(AccelerationEntry(recordingID: recording.id, firstFrame: first, frameCount: closing - first,
                                            clock: packets[first].telemetry.clock, points: points))
        }
        return result
    }

    /// The lines of the result list: highest 動きポイント first, at most `count` of them. Equal scores keep the order the
    /// scenes were given in (the original inserts a scene before the first one with fewer points); scenes without any
    /// movement are listed like the others.
    public static func ranked(_ entries: [AccelerationEntry], count: Int) -> [AccelerationEntry] {
        let limit = clampedCount(count)
        let order = entries.enumerated().sorted { left, right in
            left.element.points != right.element.points ? left.element.points > right.element.points : left.offset < right.offset
        }
        return order.prefix(limit).map { $0.element }
    }
}
