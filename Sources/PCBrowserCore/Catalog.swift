import Foundation

/// A bounded reference read without decoding video, PCM or per-frame telemetry.
struct PacketReference: Sendable {
    let sector: UInt64, tail: UInt64
    let sequence: UInt32, record: UInt32, recordID: UInt32, generation: UInt32
    let channel: UInt8, previous: UInt64
    let videoBytes: Int, auxiliaryBytes: Int
    init(_ h: Data, sector: UInt64, diskBytes: UInt64) throws {
        guard h.count == 512 else { throw BrowserError.truncated("パケットヘッダーが不足しています") }
        let b = Bytes(h)
        guard try b.le32(0) == 0xFFFFD101 else { throw BrowserError.invalid("映像パケットの署名が不正です") }
        let seq = try b.le32(4), selfSector = UInt64(try b.le32(0x1B0)), end = UInt64(try b.le32(0x1B4))
        let span = UInt64(try b.le32(0x1AC)), n = UInt64(try b.le32(0x1A6)), aux = UInt64(try b.le32(0x1BC))
        guard selfSector == sector, end > sector + 1, end < diskBytes / 512,
              end - sector + 1 == span, try b.le32(0x1FC) == seq else { throw BrowserError.invalid("映像パケットの参照範囲が不正です") }
        let capacity = (end - sector - 1) * 512
        guard n > 0, n <= 16 * 1024 * 1024, n <= capacity, aux <= 65536,
              (n + 511) / 512 * 512 + aux <= capacity else { throw BrowserError.invalid("映像または補助データの長さが不正です") }
        self.sector = sector; tail = end; sequence = seq; record = try b.le32(0x1B8)
        recordID = try b.le32(0x1DC); generation = try b.le32(0x1D8)
        channel = try b.u8(8); previous = UInt64(try b.le32(0x1C0)); videoBytes = Int(n); auxiliaryBytes = Int(aux)
    }
}

/// D103/D105 identify stream segments. Offsets 1C4/98/9C
/// retain the session origin, cumulative frame ordinal and session serial.
/// Ring-wrap generation 1F8 is NOT an ignition/session identifier.
public struct RecordMetadata: Sendable {
    public let sector: UInt32, identifier: UInt32, generation: UInt32
    public let sessionSector: UInt32, sessionSerial: UInt32, frameOffset: UInt32
    public let startsSession: Bool
    public let formatKey: String
    static func parse(_ h: Data, sector: UInt32) throws -> RecordMetadata {
        let b = Bytes(h), magic = try b.le32(0)
        guard h.count == 512, [0xFFFFD103,0xFFFFD105].contains(magic),
              try b.le32(4) == b.le32(0x1FC), try b.le32(0x1E0) == sector else {
            throw BrowserError.invalid("録画管理ヘッダーの参照が不正です")
        }
        let root = try b.le32(0x1C4), ordinal = try b.le32(0x98)
        guard root > 0 else {
            throw BrowserError.invalid("録画開始・継続の参照が不正です")
        }
        // Only media-format fields participate; user display/settings do not split a session.
        let format = h.subdata(in:0xC..<0x34).map { String(format:"%02x",$0) }.joined()
        return .init(sector:sector,identifier:try b.le32(4),generation:try b.le32(0x1F8),
                     sessionSector:root,sessionSerial:try b.le32(0x9C),frameOffset:ordinal,
                     startsSession:magic == 0xFFFFD103 && root == sector && ordinal == 0,formatKey:format)
    }
    func matches(_ p: PacketReference) -> Bool { p.record == sector && p.recordID == identifier && p.generation == generation }
}

/// Boundaries are checked packet pairs. Intermediate packets remain unloaded.
public struct RecordBlock: Sendable {
    public let recordSector: UInt32, channel: UInt8
    public let first: FramePacket, last: FramePacket
    public let metadata: RecordMetadata?
    public let frameCount: Int
    public let countIsEstimate: Bool
    public var sectorRange: Range<UInt64> { first.headerSector..<(last.trailerSector + 1) }
    var key: String { "\(recordSector)-\(channel)" }
}

public struct RecordingStatistics: Sendable {
    public let hasGPS: Bool, hasAudio: Bool
    public let maximumSpeedKMH: Double?
    public static func make(_ packets: [FramePacket]) -> RecordingStatistics {
        .init(hasGPS:packets.contains { $0.telemetry.coordinate() != nil },
              hasAudio:packets.contains { $0.auxiliaryBytes > 0 },
              maximumSpeedKMH:packets.compactMap { $0.telemetry.speedKMH }.max())
    }
}

