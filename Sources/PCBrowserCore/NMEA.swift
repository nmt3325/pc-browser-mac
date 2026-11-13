import Foundation
public struct GPSPoint:Identifiable,Sendable {
    public let id:Int;public let latitude:Double;public let longitude:Double
    public let speedKMH:Double?;public let timestamp:Date?
    public init(id:Int,latitude:Double,longitude:Double,speedKMH:Double?,timestamp:Date?){self.id=id;self.latitude=latitude;self.longitude=longitude;self.speedKMH=speedKMH;self.timestamp=timestamp}
}
public struct LogSummary:Sendable {
    public var points:[GPSPoint]=[];public var vendorRecords:Int=0;public var rejected:Int=0
    public var lines:Int=0;public init(){}
}
public enum NMEAParser {
    private static func coordinate(_ s:String,_ h:String)->Double? {
        guard let raw=Double(s),raw.isFinite,raw>=0 else{return nil}
        let deg=floor(raw/100),minutes=raw-deg*100
        guard minutes<60 else{return nil}
        let v=(deg+minutes/60)*(["S","W"].contains(h) ? -1:1)
        guard ["N","S","E","W"].contains(h),abs(v)<=(["N","S"].contains(h) ? 90:180) else{return nil};return v
    }
    private static func utcDate(day: String, time: String) -> Date? {
        guard day.utf8.count == 6, time.utf8.count >= 6,
              day.utf8.allSatisfy({ (48...57).contains($0) }),
              time.prefix(6).utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let d = Array(day), t = Array(time.prefix(6)), suffix = String(time.dropFirst(6))
        let fraction: Double
        if suffix.isEmpty { fraction = 0 }
        else { guard suffix.first == ".", suffix.count > 1, suffix.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }), let value = Double("0" + suffix), value.isFinite, value < 1 else { return nil }; fraction = value }
        let year = Int(String(d[4...5]))!, month = Int(String(d[2...3]))!, date = Int(String(d[0...1]))!
        let hour = Int(String(t[0...1]))!, minute = Int(String(t[2...3]))!, second = Int(String(t[4...5]))!
        guard (1...12).contains(month), (1...31).contains(date), hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fullYear = (year >= 80 ? 1900 : 2000) + year
        guard let result = calendar.date(from: DateComponents(year: fullYear, month: month, day: date, hour: hour, minute: minute, second: second)) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: result)
        guard check.year == fullYear, check.month == month, check.day == date else { return nil }
        return result.addingTimeInterval(fraction)
    }
    public static func parse(_ text:String)->LogSummary {
        var out=LogSummary()
        for raw in text.components(separatedBy:.newlines) {
            guard let dollar=raw.firstIndex(of:"$") else{continue}
            let line=String(raw[dollar...]).trimmingCharacters(in:.whitespacesAndNewlines);out.lines+=1
            let split=line.split(separator:"*",maxSplits:1,omittingEmptySubsequences:false)
            if split.count==2 {
                let body=split[0].dropFirst();let check=body.utf8.reduce(UInt8(0),^)
                guard let expected=UInt8(split[1].prefix(2),radix:16),check==expected else{out.rejected+=1;continue}
            }
            let f=split[0].split(separator:",",omittingEmptySubsequences:false).map(String.init)
            guard let kind=f.first else{continue}
            if kind.hasPrefix("$YPDRL"){out.vendorRecords+=1;continue}
            if kind.hasSuffix("RMC"),f.count>=10,f[2]=="A",let lat=coordinate(f[3],f[4]),let lon=coordinate(f[5],f[6]) {
                let speed=Double(f[7]).flatMap{$0.isFinite&&$0>=0 ? $0*1.852:nil}
                let date = utcDate(day: f[9], time: f[1])
                out.points.append(.init(id:out.points.count,latitude:lat,longitude:lon,speedKMH:speed,timestamp:date))
            } else if kind.hasSuffix("GGA"),f.count>=7,f[6] != "0",let lat=coordinate(f[2],f[3]),let lon=coordinate(f[4],f[5]) {
                out.points.append(.init(id:out.points.count,latitude:lat,longitude:lon,speedKMH:nil,timestamp:nil))
            }
        }
        return out
    }
}
