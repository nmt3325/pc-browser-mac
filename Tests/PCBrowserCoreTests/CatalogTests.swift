import XCTest
@testable import PCBrowserCore

final class CatalogTests:XCTestCase {
    struct Spec {var record:UInt32;var root:UInt32=10;var serial:UInt32=7;var ordinal:UInt32=0;var generation:UInt32=68;var channel:UInt8=1;var start=false;var frames=2;var bits:UInt8=8;var channels:UInt8=1}
    func put(_ v:UInt32,_ o:Int,_ data:inout Data){FormatTests().put(v,o,&data)}
    func fixture(_ specs:[Spec],backlinks:Bool=false)->Data {
        var d=ExtendedTests().image();d.replaceSubrange(10*512..<d.count,with:Data(count:d.count-10*512));d[8*512+0x14]=backlinks ? 1:2
        var previous:UInt32=backlinks ? specs.last!.record+2+UInt32(specs.last!.frames-1)*5:0
        for s in specs {
            var m=Data(count:512);put(s.start ? 0xffffd103:0xffffd105,0,&m);put(s.record+1000,4,&m);put(s.record+1000,0x1fc,&m)
            put(s.root,0x1c4,&m);put(s.record,0x1e0,&m);put(s.ordinal,0x98,&m);put(s.serial,0x9c,&m);put(s.generation,0x1f8,&m)
            m[0x16]=80;m[0x18]=s.channels;m[0x19]=s.bits
            let base=Int(s.record)*512;d.replaceSubrange(base..<base+512,with:m);m[0x70]=1;d.replaceSubrange(base+512..<base+1024,with:m)
            for i in 0..<s.frames {
                let l=s.record+2+UInt32(i)*5
                var h=FormatTests().packet();put(UInt32(i),4,&h);put(UInt32(i),0x1fc,&h);put(l,0x1b0,&h);put(l+4,0x1b4,&h);put(s.record,0x1b8,&h)
                put(s.record+1000,0x1dc,&h);put(s.generation,0x1d8,&h);put(previous,0x1c0,&h);h[8]=s.channel;h[0x1d]=30
                let ordinal=Int(s.ordinal)+i;h.replaceSubrange(10..<17,with:Data([26,11,11,20,25,UInt8(20+ordinal/30),UInt8(ordinal%30)]))
                let at=Int(l)*512;d.replaceSubrange(at..<at+512,with:h);put(0xffffd102,0,&h);d.replaceSubrange(at+2048..<at+2560,with:h)
                d.replaceSubrange(at+1536..<at+1856,with:Data(repeating:UInt8(s.record),count:320));previous=l
            }
        };return d
    }
    var three:[Spec] {[Spec(record:10,start:true),Spec(record:22,ordinal:2),Spec(record:34,ordinal:4)]}
    func testThreeStorageBlocksBecomeOneContinuousRecording() throws {
        let src=MemorySource(fixture(three)),i=try CatalogScanner.scan(src),r=try XCTUnwrap(i.recordings.first)
        XCTAssertEqual(i.recordings.count,1);XCTAssertEqual(i.blockCount,3);XCTAssertEqual(i.frameCount,6);XCTAssertEqual(i.validatedFrameCount,0);XCTAssertFalse(r.isLoaded)
        let loaded=try CatalogScanner.loadRecording(r,source:src);XCTAssertEqual(loaded.packets.count,6);XCTAssertEqual(loaded.packets.map(\.recordSector),[10,10,22,22,34,34]);XCTAssertEqual(RecordingTimeline(packets:loaded.packets).duration,0.2,accuracy:1e-12)
    }
    func testCatalogReadsFewerBytesThanRecoveryWithoutPayloadReads() throws {
        let spy=ReadSpy(fixture(three)),catalog=try CatalogScanner.scan(spy);spy.calls=[]
        let full=try ImageScanner.scan(spy),read=spy.calls.reduce(0){$0+$1.1}
        XCTAssertEqual(full.frameCount,catalog.frameCount);XCTAssertLessThan(catalog.scannedBytes,UInt64(read))
    }
    func testRecoveryUsesSameSessionGrouping() throws {let i=try ImageScanner.scan(MemorySource(fixture(three)));XCTAssertEqual(i.recordings.count,1);XCTAssertEqual(i.frameCount,6);XCTAssertEqual(i.validatedFrameCount,6)}
    func testD103CanStartStreamPhaseWithoutStartingAnotherSession() throws {
        // Event-region D103 may have a nonzero cumulative ordinal and point to
        // an earlier session root; it is not necessarily a separate ignition.
        var s=three;s[1].start=true
        let i=try CatalogScanner.scan(MemorySource(fixture(s)))
        XCTAssertEqual(i.recordings.count,1);XCTAssertEqual(i.blockCount,3);XCTAssertFalse(i.recordings[0].blocks[1].metadata!.startsSession)
    }
    func testDifferentSessionSerialNeverMerges() throws {var s=three;s[1].serial=8;s[2].serial=8;XCTAssertEqual(try CatalogScanner.scan(MemorySource(fixture(s))).recordings.count,2)}
    func testDifferentChannelsNeverMerge() throws {var s=three;s[2].channel=2;XCTAssertEqual(try CatalogScanner.scan(MemorySource(fixture(s))).recordings.count,2)}
    func testChangedMediaFormatStaysSeparate() throws {var s=three;s[2].bits=16;XCTAssertEqual(try CatalogScanner.scan(MemorySource(fixture(s))).recordings.count,2)}
    func testRingWrapSortsSessionOrdinalNotPhysicalLBAOrGeneration() throws {
        let s=[Spec(record:10,root:34,ordinal:4),Spec(record:22,root:34,ordinal:2,generation:67),Spec(record:34,root:34,generation:67,start:true)]
        let src=MemorySource(fixture(s)),i=try CatalogScanner.scan(src),r=try CatalogScanner.loadRecording(XCTUnwrap(i.recordings.first),source:src)
        XCTAssertEqual(i.recordings.count,1);XCTAssertEqual(r.packets.map(\.recordSector),[34,34,22,22,10,10]);XCTAssertEqual(RecordingTimeline(packets:r.packets).duration,0.2,accuracy:1e-12)
    }
    func testBacklinksSkipWholeBlocksWithBoundedCycle() throws {
        let src=MemorySource(fixture(three,backlinks:true)),i=try CatalogScanner.scan(src)
        XCTAssertEqual(i.backlinkBlocks,3);XCTAssertEqual(i.frameCount,6);XCTAssertEqual(i.validatedFrameCount,0);XCTAssertLessThan(i.catalogReadCalls,70)
        XCTAssertEqual(try CatalogScanner.loadRecording(XCTUnwrap(i.recordings.first),source:src).packets.count,6)
    }
    func testBrokenBacklinkFallsBackToForwardHeaders() throws {
        var d=fixture(three,backlinks:true);put(13,12*512+0x1c0,&d);put(13,16*512+0x1c0,&d)
        let i=try CatalogScanner.scan(MemorySource(d));XCTAssertEqual(i.backlinkBlocks,0);XCTAssertEqual(i.blockCount,3);XCTAssertEqual(i.frameCount,6)
    }
    func testUnknownMetadataRemainsAnUnassignedFragment() throws {
        var d=fixture(three);put(999,22*512+4,&d);put(999,22*512+0x1fc,&d)
        let i=try CatalogScanner.scan(MemorySource(d));XCTAssertEqual(i.recordings.count,2);XCTAssertEqual(i.recordings.filter{!$0.hasSessionReference}.count,1)
    }
    func testCatalogDoesNotReadVideoOrPCMAndLazyLoadStaysSelected() throws {
        var s=three;s[2].serial=99;let spy=ReadSpy(fixture(s)),i=try CatalogScanner.scan(spy)
        let forbidden=Set(s.flatMap{s in (0..<s.frames).flatMap{n in (1...3).map{Int(s.record)+2+n*5+$0}}})
        XCTAssertTrue(spy.calls.allSatisfy{$0.1==512 && !forbidden.contains(Int($0.0/512))})
        XCTAssertEqual(i.scannedBytes,UInt64(spy.calls.reduce(0){$0+$1.1}));spy.calls=[]
        let r=try XCTUnwrap(i.recordings.first{ $0.blocks.count==2 });let loaded=try CatalogScanner.loadRecording(r,source:spy)
        XCTAssertEqual(loaded.packets.count,4);XCTAssertTrue(spy.calls.allSatisfy{$0.0<34*512 && !forbidden.contains(Int($0.0/512))})
    }
    func testPartialRangeCannotFollowUnavailableBacklinks() throws {
        let src=ReadSpy(fixture(three,backlinks:true),ranges:[0..<512,UInt64(8*512)..<UInt64(34*512)]),i=try CatalogScanner.scan(src)
        XCTAssertTrue(i.isPartialScan);XCTAssertEqual(i.blockCount,2);XCTAssertEqual(i.frameCount,4);XCTAssertTrue(src.calls.allSatisfy{$0.0<34*512})
    }
    func testCorruptMiddlePacketDetectedDuringLazyLoad() throws {
        let s=[Spec(record:10,start:true,frames:3)];var d=fixture(s,backlinks:true);d[21*512+10]=25
        let src=MemorySource(d),i=try CatalogScanner.scan(src);XCTAssertEqual(i.frameCount,3);XCTAssertEqual(i.validatedFrameCount,0)
        XCTAssertThrowsError(try CatalogScanner.loadRecording(XCTUnwrap(i.recordings.first),source:src))
    }
    func testCancellationStopsCatalogAndSelection() throws {
        let src=MemorySource(fixture(three));XCTAssertThrowsError(try CatalogScanner.scan(src,cancelled:{true}))
        let i=try CatalogScanner.scan(src);XCTAssertThrowsError(try CatalogScanner.loadRecording(XCTUnwrap(i.recordings.first),source:src,cancelled:{true}))
    }
    func testAudioTrimsPerBlockTailRatherThanAccumulatingDrift() throws {
        let s=[Spec(record:10,start:true,frames:1),Spec(record:17,ordinal:1,frames:1)],src=MemorySource(fixture(s)),i=try ImageScanner.scan(src),r=try XCTUnwrap(i.recordings.first)
        let a=try AudioClip.load(source:src,packets:r.packets,format:PCMFormat())
        XCTAssertEqual(a.samples,Data(repeating:10,count:267)+Data(repeating:17,count:320))
    }
    func testAudioPadsSignedStereoPCMWithZeroSilence() throws {
        let s=[Spec(record:10,start:true,frames:1,bits:16,channels:2),Spec(record:17,ordinal:1,frames:1,bits:16,channels:2)],src=MemorySource(fixture(s)),r=try XCTUnwrap(ImageScanner.scan(src).recordings.first)
        let a=try AudioClip.load(source:src,packets:r.packets,format:PCMFormat(channels:2,bitsPerSample:16))
        XCTAssertEqual(a.samples,Data(repeating:10,count:320)+Data(repeating:0,count:748)+Data(repeating:17,count:320));XCTAssertEqual(a.samples.count%4,0)
    }
    func testAudioPadsUnsignedPCMWith128AndCanCancel() throws {
        let s=[Spec(record:10,start:true,frames:1),Spec(record:17,ordinal:30,frames:1)],src=MemorySource(fixture(s)),r=try XCTUnwrap(ImageScanner.scan(src).recordings.first)
        let a=try AudioClip.load(source:src,packets:r.packets,format:PCMFormat())
        XCTAssertEqual(a.samples,Data(repeating:10,count:320)+Data(repeating:128,count:7680)+Data(repeating:17,count:320))
        XCTAssertThrowsError(try AudioClip.load(source:src,packets:r.packets,format:PCMFormat(),cancelled:{true}))
    }
    func testBackupPreservesEveryMergedBlockAndDeferredHashChecksTamper() throws {
        let src=MemorySource(fixture(three)),i=try ImageScanner.scan(src),r=try XCTUnwrap(i.recordings.first),u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pcbbackup")
        defer{try? FileManager.default.removeItem(at:u)}
        try ArchiveWriter.write(source:src,index:i,recordings:[r],name:"Synthetic merged session",to:u)
        let copy=try ArchiveSource(url:u,verifyHash:false);XCTAssertFalse(copy.isHashVerified)
        let catalog=try CatalogScanner.scan(copy);XCTAssertEqual(catalog.recordings.count,1);XCTAssertEqual(catalog.blockCount,3);XCTAssertEqual(catalog.frameCount,6)
        let detail=try CatalogScanner.loadRecording(XCTUnwrap(catalog.recordings.first),source:copy)
        XCTAssertEqual(detail.packets.count,6);XCTAssertEqual(try PCMFormat.recordFormat(source:copy,recording:detail),PCMFormat())
        try copy.verifyPayload();XCTAssertTrue(copy.isHashVerified)
        let handle=try FileHandle(forWritingTo:u.appendingPathComponent("payload.bin"));try handle.seek(toOffset:100);try handle.write(contentsOf:Data([9]));try handle.close()
        let tampered=try ArchiveSource(url:u,verifyHash:false);XCTAssertThrowsError(try tampered.verifyPayload());XCTAssertFalse(tampered.isHashVerified)
    }
    func testUnloadedSummaryCannotSilentlyCreateEmptyBackup() throws {
        let src=MemorySource(fixture(three)),i=try CatalogScanner.scan(src),u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pcbbackup")
        XCTAssertThrowsError(try ArchiveWriter.write(source:src,index:i,recordings:i.recordings,name:"Synthetic",to:u));XCTAssertFalse(FileManager.default.fileExists(atPath:u.path))
    }
}
private final class ReadSpy:ByteSource,@unchecked Sendable {
    let data:Data,ranges:[Range<UInt64>]?
    var calls:[(UInt64,Int)]=[]
    init(_ data:Data,ranges:[Range<UInt64>]?=nil){self.data=data;self.ranges=ranges}
    var byteCount:UInt64{UInt64(data.count)}
    var scanRanges:[Range<UInt64>]?{ranges}
    var isPartialCopy:Bool{ranges != nil}
    func read(at offset:UInt64,count:Int)throws->Data{calls.append((offset,count));return try MemorySource(data).read(at:offset,count:count)}
}
