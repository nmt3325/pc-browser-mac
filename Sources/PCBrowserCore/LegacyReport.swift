import Foundation

/// The report of the original application (レポート表示 and its CSV export) is computed per frame.
/// Every rule below was measured against CSV files exported by the original from a real card
/// (see docs/report-format.md); the documentation lists the few rules that are only inferred.
public enum LegacyReportKind: String, Sendable, Codable {
    case event, continuous
    /// The title word of the exported file names and of the report window.
    public var title: String { self == .event ? "イベント記録レポート" : "常時録画レポート" }
}

/// Text of the CSV column "GPS測位フラグ". The fix byte 1 with seven satellites is "3D測位" in the original (established);
/// the other combinations are inferred from the satellite count.
public enum LegacyGPSFlag: Int, Sendable, Codable {
    case none = 0, fix2D = 1, fix3D = 2
    public var text: String { ["非測位", "2D測位", "3D測位"][rawValue] }
    public init(fixRaw: UInt8, satellites: UInt8) {
        if fixRaw == 0 || satellites == 0 { self = .none }
        else if satellites >= 4 { self = .fix3D }
        else { self = .fix2D }
    }
}

/// One CSV row. The original keeps these values in per-frame arrays while a recording is loaded.
public struct LegacyReportFrame: Sendable, Equatable {
    /// Header byte 8; in the event region it names the phase (5 pre-roll, 2 trigger, 3 post).
    public let phase: UInt8
    public let clock: CardTimestamp?
    public let deviceClock: CardTimestamp?
    /// Whole km/h: the raw value times 0.036, truncated (not rounded).
    public let speed: Int
    /// Thousandths of a G, signed.
    public let acceleration: [Int16]
    public let gps: LegacyGPSFlag
    public let latitudeRaw: Int32, longitudeRaw: Int32, altitudeRaw: Int16
    public let trigger: EventTrigger.Sample
    /// Direct construction for synthetic reports (tests and the GUI self-check); real rows come from `init(_:)`.
    public init(phase: UInt8, clock: CardTimestamp?, deviceClock: CardTimestamp? = nil, speed: Int, acceleration: [Int16], gps: LegacyGPSFlag,
                latitudeRaw: Int32 = 0, longitudeRaw: Int32 = 0, altitudeRaw: Int16 = 0, trigger: EventTrigger.Sample = .init(flags: 0, mask: 0)) {
        self.phase = phase; self.clock = clock; self.deviceClock = deviceClock; self.speed = speed
        self.acceleration = acceleration; self.gps = gps
        self.latitudeRaw = latitudeRaw; self.longitudeRaw = longitudeRaw; self.altitudeRaw = altitudeRaw; self.trigger = trigger
    }
    public init(_ packet: FramePacket) {
        let t = packet.telemetry
        phase = packet.channel; clock = t.clock; deviceClock = t.secondaryClock
        speed = Int(t.speedRaw) * 36 / 1000
        acceleration = t.accelerationRaw
        gps = LegacyGPSFlag(fixRaw: t.fixRaw, satellites: t.satelliteCount)
        latitudeRaw = t.latitudeRaw; longitudeRaw = t.longitudeRaw; altitudeRaw = t.altitudeRaw
        trigger = t.trigger
    }
}

/// Distance of the original's report: the Hubeny formula on the WGS84 ellipsoid.
public enum Hubeny {
    static let semiMajor = 6378137.0, eccentricitySquared = 0.00669437999019757, meridianNumerator = 6335439.32729246
    public static func distance(from p: GeoCoordinate, to q: GeoCoordinate) -> Double {
        let phi1 = p.latitude * .pi / 180, phi2 = q.latitude * .pi / 180
        let dy = phi1 - phi2, dx = (p.longitude - q.longitude) * .pi / 180, mu = (phi1 + phi2) / 2
        let w = (1 - eccentricitySquared * sin(mu) * sin(mu)).squareRoot()
        let m = meridianNumerator / (w * w * w), n = semiMajor / w
        return ((dy * m) * (dy * m) + (dx * n * cos(mu)) * (dx * n * cos(mu))).squareRoot()
    }
}

