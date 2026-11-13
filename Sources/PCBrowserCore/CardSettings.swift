import Foundation

public struct CardFile: Identifiable, Sendable {
    public var id: String { path }; public let path: String, bytes: Int
    public let items: [SettingItem]
}
public enum CardSettingsReader {
    /// Bounded FAT16 read-only parser. Does not guess or write proprietary settings.
    public static func read(_ source: any ByteSource) throws -> [CardFile] {
        let partitions=try PartitionTable.parse(source.read(at:0,count:512),diskBytes:source.byteCount)
        guard let part=partitions.first(where:{[0x04,0x06,0x0e].contains($0.type)}) else {throw BrowserError.unsupported("FAT16の設定領域がありません")}
        let v=try source.read(at:part.start,count:512),b=Bytes(v),bs=Int(try b.le16(11)),spc=Int(try b.u8(13)),reserved=Int(try b.le16(14)),fats=Int(try b.u8(16)),entries=Int(try b.le16(17)),fs=Int(try b.le16(22))
        guard bs==512,[1,2,4,8,16,32,64,128].contains(spc),(1...2).contains(fats),entries>0,entries<=4096,reserved>0,fs>0 else {throw BrowserError.unsupported("未対応のFAT16レイアウトです")}
        let fatStart=part.start+UInt64(reserved*bs),rootStart=fatStart+UInt64(fats*fs*bs),rootLength=(entries*32+bs-1)/bs*bs,dataStart=rootStart+UInt64(rootLength),clusterBytes=spc*bs
        guard fatStart>=part.start,rootStart>=fatStart,dataStart>=rootStart,dataStart<=part.end else{throw BrowserError.invalid("FAT16の管理領域がパーティションを超えています")}
        let fat=try source.read(at:fatStart,count:fs*bs)
        func chain(_ first:UInt16,limit:Int=1024*1024) throws -> Data {
            var n=first,seen=Set<UInt16>(),out=Data()
            while n>=2 && n<0xfff8 {
                guard !seen.contains(n),out.count+clusterBytes<=limit else {throw BrowserError.invalid("FATチェーンの循環または過大な設定ファイルです")}
                seen.insert(n);let at=dataStart+UInt64(n-2)*UInt64(clusterBytes)
                guard at<=part.end,UInt64(clusterBytes)<=part.end-at else {throw BrowserError.invalid("設定ファイルがパーティションを超えています")}
                out.append(try source.read(at:at,count:clusterBytes));n=try Bytes(fat).le16(Int(n)*2)
            }
            return out
        }
        var result:[CardFile]=[]
        func directory(_ data:Data,prefix:String,depth:Int) throws {
            guard depth<=2 else{return}
            for i in stride(from:0,to:data.count-31,by:32) {
                let e=data.subdata(in:i..<i+32),b=Bytes(e),first=try b.u8(0),attr=try b.u8(11)
                if first==0 {break};if first==0xe5 || first==46 || attr==15 || attr&8 != 0 {continue}
                let base=String(decoding:e.prefix(8),as:UTF8.self).trimmingCharacters(in:.whitespaces),ext=String(decoding:e.dropFirst(8).prefix(3),as:UTF8.self).trimmingCharacters(in:.whitespaces)
                let name=base+(ext.isEmpty ? "":"."+ext),path=prefix+name,n=try b.le16(26),size=Int(try b.le32(28))
                if attr&16 != 0 {
                    if depth==0 && name.uppercased()=="CONFIG" {try directory(chain(n),prefix:path+"/",depth:depth+1)}
                } else if ["INI","TXT","CFG"].contains(ext.uppercased()),size>0,size<=256*1024,result.count<64 {
                    let d=try chain(n);guard size<=d.count else {throw BrowserError.truncated("設定ファイルの長さが不正です")}
                    result.append(.init(path:path,bytes:size,items:INIParser.parse(INIParser.decode(d.prefix(size)))))
                }
            }
        }
        try directory(source.read(at:rootStart,count:rootLength),prefix:"",depth:0)
        return result
    }
}
