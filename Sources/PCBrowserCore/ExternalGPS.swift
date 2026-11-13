import Foundation

public extension CardTimestamp {
    /// Callers must provide the device timezone explicitly. Card bytes do not
    /// imply UTC, the host timezone, or the user's current timezone.
    func date(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute, check.second == second else { return nil }
        return date.addingTimeInterval(Double(frameSlot) / Double(max(1, nominalFPS)))
    }
}

public struct SynchronizedGPS: Sendable {
    public let coordinate: GeoCoordinate
    public let speedKMH: Double?
    public let interpolated: Bool
}

public struct ExternalGPSTrack: Sendable {
    public let points: [GPSPoint]
    public init(points: [GPSPoint]) {
        // Keep the first valid fix at duplicate UTC timestamps deterministically.
        let sorted = points.enumerated().filter { _, p in
            p.timestamp != nil && p.timestamp!.timeIntervalSince1970.isFinite &&
            p.latitude.isFinite && p.longitude.isFinite && abs(p.latitude) <= 90 && abs(p.longitude) <= 180
        }.sorted { a, b in a.element.timestamp! == b.element.timestamp! ? a.offset < b.offset : a.element.timestamp! < b.element.timestamp! }
        var unique: [GPSPoint] = [], last: Date?
        for (_, p) in sorted where p.timestamp != last { unique.append(p); last = p.timestamp }
        self.points = unique
    }
    /// Positive logOffsetSeconds queries a later point in the external UTC log.
    /// No extrapolation and no interpolation across outages greater than maxGap.
    public func sample(clock: CardTimestamp?, deviceTimeZone: TimeZone?, logOffsetSeconds: Double = 0,
                       maxGap: Double = 10) -> SynchronizedGPS? {
        guard let clock, let deviceTimeZone, logOffsetSeconds.isFinite, maxGap.isFinite, maxGap > 0,
              let date = clock.date(in: deviceTimeZone), !points.isEmpty else { return nil }
        let target = date.timeIntervalSince1970 + logOffsetSeconds
        guard target.isFinite else { return nil }
        var lo = 0, hi = points.count
        while lo < hi { let mid = (lo + hi) / 2; if points[mid].timestamp!.timeIntervalSince1970 < target { lo = mid + 1 } else { hi = mid } }
        func fix(_ p: GPSPoint) -> SynchronizedGPS { .init(coordinate: .init(latitude: p.latitude, longitude: p.longitude), speedKMH: p.speedKMH, interpolated: false) }
        if lo < points.count, abs(points[lo].timestamp!.timeIntervalSince1970 - target) < 1e-6 { return fix(points[lo]) }
        guard lo > 0, lo < points.count else { return nil }
        let a = points[lo - 1], b = points[lo], start = a.timestamp!.timeIntervalSince1970
        let span = b.timestamp!.timeIntervalSince1970 - start
        guard span > 0, span <= maxGap else { return nil }
        let f = (target - start) / span
        var delta = b.longitude - a.longitude
        if delta > 180 { delta -= 360 }; if delta < -180 { delta += 360 }
        var longitude = a.longitude + delta * f
        if longitude > 180 { longitude -= 360 }; if longitude < -180 { longitude += 360 }
        let speed: Double?
        if let x = a.speedKMH, let y = b.speedKMH, x.isFinite, y.isFinite { speed = x + (y - x) * f } else { speed = nil }
        return .init(coordinate: .init(latitude: a.latitude + (b.latitude - a.latitude) * f, longitude: longitude), speedKMH: speed, interpolated: true)
    }
}