public struct LegacyReport: Sendable {
    public let kind: LegacyReportKind
    public let frames: [LegacyReportFrame]
    /// Index into `Recording.packets` of each row's packet.
    public let packetIndices: [Int]
    public let deviceID: String
    /// Text of the column イベント種類 of the summary (event recordings).
    public let eventLabel: String
    /// The row that carries the trigger: the first frame whose header names a cause, else the first frame of the post phase.
    public let eventFrame: Int?

    /// Direct construction for synthetic reports (tests and the GUI self-check); real reports come from `make`.
    public init(kind: LegacyReportKind, frames: [LegacyReportFrame], packetIndices: [Int], deviceID: String, eventLabel: String, eventFrame: Int?) {
        self.kind = kind; self.frames = frames; self.packetIndices = packetIndices; self.deviceID = deviceID
        self.eventLabel = eventLabel; self.eventFrame = eventFrame
    }

    /// Event recordings report only the trigger and post phases; the few pre-roll frames in front are not rows.
    /// `eventLabel` is the label of the event list; without it the label follows the rows' own trigger fields.
    public static func make(_ recording: Recording, eventLabel: String? = nil, deviceID: String? = nil) throws -> LegacyReport {
        guard recording.isLoaded, !recording.packets.isEmpty else { throw BrowserError.invalid("レポートには照合済みの録画が必要です") }
        let kind: LegacyReportKind = recording.isEvent ? .event : .continuous
        var indices = Array(recording.packets.indices)
        if kind == .event {
            let phased = indices.filter { recording.packets[$0].channel == EventBlockType.trigger || recording.packets[$0].channel == EventBlockType.post }
            if !phased.isEmpty { indices = phased }
        }
        let frames = indices.map { LegacyReportFrame(recording.packets[$0]) }
        var moment = frames.firstIndex { !$0.trigger.isEmpty }
        if moment == nil && kind == .event { moment = frames.firstIndex { $0.phase == EventBlockType.post } }
        let own = frames.map(\.trigger).filter { !$0.isEmpty }
        return LegacyReport(kind: kind, frames: frames, packetIndices: indices, deviceID: deviceID ?? "",
                            eventLabel: eventLabel ?? EventTrigger.label(own), eventFrame: moment)
    }

    // MARK: Statistics

    public var startClock: CardTimestamp? { frames.first?.clock }
    public var endClock: CardTimestamp? { frames.last?.clock }
    /// The moment of an event: the clock of the trigger row.
    public var eventClock: CardTimestamp? { eventFrame.flatMap { frames[$0].clock } ?? startClock }
    /// Mean of the whole-km/h values of all rows.
    public var averageSpeed: Double? {
        frames.isEmpty ? nil : Double(frames.reduce(0) { $0 + $1.speed }) / Double(frames.count)
    }
    public var maximumSpeed: Int? { frames.map(\.speed).max() }
    /// Last clock minus first clock in whole seconds (the original's 運転時間).
    public var drivingSeconds: Int {
        guard let a = startClock, let b = endClock else { return 0 }
        let x = CivilTime.seconds(year: a.year, month: a.month, day: a.day, hour: a.hour, minute: a.minute, second: a.second)
        let y = CivilTime.seconds(year: b.year, month: b.month, day: b.day, hour: b.hour, minute: b.minute, second: b.second)
        return max(0, Int(y - x))
    }
    /// Sum of Hubeny distances between consecutive 3D-fix rows; rows with other fixes or invalid positions are skipped and
    /// do not become the reference point, an unchanged position adds nothing.
    public var distanceMeters: Double {
        var total = 0.0
        var previous: GeoCoordinate?
        for f in frames where f.gps == .fix3D {
            guard let c = DeviceGeodesy.coordinate(latitude: f.latitudeRaw, longitude: f.longitudeRaw, altitudeRaw: f.altitudeRaw, datum: .deviceTokyo) else { continue }
            if let p = previous, p != c { total += Hubeny.distance(from: p, to: c) }
            previous = c
        }
        return total
    }
    /// Rows whose header names a cause (イベント回数 of a continuous report).
    public var eventCount: Int { frames.filter { !$0.trigger.isEmpty }.count }
    public func rowLabel(_ index: Int) -> String {
        frames[index].trigger.isEmpty ? "" : EventTrigger.label([frames[index].trigger])
    }

