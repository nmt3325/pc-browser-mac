import Foundation

/// Conditions must match the same frame. Never infer G units, camera identity,
/// brake/turn-signal bits or named event kinds from these raw packet fields.
public struct RawSensorQuery: Equatable, Sendable {
    public var enabled = false
    public var accelerationAxis = 0, gyroAxis = 2
    public var minimumAbsoluteAcceleration = 0, minimumAbsoluteGyro = 0
    public var eventByte = -1, inputIndex = -1, inputValue = 0
    public init() {}
    public var clamped: Self {
        var q = self
        q.accelerationAxis = min(2, max(0, accelerationAxis)); q.gyroAxis = min(2, max(0, gyroAxis))
        q.minimumAbsoluteAcceleration = min(32768, max(0, minimumAbsoluteAcceleration)); q.minimumAbsoluteGyro = min(32768, max(0, minimumAbsoluteGyro))
        q.eventByte = min(255, max(-1, eventByte)); q.inputIndex = min(5, max(-1, inputIndex)); q.inputValue = min(255, max(0, inputValue))
        return q
    }
    public var hasConditions: Bool { enabled && (minimumAbsoluteAcceleration > 0 || minimumAbsoluteGyro > 0 || eventByte >= 0 || inputIndex >= 0) }
    public func matches(_ packet: FramePacket) -> Bool {
        guard hasConditions else { return true }; let q = clamped, t = packet.telemetry
        if q.minimumAbsoluteAcceleration > 0, abs(Int(t.accelerationRaw[q.accelerationAxis])) < q.minimumAbsoluteAcceleration { return false }
        if q.minimumAbsoluteGyro > 0, abs(Int(t.gyroRaw[q.gyroAxis])) < q.minimumAbsoluteGyro { return false }
        if q.eventByte >= 0, Int(t.eventRaw) != q.eventByte { return false }
        if q.inputIndex >= 0, Int(t.inputRaw[q.inputIndex]) != q.inputValue { return false }
        return true
    }
}
