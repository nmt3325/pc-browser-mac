import Foundation

/// A point of a report figure in a unit box whose y axis points down (0 = top, 1 = bottom).
public struct ReportPoint: Sendable, Equatable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One label/value block of the original report: a label on the left and one or two value lines.
public struct LegacyReportRow: Sendable, Equatable {
    public let label: String
    public let lines: [String]
    public init(label: String, lines: [String]) { self.label = label; self.lines = lines }
}

/// The driving route of a report fitted into a box, north up.
public struct LegacyReportRoute: Sendable, Equatable {
    public var points: [ReportPoint]
    /// The position of the event frame (event reports) when it has a position.
    public var event: ReportPoint?
    public var start: ReportPoint? { points.first }
    public var end: ReportPoint? { points.last }
}

public enum ReportGraph {
    /// Keeps at most four points per pixel column (first, lowest, highest and last of the column, in time order)
    /// so that a long drive stays drawable without losing its extremes.
    public static func decimate(_ points: [ReportPoint], columns: Int) -> [ReportPoint] {
        guard columns > 0, points.count > columns * 4 else { return points }
        func column(_ p: ReportPoint) -> Int { min(columns - 1, max(0, Int(p.x * Double(columns)))) }
        var out: [ReportPoint] = []
        var start = 0
        while start < points.count {
            let current = column(points[start])
            var end = start + 1
            while end < points.count && column(points[end]) == current { end += 1 }
            var low = start, high = start
            for i in start..<end {
                if points[i].y < points[low].y { low = i }
                if points[i].y > points[high].y { high = i }
            }
            for i in Set([start, low, high, end - 1]).sorted() { out.append(points[i]) }
            start = end
        }
        return out
    }
}

extension LegacyReport {
    /// Captions of the five reference images of an event report, in the original's order.
    public static let eventThumbnailCaptions = ["開始", "イベント2秒前", "イベント発生時", "イベント2秒後", "終了"]

    /// `yyyy/MM/dd HH:mm:ss`.
    public static func dateTimeText(_ c: CardTimestamp?) -> String { dateText(c) + " " + timeText(c) }

    /// The label/value blocks of the report dialog and of the printed page.
    public var rows: [LegacyReportRow] {
        let speed = LegacyReportRow(label: "速度", lines: [averageSpeedText, maximumSpeedText])
        switch kind {
        case .event:
            return [LegacyReportRow(label: "発生日時", lines: [Self.dateTimeText(eventClock)]), speed,
                    LegacyReportRow(label: "イベント種類", lines: [eventLabel])]
        case .continuous:
            return [LegacyReportRow(label: "日時", lines: [Self.dateTimeText(startClock) + "～" + Self.dateTimeText(endClock)]),
                    LegacyReportRow(label: "運転時間", lines: [Self.durationText(seconds: drivingSeconds)]), speed,
                    LegacyReportRow(label: "走行距離", lines: [distanceText()]),
                    LegacyReportRow(label: "イベント回数", lines: [String(eventCount)])]
        }
    }

    /// Seconds covered by the graphs: first to last row, at least one.
    public var graphSpan: Double { max(1, timeOffsets.last ?? 0) }

    /// Speed over time; the top of the box is `speedAxisTop`.
    public func speedSeries() -> [ReportPoint] {
        let offsets = timeOffsets, span = max(1, offsets.last ?? 0), top = Double(speedAxisTop)
        return frames.indices.map { i in
            ReportPoint(x: offsets[i] / span, y: 1 - min(1, max(0, Double(frames[i].speed) / top)))
        }
    }

    /// One acceleration axis (0 = X, 1 = Y, 2 = Z) over time; the box spans ±`accelerationAxisLimit`.
    public func accelerationSeries(axis: Int) -> [ReportPoint] {
        let offsets = timeOffsets, span = max(1, offsets.last ?? 0), limit = Double(accelerationAxisLimit)
        let a = min(2, max(0, axis))
        return frames.indices.map { i in
            let g = Double(frames[i].acceleration[a]) / limit
            return ReportPoint(x: offsets[i] / span, y: 1 - min(1, max(0, (g + 1) / 2)))
        }
    }

    /// Axis labels from the top of the speed graph down: the top value, half of it and 0.
    public var speedAxisLabels: [String] { [String(speedAxisTop), String(speedAxisTop / 2), "0"] }

    /// Axis labels from the top of the acceleration graph down: ±limit, ±limit/2 and 0.0.
    public var accelerationAxisLabels: [String] {
        let limit = Double(accelerationAxisLimit) / 1000
        func text(_ v: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v) }
        return [text(limit), text(limit / 2), "0.0", text(-limit / 2), text(-limit)]
    }

    /// Clock labels under the graphs: start, middle and end of the covered time.
    public var timeAxisLabels: [String] {
        guard let first = startClock else { return ["00:00:00", "00:00:00", "00:00:00"] }
        let base = CivilTime.seconds(year: first.year, month: first.month, day: first.day, hour: first.hour, minute: first.minute, second: first.second)
        let span = graphSpan
        return [0, span / 2, span].map { offset in
            let c = CivilTime.components(base + Int64(offset.rounded()))
            return String(format: "%02d:%02d:%02d", c.hour, c.minute, c.second)
        }
    }

    /// Position (0...1 along the time axis) of the event marker of an event report.
    public var eventMarkerPosition: Double? {
        guard kind == .event, let moment = eventFrame else { return nil }
        let offsets = timeOffsets
        return offsets[moment] / max(1, offsets.last ?? 0)
    }
    /// The clock the marker is labelled with.
    public var eventMarkerLabel: String? { eventMarkerPosition == nil ? nil : Self.timeText(eventClock) }

    /// Positions of the 3D-fix rows fitted into a box of the given width/height ratio with a margin, north up and with the
    /// east-west scale reduced by the cosine of the latitude. At most `limit` points are kept.
    public func route(aspect: Double, limit: Int = 4000) -> LegacyReportRoute {
        var coordinates: [GeoCoordinate] = []
        var eventAt: Int?
        for (i, f) in frames.enumerated() where f.gps == .fix3D {
            guard let c = DeviceGeodesy.coordinate(latitude: f.latitudeRaw, longitude: f.longitudeRaw, altitudeRaw: f.altitudeRaw, datum: .deviceTokyo), c.valid else { continue }
            coordinates.append(c)
            if let moment = eventFrame, i <= moment { eventAt = coordinates.count - 1 }
        }
        guard !coordinates.isEmpty else { return LegacyReportRoute(points: [], event: nil) }
        let lats = coordinates.map(\.latitude), lons = coordinates.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2, centerLon = (lons.min()! + lons.max()!) / 2
        let scale = cos(centerLat * .pi / 180)
        let spanX = max(1e-9, (lons.max()! - lons.min()!) * scale), spanY = max(1e-9, lats.max()! - lats.min()!)
        let margin = 0.1, width = max(0.1, aspect)
        let fit = min(width * (1 - 2 * margin) / spanX, (1 - 2 * margin) / spanY)
        func place(_ c: GeoCoordinate) -> ReportPoint {
            ReportPoint(x: (width / 2 + (c.longitude - centerLon) * scale * fit) / width, y: 0.5 - (c.latitude - centerLat) * fit)
        }
        var points = coordinates.map(place)
        let event = kind == .event ? eventAt.map { place(coordinates[$0]) } : nil
        if points.count > limit {
            let stride = Double(points.count - 1) / Double(limit - 1)
            points = (0..<limit).map { points[Int((Double($0) * stride).rounded())] }
        }
        return LegacyReportRoute(points: points, event: event)
    }
}
