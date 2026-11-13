import Foundation

public enum TrackExport {
    public static func xml(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;") }
    private static func number(_ n: Double) -> String { String(format:"%.8f",locale:Locale(identifier:"en_US_POSIX"),n) }
    public static func csv(_ recordings: [Recording], datum: GPSDatum = .deviceTokyo) -> String {
        var rows = ["recording,channel,sequence,card_wall_time,relative_seconds,latitude_wgs84,longitude_wgs84,speed_kmh,accel_x_raw,accel_y_raw,accel_z_raw,gyro_x_raw,gyro_y_raw,gyro_z_raw,fix_raw,satellites,event_raw"]
        for r in recordings {
            let timeline = RecordingTimeline(packets:r.packets)
            for (i,p) in r.packets.enumerated() {
                let t=p.telemetry,g=t.coordinate(datum:datum)
                var cells: [String] = [r.id,String(p.channel),String(p.sequence),p.cardTime,number(timeline.starts[i])]
                cells.append(g.map { number($0.latitude) } ?? "")
                cells.append(g.map { number($0.longitude) } ?? "")
                cells.append(t.speedKMH.map { number($0) } ?? "")
                cells.append(contentsOf:t.accelerationRaw.map { String($0) })
                cells.append(contentsOf:t.gyroRaw.map { String($0) })
                cells.append(contentsOf:[String(t.fixRaw),String(t.satelliteCount),String(t.eventRaw)])
                rows.append(cells.map { "\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }.joined(separator:","))
            }
        }
        return rows.joined(separator:"\r\n")+"\r\n"
    }
    public static func kml(_ recordings: [Recording], datum: GPSDatum = .deviceTokyo, stride: Int = 1, name: String = "PC Browser Mac", style: TrackStyle? = nil) -> String {
        var requested = style ?? TrackStyle()
        if style == nil { requested.density = stride }
        let options = requested.clamped, step = options.density
        let tracks = recordings.map { r -> String in
            var points: [(String, GeoCoordinate)] = []
            let valid = r.packets.compactMap { p in p.telemetry.coordinate(datum: datum).map { (p.cardTime, $0) } }
            for (i, item) in valid.enumerated() where i % step == 0 || i == valid.count - 1 { points.append(item) }
            guard !points.isEmpty else { return "" }
            let title = xml(r.startTime) + " CH\(r.channel)"
            var output = "<Folder><name>\(title)</name>"
            if options.showRoute {
                let coords = points.map { "\(number($0.1.longitude)),\(number($0.1.latitude)),0" }.joined(separator: " ")
                output += "<Placemark><name>\(title)</name><styleUrl>#route</styleUrl><LineString><tessellate>1</tessellate><coordinates>\(coords)</coordinates></LineString></Placemark>"
            }
            if options.showPoints {
                for (time, c) in points { output += "<Placemark><name>\(xml(time))</name><styleUrl>#point</styleUrl><Point><coordinates>\(number(c.longitude)),\(number(c.latitude)),0</coordinates></Point></Placemark>" }
            }
            return output + "</Folder>"
        }.joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>\(xml(name))</name><description>Device wall time has no declared timezone. No UTC timestamps are invented.</description><Style id=\"route\"><LineStyle><color>\(options.kmlColor())</color><width>\(options.width)</width></LineStyle></Style><Style id=\"point\"><IconStyle><color>\(options.kmlColor(points: true))</color><scale>\(options.pointScale)</scale></IconStyle></Style>\(tracks)</Document></kml>\n"
    }
    public static func gpx(_ recordings: [Recording], datum: GPSDatum = .deviceTokyo) -> String {
        let tracks = recordings.map { r in
            let points = r.packets.compactMap { $0.telemetry.coordinate(datum:datum) }.map { "<trkpt lat=\"\(number($0.latitude))\" lon=\"\(number($0.longitude))\"/>" }.joined()
            return "<trk><name>\(xml(r.startTime)) CH\(r.channel)</name><trkseg>\(points)</trkseg></trk>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"PC Browser Mac\" xmlns=\"http://www.topografix.com/GPX/1/1\">\(tracks)</gpx>\n"
    }
}
