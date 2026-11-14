import Foundation

/// Device wall-clock components; no timezone is implied by the on-card bytes.
public struct CardTimestamp: Sendable, Hashable, Codable {
    public let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    public let frameSlot: Int
    public let nominalFPS: Int
    public var text: String { String(format:"%04d-%02d-%02d %02d:%02d:%02d",year,month,day,hour,minute,second) }
    private var wholeSeconds: Int64 {
        let y = year-(month <= 2 ? 1:0), era = y/400, yoe = y-era*400
        let mp = month+(month > 2 ? -3:9), doy = (153*mp+2)/5+day-1
        let days = era*146097+yoe*365+yoe/4-yoe/100+doy-719468
        return Int64(days)*86400+Int64(hour*3600+minute*60+second)
    }
    public var linearSeconds: Double {
        Double(wholeSeconds)+Double(frameSlot)/Double(max(1,nominalFPS))
    }
    /// Subtract whole seconds before adding frame fractions. Subtracting two
    /// epoch-sized Doubles loses enough precision to create duplicate media PTS.
    public func seconds(since other: CardTimestamp) -> Double {
        Double(wholeSeconds-other.wholeSeconds)
            + Double(frameSlot)/Double(max(1,nominalFPS))
            - Double(other.frameSlot)/Double(max(1,other.nominalFPS))
    }
    public static func parse(_ data: Data, offset: Int, fps: Int = 30, hasSlot: Bool = true) -> CardTimestamp? {
        guard offset >= 0, offset+(hasSlot ? 7:6) <= data.count, (1...120).contains(fps) else { return nil }
        let a = Array(data.dropFirst(offset).prefix(hasSlot ? 7:6)).map(Int.init)
        let y = 2000+a[0], m = a[1], d = a[2]
        guard (1...12).contains(m), a[3]<24, a[4]<60, a[5]<60 else { return nil }
        let leap = y%4 == 0 && (y%100 != 0 || y%400 == 0)
        let days = [31,leap ? 29:28,31,30,31,30,31,31,30,31,30,31]
        guard (1...days[m-1]).contains(d), !hasSlot || a[6] <= fps else { return nil }
        return .init(year:y,month:m,day:d,hour:a[3],minute:a[4],second:a[5],frameSlot:hasSlot ? a[6]:0,nominalFPS:fps)
    }
}