/// Groups verified session references, not merely timestamps which happen to be close.
/// Unreferenced/recovery fragments stay separate rather than being assigned a guessed boot.
public enum RecordingSessions {
    public static func group(_ blocks: [RecordBlock]) -> [Recording] {
        var groups: [String:[RecordBlock]] = [:]
        for b in blocks {
            let key: String
            if let m = b.metadata {
                key = "session-\(m.sessionSector)-\(m.sessionSerial)-\(b.channel)-\(m.formatKey)"
            } else { key = "fragment-\(b.key)" }
            groups[key,default:[]].append(b)
        }
        var result: [Recording] = []
        for (key,parts) in groups {
            let ordered = parts.sorted { a,b in
                if let x = a.metadata, let y = b.metadata, x.frameOffset != y.frameOffset { return x.frameOffset < y.frameOffset }
                if a.first.cardTime != b.first.cardTime { return a.first.cardTime < b.first.cardTime }
                return a.first.headerSector < b.first.headerSector
            }
            guard let first = ordered.first else { continue }
            result.append(.init(id:key,recordSector:first.recordSector,channel:first.channel,packets:[],blocks:ordered))
        }
        return result.sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
    }

    /// Recovery keeps every already validated packet, including orphaned fragments.
    static func groupValidated(_ records: [Recording], source: any ByteSource) -> [Recording] {
        var packetGroups: [String:[FramePacket]] = [:], blocks: [RecordBlock] = []
        for r in records {
            guard let first = r.packets.first, let last = r.packets.last else { continue }
            let meta = try? RecordMetadata.parse(source.read(at:UInt64(r.recordSector)*512,count:512),sector:r.recordSector)
            // A reused ring address must not attach stale packets to a newer session.
            let validMeta: RecordMetadata?
            if let meta, let h = try? source.read(at:first.headerSector*512,count:512),
               let p = try? PacketReference(h,sector:first.headerSector,diskBytes:source.byteCount), meta.matches(p) { validMeta = meta }
            else { validMeta = nil }
            let block = RecordBlock(recordSector:r.recordSector,channel:r.channel,first:first,last:last,metadata:validMeta,frameCount:r.packets.count,countIsEstimate:false)
            blocks.append(block); packetGroups[block.key] = r.packets
        }
        return group(blocks).map { r in
            var loaded = r
            loaded.packets = r.blocks.flatMap { packetGroups[$0.key] ?? [] }
            loaded.statistics = RecordingStatistics.make(loaded.packets)
            return loaded
        }
    }
}

private final class CatalogMeter: ByteSource, @unchecked Sendable {
    let base: any ByteSource
    var bytes: UInt64 = 0, calls = 0
    init(_ base: any ByteSource) { self.base = base }
    var byteCount: UInt64 { base.byteCount }
    var scanRanges: [Range<UInt64>]? { base.scanRanges }
    var isPartialCopy: Bool { base.isPartialCopy }
    func read(at offset: UInt64, count: Int) throws -> Data {
        bytes += UInt64(max(0,count)); calls += 1
        return try base.read(at:offset,count:count)
    }
}

