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
    public static func kml(_ recordings: [Recording], datum: GPSDatum = .deviceTokyo, stride: Int = 1, name: String = "PC Browser Mac") -> String {
        let step = max(1,min(300,stride))
        let tracks = recordings.compactMap { r -> String? in
            let points = r.packets.enumerated().compactMap { i,p -> GeoCoordinate? in i%step == 0 ? p.telemetry.coordinate(datum:datum):nil }
            guard !points.isEmpty else { return nil }
            let coords = points.map { "\(number($0.longitude)),\(number($0.latitude)),0" }.joined(separator:" ")
            return "<Placemark><name>\(xml(r.startTime)) CH\(r.channel)</name><styleUrl>#route</styleUrl><LineString><tessellate>1</tessellate><coordinates>\(coords)</coordinates></LineString></Placemark>"
        }.joined(separator:"\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>\(xml(name))</name><description>Device wall time has no declared timezone. No UTC timestamps are invented.</description><Style id=\"route\"><LineStyle><color>ffeda83b</color><width>4</width></LineStyle></Style>\(tracks)</Document></kml>\n"
    }
    public static func gpx(_ recordings: [Recording], datum: GPSDatum = .deviceTokyo) -> String {
        let tracks = recordings.map { r in
            let points = r.packets.compactMap { $0.telemetry.coordinate(datum:datum) }.map { "<trkpt lat=\"\(number($0.latitude))\" lon=\"\(number($0.longitude))\"/>" }.joined()
            return "<trk><name>\(xml(r.startTime)) CH\(r.channel)</name><trkseg>\(points)</trkseg></trk>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"PC Browser Mac\" xmlns=\"http://www.topografix.com/GPX/1/1\">\(tracks)</gpx>\n"
    }
}
