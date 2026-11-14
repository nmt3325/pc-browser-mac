import Foundation

/// The settings of the original's ログデータ変換 dialog (GPSログ／Earth) in the order of its controls. The defaults are the
/// original's; the dialog does not keep them between openings.
public struct JournalKMLOptions: Sendable, Equatable {
    public static let densityRange = 1...30
    public static let widthRange = 1...10
    public static let alphaRange = 0...255

    /// ポイント: one arrow with a balloon for every `density`-th journal entry.
    public var showPoints = true
    /// The spin box of the point density, 1…30.
    public var density = 10
    /// ルート: the drawn track of every fix of the journal.
    public var showRoute = true
    /// 幅 of the route line, 1…10.
    public var width = 5
    /// 透明度, 0…255. It is written as the alpha byte of the line colour, so 0 is fully transparent.
    public var alpha = 100
    /// 色 of the route line as 0xRRGGBB (the original's colour button starts black).
    public var rgb: UInt32 = 0x000000
    /// Google Earth Pro起動: open the finished file in Google Earth afterwards (on by default).
    public var launchEarth = true

    public init() {}

    /// The values forced into the ranges of the dialog's spin boxes.
    public var clamped: JournalKMLOptions {
        var o = self
        o.density = min(max(density, Self.densityRange.lowerBound), Self.densityRange.upperBound)
        o.width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        o.alpha = min(max(alpha, Self.alphaRange.lowerBound), Self.alphaRange.upperBound)
        o.rgb &= 0xFFFFFF
        return o
    }

    /// KML colour order AABBGGRR (alpha, blue, green, red) in upper-case hexadecimal.
    public var colourText: String {
        let o = clamped
        return String(format: "%02X%02X%02X%02X", o.alpha, o.rgb & 0xFF, (o.rgb >> 8) & 0xFF, (o.rgb >> 16) & 0xFF)
    }
}

/// ログデータ変換 of the original: the Google Earth file of the whole 履歴記録 journal (docs/kml-export.md).
///
/// The export always covers every journal entry, whatever rows are selected in the list. A point is written for the entries whose
/// index is a multiple of the density and whose record carries a 2D or 3D fix; the route lists every fix entry. The file is UTF-8
/// with a byte order mark and CRLF line ends, laid out line for line like the original's.
public struct JournalKML: Sendable {
    public static let title = "ログデータ変換"
    public static let completionText = "完了しました"
    /// The arrow icon the original names in every point (an address of the manufacturer's map site; nothing is fetched here).
    public static let iconURL = "http://map.yupiteru-itymap.com/icon/arrow_r_2.png"
    static let weekdays: [Character] = ["月", "火", "水", "木", "金", "土", "日"]

    let log: HistoryLog

    public init?(log: HistoryLog) {
        guard !log.rows.isEmpty else { return nil }
        self.log = log
    }

    /// Number of journal entries the file is made from.
    public var entryCount: Int { log.journal.gps.count }
    /// The shown clock of the first entry; it names the document, the route and the default file.
    public var firstClock: Int64 { log.rows[0].start }
    /// `YP_<yyyymmdd>_<hhmmss>` of the first row's start, the file name the dialog proposes (without the extension).
    public var defaultStem: String {
        let c = CivilTime.components(firstClock)
        return String(format: "YP_%04d%02d%02d_%02d%02d%02d", c.year, c.month, c.day, c.hour, c.minute, c.second)
    }
    public var defaultFileName: String { defaultStem + ".kml" }

    /// 月火水木金土日 for a clock (seconds since 1970 of the device's own time); 1970-01-01 was a Thursday.
    static func weekday(_ t: Int64) -> Character {
        let days = t >= 0 ? t / 86400 : -((-t + 86399) / 86400)
        return weekdays[Int(((days % 7) + 7 + 3) % 7)]
    }
    /// `%.nf` of the C library (no locale: Foundation would otherwise round the shortest decimal form).
    static func decimal(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }

