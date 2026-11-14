import XCTest
@testable import PCBrowserCore

/// Event list, trigger names and the per-second journal (Windows イベント記録 / 常時録画 / 履歴記録 lists).
final class RecordListTests: XCTestCase {
    private func put(_ v: UInt32, _ o: Int, _ d: inout Data) { CatalogTests().put(v, o, &d) }
    private typealias Spec = CatalogTests.Spec

    /// Event blocks (pre-roll 5, trigger 2, post 3) at records 20/32/44 (and 56/68/80 for a second event, or one more post
    /// block at 56 with `extraPost`); the control sector at 8 names the event region 18..<95 behind a normal region 10..<12.
    /// With one frame per block the two sectors behind the packet are free for a trailer pair.
    private func eventImage(events: Int = 1, region: Bool = true, serial: UInt32 = 5, frames: Int = 2, extraPost: Bool = false, postOrdinal: UInt32 = 4) -> Data {
        // Without a region table the scan starts at the first record sector and must not meet eight empty sectors.
        let r0: UInt32 = region ? 20 : 10
        // On a real card the packet header byte 8 ("channel") of event packets is the phase, not a camera number.
        var specs = [Spec(record: r0, root: r0, serial: serial, ordinal: 0, channel: 5, start: true, frames: frames), Spec(record: r0 + 12, root: r0, serial: serial, ordinal: 2, channel: 2, frames: frames), Spec(record: r0 + 24, root: r0, serial: serial, ordinal: postOrdinal, channel: 3, frames: frames)]
        var phases: [UInt8] = [5, 2, 3]
        if events > 1 {
            let r1 = r0 + 36
            specs += [Spec(record: r1, root: r1, serial: serial + 1, ordinal: 0, channel: 5, start: true, frames: frames), Spec(record: r1 + 12, root: r1, serial: serial + 1, ordinal: 2, channel: 2, frames: frames), Spec(record: r1 + 24, root: r1, serial: serial + 1, ordinal: 4, channel: 3, frames: frames)]
            phases += [5, 2, 3]
        }
        if extraPost {
            specs.append(Spec(record: r0 + 36, root: r0, serial: serial, ordinal: 6, channel: 3, frames: frames))
            phases.append(3)
        }
        var d = CatalogTests().fixture(specs)
        for (i, s) in specs.enumerated() { d[Int(s.record) * 512 + 0x0C] = phases[i] }
        if region { put(12, 8 * 512 + 0x1C2, &d); put(18, 8 * 512 + 0x1C6, &d); put(95, 8 * 512 + 0x1CA, &d) }
        return d
    }
    /// The cause of an event sits in the second sector of the trailer pair behind the last packet of a post block:
    /// flags at 0xDB and the 24-bit cause mask at 0xE7. The identifier word at 4 is repeated at 0x1FC.
    private func trailer(_ d: inout Data, record: Int, frames: Int = 1, magic: UInt32 = 0xFFFFD104, flags: UInt8, mask: UInt32, identifier: UInt32 = 77, mirrored: UInt32 = 77) {
        let first = (record + 2 + frames * 5) * 512
        for k in 0..<2 {
            let s = first + k * 512
            put(magic, s, &d); put(identifier, s + 4, &d); put(mirrored, s + 0x1FC, &d)
        }
        let o = first + 512
        d[o + 0xDB] = flags
        d[o + 0xE7] = UInt8(mask & 0xFF); d[o + 0xE8] = UInt8((mask >> 8) & 0xFF); d[o + 0xE9] = UInt8((mask >> 16) & 0xFF)
    }
    /// The mirror (D102 copy) of the first packet of a block holds the same two fields at 0x40 and 0x4C. A real card
    /// finishes them after the header copy, so only the mirror is changed here.
    private func mirror(_ d: inout Data, record: Int, flags: UInt8, mask: UInt32) {
        let o = (record + 6) * 512
        d[o + 0x40] = flags
        d[o + 0x4C] = UInt8(mask & 0xFF); d[o + 0x4D] = UInt8((mask >> 8) & 0xFF); d[o + 0x4E] = UInt8((mask >> 16) & 0xFF)
    }

