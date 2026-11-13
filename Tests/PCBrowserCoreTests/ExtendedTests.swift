import XCTest
@testable import PCBrowserCore

final class ExtendedTests: XCTestCase {
    func put(_ v:UInt32,_ at:Int,_ d:inout Data) { for i in 0..<4 {d[at+i]=UInt8(truncatingIfNeeded:v>>(i*8))} }
    func image() -> Data {
        var d=Data(count:100*512);d[510]=0x55;d[511]=0xaa;d[450]=6;put(1,454,&d);put(7,458,&d)
        let marker=Data("YP_FORMAT_1.01__\0".utf8)
        d.replaceSubrange((8*512+1)..<(8*512+18),with:marker);d.replaceSubrange((8*512+0x1ec)..<(8*512+0x1fd),with:marker);put(10,8*512+0x1be,&d)
        var rec=Data(count:512);put(0xffffd105,0,&rec);rec[0x16]=80;rec[0x18]=1;rec[0x19]=8
        d.replaceSubrange(10*512..<11*512,with:rec);d.replaceSubrange(11*512..<12*512,with:rec)
        var h=FormatTests().packet();put(12,0x1b0,&h);put(16,0x1b4,&h);put(10,0x1b8,&h);h[0x1d]=30;h[0x10]=4;h[0x26]=7;h[0x27]=1
        put(35*600000,0x28,&h);put(139*600000,0x2c,&h);put(1000,0x32,&h);h[0x46]=0xff;h[0x47]=0xff
        d.replaceSubrange(12*512..<13*512,with:h);put(0xffffd102,0,&h);d.replaceSubrange(16*512..<17*512,with:h)
        d.replaceSubrange(15*512..<15*512+320,with:Data(repeating:128,count:320));return d
    }
    func recording() throws -> (MemorySource,ImageIndex,Recording) {let src=MemorySource(image()),index=try ImageScanner.scan(src);return(src,index,try XCTUnwrap(index.recordings.first))}
    func testFastScanFindsOnlyValidatedPair() throws {let(_,i,_)=try recording();XCTAssertEqual(i.frameCount,1);XCTAssertEqual(i.rejectedCandidates,0);XCTAssertFalse(i.isPartialScan)}
    func testCardClockIsFrameSlotNotCentiseconds() throws {let(_,_,r)=try recording();let t=try XCTUnwrap(r.packets[0].telemetry.clock);XCTAssertEqual(t.frameSlot,4);XCTAssertEqual(t.nominalFPS,30);XCTAssertEqual(t.linearSeconds-floor(t.linearSeconds),4.0/30,accuracy:0.000001)}
    func testCardClockRejectsImpossibleDate() {var d=Data([24,2,30,12,0,0,0]);XCTAssertNil(CardTimestamp.parse(d,offset:0));d[2]=29;XCTAssertNotNil(CardTimestamp.parse(d,offset:0))}
    func testCardClockRejectsImpossibleSlot() {XCTAssertNil(CardTimestamp.parse(Data([24,1,1,0,0,0,31]),offset:0,fps:30))}
    func testSpeedScaleAndSignedAcceleration() throws {let(_,_,r)=try recording();XCTAssertEqual(r.packets[0].telemetry.speedKMH,36);XCTAssertEqual(r.packets[0].telemetry.accelerationRaw[0],-1)}
    func testGPSUnitsAndWGSOverride() {let c=DeviceGeodesy.coordinate(latitude:35*600000,longitude:139*600000,altitudeRaw:0,datum:.wgs84);XCTAssertEqual(c?.latitude,35);XCTAssertEqual(c?.longitude,139)}
    func testGPSInvalidZeroAndOutOfRange() {XCTAssertNil(DeviceGeodesy.coordinate(latitude:0,longitude:0,altitudeRaw:0,datum:.deviceTokyo));XCTAssertNil(DeviceGeodesy.coordinate(latitude:91*600000,longitude:139*600000,altitudeRaw:0,datum:.deviceTokyo))}
    func testGPSDeviceDatumTranslation() throws {let c=try XCTUnwrap(DeviceGeodesy.coordinate(latitude:35*600000,longitude:139*600000,altitudeRaw:0,datum:.deviceTokyo));XCTAssertGreaterThan(c.latitude,35.002);XCTAssertLessThan(c.latitude,35.005);XCTAssertGreaterThan(c.longitude,138.995);XCTAssertLessThan(c.longitude,138.999)}
    func testPCMReadFromRecordHeader() throws {let(src,_,r)=try recording();XCTAssertEqual(try PCMFormat.recordFormat(source:src,recording:r),PCMFormat())}
    func testPCMAndWAVExtraction() throws {let(src,_,r)=try recording();let clip=try AudioClip.load(source:src,packets:r.packets,format:PCMFormat());XCTAssertEqual(clip.samples,Data(repeating:128,count:320));XCTAssertEqual(clip.duration,0.04,accuracy:1e-12);let wav=try clip.wav();XCTAssertEqual(wav.count,364);XCTAssertEqual(try Bytes(wav).ascii(0,4),"RIFF");XCTAssertEqual(try Bytes(wav).le32(24),8000);XCTAssertEqual(try Bytes(wav).le16(34),8)}
    func testWAVRange() throws {let clip=AudioClip(samples:Data(repeating:128,count:8000),format:.init());XCTAssertEqual(try clip.wav(range:0.25..<0.75).count,4044);XCTAssertThrowsError(try clip.wav(range:0..<2))}
    func testUnsupportedAudioFormatRefused() {XCTAssertFalse(PCMFormat(sampleRate:1234).valid);XCTAssertFalse(PCMFormat(bitsPerSample:24).valid)}
    func testTimelineBounds() throws {let(_,_,r)=try recording();let t=RecordingTimeline(packets:r.packets);XCTAssertEqual(t.frame(at:-10),0);XCTAssertEqual(t.frame(at:100),0);XCTAssertEqual(t.duration,1.0/30,accuracy:0.000001)}
    func clockPackets(_ clocks:[(Int,Int)]) throws -> [FramePacket] {
        try clocks.map { second,slot in
            var h=FormatTests().packet()
            h.replaceSubrange(10..<17,with:Data([26,11,11,20,25,UInt8(second),UInt8(slot)]));h[0x1d]=30
            return try FramePacket.parse(h,sector:10,diskBytes:100*512)
        }
    }
    func testClockDifferenceAvoidsEpochCancellation() throws {
        let a=try XCTUnwrap(CardTimestamp.parse(Data([26,11,11,20,25,20,4]),offset:0))
        let b=try XCTUnwrap(CardTimestamp.parse(Data([26,11,11,20,25,21,5]),offset:0))
        XCTAssertEqual(b.seconds(since:a),1+1.0/30,accuracy:1e-14)
    }
    func testClockDifferenceAcrossYearBoundary() throws {
        let a=try XCTUnwrap(CardTimestamp.parse(Data([26,12,31,23,59,59,29]),offset:0))
        let b=try XCTUnwrap(CardTimestamp.parse(Data([27,1,1,0,0,0,0]),offset:0))
        XCTAssertEqual(b.seconds(since:a),1.0/30,accuracy:1e-14)
    }
    func testDuplicateBoundarySlotsRemainSeparatedAtMediaTimescale() throws {
        // Includes the observed 30 -> 0 boundary and hundreds of later samples.
        let packets=try clockPackets((0..<900).map { n in (20+(n+4)/31,(n+4)%31) })
        let t=RecordingTimeline(packets:packets)
        XCTAssertEqual(t.starts[0],0);XCTAssertEqual(t.duration,30,accuracy:1e-9)
        let ticks=t.starts.map { Int64(($0*60000).rounded()) }
        for i in 1..<ticks.count {
            XCTAssertGreaterThanOrEqual(t.starts[i]-t.starts[i-1],1.0/30-1e-12)
            XCTAssertGreaterThan(ticks[i],ticks[i-1])
        }
    }
    func testTimelinePreservesPositiveCardClockGap() throws {
        let t=RecordingTimeline(packets:try clockPackets([(20,0),(20,1),(22,0)]))
        XCTAssertTrue(t.usedCardClock);XCTAssertEqual(t.starts[2],2,accuracy:1e-12)
    }
    func testTimelineRepairsBackwardsClock() throws {
        let t=RecordingTimeline(packets:try clockPackets([(21,0),(20,0),(20,1)]))
        XCTAssertFalse(t.usedCardClock);XCTAssertEqual(t.duration,0.1,accuracy:1e-12)
    }
    func testTrackXMLIsEscapedAndNoInventedUTC() throws {let(_,_,r)=try recording();let k=TrackExport.kml([r],name:"A&B<test>");XCTAssertTrue(k.contains("A&amp;B&lt;test&gt;"));XCTAssertTrue(k.contains("LineString"));XCTAssertFalse(k.contains("<when>"));let g=TrackExport.gpx([r]);XCTAssertTrue(g.contains("<trkpt "));XCTAssertFalse(g.contains("<time>"))}
    func testCSVHasRawSensorUnits() throws {let(_,_,r)=try recording();let c=TrackExport.csv([r]);XCTAssertTrue(c.contains("accel_x_raw"));XCTAssertTrue(c.contains("card_wall_time"));XCTAssertEqual(c.components(separatedBy:"\r\n").count,3)}
    func testProjectionCenterAndRay() throws {let ray=ProjectionMath.perspectiveRay(u:0.5,v:0.5,aspect:16.0/9,fov:100,yaw:0,pitch:0);XCTAssertEqual(ray,SIMD3(0,0,1));let p=try XCTUnwrap(ProjectionMath.sourceCoordinate(ray:ray,width:2560,height:1080,settings:.init()));XCTAssertEqual(p.x,640,accuracy:1e-8);XCTAssertEqual(p.y,540,accuracy:1e-8)}
    func testProjectionRearCenter() throws {let p=try XCTUnwrap(ProjectionMath.sourceCoordinate(ray:SIMD3(0,0,-1),width:2560,height:1080,settings:.init()));XCTAssertEqual(p.x,1920,accuracy:1e-8);XCTAssertEqual(p.y,540,accuracy:1e-8)}
    func testProjectionClampsNonfiniteSettings() {var s=ProjectionSettings();s.yaw = .nan;s.rawZoom = .infinity;s.lensFOV=900;XCTAssertEqual(s.clamped.yaw,0);XCTAssertEqual(s.clamped.rawZoom,1);XCTAssertEqual(s.clamped.lensFOV,220)}
    func testArchiveRoundTripAndImmutability() throws {
        let(src,index,r)=try recording(),before=src.data,u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pcbbackup")
        defer {try? FileManager.default.removeItem(at:u)}
        try ArchiveWriter.write(source:src,index:index,recordings:[r],name:"Synthetic",to:u)
        let copy=try ArchiveSource(url:u);XCTAssertEqual(copy.byteCount,src.byteCount);XCTAssertTrue(copy.isPartialCopy)
        XCTAssertEqual(try copy.read(at:12*512,count:5*512),try src.read(at:12*512,count:5*512));XCTAssertEqual(try copy.read(at:20*512,count:512),Data(count:512))
        let i=try ImageScanner.scan(copy);XCTAssertEqual(i.frameCount,1);XCTAssertTrue(i.isPartialScan);XCTAssertEqual(src.data,before)
        XCTAssertEqual(try PCMFormat.recordFormat(source:copy,recording:r),PCMFormat());XCTAssertThrowsError(try ArchiveWriter.write(source:src,index:index,recordings:[r],name:"Synthetic",to:u))
    }
    func testArchiveTamperingDetected() throws {
        let(src,index,r)=try recording(),u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pcbbackup");defer{try? FileManager.default.removeItem(at:u)}
        try ArchiveWriter.write(source:src,index:index,recordings:[r],name:"Synthetic",to:u)
        let h=try FileHandle(forWritingTo:u.appendingPathComponent("payload.bin"));try h.seek(toOffset:100);try h.write(contentsOf:Data([4]));try h.close();XCTAssertThrowsError(try ArchiveSource(url:u))
    }
    func testCancelledBackupLeavesNoDestination() throws {let(src,index,r)=try recording(),u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pcbbackup");XCTAssertThrowsError(try ArchiveWriter.write(source:src,index:index,recordings:[r],name:"Synthetic",to:u,cancelled:{true}));XCTAssertFalse(FileManager.default.fileExists(atPath:u.path))}
    func testRejectsMismatchedMirror() throws {var d=image();d[16*512+10]=25;let i=try ImageScanner.scan(MemorySource(d));XCTAssertEqual(i.frameCount,0);XCTAssertEqual(i.rejectedCandidates,1)}
    func fatImage() -> Data {
        var d=Data(count:64*512);d[510]=0x55;d[511]=0xaa;d[450]=6;put(1,454,&d);put(63,458,&d)
        let b=512;d[b+11]=0;d[b+12]=2;d[b+13]=1;d[b+14]=1;d[b+16]=1;d[b+17]=16;d[b+22]=1
        // One FAT sector, one root sector; data clusters 2/3 at sectors 4/5.
        d[2*512+4]=0xff;d[2*512+5]=0xff;d[2*512+6]=0xff;d[2*512+7]=0xff
        d.replaceSubrange(3*512..<3*512+11,with:Data("CONFIG     ".utf8));d[3*512+11]=16;d[3*512+26]=2
        let text=Data("[VERSION]\nSoftware=1.2\nPASSWORD=secret\n".utf8)
        d.replaceSubrange(4*512..<4*512+11,with:Data("VERSION INI".utf8));d[4*512+26]=3;put(UInt32(text.count),4*512+28,&d)
        d.replaceSubrange(5*512..<5*512+text.count,with:text);return d
    }
    func testReadOnlyFAT16SettingsAndRedaction() throws {
        let d=fatImage(),src=MemorySource(d),files=try CardSettingsReader.read(src)
        XCTAssertEqual(files.count,1);XCTAssertEqual(files.first?.path,"CONFIG/VERSION.INI")
        XCTAssertTrue(files[0].items.contains{$0.key=="Software" && $0.displayValue=="1.2"})
        XCTAssertFalse(files[0].items.contains{$0.displayValue=="secret"});XCTAssertEqual(src.data,d)
    }
    func testFAT16CycleRejected() {
        var d=fatImage();d[2*512+4]=2;d[2*512+5]=0
        XCTAssertThrowsError(try CardSettingsReader.read(MemorySource(d)))
    }
    func testFAT16OutsidePartitionRejected() {
        var d=fatImage();d[512+22]=200
        XCTAssertThrowsError(try CardSettingsReader.read(MemorySource(d)))
    }
    func testAllNineProjectionModesHaveStableIDs() {
        XCTAssertEqual(ProjectionMode.allCases.count,9)
        XCTAssertEqual(ProjectionMode.grid16.shaderID,8)
        XCTAssertEqual(ProjectionSettings().frontRotation,-90)
    }

}
