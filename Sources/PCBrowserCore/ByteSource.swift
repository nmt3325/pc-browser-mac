import Foundation

public enum BrowserError: LocalizedError, Equatable {
    case invalid(String), truncated(String), unsupported(String), io(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s),.truncated(let s),.unsupported(let s),.io(let s):return s }
    }
}
public protocol ByteSource: AnyObject, Sendable {
    var byteCount: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
    var scanRanges: [Range<UInt64>]? { get }
    var isPartialCopy: Bool { get }
}
public extension ByteSource {
    var scanRanges: [Range<UInt64>]? { nil }
    var isPartialCopy: Bool { false }
}
public final class MemorySource: ByteSource {
    public let data: Data
    public var byteCount:UInt64 {UInt64(data.count)}
    public init(_ data:Data){self.data=data}
    public func read(at offset:UInt64,count:Int)throws->Data {
        guard count>=0,offset<=byteCount,UInt64(count)<=byteCount-offset else {throw BrowserError.truncated("範囲外の読み取りです")}
        return data.subdata(in:Int(offset)..<Int(offset)+count)
    }
}
public struct Bytes {
    public let data:Data
    public init(_ data:Data){self.data=data}
    public func u8(_ offset:Int)throws->UInt8 {
        guard offset>=0,offset<data.count else {throw BrowserError.truncated("データが途中で終わっています")}
        return data[data.startIndex+offset]
    }
    public func le16(_ o:Int)throws->UInt16 {UInt16(try u8(o))|UInt16(try u8(o+1))<<8}
    public func le32(_ o:Int)throws->UInt32 {var v:UInt32=0;for i in 0..<4 {v|=UInt32(try u8(o+i))<<(i*8)};return v}
    public func be32(_ o:Int)throws->UInt32 {var v:UInt32=0;for i in 0..<4 {v=(v<<8)|UInt32(try u8(o+i))};return v}
    public func ascii(_ o:Int,_ count:Int)throws->String {
        guard o>=0,count>=0,o<=data.count,count<=data.count-o else {throw BrowserError.truncated("文字列が範囲外です")}
        return String(decoding:data[o..<o+count].prefix(while:{$0 != 0}),as:UTF8.self)
    }
}
public struct Partition:Identifiable,Sendable {
    public var id:Int;public var type:UInt8;public var firstSector:UInt32;public var sectorCount:UInt32
    public var start:UInt64 {UInt64(firstSector)*512}
    public var end:UInt64 {(UInt64(firstSector)+UInt64(sectorCount))*512}
}
public enum PartitionTable {
    public static func parse(_ data:Data,diskBytes:UInt64)throws->[Partition] {
        let b=Bytes(data)
        guard try b.le16(510)==0xaa55 else {throw BrowserError.invalid("MBRの署名がありません")}
        var result:[Partition]=[]
        for i in 0..<4 {
            let o=446+i*16,t=try b.u8(o+4),s=try b.le32(o+8),n=try b.le32(o+12)
            if t==0||n==0 {continue}
            let p=Partition(id:i,type:t,firstSector:s,sectorCount:n)
            guard p.start>=512,p.end<=diskBytes,p.start<p.end else {throw BrowserError.invalid("パーティションの範囲が不正です")}
            result.append(p)
        }
        guard !result.isEmpty else {throw BrowserError.invalid("パーティションが見つかりません")}
        return result
    }
}