    // MARK: Text

    public static func dateText(_ c: CardTimestamp?) -> String {
        c.map { String(format: "%04d/%02d/%02d", $0.year, $0.month, $0.day) } ?? "0000/00/00"
    }
    public static func timeText(_ c: CardTimestamp?) -> String {
        c.map { String(format: "%02d:%02d:%02d", $0.hour, $0.minute, $0.second) } ?? "00:00:00"
    }
    public static func compactText(_ c: CardTimestamp?) -> String {
        c.map { String(format: "%04d%02d%02d%02d%02d%02d", $0.year, $0.month, $0.day, $0.hour, $0.minute, $0.second) } ?? "00000000000000"
    }
    /// Thousandths of a G cut (not rounded) to two decimals: "0.00" … "-0.51" … "1.00".
    public static func accelerationText(_ raw: Int16) -> String {
        let v = Int(raw), a = abs(v)
        return (v < 0 ? "-" : "") + String(format: "%d.%d%d", a / 1000, (a / 100) % 10, (a / 10) % 10)
    }
    /// The original's CTimeSpan formats: seconds, minutes and seconds, hours…, days….
    public static func durationText(seconds s: Int) -> String {
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60, sec = s % 60
        if d > 0 { return String(format: "%d日%02d時間%02d分%02d秒", d, h, m, sec) }
        if h > 0 { return String(format: "%02d時間%02d分%02d秒", h, m, sec) }
        if m > 0 { return String(format: "%02d分%02d秒", m, sec) }
        return String(format: "%02d秒", sec)
    }
    private static func decimal(_ value: Double, _ digits: Int) -> String {
        // No locale: Foundation then uses the C library's exact rounding like the original (a locale rounds the shortest decimal form).
        String(format: "%.\(digits)f", value)
    }
    /// The dialog strings: "平均速度 14.8 km/h", "最高速度 55 km/h" ("--.-" and "--" when there is no row).
    public var averageSpeedText: String { "平均速度 " + (averageSpeed.map { Self.decimal($0, 1) } ?? "--.-") + " km/h" }
    public var maximumSpeedText: String { "最高速度 " + (maximumSpeed.map { String($0) } ?? "--") + " km/h" }
    /// "593 m" below one kilometre, "1.234 km" from there on, "1.234 nm" in knot mode.
    public func distanceText(knots: Bool = false) -> String {
        let m = distanceMeters
        if knots { return Self.decimal(m / 1852, 3) + " nm" }
        return m < 1000 ? Self.decimal(m, 0) + " m" : Self.decimal(m / 1000, 3) + " km"
    }

    // MARK: CSV

    public static let dataHeader = "日付,時刻,本体時計日付,本体時計時刻,速度[km/h],加速度X[G],加速度Y[G],加速度Z[G],緯度,経度,GPS測位フラグ,イベント種類,SDカードID,機器ID"
    public static let eventSummaryHeader = "日付,発生時刻,平均速度[km/h],最高速度[km/h],イベント種類"
    public static let continuousSummaryHeader = "日付,時刻,運転時間,平均速度[km/h],最高速度[km/h],走行距離[km],イベント回数"

