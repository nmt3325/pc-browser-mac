import Foundation

public struct RawValueCount: Codable, Sendable { public let value: UInt8, frames: Int }
public struct RawAxisRange: Codable, Sendable { public let minimum: Int16, maximum: Int16 }
public struct RecordingReport: Codable, Sendable {
    public let recordingID: String, startWallTime: String, endWallTime: String
    public let channel: UInt8
    public let frames: Int, storageBlocks: Int, gpsFrames: Int, audioBytes: Int
    public let durationSeconds: Double, speedCoverageSeconds: Double
    public let meanSpeedKMH: Double?, maximumSpeedKMH: Double?, distanceEstimateKM: Double?
    public let accelerationRaw: [RawAxisRange], gyroRaw: [RawAxisRange], eventRawDistribution: [RawValueCount]
    public let notes: String
    public static func make(_ recording: Recording, notes: String = "", maximumGPSGap: Double = 2) throws -> RecordingReport {
        guard recording.isLoaded, !recording.packets.isEmpty, maximumGPSGap.isFinite, maximumGPSGap > 0 else { throw BrowserError.invalid("レポートには照合済みの録画が必要です") }
        let timeline = RecordingTimeline(packets: recording.packets), packets = recording.packets
        var coverage = 0.0, integral = 0.0, speeds: [Double] = [], counts: [UInt8: Int] = [:], gpsFrames = 0
        func speed(_ packet: FramePacket) -> Double? {
            guard packet.telemetry.coordinate() != nil else { return nil }; return packet.telemetry.speedKMH
        }
        for i in packets.indices {
            let p = packets[i]; counts[p.telemetry.eventRaw, default: 0] += 1
            if p.telemetry.coordinate() != nil { gpsFrames += 1 }
            guard let a = speed(p) else { continue }; speeds.append(a)
            let span: Double, average: Double
            if i + 1 < packets.count {
                span = timeline.starts[i + 1] - timeline.starts[i]
                guard span > 0, span <= maximumGPSGap, let b = speed(packets[i + 1]) else { continue }
                average = (a + b) / 2
            } else { span = 1 / timeline.nominalFPS; average = a }
            coverage += span; integral += average * span
        }
        func ranges(_ get: (PacketTelemetry) -> [Int16]) -> [RawAxisRange] {
            (0..<3).map { axis in
                let values = packets.map { get($0.telemetry)[axis] }
                return .init(minimum: values.min() ?? 0, maximum: values.max() ?? 0)
            }
        }
        return .init(recordingID: recording.id, startWallTime: recording.startTime, endWallTime: recording.endTime, channel: recording.channel,
                     frames: packets.count, storageBlocks: recording.blockCount, gpsFrames: gpsFrames, audioBytes: packets.reduce(0) { $0 + $1.auxiliaryBytes },
                     durationSeconds: timeline.duration, speedCoverageSeconds: coverage, meanSpeedKMH: coverage > 0 ? integral / coverage : nil,
                     maximumSpeedKMH: speeds.max(), distanceEstimateKM: coverage > 0 ? integral / 3600 : nil,
                     accelerationRaw: ranges { $0.accelerationRaw }, gyroRaw: ranges { $0.gyroRaw },
                     eventRawDistribution: counts.keys.sorted().map { .init(value: $0, frames: counts[$0]!) }, notes: String(notes.prefix(16384)))
    }
    public static func csv(_ reports: [RecordingReport]) -> String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "" }
        func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "recording,channel,start_wall_time,end_wall_time,frames,storage_blocks,duration_seconds,gps_frames,speed_coverage_seconds,mean_speed_kmh,max_speed_kmh,distance_estimate_km,event_raw_distribution,notes"
        let rows = reports.map { r -> String in
            let events = r.eventRawDistribution.map { String(format: "%02X:%d", $0.value, $0.frames) }.joined(separator: ";")
            // Prefix spreadsheet formula markers only in human-supplied notes.
            let note = r.notes.first.map { "=+-@\t\r".contains($0) } == true ? "'" + r.notes : r.notes
            return [r.recordingID, String(r.channel), r.startWallTime, r.endWallTime, String(r.frames), String(r.storageBlocks), number(r.durationSeconds), String(r.gpsFrames), number(r.speedCoverageSeconds), number(r.meanSpeedKMH), number(r.maximumSpeedKMH), number(r.distanceEstimateKM), events, note].map(cell).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