public enum CatalogScanner {
    /// Header-only catalog. No H.264/PCM payload reads and no persistent cache.
    /// Existing last->first backlinks skip completed 15s blocks. Unlinked blocks
    /// use a bounded forward header walk. Unknown gaps are explicitly recoverable.
    public static func scan(_ input: any ByteSource, limitBytes: UInt64? = nil,
                            cancelled: () -> Bool = { false },
                            progress: (ImageIndex,Double) -> Void = { _,_ in }) throws -> ImageIndex {
        let source = CatalogMeter(input)
        let control = try ControlHeader.locate(in:source)
        let start = control.firstRecordSector, diskEnd = source.byteCount/512
        let end = start + min((limitBytes ?? source.byteCount)/512,diskEnd-start)
        let controlBytes = try source.read(at:control.sector*512,count:512), cb = Bytes(controlBytes)
        var regions: [Range<UInt64>] = [start..<end]
        // The original control table distinguishes normal/event/history regions.
        // E202 history is not treated as H.264 data. Invalid bounds use the safe generic path.
        let a = UInt64(try cb.le32(0x1C2)), b = UInt64(try cb.le32(0x1C6)), c = UInt64(try cb.le32(0x1CA))
        if start < a, a <= b, b < c, c <= diskEnd {
            regions = [start..<min(a,end)]
            if b < end { regions.append(b..<min(c,end)) }
        }
        let available = source.scanRanges?.map { ($0.lowerBound+511)/512..<($0.upperBound/512) }
        if let available {
            regions = regions.flatMap { region in available.compactMap { r in
                let lo = max(region.lowerBound,r.lowerBound), hi = min(region.upperBound,r.upperBound)
                return lo < hi ? lo..<hi : nil
            }}
        }
        func present(_ lba: UInt64) -> Bool {
            guard lba < diskEnd, lba >= start, lba < end else { return false }
            return available?.contains { $0.contains(lba) } ?? true
        }
        var metadataCache: [UInt32:RecordMetadata] = [:], badMetadata = Set<UInt32>()
        func read(_ sector: UInt64) throws -> Data {
            guard present(sector) else { throw BrowserError.truncated("未取得または走査範囲外のセクターです") }
            return try source.read(at:sector*512,count:512)
        }
        func metadata(_ sector: UInt32) -> RecordMetadata? {
            if let m = metadataCache[sector] { return m }; if badMetadata.contains(sector) { return nil }
            guard let h = try? read(UInt64(sector)), let m = try? RecordMetadata.parse(h,sector:sector), UInt64(m.sessionSector) >= start, UInt64(m.sessionSector) < diskEnd else {
                badMetadata.insert(sector); return nil
            }
            metadataCache[sector] = m; return m
        }
        func checked(_ sector: UInt64, header: Data? = nil) throws -> (PacketReference,Data) {
            let h = try header ?? read(sector), ref = try PacketReference(h,sector:sector,diskBytes:source.byteCount)
            let tail = try read(ref.tail)
            guard try Bytes(tail).le32(0) == 0xFFFFD102, h.dropFirst(4) == tail.dropFirst(4) else {
                throw BrowserError.invalid("対になるパケットヘッダーが一致しません")
            }
            return (ref,h)
        }
        var blocks: [String:RecordBlock] = [:], skippable: [UInt64:RecordBlock] = [:], rejected = 0, recovery = false, backward = 0
        var lastPublished = Date.timeIntervalSinceReferenceDate
        func index() -> ImageIndex {
            ImageIndex(control:control,recordings:RecordingSessions.group(Array(blocks.values)),scannedBytes:source.bytes,
                       isPartialScan:limitBytes != nil && end < diskEnd || source.isPartialCopy,rejectedCandidates:rejected,
                       isMetadataCatalog:true,recoveryRecommended:recovery,catalogReadCalls:source.calls,backlinkBlocks:backward)
        }
        func publish(_ fraction: Double, force: Bool = false) {
            let now = Date.timeIntervalSinceReferenceDate
            if force || now-lastPublished >= 0.15 { progress(index(),fraction); lastPublished = now }
        }
        // Single-camera layout: the control stores one metadata sector per camera.
        // Only activate this accelerator when the actual first packet verifies that layout.
        if try cb.u8(0x14) == 1, present(start+2), let (seed,_) = try? checked(start+2) {
            var cursor = seed.previous, seen = Set<UInt64>()
            while cursor > 0, seen.insert(cursor).inserted, seen.count <= 200_000 {
                if cancelled() { throw BrowserError.io("索引取得をキャンセルしました") }
                guard let (lastRef,lastH) = try? checked(cursor),
                      let m = metadata(lastRef.record), m.matches(lastRef),
                      let (firstRef,firstH) = try? checked(UInt64(lastRef.record)+2), m.matches(firstRef),
                      firstRef.channel == lastRef.channel, firstRef.sequence == 0,
                      lastRef.sequence < 120*60*60,
                      firstRef.sector <= lastRef.sector,
                      let first = try? FramePacket.parse(firstH,sector:firstRef.sector,diskBytes:source.byteCount),
                      let last = try? FramePacket.parse(lastH,sector:lastRef.sector,diskBytes:source.byteCount) else { break }
                let block = RecordBlock(recordSector:lastRef.record,channel:lastRef.channel,first:first,last:last,
                                        metadata:m,frameCount:Int(lastRef.sequence)+1,countIsEstimate:true)
                if blocks[block.key] != nil { break }
                blocks[block.key] = block; skippable[UInt64(block.recordSector)] = block; backward += 1; cursor = firstRef.previous
                publish(backward == 1 ? 0.01:0.05,force:backward == 1)
            }
        }
        let total = regions.reduce(UInt64(0)) { $0+$1.upperBound-$1.lowerBound }
        var covered: UInt64 = 0
        for range in regions {
            var sector = range.lowerBound, zeros = 0, unknown = 0
            while sector < range.upperBound {
                if cancelled() { throw BrowserError.io("索引取得をキャンセルしました") }
                // A known block is skipped only at its metadata/start, not midway.
                if let block = skippable[sector],
                   block.last.trailerSector < range.upperBound {
                    sector = block.last.trailerSector+1; zeros = 0; unknown = 0
                    continue
                }
                let h = try read(sector), magic = try Bytes(h).le32(0)
                if magic == 0xFFFFD101 {
                    do {
                        let (ref,_) = try checked(sector,header:h)
                        guard ref.tail < range.upperBound else { recovery = true; break }
                        let key = "\(ref.record)-\(ref.channel)"
                        let existing = blocks[key]
                        let parsed: FramePacket?
                        // Telemetry only for boundary packets. Each forward header pair is still checked.
                        if existing == nil || ref.sequence == 0 { parsed = try FramePacket.parse(h,sector:sector,diskBytes:source.byteCount) }
                        else { parsed = nil }
                        let m = metadata(ref.record).flatMap { $0.matches(ref) ? $0 : nil }
                        if let old = existing, !old.countIsEstimate {
                            // Last boundary must carry real telemetry; this allocation is small and never media.
                            let last = try FramePacket.parse(h,sector:sector,diskBytes:source.byteCount)
                            blocks[key] = .init(recordSector:old.recordSector,channel:old.channel,first:old.first,last:last,
                                                metadata:old.metadata,frameCount:old.frameCount+1,countIsEstimate:false)
                        } else if existing == nil {
                            let p = try parsed ?? FramePacket.parse(h,sector:sector,diskBytes:source.byteCount)
                            blocks[key] = .init(recordSector:ref.record,channel:ref.channel,first:p,last:p,metadata:m,frameCount:1,countIsEstimate:false)
                        }
                        sector = ref.tail+1; zeros = 0; unknown = 0
                    } catch {
                        rejected += 1; sector += 1; unknown += 1; recovery = true
                    }
                } else if [0xFFFFD103,0xFFFFD104,0xFFFFD105,0xFFFFD106].contains(magic) {
                    sector += 1; zeros = 0; unknown = 0
                } else {
                    sector += 1; unknown += 1
                    zeros = h.allSatisfy { $0 == 0 } ? zeros+1 : 0
                    // An indexed catalog is not a forensic full-disk scan. Never silently claim
                    // empty/unknown tails contain no recoverable data. Offer explicit recovery.
                    if zeros >= 8 || unknown >= 4096 { recovery = true; break }
                }
                let fraction = total > 0 ? Double(covered+sector-range.lowerBound)/Double(total) : 1
                publish(min(0.99,max(0.05,fraction)))
            }
            covered += range.upperBound-range.lowerBound
        }
        publish(1,force:true)
        return index()
    }