public enum GPSDatum: String, CaseIterable, Sendable, Codable {
    case deviceTokyo, wgs84
    public var label: String { self == .deviceTokyo ? "Windows版互換（Tokyo→WGS84）" : "WGS84として解釈" }
}
public struct GeoCoordinate: Sendable, Hashable, Codable {
    public let latitude: Double, longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude=latitude;self.longitude=longitude }
    public var valid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude)<=90 && abs(longitude)<=180 && (latitude != 0 || longitude != 0) }
}
public enum DeviceGeodesy {
    /// Same ellipsoids, 1/600000 degree units and (-147,+506,+687)m translation
    /// observed in original Windows VA 0x56DE20. This is NOT a generic Japan datum preset.
    public static func coordinate(latitude rawLat: Int32, longitude rawLon: Int32, altitudeRaw: Int16, datum: GPSDatum) -> GeoCoordinate? {
        coordinate(latitude: rawLat, longitude: rawLon, altitudeMillimetres: Int32(altitudeRaw), datum: datum)
    }
    /// The per-second journal (履歴記録) stores the altitude as a 32-bit millimetre value; the video packets keep a 16-bit one.
    public static func coordinate(latitude rawLat: Int32, longitude rawLon: Int32, altitudeMillimetres: Int32, datum: GPSDatum) -> GeoCoordinate? {
        let lat = Double(rawLat)/600000, lon = Double(rawLon)/600000
        let initial = GeoCoordinate(latitude:lat,longitude:lon)
        guard initial.valid else { return nil }
        if datum == .wgs84 { return initial }
        let a = 6377397.155, b = 6356078.962818188, a2 = 6378137.0, b2 = 6356752.314245179
        let phi = lat * .pi/180, lam = lon * .pi/180, h = Double(altitudeMillimetres)*0.001
        let e = (a*a-b*b)/(a*a), n = a/sqrt(1-e*sin(phi)*sin(phi))
        let x = (n+h)*cos(phi)*cos(lam)-147, y = (n+h)*cos(phi)*sin(lam)+506
        let z = (n*(1-e)+h)*sin(phi)+687, p = hypot(x,y)
        let e2 = (a2*a2-b2*b2)/(a2*a2), ep2 = (a2*a2-b2*b2)/(b2*b2), t = atan2(z*a2,p*b2)
        let outLat = atan2(z+ep2*b2*pow(sin(t),3),p-e2*a2*pow(cos(t),3))*180 / .pi
        let outLon = atan2(y,x)*180 / .pi
        let out = GeoCoordinate(latitude:outLat,longitude:outLon)
        return out.valid ? out : nil
    }
}
public struct PacketTelemetry: Sendable, Codable {
    public let clock: CardTimestamp?
    public let secondaryClock: CardTimestamp?
    public let latitudeRaw: Int32, longitudeRaw: Int32
    public let altitudeRaw: Int16
    public let speedRaw: UInt32
    public let satelliteCount: UInt8, fixRaw: UInt8
    public let accelerationRaw: [Int16]
    public let gyroRaw: [Int16]
    public let inputRaw: [UInt8]
    public let eventRaw: UInt8
    /// Trigger fields of the packet header: flags at 0x40 and the 24-bit cause mask at 0x4C…0x4E. Only the packet that
    /// carries the trigger moment has them set; the original's report names the event on exactly that row.
    public let triggerFlags: UInt8, triggerMask: UInt32
    public var trigger: EventTrigger.Sample { .init(flags: triggerFlags, mask: triggerMask) }
    public var speedKMH: Double? { speedRaw < 100000 ? Double(speedRaw)*0.036 : nil }
    public func coordinate(datum: GPSDatum = .deviceTokyo) -> GeoCoordinate? {
        guard fixRaw != 0, satelliteCount > 0 else { return nil }
        return DeviceGeodesy.coordinate(latitude:latitudeRaw,longitude:longitudeRaw,altitudeRaw:altitudeRaw,datum:datum)
    }
    public static func parse(_ data: Data) throws -> PacketTelemetry {
        let b = Bytes(data), rawFPS = Int(try b.le16(0x1D)), fps = (1...120).contains(rawFPS) ? rawFPS:30
        let maskLow = UInt32(try b.u8(0x4C)), maskMiddle = UInt32(try b.u8(0x4D)), maskHigh = UInt32(try b.u8(0x4E))
        let mask = maskLow | (maskMiddle << 8) | (maskHigh << 16)
        return .init(clock:CardTimestamp.parse(data,offset:0xA,fps:fps), secondaryClock:CardTimestamp.parse(data,offset:0x12,hasSlot:false),
                     latitudeRaw:Int32(bitPattern:try b.le32(0x28)),longitudeRaw:Int32(bitPattern:try b.le32(0x2C)),altitudeRaw:Int16(bitPattern:try b.le16(0x30)),
                     speedRaw:try b.le32(0x32),satelliteCount:try b.u8(0x26),fixRaw:try b.u8(0x27),
                     accelerationRaw:try [0x46,0x48,0x4A].map { Int16(bitPattern:try b.le16($0)) },
                     gyroRaw:try [0x50,0x52,0x54].map { Int16(bitPattern:try b.le16($0)) },
                     inputRaw:try [0x3A,0x3D,0x3E,0x3F,0x40,0x41].map { try b.u8($0) }, eventRaw:try b.u8(0x18),
                     triggerFlags:try b.u8(0x40), triggerMask:mask)
    }
}
public struct RecordingTimeline: Sendable {
    public let starts: [Double]
    public let duration: Double
    public let usedCardClock: Bool
    public let nominalFPS: Double
    public init(packets: [FramePacket]) {
        let fps = Double(packets.compactMap { $0.telemetry.clock?.nominalFPS }.first ?? 30)
        nominalFPS = fps
        let first = packets.first?.telemetry.clock
        let step = 1/fps
        var times: [Double] = [], last = -step, valid = first != nil
        for (i,p) in packets.enumerated() {
            let relative = p.telemetry.clock.flatMap { clock in first.map { clock.seconds(since:$0) } }
            // Slot 30 and slot 0 may share the same boundary. Keep at least one
            // nominal frame between samples, not merely a sub-microsecond increase
            // that would round to the same AVAssetWriter presentation timestamp.
            var t = relative ?? Double(i)/fps
            if relative == nil { valid = false }
            if !t.isFinite || t < 0 || t < last-0.25 { valid = false; t = Double(i)/fps }
            t = max(t,last+step)
            times.append(t);last=t
        }
        starts=times;duration=(times.last ?? 0)+(packets.isEmpty ? 0:1/fps);usedCardClock=valid
    }
    public func frame(at seconds: Double) -> Int {
        guard !starts.isEmpty else { return 0 }
        var lo = 0, hi = starts.count
        while lo < hi { let mid=(lo+hi)/2; if starts[mid] <= seconds { lo=mid+1 } else { hi=mid } }
        return max(0,min(starts.count-1,lo-1))
    }
}
