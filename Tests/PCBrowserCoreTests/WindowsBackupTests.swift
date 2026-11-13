import XCTest
import CryptoKit
@testable import PCBrowserCore

final class WindowsBackupTests: XCTestCase {
    func put64(_ v:UInt64,_ o:Int,_ d:inout Data) { for i in 0..<8 { d[o+i]=UInt8(truncatingIfNeeded:v>>(i*8)) } }
    /// Independent format fixture, not a round trip through a production writer.
    /// Key bytes are explicit values from independent constructor/live evidence.
    func fixture(keyIndex:UInt8=0x7a,key:UInt8=0,ranges:[Range<Int>]=[0..<512,8*512..<46*512],reversed:Bool=false) -> Data {
        let image=CatalogTests().fixture(CatalogTests().three)
        let ranges=reversed ? Array(ranges.reversed()):ranges
        let tableEnd=48+ranges.count*32
        var d=Data(count:tableEnd+ranges.reduce(0){$0+$1.count})
        d.replaceSubrange(0..<12,with:Data("BDRBACKUP___".utf8));d[12]=1;d[22]=keyIndex
        put64(UInt64(ranges.count),24,&d);put64(UInt64(d.count),32,&d)
        var stored=tableEnd
        for (i,r) in ranges.enumerated() {
            var entry=Data(count:32)
            put64(UInt64(r.lowerBound),0,&entry);put64(UInt64(r.upperBound-1),8,&entry)
            put64(UInt64(stored),16,&entry);put64(UInt64(r.count),24,&entry)
            d.replaceSubrange(48+i*32..<80+i*32,with:entry.map{$0 ^ key})
            d.replaceSubrange(stored..<stored+r.count,with:image[r].map{$0 ^ key});stored+=r.count
        }
        return d
    }
    func testConstructorTableMatchesIndependentDigestAndKeyBytes() {
        XCTAssertEqual(WindowsBackupSource.xorTable.count,256)
        XCTAssertEqual(SHA256.hash(data:Data(WindowsBackupSource.xorTable)).map{String(format:"%02x",$0)}.joined(),"5bf74ee875ed4b81706351ef3e2faf677d16d78c9d1245494619f91952726ff4")
        XCTAssertEqual(WindowsBackupSource.xorTable[0x7a],0);XCTAssertEqual(WindowsBackupSource.xorTable[0],0xfe)
        XCTAssertEqual(WindowsBackupSource.xorTable[1],0x3a);XCTAssertEqual(WindowsBackupSource.xorTable[255],0xe2)
    }
    func testPlainBackupCatalogAndContinuousLazyDetail() throws {
        let s=try WindowsBackupSource(storage:MemorySource(fixture())),i=try CatalogScanner.scan(s)
        XCTAssertTrue(s.isPartialCopy);XCTAssertTrue(i.isPartialScan);XCTAssertEqual(i.recordings.count,1)
        XCTAssertEqual(i.frameCount,6);XCTAssertEqual(i.blockCount,3);XCTAssertEqual(i.validatedFrameCount,0)
        let r=try CatalogScanner.loadRecording(XCTUnwrap(i.recordings.first),source:s)
        XCTAssertEqual(r.packets.count,6);XCTAssertEqual(r.packets.map(\.recordSector),[10,10,22,22,34,34])
        let audio=try AudioClip.load(source:s,packets:r.packets,format:PCMFormat())
        XCTAssertEqual(audio.samples.prefix(267),Data(repeating:10,count:267))
    }
    func testEveryByteUsesOneFixedXORByteNotRollingKey() throws {
        for (index,key) in [(UInt8(0),UInt8(0xfe)),(1,0x3a),(0x7a,0),(255,0xe2)] {
            let s=try WindowsBackupSource(storage:MemorySource(fixture(keyIndex:index,key:key)))
            XCTAssertEqual(try s.read(at:8*512,count:38*512),CatalogTests().fixture(CatalogTests().three).subdata(in:8*512..<46*512))
            XCTAssertEqual(try CatalogScanner.scan(s).frameCount,6)
        }
    }
    func testNonMonotonicTableStorageOrderIsSortedByVirtualAddress() throws {
        let s=try WindowsBackupSource(storage:MemorySource(fixture(reversed:true)))
        XCTAssertEqual(s.extents.map(\.sourceOffset),[UInt64(0),UInt64(8*512)]);XCTAssertEqual(try CatalogScanner.scan(s).frameCount,6)
    }
    func testMissingRangesAreZerosAndReadsCrossExtentBoundaries() throws {
        let s=try WindowsBackupSource(storage:MemorySource(fixture())),d=CatalogTests().fixture(CatalogTests().three)
        XCTAssertEqual(try s.read(at:512,count:7*512),Data(count:7*512))
        var expected=d.subdata(in:500..<512);expected.append(Data(count:7*512));expected.append(d.subdata(in:8*512..<8*512+37))
        XCTAssertEqual(try s.read(at:500,count:expected.count),expected)
        XCTAssertEqual(s.scanRanges,[UInt64(0)..<512,UInt64(8*512)..<UInt64(46*512)])
    }
    func testHeaderStoredLengthIsNeverUsedAsVirtualDiskCapacity() throws {
        var d=fixture();put64(UInt64.max,32,&d)
        let s=try WindowsBackupSource(storage:MemorySource(d))
        XCTAssertEqual(s.byteCount,46*512);XCTAssertEqual(s.headerStoredBytes,UInt64.max)
        XCTAssertEqual(s.storedByteCount,UInt64(d.count))
    }
    func testTypeZeroRecordingPartitionOnlyExpandsAddressableSpan() throws {
        var d=fixture();let stored=48+2*32
        // Second partition is proprietary: type zero but nonzero first/count.
        ExtendedTests().put(8,stored+470,&d);ExtendedTests().put(992,stored+474,&d)
        let s=try WindowsBackupSource(storage:MemorySource(d));XCTAssertEqual(s.byteCount,1000*512)
        XCTAssertTrue(s.isPartialCopy);XCTAssertEqual(try s.read(at:999*512,count:512),Data(count:512))
    }
    func testMalformedHeaderCountAndVersionRejected() {
        for field in [0,12] {var d=fixture();d[field]=0;XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)))}
        for n:UInt64 in [0,262145,UInt64.max] {var d=fixture();put64(n,24,&d);XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)))}
        var d=fixture();put64(1000,24,&d);XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)))
    }
    func testSplitPartReferenceExplicitlyRefused() {
        var d=fixture();put64(0x0100000000000070,48+16,&d)
        XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d))) { error in
            XCTAssertTrue(error.localizedDescription.contains("分割BAK"))
        }
    }
    func testMalformedExtentBoundsOverlapAndLengthsRejected() {
        let mutations:[(Int,UInt64)]=[(48,1),(56,510),(64,0),(72,0),(72,513),(48,UInt64.max-511),(56,UInt64.max),(80,0),(96,112)]
        for (o,v) in mutations {var d=fixture();put64(v,o,&d);XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)),"offset \(o), value \(v)")}
        var d=fixture();d.removeLast();XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)))
    }
    func testMissingOrInvalidMBRAndWrongXORRejected() {
        var d=fixture();d[112+510]=0;XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)))
        d=fixture();d[22]=0;XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)))
        d=fixture();put64(512,48,&d);put64(1023,56,&d);XCTAssertThrowsError(try WindowsBackupSource(storage:MemorySource(d)))
    }
    func testReadBoundsAndPartialImageCopyRefusal() throws {
        let s=try WindowsBackupSource(storage:MemorySource(fixture()))
        XCTAssertThrowsError(try s.read(at:UInt64.max,count:1));XCTAssertThrowsError(try s.read(at:0,count:-1))
        XCTAssertThrowsError(try s.read(at:0,count:64*1024*1024+1));XCTAssertThrowsError(try s.read(at:s.byteCount,count:1))
        XCTAssertEqual(try s.read(at:s.byteCount,count:0),Data())
        let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".img")
        defer {try? FileManager.default.removeItem(at:u)}
        XCTAssertThrowsError(try ImageCopy.write(source:s,to:u));XCTAssertFalse(FileManager.default.fileExists(atPath:u.path))
    }
    func testAutoDetectionImmutabilityRawFallbackAndSymlinkRefusal() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:dir)}
        let u=dir.appendingPathComponent("source.bak"),d=fixture();try d.write(to:u)
        let s=try SourceOpener.open(u);XCTAssertTrue(s is WindowsBackupSource)
        XCTAssertEqual(try CatalogScanner.scan(s).frameCount,6);XCTAssertEqual(try Data(contentsOf:u),d)
        let noExtension=dir.appendingPathComponent("source");try d.write(to:noExtension);XCTAssertTrue(try SourceOpener.open(noExtension) is WindowsBackupSource)
        let raw=dir.appendingPathComponent("raw.img");try CatalogTests().fixture(CatalogTests().three).write(to:raw);XCTAssertTrue(try SourceOpener.open(raw) is FileByteSource)
        let invalid=dir.appendingPathComponent("invalid.bak");try Data(count:512).write(to:invalid);XCTAssertThrowsError(try SourceOpener.open(invalid))
        let link=dir.appendingPathComponent("link.bak");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:u);XCTAssertThrowsError(try SourceOpener.open(link))
    }
    func testOpeningAndCatalogNeverReadVideoOrPCM() throws {
        final class Spy:ByteSource,@unchecked Sendable {
            let data:Data;var calls:[(UInt64,Int)]=[];var byteCount:UInt64{UInt64(data.count)}
            init(_ data:Data){self.data=data}
            func read(at o:UInt64,count:Int)throws->Data{calls.append((o,count));return try MemorySource(data).read(at:o,count:count)}
        }
        let spy=Spy(fixture()),s=try WindowsBackupSource(storage:spy);_ = try CatalogScanner.scan(s)
        let payload=48+2*32,sourceStart=8*512,storageStart=payload+512
        let forbidden=Set(CatalogTests().three.flatMap{spec in (0..<spec.frames).flatMap{n in (1...3).map{Int(spec.record)+2+n*5+$0}}})
        for (offset,count) in spy.calls where offset>=UInt64(storageStart) {
            XCTAssertEqual(count,512)
            let virtualSector=(Int(offset)-storageStart+sourceStart)/512;XCTAssertFalse(forbidden.contains(virtualSector))
        }
    }
}