    /// Lazily validates every frame header/trailer only in the selected session.
    /// Media payloads are fetched later by the decoder/audio reader.
    public static func loadRecording(_ summary: Recording, source: any ByteSource,
                                     cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> Recording {
        if summary.isLoaded { return summary }
        var packets: [FramePacket] = [], seen = Set<UInt64>()
        packets.reserveCapacity(min(summary.frameCount,1_000_000))
        for (i,block) in summary.blocks.enumerated() {
            var sector = block.first.headerSector
            while sector <= block.last.headerSector {
                if cancelled() { throw BrowserError.io("録画の読み込みをキャンセルしました") }
                let h = try source.read(at:sector*512,count:512)
                let ref = try PacketReference(h,sector:sector,diskBytes:source.byteCount)
                guard ref.record == block.recordSector, ref.channel == block.channel,
                      ref.tail <= block.last.trailerSector,
                      block.metadata?.matches(ref) ?? true else { throw BrowserError.invalid("録画の索引が変更または破損しています。復旧走査を試してください") }
                let tail = try source.read(at:ref.tail*512,count:512)
                guard try Bytes(tail).le32(0) == 0xFFFFD102, h.dropFirst(4) == tail.dropFirst(4),
                      seen.insert(sector).inserted else { throw BrowserError.invalid("録画パケットの照合に失敗しました") }
                packets.append(try FramePacket.parse(h,sector:sector,diskBytes:source.byteCount))
                sector = ref.tail+1
            }
            progress(Double(i+1)/Double(max(1,summary.blocks.count)))
        }
        guard !packets.isEmpty else { throw BrowserError.invalid("録画に再生可能なフレームがありません") }
        var result = summary; result.packets = packets; result.statistics = RecordingStatistics.make(packets)
        return result
    }
}
