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
                var date:Date?=nil
                if f[9].count==6,f[1].count>=6 {
                    let ds=Array(f[9]),ts=Array(f[1].prefix(6));var c=DateComponents()
                    let yy=Int(String(ds[4...5])) ?? 0;c.year=(yy>=80 ? 1900:2000)+yy;c.month=Int(String(ds[2...3]));c.day=Int(String(ds[0...1]));c.hour=Int(String(ts[0...1]));c.minute=Int(String(ts[2...3]));c.second=Int(String(ts[4...5]));var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!;date=cal.date(from:c)
                }
                out.points.append(.init(id:out.points.count,latitude:lat,longitude:lon,speedKMH:speed,timestamp:date))
            } else if kind.hasSuffix("GGA"),f.count>=7,f[6] != "0",let lat=coordinate(f[2],f[3]),let lon=coordinate(f[4],f[5]) {
                out.points.append(.init(id:out.points.count,latitude:lat,longitude:lon,speedKMH:nil,timestamp:nil))
            }
        }
        return out
    }
}