    /// The complete file. `cancelled` is polled while the entries are walked.
    public func data(options: JournalKMLOptions = JournalKMLOptions(), cancelled: () -> Bool = { false }) throws -> Data {
        let o = options.clamped
        let journal = log.journal
        let count = entryCount
        let invalid = JournalSlot.invalid
        var out = Data([0xEF, 0xBB, 0xBF])
        var text = ""
        text.reserveCapacity(1 << 20)
        func line(_ s: String) { text += s; text += "\r\n" }
        func flush(force: Bool = false) {
            if force || text.utf8.count >= 1 << 20 {
                out.append(contentsOf: text.utf8)
                text.removeAll(keepingCapacity: true)
            }
        }
        func coordinates(_ s: JournalSlot) -> (longitude: String, latitude: String)? {
            guard let c = DeviceGeodesy.coordinate(latitude: s.latitudeRaw, longitude: s.longitudeRaw, altitudeMillimetres: s.altitudeMillimetres, datum: .deviceTokyo) else { return nil }
            return (Self.decimal(c.longitude, 12), Self.decimal(c.latitude, 12))
        }

        let first = CivilTime.components(firstClock)
        line("<?xml version=\"1.0\" encoding=\"UTF-8\"?><kml xmlns=\"http://earth.google.com/kml/2.1\">")
        line(String(format: "<Document><name>%04d年 %02d月 %02d日(", first.year, first.month, first.day) + String(Self.weekday(firstClock)) + ")</name>")
        line("<Style id=\"line_style\">")
        line("<LineStyle><color>\(o.colourText)</color><width>\(o.width)</width></LineStyle></Style>")

        if o.showPoints {
            line("<Folder><name>ポイント</name>")
            var walked = 0
            for n in stride(from: 0, to: count, by: o.density) {
                if walked & 0x3FFF == 0 && cancelled() { throw BrowserError.io("ログデータ変換をキャンセルしました") }
                walked += 1
                let s = journal.dataSlot(n)
                let g = journal.gps[n]
                guard s.hasFix, g != invalid else { continue }
                let t = CivilTime.components(g)
                let place = coordinates(s) ?? ("0.000000000000", "0.000000000000")
                let heading = Int((Double(s.headingRaw) * 1e-5).rounded(.toNearestOrEven))
                line(String(format: "<Placemark><name>%02d:%02d:%02d</name>", t.hour, t.minute, t.second))
                line("<Style><IconStyle><color>FF00FF00</color><scale>0.8</scale><Icon><href>\(Self.iconURL)</href></Icon><heading>\(heading)</heading></IconStyle></Style>")
                line("<Point><coordinates>\(place.longitude),\(place.latitude),0</coordinates></Point>")
                let day = String(format: "%04d年%02d月%02d日(", t.year, t.month, t.day) + String(Self.weekday(g)) + ")"
                let clock = String(format: "%02d時%02d分%02d秒", t.hour, t.minute, t.second)
                let speed = Self.decimal(Double(s.speedRaw) * 0.036, 1), direction = Self.decimal(Double(s.headingRaw) * 1e-5, 1)
                line("<description><![CDATA[<table><tr><td>日付</td><td>\(day)</td></tr><tr><td>時刻</td><td>\(clock)</td></tr><tr><td>速度(GPS値)</td><td>\(speed)km/h</td></tr><tr><td>進行方向</td><td>\(direction)度</td></tr></table>]]></description>")
                line("<LookAt><longitude>\(place.longitude)</longitude><latitude>\(place.latitude)</latitude><tilt>50</tilt><range>400</range><heading>\(heading)</heading></LookAt>")
                line("</Placemark>")
                flush()
            }
            line("</Folder>")
        }

        if o.showRoute {
            line("<Folder><name>ルート</name>")
            line(String(format: "<Placemark><name>%04d年%02d月%02d日 %02d時%02d分%02d秒</name>", first.year, first.month, first.day, first.hour, first.minute, first.second))
            line("<styleUrl>#line_style</styleUrl>")
            line("<LineString id=\"CarRoute\"><tessellate>1</tessellate>")
            text += "<coordinates>"
            for n in 0..<count {
                if n & 0x3FFF == 0 && cancelled() { throw BrowserError.io("ログデータ変換をキャンセルしました") }
                let s = journal.dataSlot(n)
                guard s.hasFix, let place = coordinates(s) else { continue }
                text += place.longitude; text += ","; text += place.latitude; text += ",0 "
                flush()
            }
            text += "\r\n"
            line("</coordinates></LineString>")
            line("</Placemark>")
            line("</Folder>")
        }
        line("</Document>")
        line("</kml>")
        flush(force: true)
        return out
    }
}
