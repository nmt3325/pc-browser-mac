import Foundation

public struct SubtitleFields: OptionSet, Codable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let date = Self(rawValue: 1 << 0), speed = Self(rawValue: 1 << 1), gps = Self(rawValue: 1 << 2)
    public static let acceleration = Self(rawValue: 1 << 3), gyro = Self(rawValue: 1 << 4)
    public static let inputs = Self(rawValue: 1 << 5), event = Self(rawValue: 1 << 6)
    public static let defaults: Self = [.date, .speed, .gps]
    public static let all: Self = [.date, .speed, .gps, .acceleration, .gyro, .inputs, .event]
}

public struct GPSLogSynchronization: Sendable {
    public let track: ExternalGPSTrack
    public let deviceTimeZone: TimeZone
    public let logOffsetSeconds: Double
    public init(track: ExternalGPSTrack, deviceTimeZone: TimeZone, logOffsetSeconds: Double = 0) {
        self.track = track; self.deviceTimeZone = deviceTimeZone; self.logOffsetSeconds = logOffsetSeconds
    }
    public func sample(_ clock: CardTimestamp?) -> SynchronizedGPS? {
        track.sample(clock: clock, deviceTimeZone: deviceTimeZone, logOffsetSeconds: logOffsetSeconds)
    }
}

public enum SubtitleText {
    public static func lines(packet: FramePacket, datum: GPSDatum = .deviceTokyo,
                             fields: SubtitleFields = .defaults, externalGPS: GPSLogSynchronization? = nil) -> [String] {
        let telemetry = packet.telemetry, fix = externalGPS?.sample(telemetry.clock)
        let coordinate = externalGPS == nil ? telemetry.coordinate(datum: datum) : fix?.coordinate
        let speed = externalGPS == nil ? telemetry.speedKMH : fix?.speedKMH
        var first: [String] = [], second: [String] = [], third: [String] = []
        func number(_ value: Double, _ decimals: Int) -> String { String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value) }
        if fields.contains(.date) { first.append(packet.cardTime) }
        if fields.contains(.speed), let speed { first.append(number(speed, 1) + " km/h") }
        if fields.contains(.gps), let coordinate { first.append(number(coordinate.latitude, 6) + ", " + number(coordinate.longitude, 6)) }
        if externalGPS != nil, fields.contains(.gps) || fields.contains(.speed) { first.append(fix == nil ? "External GPS: no fix" : "External GPS") }
        if fields.contains(.acceleration) { second.append("Accel raw " + telemetry.accelerationRaw.map(String.init).joined(separator: "/")) }
        if fields.contains(.gyro) { second.append("Gyro raw " + telemetry.gyroRaw.map(String.init).joined(separator: "/")) }
        if fields.contains(.inputs) { third.append("Inputs raw " + telemetry.inputRaw.map { String(format: "%02X", $0) }.joined(separator: "/")) }
        if fields.contains(.event) { third.append(String(format: "Event raw %02X", telemetry.eventRaw)) }
        return [first, second, third].filter { !$0.isEmpty }.map { $0.joined(separator: "  ") }
    }
}
