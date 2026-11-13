import Foundation

/// Read-only, single-part BDRBACKUP___ adapter recovered from PC Browser 1.9.60.0.
/// Extents describe available virtual disk bytes, not an acquired whole disk.
/// In particular header[32] is a stored-file cursor/length, NEVER disk capacity.
/// A BAK has no established cryptographic integrity field; XOR is not authentication.
public final class WindowsBackupSource: ByteSource, @unchecked Sendable {
    public static let magic = Data("BDRBACKUP___".utf8)
    public let byteCount: UInt64
    public let extents: [ArchiveSegment]
    public let keyIndex: UInt8
    public let headerStoredBytes: UInt64
    public var storedByteCount: UInt64 { storage.byteCount }
    public var isPartialCopy: Bool { true }
    public var scanRanges: [Range<UInt64>]? { extents.map { $0.sourceOffset..<($0.sourceOffset+$0.length) } }
    private let storage: any ByteSource
    private let xorByte: UInt8
    // IO constructor VA 488760: 64 LE DWORD stores, independently matched in
    // the original process; SHA256 5bf74ee875ed4b81706351ef3e2faf677d16d78c9d1245494619f91952726ff4.
    static let xorTable: [UInt8] = [
        0xfe,0x3a,0x91,0x57,0xd1,0x71,0x1b,0x6d,0xb7,0x88,0xbb,0x20,0x24,0xf2,0xa4,0x2b,
        0xf4,0xee,0xb0,0x4c,0xff,0xc1,0x9a,0xa6,0x42,0x64,0x4d,0x9c,0x3c,0x9f,0xe1,0x50,
        0x14,0x81,0x3b,0x79,0x2f,0xab,0x8d,0x54,0x6a,0xd5,0xbd,0xf9,0xb4,0xb8,0x5a,0x21,
        0x09,0x0b,0x87,0x77,0xaa,0x7e,0x70,0x3d,0x19,0x2c,0xa8,0x05,0xaf,0xe3,0x5f,0x93,
        0x2e,0x28,0x90,0x99,0xc0,0x7b,0x48,0x75,0x56,0x69,0x16,0x40,0x82,0x76,0x86,0xef,
        0x5c,0xc9,0xfa,0x11,0xfc,0x04,0xd3,0xd7,0xed,0xda,0x22,0x10,0x26,0x4a,0xb6,0x67,
        0xce,0x66,0xe6,0x61,0xf1,0x6f,0x45,0xae,0xa1,0x8f,0x97,0x9b,0xf0,0x95,0xd6,0xc5,
        0x72,0x60,0x07,0xf7,0x23,0x1e,0x5b,0x47,0x30,0xdd,0x00,0x08,0x92,0xec,0x0f,0x7c,
        0x96,0xa7,0xd2,0x2d,0xdc,0x59,0xe9,0x78,0x01,0xb5,0x89,0x6e,0x37,0x83,0x0e,0xfd,
        0x17,0x84,0xbf,0xba,0x1c,0x7d,0x33,0x46,0x63,0x32,0x74,0xc8,0x2a,0x68,0x51,0x5e,
        0x3e,0x98,0x49,0xc3,0xa3,0x03,0x18,0x5d,0xe5,0x38,0x0c,0xe0,0xc6,0xcd,0xb2,0x12,
        0x31,0x58,0x8c,0xea,0xbe,0x8a,0xac,0x3f,0xb3,0x7f,0xde,0xcc,0x6c,0xa0,0x94,0xca,
        0x1d,0x27,0x52,0xd9,0x34,0x85,0x06,0x62,0xe8,0x80,0xcb,0x15,0xa2,0x53,0xc2,0xdb,
        0x41,0xf6,0xb1,0x02,0x0a,0x55,0xfb,0x1a,0x9e,0x35,0xbc,0x13,0x8e,0x4e,0xa9,0x36,
        0xf3,0x73,0x7a,0x44,0xf5,0xad,0xe4,0xf8,0x1f,0xe7,0x29,0x65,0xa5,0xd8,0xeb,0xc7,
        0x4b,0xb9,0xdf,0x4f,0x43,0xd4,0x9d,0x25,0xcf,0x39,0x0d,0xc4,0xd0,0x6b,0x8b,0xe2,
    ]
    public convenience init(url: URL) throws { try self.init(storage: FileByteSource(url: url)) }
    public init(storage: any ByteSource) throws {
        guard storage.byteCount >= 512, !storage.isPartialCopy else { throw BrowserError.invalid("BAKファイルが短すぎるか、入力が不正です") }
        let header = try storage.read(at: 0, count: 48), b = Bytes(header)
        guard header.prefix(12) == Self.magic else { throw BrowserError.invalid("BDRBACKUP___の署名がありません") }
        guard try b.le32(12) == 1 else { throw BrowserError.unsupported("このBAKヘッダー形式には対応していません") }
        let keyIndex = try b.u8(22), key = Self.xorTable[Int(keyIndex)]
        let n = try Self.le64(header, 24)
        guard n > 0, n <= 262144 else { throw BrowserError.invalid("BAKのセグメント数が不正または上限を超えています") }
        let tableEnd = 48+n*32
        guard tableEnd <= storage.byteCount else { throw BrowserError.truncated("BAKのセグメント表が途中で終わっています") }
        let table = Self.transform(try storage.read(at:48,count:Int(n*32)), key:key)
        var extents: [ArchiveSegment] = []
        for i in 0..<Int(n) {
            let o=i*32, start=try Self.le64(table,o), last=try Self.le64(table,o+8)
            let packed=try Self.le64(table,o+16), length=try Self.le64(table,o+24)
            guard packed >> 56 == 0 else { throw BrowserError.unsupported("分割BAKの追加ファイル参照は未検証です。単一ファイルのBAKを選択してください") }
            let stored=packed & 0x00ffffffffffffff
            guard length > 0, length % 512 == 0, start % 512 == 0,
                  start <= UInt64(Int64.max), length <= UInt64(Int64.max)-start,
                  last >= start, last-start == length-1,
                  stored >= tableEnd, stored <= storage.byteCount, length <= storage.byteCount-stored else {
                throw BrowserError.invalid("BAKのセグメント範囲・長さが不正です")
            }
            extents.append(.init(sourceOffset:start,length:length,storageOffset:stored))
        }
        extents.sort { $0.sourceOffset < $1.sourceOffset }
        var virtualEnd: UInt64 = 0
        for e in extents {
            guard e.sourceOffset >= virtualEnd else { throw BrowserError.invalid("BAKの仮想領域が重複しています") }
            virtualEnd=e.sourceOffset+e.length
        }
        var storedEnd=tableEnd
        for e in extents.sorted(by: { $0.storageOffset < $1.storageOffset }) {
            guard e.storageOffset >= storedEnd else { throw BrowserError.invalid("BAKの格納領域が重複しています") }
            storedEnd=e.storageOffset+e.length
        }
        guard let mbrExtent=extents.first, mbrExtent.sourceOffset==0, mbrExtent.length>=512 else { throw BrowserError.invalid("BAKにMBRが含まれていません") }
        let mbr=Self.transform(try storage.read(at:mbrExtent.storageOffset,count:512),key:key), mb=Bytes(mbr)
        guard try mb.le16(510)==0xaa55 else { throw BrowserError.invalid("BAKのMBR署名が不正です") }
        // Include the proprietary type-zero recording-area entry, if present.
        // This is only an addressable span, never evidence of whole-card coverage.
        for i in 0..<4 {
            let o=446+i*16, first=UInt64(try mb.le32(o+8)), count=UInt64(try mb.le32(o+12))
            if count > 0 { virtualEnd=max(virtualEnd,(first+count)*512) }
        }
        _ = try PartitionTable.parse(mbr,diskBytes:virtualEnd)
        self.storage=storage;self.byteCount=virtualEnd;self.extents=extents;self.keyIndex=keyIndex;self.xorByte=key
        self.headerStoredBytes=try Self.le64(header,32)
    }
    private static func le64(_ d:Data,_ o:Int) throws -> UInt64 {
        let b=Bytes(d);var v:UInt64=0
        for i in 0..<8 { v |= UInt64(try b.u8(o+i)) << (i*8) };return v
    }
    private static func transform(_ data:Data,key:UInt8) -> Data {
        key==0 ? data:Data(data.map { $0 ^ key })
    }
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count>=0,count<=64*1024*1024,offset<=byteCount,UInt64(count)<=byteCount-offset else { throw BrowserError.truncated("BAKの読み取り範囲が不正です") }
        var out=Data(count:count)
        let end=offset+UInt64(count)
        var low=0,high=extents.count
        while low<high {
            let mid=(low+high)/2,e=extents[mid]
            if e.sourceOffset+e.length<=offset { low=mid+1 } else { high=mid }
        }
        for e in extents.dropFirst(low) {
            if e.sourceOffset>=end { break }
            let lo=max(offset,e.sourceOffset),hi=min(end,e.sourceOffset+e.length)
            let data=Self.transform(try storage.read(at:e.storageOffset+lo-e.sourceOffset,count:Int(hi-lo)),key:xorByte)
            out.replaceSubrange(Int(lo-offset)..<Int(hi-offset),with:data)
        }
        return out
    }
}