    /// `<yyyyMMddHHmmss of the event>_イベント記録レポート` or `<start>_<end>_常時録画レポート`.
    public var fileStem: String {
        kind == .event ? Self.compactText(eventClock) + "_" + kind.title
                       : Self.compactText(startClock) + "_" + Self.compactText(endClock) + "_" + kind.title
    }
    public var dataFileName: String { fileStem + "_データ.csv" }
    public var summaryFileName: String { fileStem + "_集計.csv" }

    /// One row per frame in recording order. Latitude, longitude and the SD card ID are empty columns in the original's report.
    public func dataCSV() -> String {
        var out = Self.dataHeader + "\n"
        out.reserveCapacity(frames.count * 96)
        for (i, f) in frames.enumerated() {
            let a = f.acceleration
            out += Self.dateText(f.clock) + "," + Self.timeText(f.clock) + "," + Self.dateText(f.deviceClock) + "," + Self.timeText(f.deviceClock)
            out += "," + String(f.speed) + "," + Self.accelerationText(a[0]) + "," + Self.accelerationText(a[1]) + "," + Self.accelerationText(a[2])
            out += ",,," + f.gps.text + "," + rowLabel(i) + ",," + deviceID + "\n"
        }
        return out
    }
    public func summaryCSV() -> String {
        let average = Self.decimal(averageSpeed ?? 0, 1), maximum = String(maximumSpeed ?? 0)
        if kind == .event {
            return Self.eventSummaryHeader + "\n" + Self.dateText(eventClock) + "," + Self.timeText(eventClock) + "," + average + "," + maximum + "," + eventLabel + "\n"
        }
        let range = Self.timeText(startClock) + "\u{FF5E}" + Self.timeText(endClock)
        return Self.continuousSummaryHeader + "\n" + Self.dateText(startClock) + "," + range + "," + Self.durationText(seconds: drivingSeconds) + ","
            + average + "," + maximum + "," + Self.decimal(distanceMeters / 1000, 3) + "," + String(eventCount) + "\n"
    }
    /// The original writes Windows code page 932. U+FF5E (the range separator) is 0x8160 there; `String.Encoding.shiftJIS`
    /// does not map it, the DOS Japanese encoding does.
    public static func encodeCP932(_ text: String) throws -> Data {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        guard let data = text.data(using: encoding, allowLossyConversion: false) else { throw BrowserError.invalid("コードページ932で表せない文字があります") }
        return data
    }

    // MARK: Graph scales

    /// Top label of the speed graph: the highest speed rounded up to a multiple of ten (never below ten).
    public var speedAxisTop: Int { max(10, ((maximumSpeed ?? 0) + 9) / 10 * 10) }
    /// Half range of the acceleration graph in thousandths of a G: ±1.0 G while all values fit, else ±2.0 G, doubling on.
    public var accelerationAxisLimit: Int {
        var peak = 0
        for frame in frames { for value in frame.acceleration { peak = max(peak, abs(Int(value))) } }
        var limit = 1000
        while peak > limit && limit < 16000 { limit *= 2 }
        return limit
    }
    /// Seconds from the first row for every row (the graphs' x axis); rows without a clock continue at 30 frames per second.
    public var timeOffsets: [Double] {
        guard let first = startClock else { return frames.indices.map { Double($0) / 30 } }
        return frames.enumerated().map { i, f in f.clock.map { $0.seconds(since: first) } ?? Double(i) / 30 }
    }

    /// The reference images of the event report: start, two seconds before the trigger, the trigger, two seconds after and end.
    /// Indices point into `Recording.packets`. A continuous report has none.
    public func thumbnailPacketIndices() -> [Int] {
        guard kind == .event, let moment = eventFrame, !frames.isEmpty else { return [] }
        let offsets = timeOffsets, target = offsets[moment]
        func frame(at time: Double) -> Int {
            var best = 0
            for (i, t) in offsets.enumerated() where t <= time { best = i }
            return best
        }
        return [0, frame(at: target - 2), moment, frame(at: target + 2), frames.count - 1].map { packetIndices[$0] }
    }
}