    func testEventBlocksFormOneEventRecordingInsideTheEventRegion() throws {
        let i = try CatalogScanner.scan(MemorySource(eventImage()))
        XCTAssertEqual(i.layout?.eventRegion, UInt64(18)..<UInt64(95))
        XCTAssertEqual(i.recordings.count, 1)
        let e = try XCTUnwrap(i.recordings.first)
        XCTAssertTrue(e.isEvent)
        XCTAssertEqual(e.blocks.count, 3)
        XCTAssertEqual(e.frameCount, 6)
        XCTAssertEqual(e.blocks.compactMap { $0.metadata?.blockType }, [5, 2, 3])
        XCTAssertEqual(i.eventRecordings.count, 1)
        XCTAssertEqual(i.continuousRecordings.count, 0)
        XCTAssertEqual(e.eventTime.map { CivilTime.minuteText($0) }, "2026/11/11 20:25")
    }
    /// The trigger fields sit on the first frame of the post phase, and the original names the event by that frame (its trigger
    /// list and the report files show seconds); the phase before it starts earlier.
    func testEventTimeIsTheFirstFrameOfThePostBlock() throws {
        let i = try CatalogScanner.scan(MemorySource(eventImage(postOrdinal: 34)))
        let e = try XCTUnwrap(i.recordings.first)
        XCTAssertEqual(e.blocks.compactMap { $0.metadata?.blockType }, [5, 2, 3])
        XCTAssertEqual(e.eventTime.map { CivilTime.secondText($0) }, "2026/11/11 20:25:21")
        XCTAssertEqual(e.blocks[1].first.telemetry.clock.map { CivilTime.secondText($0) }, "2026/11/11 20:25:20")
    }
    func testSameBlocksWithoutARegionTableKeepThePreviousGrouping() throws {
        let i = try CatalogScanner.scan(MemorySource(eventImage(region: false)))
        XCTAssertNil(i.layout)
        XCTAssertEqual(i.recordings.count, 3, "block types differ in the format key, so without a region table they stay separate")
        XCTAssertTrue(i.recordings.allSatisfy { !$0.isEvent })
    }
    func testDifferentEventSerialsStaySeparateAndLoadInOrdinalOrder() throws {
        let src = MemorySource(eventImage(events: 2)), i = try CatalogScanner.scan(src)
        XCTAssertEqual(i.eventRecordings.count, 2)
        let loaded = try CatalogScanner.loadRecording(XCTUnwrap(i.recordings.first), source: src)
        XCTAssertEqual(loaded.packets.map(\.recordSector), [20, 20, 32, 32, 44, 44])
    }
    func testRecoveryScanMergesEventsTheSameWay() throws {
        let i = try ImageScanner.scan(MemorySource(eventImage()))
        XCTAssertEqual(i.recordings.count, 1)
        XCTAssertTrue(i.recordings[0].isEvent)
        XCTAssertEqual(i.validatedFrameCount, 6)
    }
    /// Established on a copy of a real card by editing single sectors and reading the original application's event list:
    /// the label follows the post block trailer, not the per-packet headers.
    func testEventListReadsTheCauseFromThePostBlockTrailer() throws {
        let table: [(UInt8, UInt32, String)] = [
            (0x01, 0x01, "衝撃"), (0x01, 0x02, "急発進/急ブレーキ"), (0x01, 0x04, "急ハンドル"), (0x01, 0x08, "急旋回"),
            (0x04, 0x10, "ワンタッチ"), (0x04, 0x00, "ワンタッチ"), (0x01, 0x00, "イベント"), (0x80, 0x01, "衝撃"),
            (0x01, 0x03, "衝撃, など"), (0x01, 0x100, "外部トリガ1")]
        for (flags, mask, name) in table {
            var d = eventImage(frames: 1); trailer(&d, record: 44, flags: flags, mask: mask)
            let src = MemorySource(d), rows = try EventList.entries(CatalogScanner.scan(src), source: src)
            XCTAssertEqual(rows.map(\.trigger), [name], "flags \(flags) mask \(mask)")
            XCTAssertEqual(rows.first?.timeText, "2026/11/11 20:25:20", "the time is the first frame of the post block (the same second as the trigger block in this fixture)")
            XCTAssertEqual(rows.first?.blocks, 3)
        }
    }
    func testOnlyPostTrailersCountAndAnEmptyFirstOneFallsBackToTheFirstPostMirror() throws {
        func label(_ configure: (inout Data) -> Void) throws -> String? {
            var d = eventImage(frames: 1, extraPost: true); configure(&d)
            let src = MemorySource(d)
            return try EventList.entries(CatalogScanner.scan(src), source: src).first?.trigger
        }
        XCTAssertEqual(try label { d in trailer(&d, record: 20, flags: 1, mask: 8); trailer(&d, record: 32, flags: 1, mask: 8) }, "イベント", "pre-roll and trigger blocks are not consulted")
        XCTAssertEqual(try label { d in trailer(&d, record: 44, flags: 1, mask: 0x10); mirror(&d, record: 44, flags: 1, mask: 0x01) }, "ワンタッチ", "a trailer with a cause wins over the mirror")
        XCTAssertEqual(try label { d in trailer(&d, record: 44, flags: 0, mask: 0); mirror(&d, record: 44, flags: 1, mask: 0x02) }, "急発進/急ブレーキ", "an empty first trailer falls back to the mirror")
        XCTAssertEqual(try label { d in trailer(&d, record: 44, flags: 0, mask: 0); mirror(&d, record: 44, flags: 1, mask: 0x01); trailer(&d, record: 56, flags: 1, mask: 0x10) }, "衝撃, など", "the fallback and the next trailer are two records")
        XCTAssertEqual(try label { d in trailer(&d, record: 44, flags: 1, mask: 0x01); trailer(&d, record: 56, flags: 0, mask: 0); mirror(&d, record: 56, flags: 1, mask: 0x10) }, "衝撃", "a later empty trailer adds nothing")
        XCTAssertEqual(try label { d in mirror(&d, record: 44, flags: 1, mask: 0x04) }, "急ハンドル", "without any trailer pair the mirror is used")
        XCTAssertEqual(try label { d in trailer(&d, record: 44, magic: 0xFFFFD103, flags: 1, mask: 1) }, "イベント", "a trailer needs D104 or D106 magic")
        XCTAssertEqual(try label { d in trailer(&d, record: 44, flags: 1, mask: 1, mirrored: 78) }, "イベント", "a trailer needs its mirrored identifier")
        XCTAssertEqual(try label { _ in }, "イベント", "an event without any trigger record")
    }
    /// On a real card the first post packet of every event is written before its trigger fields are final, so its
    /// header and mirror differ at 0x40...0x4F. Such a packet is valid and must not be rejected as a torn pair.
    func testPacketMirrorMayDifferInTheTriggerFieldsOnly() throws {
        var d = eventImage()
        d[(44 + 6) * 512 + 0x4C] = 0x01
        d[(44 + 2) * 512 + 0x4D] = 0x02
        let src = MemorySource(d), i = try CatalogScanner.scan(src)
        // (recoveryRecommended is not asserted: eight empty sectors behind the data raise it in this small image anyway)
        XCTAssertEqual(i.rejectedCandidates, 0)
        XCTAssertEqual(i.frameCount, 6)
        XCTAssertEqual(try ImageScanner.scan(src).frameCount, 6)
        XCTAssertEqual(try CatalogScanner.loadRecording(XCTUnwrap(i.recordings.first), source: src).packets.count, 6)
        for offset in [0x3F, 0x50] {
            var bad = eventImage(); bad[(44 + 6) * 512 + offset] = 0x01
            let index = try CatalogScanner.scan(MemorySource(bad))
            XCTAssertEqual(index.rejectedCandidates, 1, "a difference at \(offset) is still a torn pair")
            XCTAssertLessThan(index.frameCount, 6, "the torn packet is not counted")
        }
    }
    func testEventListIsOldestFirstAndCancellable() throws {
        let src = MemorySource(eventImage(events: 2)), index = try CatalogScanner.scan(src)
        XCTAssertEqual(try EventList.entries(index, source: src).count, 2)
        XCTAssertThrowsError(try EventList.entries(index, source: src, cancelled: { true }))
    }
    func testTriggerLabelsFollowTheOriginalTable() {
        func s(_ f: UInt8, _ m: UInt32) -> EventTrigger.Sample { .init(flags: f, mask: m) }
        XCTAssertEqual(EventTrigger.label([]), "イベント")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x01)]), "衝撃")
        XCTAssertEqual(EventTrigger.label([s(0x04, 0x10)]), "ワンタッチ")
        XCTAssertEqual(EventTrigger.label([s(0x80, 0x01)]), "衝撃", "the cause bits name the event whatever the flag byte says")
        XCTAssertEqual(EventTrigger.label([s(0x04, 0x00)]), "ワンタッチ", "flag bit 2 without a named cause is a one-touch event")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x00)]), "イベント")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x01), s(0x01, 0x10)]), "衝撃, など")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x10), s(0x01, 0x01)]), "衝撃, など", "the cause bits are tested in a fixed order, not by arrival")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x11)]), "衝撃, など")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x03)]), "衝撃, など")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x01), s(0x04, 0x00)]), "衝撃", "a record without a cause adds no など")
        XCTAssertEqual(EventTrigger.label([s(0x01, 0x00200000)]), "エリアA検知")
        for entry in EventTrigger.names { XCTAssertEqual(EventTrigger.label([s(0x01, entry.mask)]), entry.text) }
        XCTAssertEqual(EventTrigger.names.count, 20)
    }
    func testDeviceIdentityNeedsTenPlainCharacters() throws {
        var d = eventImage(); d.replaceSubrange(12 * 512 + 0x6E..<12 * 512 + 0x78, with: Data("YQA1018762".utf8))
        let src = MemorySource(d), i = try CatalogScanner.scan(src)
        XCTAssertEqual(DeviceIdentity.read(from: src, control: i.control), "YQA1018762")
        XCTAssertEqual(try EventList.entries(i, source: src).first?.deviceID, "YQA1018762")
        d.replaceSubrange(12 * 512 + 0x6E..<12 * 512 + 0x78, with: Data("YQA10187\u{1}2".utf8))
        let bad = MemorySource(d)
        XCTAssertNil(DeviceIdentity.read(from: bad, control: i.control))
        XCTAssertNil(DeviceIdentity.read(from: MemorySource(eventImage()), control: i.control), "zero bytes are not an identity")
    }
    func testDiskLayoutNeedsOrderedBoundsInsideTheDisk() {
        var c = Data(count: 512)
        func set(_ a: UInt32, _ b: UInt32, _ e: UInt32, _ h0: UInt32 = 0, _ h1: UInt32 = 0) {
            put(a, 0x1C2, &c); put(b, 0x1C6, &c); put(e, 0x1CA, &c); put(h0, 0x1CE, &c); put(h1, 0x1D2, &c)
        }
        set(100, 120, 200, 201, 300)
        let l = DiskLayout(control: c, firstRecordSector: 10, diskSectors: 400)
        XCTAssertEqual(l?.normalEnd, 100); XCTAssertEqual(l?.eventRegion, UInt64(120)..<UInt64(200))
        XCTAssertEqual(l?.history, UInt64(201)..<UInt64(301)); XCTAssertEqual(l?.historyRecordCount, 200)
        XCTAssertNil(DiskLayout(control: c, firstRecordSector: 10, diskSectors: 199), "event region beyond the disk")
        XCTAssertNil(DiskLayout(control: c, firstRecordSector: 100, diskSectors: 400), "normal region must follow the first record")
        set(100, 99, 200); XCTAssertNil(DiskLayout(control: c, firstRecordSector: 10, diskSectors: 400))
        set(100, 120, 200, 150, 300); XCTAssertNil(DiskLayout(control: c, firstRecordSector: 10, diskSectors: 400)?.history, "journal may not overlap the event region")
        set(100, 120, 200, 201, 500); XCTAssertNil(DiskLayout(control: c, firstRecordSector: 10, diskSectors: 400)?.history, "journal must end inside the disk")
        XCTAssertNil(DiskLayout(control: Data(count: 100), firstRecordSector: 10, diskSectors: 400))
    }
    func testCivilTimeRoundTripsLeapDaysAndCenturies() {
        for (y, m, d, h, mi, s) in [(2026, 11, 12, 19, 45, 13), (2028, 2, 29, 23, 59, 59), (2000, 1, 1, 0, 0, 0), (2099, 12, 31, 12, 30, 1), (1999, 3, 1, 5, 6, 7)] {
            let t = CivilTime.seconds(year: y, month: m, day: d, hour: h, minute: mi, second: s)
            let c = CivilTime.components(t)
            XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [y, m, d, h, mi, s])
        }
        XCTAssertEqual(CivilTime.seconds(year: 2026, month: 3, day: 1, hour: 0, minute: 0, second: 0) - CivilTime.seconds(year: 2026, month: 2, day: 28, hour: 0, minute: 0, second: 0), 86400)
        XCTAssertFalse(CivilTime.isValid(year: 2026, month: 2, day: 29, hour: 0, minute: 0, second: 0))
        XCTAssertTrue(CivilTime.isValid(year: 2028, month: 2, day: 29, hour: 0, minute: 0, second: 0))
        XCTAssertEqual(CivilTime.minuteText(CivilTime.seconds(year: 2026, month: 4, day: 28, hour: 9, minute: 51, second: 59)), "2026/04/28 09:51")
        let c = CivilTime.components(CivilTime.seconds(year: 2026, month: 4, day: 28, hour: 9, minute: 51, second: 4))
        let stamp = CardTimestamp.parse(Data([26, UInt8(c.month), UInt8(c.day), UInt8(c.hour), UInt8(c.minute), UInt8(c.second), 15]), offset: 0)
        XCTAssertEqual(stamp.map { CivilTime.secondText($0) }, "2026/04/28 09:51:04")
    }

    // MARK: journal

    private func record(_ kind: Int, _ a: Int64 = 0, _ b: Int64 = 0, device: String = "YQA1018762") -> Data {
        var d = Data(count: 256)
        guard kind != 0 else { return d }
        put(kind == 2 ? 0xFFFFE202 : 0xFFFFE201, 0, &d)
        func clock(_ t: Int64, _ o: Int) {
            let c = CivilTime.components(t)
            d[o] = UInt8(c.year - 2000); d[o + 1] = UInt8(c.month); d[o + 2] = UInt8(c.day); d[o + 3] = UInt8(c.hour); d[o + 4] = UInt8(c.minute); d[o + 5] = UInt8(c.second)
        }
        clock(a, 0x0E); clock(b, 0x1E)
        d.replaceSubrange(0x9A..<0xA4, with: Data(device.utf8))
        return d
    }
    private let t0 = CivilTime.seconds(year: 2026, month: 5, day: 1, hour: 9, minute: 0, second: 0)
    /// Five rows written oldest first from slot 350 of a 400-slot ring, so the sequence wraps around the ring end.
    private func journalImage() -> (Data, Range<UInt64>) {
        var seq: [Data] = []
        func samples(_ n: Int, base: Int64, offset: (Int) -> Int64) { for i in 0..<n { seq.append(record(2, base + Int64(i) - offset(i), base + Int64(i))) } }
        samples(100, base: t0 + 30) { _ in 61 }
        seq += [record(1, t0 + 130 - 61, t0 + 130), record(1, t0 + 5399, t0 + 5399)]
        samples(20, base: t0 + 5400) { _ in 0 }
        seq += [record(1, t0 + 5420, t0 + 5420), record(0), record(1, t0 + 8999, t0 + 8999)]
        samples(30, base: t0 + 9000) { $0 < 15 ? 70 : 0 }
        seq += [record(1, t0 + 9030, t0 + 9030), record(0), record(1, t0 + 9300 - 61, t0 + 9300), record(0), record(1, t0 + 12599, t0 + 12599)]
        samples(30, base: t0 + 12600) { $0 < 10 ? 61 : 161 }
        var d = Data(count: 300 * 512)
        for (k, r) in seq.enumerated() { let slot = (350 + k) % 400, o = 20 * 512 + slot * 256; d.replaceSubrange(o..<o + 256, with: r) }
        return (d, 20..<220)
    }
    func testJournalRowsFollowRunsMarkersAndTheRingOrder() throws {
        let (data, area) = journalImage()
        let log = try XCTUnwrap(HistoryLog.read(source: MemorySource(data), area: area))
        XCTAssertEqual(log.newestSlot, (350 + 189) % 400)
        XCTAssertEqual(log.rows.map(\.startText), ["2026/05/01 08:59", "2026/05/01 10:29", "2026/05/01 11:28", "2026/05/01 11:33", "2026/05/01 12:28"])
        XCTAssertEqual(log.rows.map(\.durationText), ["1分", "21秒", "31秒", "1秒", "32秒"])
        XCTAssertEqual(log.rows.map(\.records), [100, 20, 30, 1, 30])
        XCTAssertEqual(log.rows.map(\.kind), [.session, .session, .session, .marker, .session])
        XCTAssertEqual(log.rows.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertTrue(log.rows.allSatisfy { $0.deviceID == "YQA1018762" })
        XCTAssertEqual([log.sampleRecords, log.markerRecords, log.emptyRecords, log.otherRecords, log.slotCount], [180, 7, 213, 0, 400])
    }
    func testJournalStartUsesClockBForMatchingVideoAndSecondRounding() throws {
        let (data, area) = journalImage()
        let log = try XCTUnwrap(HistoryLog.read(source: MemorySource(data), area: area))
        XCTAssertEqual(log.rows[0].videoClockStart, t0 + 30)
        XCTAssertEqual(log.rows[0].start, t0 + 30 - 61)
        XCTAssertEqual(log.rows[1].start, t0 + 5399, "unsynchronised clocks (A equals B) start one second earlier")
        XCTAssertEqual(log.rows[0].durationText, "1分")
    }
    func testJournalDurationRuleForForwardAndBackwardClockJumps() throws {
        let (data, area) = journalImage()
        let rows = try XCTUnwrap(HistoryLog.read(source: MemorySource(data), area: area)).rows
        XCTAssertEqual(rows[2].duration, 31, "forward jump: n+1")
        XCTAssertEqual(rows[4].duration, 32, "backward jump: n+1+1")
        XCTAssertEqual(rows[1].duration, 21, "steady clock: span+2")
    }
    func testJournalIsNotReadFromPartialSourcesOrWithoutSamples() throws {
        let (data, area) = journalImage()
        final class Partial: ByteSource, @unchecked Sendable {
            let base: MemorySource, ranges: [Range<UInt64>]
            init(_ base: MemorySource, _ ranges: [Range<UInt64>]) { self.base = base; self.ranges = ranges }
            var byteCount: UInt64 { base.byteCount }
            var scanRanges: [Range<UInt64>]? { ranges }
            var isPartialCopy: Bool { true }
            func read(at offset: UInt64, count: Int) throws -> Data { try base.read(at: offset, count: count) }
        }
        XCTAssertNil(try HistoryLog.read(source: Partial(MemorySource(data), [0..<UInt64(100 * 512)]), area: area))
        XCTAssertNotNil(try HistoryLog.read(source: Partial(MemorySource(data), [0..<UInt64(300 * 512)]), area: area))
        XCTAssertNil(try HistoryLog.read(source: MemorySource(Data(count: 300 * 512)), area: area), "all-zero journal")
        XCTAssertNil(try HistoryLog.read(source: MemorySource(Data(count: 512)), area: 20..<220), "area beyond the source")
        XCTAssertThrowsError(try HistoryLog.read(source: MemorySource(data), area: area, cancelled: { true }))
    }
    func testJournalOfAnUnwrappedRingHasNoMarkerRowFromTheEmptyTail() throws {
        var d = Data(count: 300 * 512)
        var seq: [Data] = []
        for i in 0..<40 { seq.append(record(2, t0 + Int64(i), t0 + Int64(i))) }
        seq.insert(record(1, t0 - 1, t0 - 1), at: 0)
        for (k, r) in seq.enumerated() { let o = 20 * 512 + k * 256; d.replaceSubrange(o..<o + 256, with: r) }
        let log = try XCTUnwrap(HistoryLog.read(source: MemorySource(d), area: 20..<220))
        XCTAssertEqual(log.rows.count, 1)
        XCTAssertEqual(log.rows[0].records, 40)
        XCTAssertEqual(log.rows[0].startText, "2026/05/01 08:59")
        XCTAssertEqual(log.rows[0].durationText, "41秒")
    }
    func testJournalRowFindsTheVideoSessionByClockB() throws {
        let (data, area) = journalImage()
        let log = try XCTUnwrap(HistoryLog.read(source: MemorySource(data), area: area))
        let src = MemorySource(CatalogTests().fixture([Spec(record: 10, start: true)]))
        let video = try CatalogScanner.scan(src).recordings
        let c = try XCTUnwrap(video.first?.blocks.first?.first.telemetry.clock)
        let s = CivilTime.seconds(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second)
        let row = HistoryRow(id: 0, kind: .session, start: s - 61, videoClockStart: s - 1, duration: 10, records: 10, deviceID: nil)
        XCTAssertEqual(log.matchingRecording(for: row, in: video)?.id, video.first?.id)
        let far = HistoryRow(id: 1, kind: .session, start: s + 9999, videoClockStart: s + 10000, duration: 10, records: 10, deviceID: nil)
        XCTAssertNil(log.matchingRecording(for: far, in: video))
    }
    func testListKindsCarryTheOriginalTabNames() {
        XCTAssertEqual(RecordListKind.allCases.map(\.title), ["履歴記録", "イベント記録", "常時録画"])
    }
}
