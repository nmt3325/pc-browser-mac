import XCTest
@testable import PCBrowserCore

/// The writer is checked against layout facts recovered from genuine PC Browser 1.9.60.0 backups
/// (docs/windows-bak-format.md); the images here are synthetic and contain no real media.
final class WindowsBackupWriterTests: XCTestCase {
    typealias Spec = CatalogTests.Spec
    let tokyo = TimeZone(identifier:"Asia/Tokyo")!
    /// 2023-11-14 22:13:20 UTC = 2023-11-15 07:13:20 in Tokyo.
    let created = Date(timeIntervalSince1970:1_700_000_000)

    func put(_ v:UInt32,_ o:Int,_ d:inout Data) { CatalogTests().put(v,o,&d) }
    /// Stamps frame serial numbers (0x1D4) and the card clock (second, hundredths) of the packets starting at `sectors`
    /// (both copies of each header, otherwise the catalog rejects the packet pair).
    func stamp(_ d:inout Data,_ sectors:[Int],counter:UInt32,second:UInt8) {
        for (i,s) in sectors.enumerated() {
            // A packet header and its trailing copy (D101/D102 pair, 4 sectors later) must stay identical.
            for at in [s*512,(s+4)*512] {
                put(counter+UInt32(i),at+0x1D4,&d)
                d[at+15] = second; d[at+16] = UInt8(i)
            }
        }
    }
    /// Three adjacent 12-sector blocks (header pair + two 5-sector packets each) of one recording.
    func singleImage() -> Data {
        var d = CatalogTests().fixture(CatalogTests().three)
        stamp(&d,[12,17],counter:1000,second:20); stamp(&d,[24,29],counter:1002,second:35); stamp(&d,[36,41],counter:1004,second:50)
        return d
    }
    /// Recording A = block 10; recording B = blocks 22 and 34 (another session serial).
    func twoRecordingImage() -> Data {
        // Recording B is a recording of its own: its blocks continue at frame ordinals 0 and 2.
        var s = CatalogTests().three; s[1].serial = 8; s[2].serial = 8; s[1].ordinal = 0; s[2].ordinal = 2
        var d = CatalogTests().fixture(s)
        stamp(&d,[12],counter:1000,second:20); stamp(&d,[17],counter:1001,second:21)
        stamp(&d,[24,29],counter:2000,second:30); stamp(&d,[36,41],counter:2002,second:45)
        return d
    }
    struct Loaded { let source:MemorySource; let index:ImageIndex; let recordings:[Recording] }
    func load(_ d:Data) throws -> Loaded {
        let source = MemorySource(d), index = try CatalogScanner.scan(source)
        let loaded = try index.recordings.map { try CatalogScanner.loadRecording($0,source:source) }
        return Loaded(source:source,index:index,recordings:loaded.sorted { $0.packets[0].headerSector < $1.packets[0].headerSector })
    }
    func temp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:u,withIntermediateDirectories:false)
        return u
    }
    func le64(_ d:Data,_ o:Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[d.startIndex+o+$1]) << UInt64($1*8) } }
    func table(_ file:Data) -> [[UInt64]] {
        let n = Int(le64(file,24)), key = WindowsBackupSource.xorTable[Int(file[22])]
        let t = BackupXOR.applied(file.subdata(in:48..<48+n*32),key:key)
        return (0..<n).map { [le64(t,$0*32),le64(t,$0*32+8),le64(t,$0*32+16),le64(t,$0*32+24)] }
    }

    func testPlanListsFixedExtentsChunksAndGenuineStyleNames() throws {
        let l = try load(singleImage())
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(created:created,timeZone:tokyo))
        XCTAssertEqual(plan.folderName,"20231115_071320"); XCTAssertEqual(plan.created,[23,11,15,7,13,20])
        XCTAssertEqual(plan.fixedSectors,[0..<1,8..<9,9..<10])
        XCTAssertEqual(plan.parts.map(\.fileName),["0000001000_20261111_202520.bak"])
        let part = plan.parts[0]
        XCTAssertEqual(part.chunks.map(\.sectors),[10..<22,22..<34,34..<46]); XCTAssertEqual(part.chunks.map(\.packets),[2,2,2])
        XCTAssertEqual(part.chunks.map(\.hasHeaderPair),[true,true,true]); XCTAssertEqual(part.chunks.map(\.hasTrailerPair),[false,false,false])
        XCTAssertEqual(plan.extents(for:part),[0..<1,8..<9,9..<10,10..<22,22..<34,34..<46])
        XCTAssertEqual(plan.totalBytes,UInt64(3*512+3*6144))
    }

    func testPartIsClosedByByteLimitOrChunkLimit() throws {
        let l = try load(singleImage())
        let bytes = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(maxChunkBytesPerPart:12_288,created:created,timeZone:tokyo))
        XCTAssertEqual(bytes.parts.map { $0.chunks.map(\.sectors) },[[10..<22,22..<34],[34..<46]])
        XCTAssertEqual(bytes.parts.map(\.fileName),["0000001000_20261111_202520.bak","0000001000_20261111_202550.bak"])
        let count = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(maxChunksPerPart:1,created:created,timeZone:tokyo))
        XCTAssertEqual(count.parts.map { $0.chunks.count },[1,1,1])
        XCTAssertEqual(count.parts.map(\.fileName),["0000001000_20261111_202520.bak","0000001000_20261111_202535.bak","0000001000_20261111_202550.bak"])
        // One chunk is always accepted, however small the limit is.
        let tiny = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(maxChunkBytesPerPart:512,created:created,timeZone:tokyo))
        XCTAssertEqual(tiny.parts.count,3)
    }

    func testGoldenPartHeaderTableAndXORPayload() throws {
        let image = singleImage(), l = try load(image), parent = try temp()
        defer { try? FileManager.default.removeItem(at:parent) }
        let options = WindowsBackupOptions(keyIndex:116,created:created,timeZone:tokyo)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:options)
        let folder = try WindowsBackupWriter.write(source:l.source,plan:plan,options:options,to:parent)
        XCTAssertEqual(folder.lastPathComponent,"20231115_071320")
        let file = try Data(contentsOf:folder.appendingPathComponent("0000001000_20261111_202520.bak"))
        XCTAssertEqual(file.prefix(12),Data("BDRBACKUP___".utf8)); XCTAssertEqual(file[12],1)
        XCTAssertEqual(Array(file[16..<22]),[23,11,15,7,13,20]); XCTAssertEqual(file[22],116)
        XCTAssertEqual(WindowsBackupSource.xorTable[116],0x23)
        XCTAssertEqual(le64(file,24),6); XCTAssertEqual(le64(file,32),UInt64(file.count)); XCTAssertEqual(file.count,20208)
        let entries = table(file)
        XCTAssertEqual(entries,[[0,511,240,512],[4096,4607,752,512],[4608,5119,1264,512],[5120,11263,1776,6144],[11264,17407,7920,6144],[17408,23551,14064,6144]])
        for e in entries {
            let stored = file.subdata(in:Int(e[2])..<Int(e[2]+e[3])).map { $0 ^ 0x23 }
            XCTAssertEqual(Data(stored),image.subdata(in:Int(e[0])..<Int(e[1]+1)))
        }
        XCTAssertEqual(try WindowsBackupWriter.verify(source:l.source,plan:plan,folder:folder),WindowsBackupWriter.Verification(parts:1,extents:6,bytes:19968))
        // Everything the original wrote is readable by the independent reader.
        let reopened = try WindowsBackupSource(url:folder.appendingPathComponent("0000001000_20261111_202520.bak"))
        XCTAssertEqual(try reopened.read(at:8*512,count:38*512),image.subdata(in:8*512..<46*512)); XCTAssertEqual(reopened.keyIndex,116)
    }

    func testRoundTripThroughFolderOpenerMergesPartsAndRecoversTheRecording() throws {
        let image = singleImage(), l = try load(image), parent = try temp()
        defer { try? FileManager.default.removeItem(at:parent) }
        let options = WindowsBackupOptions(maxChunkBytesPerPart:12_288,keyIndex:7,created:created,timeZone:tokyo)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:options)
        let folder = try WindowsBackupWriter.write(source:l.source,plan:plan,options:options,to:parent)
        let set = try XCTUnwrap(SourceOpener.open(folder) as? WindowsBackupSet)
        XCTAssertEqual(set.parts.count,2); XCTAssertEqual(set.partNames,["0000001000_20261111_202520.bak","0000001000_20261111_202550.bak"])
        XCTAssertEqual(Set(set.parts.map(\.keyIndex)),[7]); XCTAssertEqual(set.parts.first?.created,[23,11,15,7,13,20])
        let index = try CatalogScanner.scan(set)
        XCTAssertEqual(index.recordings.count,1); XCTAssertEqual(index.blockCount,3); XCTAssertEqual(index.frameCount,6)
        let r = try CatalogScanner.loadRecording(XCTUnwrap(index.recordings.first),source:set)
        XCTAssertEqual(r.packets.map(\.recordSector),[10,10,22,22,34,34])
        XCTAssertEqual(try set.read(at:8*512,count:38*512),image.subdata(in:8*512..<46*512))
        // The parent of the dated run folder opens as well (single child backup folder).
        XCTAssertTrue(try SourceOpener.open(parent) is WindowsBackupSet)
    }

    func testRecordingsFormOneChunkStreamAndNamesFollowTheFirstPacket() throws {
        let l = try load(twoRecordingImage())
        XCTAssertEqual(l.recordings.count,2)
        let mixed = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,
                                                 options:.init(maxChunksPerPart:2,recordingBoundaryReserveBytes:0,created:created,timeZone:tokyo))
        XCTAssertEqual(mixed.parts.map { $0.chunks.map(\.sectors) },[[10..<22,22..<34],[34..<46]])
        XCTAssertEqual(mixed.parts.map { $0.chunks.map(\.recording) },[[0,1],[1]])
        XCTAssertEqual(mixed.parts.map(\.fileName),["0000001000_20261111_202520.bak","0000002000_20261111_202545.bak"])
        // Room for the next recording's first chunk: the part simply continues, then closes by size.
        let roomy = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,
                                                 options:.init(maxChunkBytesPerPart:12_288,recordingBoundaryReserveBytes:100,created:created,timeZone:tokyo))
        XCTAssertEqual(roomy.parts.map { $0.chunks.map(\.recording) },[[0,1],[1]])
        XCTAssertEqual(roomy.parts.map(\.fileName),["0000001000_20261111_202520.bak","0000002000_20261111_202545.bak"])
    }

    func testFullPartIsClosedAtARecordingBoundaryAndNamedLikeTheRecordingThatEnded() throws {
        let l = try load(twoRecordingImage())
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,
                                                options:.init(maxChunkBytesPerPart:12_288,recordingBoundaryReserveBytes:6_200,created:created,timeZone:tokyo))
        XCTAssertEqual(plan.parts.map { $0.chunks.map(\.sectors) },[[10..<22],[22..<34,34..<46]])
        XCTAssertEqual(plan.parts.map { $0.chunks.map(\.recording) },[[0],[1,1]])
        // Part 2 holds only recording B but carries recording A's frame counter and A's last packet second (21),
        // exactly as the genuine second recording boundary did (counter of rec 5, clock of rec 5's last packet).
        XCTAssertEqual(plan.parts.map(\.fileName),["0000001000_20261111_202520.bak","0000001000_20261111_202521.bak"])
    }

    func testPartNameCarriesTheSerialOfFrameZeroWhenTheRecordingStartWasOverwritten() throws {
        // The first intact block is frame ordinal 5 (the ring overwrote the beginning); its first packet has serial 1005,
        // so frame 0 had serial 1000, exactly like the counters of the genuine names of such recordings.
        var d = CatalogTests().fixture([Spec(record:10,ordinal:5)])
        stamp(&d,[12,17],counter:1005,second:20)
        let l = try load(d)
        XCTAssertEqual(l.recordings.count,1)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(created:created,timeZone:tokyo))
        XCTAssertEqual(plan.parts.map(\.fileName),["0000001000_20261111_202520.bak"])
    }

    func testStartCounterRuleReproducesTheGenuineNames() {
        func chunk(_ packets:Int,header:Bool,ordinal:UInt32?,recording:Int = 0) -> WindowsBackupChunk {
            var c = WindowsBackupChunk(sectors:0..<12,packets:packets,hasHeaderPair:header,hasTrailerPair:true,firstClock:nil)
            c.recording = recording; c.firstOrdinal = ordinal
            return c
        }
        func rule(_ first:UInt32,_ chunks:[WindowsBackupChunk]) -> UInt32 { WindowsBackupWriter.startCounter(firstPacketCounter:first,chunks:chunks) }
        let block = chunk(450,header:true,ordinal:nil)
        // (serial of the first intact packet, ordinal of its block) -> serial in the genuine part name, from four genuine backups.
        var at = block; at.firstOrdinal = 4_950
        XCTAssertEqual(rule(29_689_588,[at]),29_684_638)
        at.firstOrdinal = 15_750; XCTAssertEqual(rule(29_962_007,[at]),29_946_257)
        at.firstOrdinal = 68_850; XCTAssertEqual(rule(29_943_287,[at]),29_874_437)
        at.firstOrdinal = 900;    XCTAssertEqual(rule(29_698_766,[at]),29_697_866)
        at.firstOrdinal = 0;      XCTAssertEqual(rule(29_604_184,[at]),29_604_184)
        // A first chunk without header pair (2 packets) takes the ordinal from the block that follows it: frame 7-2 = 5.
        XCTAssertEqual(rule(1005,[chunk(2,header:false,ordinal:nil),chunk(450,header:true,ordinal:7)]),1000)
        // Another recording, an impossible ordinal or no chunk at all never change the serial.
        XCTAssertEqual(rule(1005,[chunk(2,header:false,ordinal:nil),chunk(450,header:true,ordinal:7,recording:1)]),1005)
        XCTAssertEqual(rule(1005,[chunk(9,header:false,ordinal:nil),chunk(450,header:true,ordinal:7)]),1005)
        XCTAssertEqual(rule(1005,[]),1005)
        // Serials are 32-bit counters.
        at.firstOrdinal = 5; XCTAssertEqual(rule(3,[at]),UInt32.max-1)
    }

    func testPartsAreNotLimitedToElevenChunks() throws {
        // Genuine run: one part holds 12 chunks (17 table entries); only the byte limit closes parts.
        var specs: [Spec] = []
        for i in 0..<12 {
            let record: UInt32 = UInt32(10) + UInt32(7) * UInt32(i)
            specs.append(Spec(record:record,root:10,ordinal:UInt32(i),start:i == 0,frames:1))
        }
        let l = try load(CatalogTests().fixture(specs))
        XCTAssertEqual(l.recordings.count,1)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(created:created,timeZone:tokyo))
        XCTAssertEqual(plan.parts.map { $0.chunks.count },[12])
        XCTAssertEqual(plan.extents(for:plan.parts[0]).count,15)
        // The explicit option still works for callers that want a table limit.
        let limited = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(maxChunksPerPart:11,created:created,timeZone:tokyo))
        XCTAssertEqual(limited.parts.map { $0.chunks.count },[11,1])
    }

    func testBlockCutByTheRingEndIsNeverSplitAcrossParts() throws {
        // Stream order X (record 34, 4 frames), P (record 22, ordinal 4: short block at the ring end), Q (record 10, ordinal 6:
        // its continuation after the wrap, not aligned to the 4-frame block size).
        let specs = [Spec(record:10,root:34,ordinal:6),
                     Spec(record:22,root:34,ordinal:4,generation:67),
                     Spec(record:34,root:34,generation:67,start:true,frames:4)]
        let l = try load(CatalogTests().fixture(specs))
        XCTAssertEqual(l.recordings.count,1)
        func parts(_ blockFrames: Int) throws -> [[Range<UInt64>]] {
            try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,
                                         options:.init(maxChunkBytesPerPart:20_000,blockFrameCount:blockFrames,created:created,timeZone:tokyo)).parts.map { $0.chunks.map(\.sectors) }
        }
        // 11,264 B + 6,144 B would fit, but the second 6,144 B piece belongs to the same block: the pair opens the next part.
        XCTAssertEqual(try parts(4),[[34..<56],[22..<34,10..<22]])
        XCTAssertEqual(try parts(0),[[34..<56,22..<34],[10..<22]])
        // An aligned ordinal (a block that merely ends at the wrap) is an ordinary chunk.
        XCTAssertEqual(try parts(2),[[34..<56,22..<34],[10..<22]])
    }

    func testNameClashIsResolvedByAdvancingTheCounter() throws {
        var d = CatalogTests().fixture(CatalogTests().three)
        stamp(&d,[12,17],counter:500,second:20); stamp(&d,[24,29],counter:502,second:20); stamp(&d,[36,41],counter:504,second:20)
        let l = try load(d)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:.init(maxChunksPerPart:1,created:created,timeZone:tokyo))
        XCTAssertEqual(Set(plan.parts.map(\.fileName)).count,3)
        XCTAssertEqual(plan.parts.map(\.fileName),["0000000500_20261111_202520.bak","0000000501_20261111_202520.bak","0000000502_20261111_202520.bak"])
    }

    func testRingWrapKeepsStreamOrderInTheTableWhileTheReaderSortsIt() throws {
        let wrapped = [Spec(record:10,root:34,ordinal:4),Spec(record:22,root:34,ordinal:2,generation:67),Spec(record:34,root:34,generation:67,start:true)]
        let image = CatalogTests().fixture(wrapped), l = try load(image), parent = try temp()
        defer { try? FileManager.default.removeItem(at:parent) }
        let options = WindowsBackupOptions(keyIndex:0x7a,created:created,timeZone:tokyo)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:options)
        XCTAssertEqual(plan.parts[0].chunks.map(\.sectors),[34..<46,22..<34,10..<22])
        let folder = try WindowsBackupWriter.write(source:l.source,plan:plan,options:options,to:parent)
        let name = try XCTUnwrap(plan.parts.first?.fileName)
        let file = try Data(contentsOf:folder.appendingPathComponent(name))
        XCTAssertEqual(table(file).map { $0[0] },[0,4096,4608,17408,11264,5120])
        XCTAssertEqual(table(file).map { $0[2] },[240,752,1264,1776,7920,14064])
        let reopened = try WindowsBackupSource(url:folder.appendingPathComponent(name))
        XCTAssertEqual(reopened.extents.map(\.sourceOffset),[0,4096,4608,5120,11264,17408])
        XCTAssertEqual(try reopened.read(at:8*512,count:38*512),image.subdata(in:8*512..<46*512))
        _ = try WindowsBackupWriter.verify(source:l.source,plan:plan,folder:folder)
    }

    func testTrailerPairsHeaderPairsAndMirrorPairBecomeExtents() throws {
        var d = CatalogTests().fixture([Spec(record:10,start:true),Spec(record:24,ordinal:2),Spec(record:38,ordinal:4)])
        for s in [22,23,36,37] { put(0xFFFFD106,s*512,&d) }
        for s in [50,51] { put(0xFFFFD104,s*512,&d) }
        // Recording partition entry (type 0) starting at the control sector: its last two sectors are the mirror pair.
        put(8,470,&d); put(90,474,&d)
        let l = try load(d), parent = try temp()
        defer { try? FileManager.default.removeItem(at:parent) }
        let options = WindowsBackupOptions(keyIndex:3,created:created,timeZone:tokyo)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:options)
        XCTAssertEqual(plan.fixedSectors,[0..<1,8..<9,9..<10,96..<97,97..<98])
        let chunks = plan.parts[0].chunks
        XCTAssertEqual(chunks.map(\.sectors),[10..<24,24..<38,38..<52]); XCTAssertEqual(chunks.map(\.hasHeaderPair),[true,true,true])
        XCTAssertEqual(chunks.map(\.hasTrailerPair),[true,true,true])
        XCTAssertEqual(plan.extents(for:plan.parts[0]),[0..<1,8..<9,9..<10,10..<24,24..<38,38..<52,96..<97,97..<98])
        let folder = try WindowsBackupWriter.write(source:l.source,plan:plan,options:options,to:parent)
        let reopened = try WindowsBackupSource(url:folder.appendingPathComponent(plan.parts[0].fileName))
        XCTAssertEqual(reopened.extents.count,8); XCTAssertEqual(reopened.byteCount,98*512)
        XCTAssertEqual(try reopened.read(at:10*512,count:42*512),d.subdata(in:10*512..<52*512))
        XCTAssertEqual(try WindowsBackupWriter.verify(source:l.source,plan:plan,folder:folder).extents,8)
    }

    func testHeaderlessFirstBlockIsAdoptedAndItsChunkStartsAtTheFirstIntactPacket() throws {
        // Like the real card: the first block's header pair was overwritten, only its packets survive.
        let part = try WindowsBackupSource(storage:MemorySource(WindowsBackupTests().fixture(ranges:[0..<512,8*512..<10*512,12*512..<46*512])))
        let index = try CatalogScanner.scan(part)
        XCTAssertEqual(index.recordings.count,1); XCTAssertEqual(index.blockCount,3); XCTAssertEqual(index.frameCount,6)
        let r = try CatalogScanner.loadRecording(XCTUnwrap(index.recordings.first),source:part)
        XCTAssertEqual(r.packets.map(\.recordSector),[10,10,22,22,34,34])
        let plan = try WindowsBackupWriter.plan(source:part,index:index,recordings:[r],options:.init(created:created,timeZone:tokyo))
        XCTAssertEqual(plan.parts[0].chunks.map(\.sectors),[12..<22,22..<34,34..<46])
        XCTAssertEqual(plan.parts[0].chunks.map(\.hasHeaderPair),[false,true,true])
    }

    func testOverlappingPartsMergeOnlyWhenIdenticalAndTheOriginalFilesStayUntouched() throws {
        let a = try WindowsBackupSource(storage:MemorySource(WindowsBackupTests().fixture(ranges:[0..<512,8*512..<30*512])))
        let b = try WindowsBackupSource(storage:MemorySource(WindowsBackupTests().fixture(ranges:[0..<512,22*512..<46*512])))
        let set = try WindowsBackupSet(parts:[a,b],names:["a.bak","b.bak"])
        XCTAssertEqual(set.scanRanges,[UInt64(0)..<512,UInt64(8*512)..<UInt64(46*512)]); XCTAssertEqual(set.extentCount,4)
        XCTAssertEqual(try set.read(at:8*512,count:38*512),CatalogTests().fixture(CatalogTests().three).subdata(in:8*512..<46*512))
        XCTAssertEqual(try CatalogScanner.scan(set).frameCount,6)
        // One flipped byte inside the shared sectors must be refused (different card or different backup).
        var bad = WindowsBackupTests().fixture(ranges:[0..<512,22*512..<46*512]); bad[112+512+2*512+100] ^= 0xFF
        let c = try WindowsBackupSource(storage:MemorySource(bad))
        XCTAssertThrowsError(try WindowsBackupSet(parts:[a,c],names:["a.bak","c.bak"]))
        XCTAssertThrowsError(try WindowsBackupSet(parts:[],names:[]))
    }

    func testFolderResolutionRules() throws {
        let root = try temp(), fm = FileManager.default, bak = WindowsBackupTests().fixture()
        defer { try? fm.removeItem(at:root) }
        let one = root.appendingPathComponent("one",isDirectory:true); try fm.createDirectory(at:one,withIntermediateDirectories:false)
        try bak.write(to:one.appendingPathComponent("a.bak")); try Data("not a backup".utf8).write(to:one.appendingPathComponent("b.bak"))
        XCTAssertEqual(try WindowsBackupFolder.files(in:one).map(\.lastPathComponent),["a.bak"])
        XCTAssertTrue(try SourceOpener.open(root) is WindowsBackupSet)
        let two = root.appendingPathComponent("two",isDirectory:true); try fm.createDirectory(at:two,withIntermediateDirectories:false)
        try bak.write(to:two.appendingPathComponent("c.bak"))
        XCTAssertThrowsError(try SourceOpener.open(root)) { XCTAssertTrue($0.localizedDescription.contains("複数のバックアップフォルダー")) }
        XCTAssertTrue(try SourceOpener.open(one) is WindowsBackupSet)
    }

    func testExistingDestinationCancellationAndBadSelectionsLeaveNothingBehind() throws {
        let l = try load(singleImage()), parent = try temp(), fm = FileManager.default
        defer { try? fm.removeItem(at:parent) }
        let options = WindowsBackupOptions(keyIndex:1,created:created,timeZone:tokyo)
        let plan = try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings,options:options)
        XCTAssertThrowsError(try WindowsBackupWriter.write(source:l.source,plan:plan,options:options,to:parent,cancelled:{ true }))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath:parent.path),[])
        _ = try WindowsBackupWriter.write(source:l.source,plan:plan,options:options,to:parent)
        XCTAssertThrowsError(try WindowsBackupWriter.write(source:l.source,plan:plan,options:options,to:parent))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath:parent.path),["20231115_071320"])
        XCTAssertThrowsError(try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:[],options:options))
        XCTAssertThrowsError(try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.index.recordings,options:options)) // not loaded
        XCTAssertThrowsError(try WindowsBackupWriter.plan(source:l.source,index:l.index,recordings:l.recordings+l.recordings,options:options)) // duplicate selection overlaps
    }

    func testBackupXORMatchesBytewiseXORForUnalignedAndSlicedData() {
        for key in [UInt8(0),1,0x23,0xff] {
            for n in 0...37 {
                let plain = Data((0..<n).map { UInt8(truncatingIfNeeded:$0*37+5) }), expected = Data(plain.map { $0 ^ key })
                XCTAssertEqual(BackupXOR.applied(plain,key:key),expected)
                var copy = plain; BackupXOR.apply(&copy,key:key); XCTAssertEqual(copy,expected)
                var sliced = Data([1,2,3])+plain; sliced = sliced.dropFirst(3)
                BackupXOR.apply(&sliced,key:key); XCTAssertEqual(Data(sliced),expected)
            }
        }
    }
}
