import XCTest
@testable import PCBrowserCore
final class FormatTests: XCTestCase {
    func put(_ value: UInt32, _ offset: Int, _ bytes: inout Data) {
        for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    func packet() -> Data {
        var h=Data(count:512)
        let fields: [(Int,UInt32)] = [(0,0xFFFFD101),(4,7),(0x1FC,7),(0x1A6,600),(0x1AC,5),(0x1B0,10),(0x1B4,14),(0x1B8,8),(0x1BC,320),(0x1E8,15)]
        for (o,v) in fields { put(v,o,&h) }
        h[8]=1;h[9]=2;h[10]=24;h[11]=1;h[12]=2;h[13]=3;h[14]=4;h[15]=5
        return h
    }
    func testPacketUnalignedLength() throws {
        let p=try FramePacket.parse(packet(),sector:10,diskBytes:100*512)
        XCTAssertEqual(p.videoBytes,600);XCTAssertEqual(p.payloadOffset,11*512);XCTAssertTrue(p.isIntra)
        XCTAssertEqual(p.cardTime,"2024-01-02 03:04:05");XCTAssertEqual(p.rawField1E8,15)
    }
    func testPacketRejectsBadSelfPointer() {var h=packet();put(9,0x1B0,&h);XCTAssertThrowsError(try FramePacket.parse(h,sector:10,diskBytes:100*512))}
    func testPacketRejectsBadSequence() {var h=packet();put(8,0x1FC,&h);XCTAssertThrowsError(try FramePacket.parse(h,sector:10,diskBytes:100*512))}
    func testPacketRejectsOutsideInput() {XCTAssertThrowsError(try FramePacket.parse(packet(),sector:10,diskBytes:14*512))}
    func testPacketRejectsZeroVideo() {var h=packet();put(0,0x1A6,&h);XCTAssertThrowsError(try FramePacket.parse(h,sector:10,diskBytes:100*512))}
    func testPacketRejectsOversizedVideo() {var h=packet();put(UInt32.max,0x1A6,&h);XCTAssertThrowsError(try FramePacket.parse(h,sector:10,diskBytes:100*512))}
    func testPacketRejectsOversizedAuxiliary() {var h=packet();put(2000,0x1BC,&h);XCTAssertThrowsError(try FramePacket.parse(h,sector:10,diskBytes:100*512))}
    func testPacketRejectsSpanMismatch() {var h=packet();put(4,0x1AC,&h);XCTAssertThrowsError(try FramePacket.parse(h,sector:10,diskBytes:100*512))}
    func testPacketRejectsTruncation() {XCTAssertThrowsError(try FramePacket.parse(Data(count:511),sector:10,diskBytes:100*512))}
    func testRawFieldNotInterpretedAsFPS() throws {var h=packet();put(UInt32.max,0x1E8,&h);XCTAssertEqual(try FramePacket.parse(h,sector:10,diskBytes:100*512).rawField1E8,UInt32.max)}
    func testAnnexBSplitAndAVCC() throws {
        let b=Data([0,0,0,1,0x27,1,2,0,0,1,0x28,3,0,0,1,0x21,4,5])
        let u=AnnexB.units(b);XCTAssertEqual(u.count,3);XCTAssertEqual(try AnnexB.avcc(u),Data([0,0,0,3,0x21,4,5]))
    }
    func testMemoryBounds() {let s=MemorySource(Data(count:512));XCTAssertThrowsError(try s.read(at:UInt64.max,count:512));XCTAssertThrowsError(try s.read(at:500,count:20))}
    func testMissingSignature() {XCTAssertThrowsError(try PartitionTable.parse(Data(count:512),diskBytes:10000))}
    func testSettingsSensitiveValuesHidden() {let s=INIParser.parse("[A]\nPASSWORD=secret\nMODE=1");XCTAssertEqual(s.count,2);XCTAssertFalse(s[0].displayValue.contains("secret"));XCTAssertEqual(s[1].displayValue,"1")}
    func testNMEAChecksumRejected() {XCTAssertEqual(NMEAParser.parse("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*00").rejected,1)}
    func testReadOnlyFileUnchanged() throws {
        let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let d=Data(repeating:0x5A,count:1024);try d.write(to:u);defer{try? FileManager.default.removeItem(at:u)}
        let s=try FileByteSource(url:u);XCTAssertEqual(try s.read(at:512,count:512),d.prefix(512));XCTAssertEqual(try Data(contentsOf:u),d)
    }
    func testSymlinkRejected() throws {
        let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath:u.path,withDestinationPath:"/etc/hosts");defer{try? FileManager.default.removeItem(at:u)}
        XCTAssertThrowsError(try FileByteSource(url:u))
    }
}
