import Foundation
import Darwin

/// Owns a descriptor opened O_RDONLY. No write, mount, eject or format operations.
public final class FileByteSource: ByteSource, @unchecked Sendable {
    public let byteCount: UInt64
    private let fd: Int32
    private let alignedDevice: Bool
    public convenience init(url: URL) throws {
        let f = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard f >= 0 else { throw BrowserError.io("ファイルを開けません: \(String(cString: strerror(errno)))") }
        var st = stat()
        guard fstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 512 else {
            close(f); throw BrowserError.invalid("通常のディスクイメージファイルを選択してください")
        }
        try self.init(readonlyDescriptor: f, byteCount: UInt64(st.st_size), alignedDevice: false)
    }
    /// Takes ownership on success. Intended only for the validated helper's descriptor.
    public init(readonlyDescriptor fd: Int32, byteCount: UInt64, alignedDevice: Bool) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY, byteCount >= 512 else {
            close(fd); throw BrowserError.invalid("読み取り専用の入力ではありません")
        }
        self.fd = fd; self.byteCount = byteCount; self.alignedDevice = alignedDevice
    }
    deinit { close(fd) }
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, count <= 64 * 1024 * 1024, offset <= byteCount,
              UInt64(count) <= byteCount - offset else { throw BrowserError.truncated("読み取り範囲が入力を超えています") }
        if count == 0 { return Data() }
        let start = alignedDevice ? offset / 512 * 512 : offset
        let stop = alignedDevice ? (offset + UInt64(count) + 511) / 512 * 512 : offset + UInt64(count)
        guard stop <= byteCount, stop <= UInt64(Int64.max) else { throw BrowserError.truncated("セクター境界が入力を超えています") }
        let total = Int(stop - start)
        var data = Data(count: total)
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var done = 0
            while done < total {
                let n = pread(fd, raw.baseAddress!.advanced(by: done), total - done, off_t(start + UInt64(done)))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BrowserError.io("データを読み取れません。カードの取り外しや入力の変更を確認してください") }
                done += n
            }
        }
        let skip = Int(offset - start)
        return data.subdata(in: skip..<(skip + count))
    }
}

public struct ControlHeader: Sendable {
    public let sector: UInt64
    public let firstRecordSector: UInt64
    public static let legacySector: UInt64 = 0xE37BA
    /// First record sector from the region table. A card set to イベント記録 only has an empty normal region (start 0), so its recordings
    /// begin at the event region's start.
    public static func firstRecordSector(inControl h: Data) throws -> UInt64 {
        let b = Bytes(h), normal = UInt64(try b.le32(0x1BE))
        return normal != 0 ? normal : UInt64(try b.le32(0x1C6))
    }
    public static func locate(in source: ByteSource) throws -> ControlHeader {
        let mbr = try source.read(at: 0, count: 512)
        let parts = try PartitionTable.parse(mbr, diskBytes: source.byteCount)
        let candidates = [legacySector] + parts.map { UInt64($0.firstSector) + UInt64($0.sectorCount) }
        let marker = Data("YP_FORMAT_1.01__\0".utf8)
        for lba in Array(Set(candidates)).sorted() {
            guard lba < source.byteCount / 512 else { continue }
            let h = try source.read(at: lba * 512, count: 512)
            guard h.subdata(in: 1..<18) == marker, h.subdata(in: 0x1EC..<0x1FD) == marker else { continue }
            let first = try firstRecordSector(inControl: h)
            guard first > lba, first < source.byteCount / 512 else { continue }
            return ControlHeader(sector: lba, firstRecordSector: first)
        }
        throw BrowserError.unsupported("YP_FORMAT_1.01の管理領域が見つかりません。この版で未対応のカード形式です")
    }
}

public struct FramePacket: Identifiable, Sendable {
    public var id: UInt64 { headerSector }
    public let headerSector: UInt64
    public let trailerSector: UInt64
    public let sequence: UInt32
    public let recordSector: UInt32
    public let channel: UInt8
    public let codingKind: UInt8
    public let videoBytes: Int
    public let auxiliaryBytes: Int
    /// Observed as 15 in the sample; NOT established to be a frame rate.
    public let rawField1E8: UInt32
    public let telemetry: PacketTelemetry
    public var cardTime: String { telemetry.clock?.text ?? "時刻不明" }
    public var auxiliaryOffset: UInt64 { payloadOffset + UInt64((videoBytes+511)/512*512) }
    public var payloadOffset: UInt64 { (headerSector + 1) * 512 }
    public var isIntra: Bool { codingKind == 2 }
    public static func parse(_ h: Data, sector: UInt64, diskBytes: UInt64) throws -> FramePacket {
        let ref = try PacketReference(h,sector:sector,diskBytes:diskBytes), b = Bytes(h)
        return FramePacket(headerSector:sector,trailerSector:ref.tail,sequence:ref.sequence,recordSector:ref.record,
                           channel:ref.channel,codingKind:try b.u8(9),videoBytes:ref.videoBytes,auxiliaryBytes:ref.auxiliaryBytes,
                           rawField1E8:try b.le32(0x1E8),telemetry:try PacketTelemetry.parse(h))
    }
}

public struct Recording: Identifiable, Sendable {
    public let id: String
    public let recordSector: UInt32
    public let channel: UInt8
    public var packets: [FramePacket]
    public let blocks: [RecordBlock]
    public var statistics: RecordingStatistics?
    public init(id:String,recordSector:UInt32,channel:UInt8,packets:[FramePacket],blocks:[RecordBlock]=[],statistics:RecordingStatistics?=nil) {
        self.id=id;self.recordSector=recordSector;self.channel=channel;self.packets=packets;self.blocks=blocks;self.statistics=statistics
    }
    public var isLoaded: Bool { !packets.isEmpty || blocks.isEmpty }
    public var startTime: String { packets.first?.cardTime ?? blocks.first?.first.cardTime ?? "時刻不明" }
    public var endTime: String { packets.last?.cardTime ?? blocks.last?.last.cardTime ?? "時刻不明" }
    public var frameCount: Int { isLoaded ? packets.count : blocks.reduce(0) { $0+$1.frameCount } }
    public var blockCount: Int { blocks.isEmpty ? Set(packets.map(\.recordSector)).count : blocks.count }
    public var hasSessionReference: Bool { blocks.first?.metadata != nil }
    public var estimatedDuration: Double {
        if isLoaded { return RecordingTimeline(packets:packets).duration }
        let fps = Double(blocks.first?.first.telemetry.clock?.nominalFPS ?? 30)
        return Double(frameCount)/fps
    }
    public var videoBytes: Int { packets.reduce(0) { $0+$1.videoBytes } }
}
public struct ImageIndex: Sendable {
    public let control: ControlHeader
    public var recordings: [Recording]
    public let scannedBytes: UInt64
    public let isPartialScan: Bool
    public let rejectedCandidates: Int
    public var isMetadataCatalog = false
    public var recoveryRecommended = false
    public var catalogReadCalls = 0
    public var catalogBoundaryParses = 0
    public var backlinkBlocks = 0
    /// Region table of the control sector, when it is consistent with the disk size.
    public var layout: DiskLayout?
    /// Regions the original does not list because a 削除／初期化 happened after their data was written (`RecordingGeneration`).
    /// The data is still on the card; the recovery scan lists it. Empty when the card has no checksummed generation information.
    public var hiddenRegions: [HiddenRegion] = []
    /// The journal area to read: nil when the journal is absent or hidden by the generation rule.
    public var historyArea: Range<UInt64>? { hiddenRegions.contains { $0.kind == .history } ? nil : layout?.history }
    public var frameCount: Int { recordings.reduce(0) { $0+$1.frameCount } }
    public var validatedFrameCount: Int { recordings.reduce(0) { $0+$1.packets.count } }
    public var blockCount: Int { recordings.reduce(0) { $0+$1.blockCount } }
}

public enum ImageScanner {
    /// All offsets are source-absolute. A limited scan is explicitly reported as partial.
    public static func scan(_ source: ByteSource, limitBytes: UInt64? = nil,
                            cancelled: () -> Bool = { false },
                            progress: (UInt64, UInt64, Int) -> Void = { _, _, _ in }) throws -> ImageIndex {
        let control = try ControlHeader.locate(in: source)
        let start = control.firstRecordSector * 512
        let end = start + min(limitBytes ?? source.byteCount, source.byteCount - start)
        let ranges = (source.scanRanges ?? [start..<end]).compactMap { r -> Range<UInt64>? in
            let lo = max(start, r.lowerBound), hi = min(end, r.upperBound)
            return lo < hi ? lo..<hi : nil
        }
        var sector = control.firstRecordSector, cacheStart = UInt64.max, cache = Data()
        var groups: [String: Recording] = [:], count = 0, rejected = 0
        var lastProgress: UInt64 = 0, covered: UInt64 = 0
        let total = ranges.reduce(UInt64(0)) { $0 + $1.count64 }
        func header(_ offset: UInt64) throws -> Data {
            guard offset <= end, 512 <= end - offset else { throw BrowserError.truncated("走査範囲の終端です") }
            if cacheStart == UInt64.max || offset < cacheStart || offset - cacheStart + 512 > UInt64(cache.count) {
                cacheStart = offset
                cache = try source.read(at: offset, count: Int(min(4 * 1024 * 1024, end - offset)))
            }
            let i = Int(offset - cacheStart)
            return cache.subdata(in: i..<(i + 512))
        }
        for range in ranges {
            sector = (range.lowerBound + 511) / 512
            let rangeEnd = range.upperBound / 512
            let prior = covered
            while sector < rangeEnd {
                if cancelled() { throw BrowserError.io("走査をキャンセルしました") }
                let offset = sector * 512
                // Inspect cached bytes first. Allocate a 512-byte header only for D101.
                if cacheStart == UInt64.max || offset < cacheStart || offset - cacheStart + 512 > UInt64(cache.count) {
                    _ = try header(offset)
                }
                let local = Int(offset - cacheStart)
                let marker: UInt32 = cache.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: local, as: UInt32.self).littleEndian }
                if marker == 0xFFFFD101 {
                    do {
                        let h = cache.subdata(in: local..<(local + 512))
                        let packet = try FramePacket.parse(h, sector: sector, diskBytes: source.byteCount)
                        if packet.trailerSector >= rangeEnd { break }
                        let mirror = try header(packet.trailerSector * 512)
                        guard try Bytes(mirror).le32(0) == 0xFFFFD102, PacketMirror.matches(header: h, mirror: mirror) else {
                            throw BrowserError.invalid("対になるパケットヘッダーが一致しません")
                        }
                        let key = "\(packet.recordSector)-\(packet.channel)"
                        if groups[key] == nil { groups[key] = Recording(id: key, recordSector: packet.recordSector, channel: packet.channel, packets: []) }
                        groups[key]!.packets.append(packet); count += 1
                        sector = packet.trailerSector + 1
                    } catch { rejected += 1; sector += 1 }
                } else {
                    let stop = Int(min(UInt64(cache.count), range.upperBound - cacheStart))
                    let next: Int = cache.withUnsafeBytes { bytes in
                        var j = local + 512
                        while j + 512 <= stop {
                            if bytes.loadUnaligned(fromByteOffset: j, as: UInt32.self).littleEndian == 0xFFFFD101 { return j }
                            j += 512
                        }
                        return j
                    }
                    sector = min(rangeEnd, (cacheStart + UInt64(next)) / 512)
                }
                covered = prior + min(sector * 512, range.upperBound) - range.lowerBound
                if covered - min(covered, lastProgress) >= 8 * 1024 * 1024 {
                    progress(covered, total, count); lastProgress = covered
                }
            }
            covered = prior + range.count64
        }
        var recordings: [Recording] = []
        for var recording in groups.values {
            recording.packets.sort { (a: FramePacket, b: FramePacket) -> Bool in a.sequence < b.sequence }
            recordings.append(recording)
        }
        recordings.sort { (a: Recording, b: Recording) -> Bool in
            if a.startTime == b.startTime { return a.id < b.id }
            return a.startTime < b.startTime
        }
        progress(covered, total, count)
        let layout = (try? source.read(at: control.sector * 512, count: 512)).flatMap {
            DiskLayout(control: $0, firstRecordSector: control.firstRecordSector, diskSectors: source.byteCount / 512)
        }
        return ImageIndex(control: control, recordings: RecordingSessions.groupValidated(recordings,source:source,eventRegion:layout?.eventRegion), scannedBytes: covered,
                          isPartialScan: end < source.byteCount || source.isPartialCopy, rejectedCandidates: rejected, layout: layout)
    }
}

public enum AnnexB {
    /// True when a frame's video area holds only zero bytes (or nothing). The continuous recordings of the sample card keep their
    /// frame headers (clock, GPS, sensors) but their video area is zero-filled, which is not a decoder fault.
    public static func isBlankPayload(_ data: Data) -> Bool { data.allSatisfy { $0 == 0 } }
    /// True when at least one NAL unit is a coded slice (non-IDR or IDR); delimiters, SEI and parameter sets never make a picture.
    public static func hasPicture(_ units: [Data]) -> Bool { units.contains { !$0.isEmpty && [1, 5].contains($0[$0.startIndex] & 31) } }
    /// True when the frame carries no picture: only zero bytes, or only well-formed NAL units that never hold one (a few frames of
    /// the sample card's continuous recordings keep an access-unit delimiter). Non-zero bytes without any start code are damaged
    /// data and stay a decoder error, so a damaged frame is never presented as "no video".
    public static func isPictureless(_ data: Data, units: [Data]) -> Bool { units.isEmpty ? isBlankPayload(data) : !hasPicture(units) }
    public static func units(_ data: Data) -> [Data] {
        let a = Array(data); var starts: [(Int, Int)] = []; var i = 0
        while i + 3 <= a.count {
            if i + 4 <= a.count && a[i] == 0 && a[i+1] == 0 && a[i+2] == 0 && a[i+3] == 1 { starts.append((i,4)); i += 4 }
            else if a[i] == 0 && a[i+1] == 0 && a[i+2] == 1 { starts.append((i,3)); i += 3 }
            else { i += 1 }
        }
        return starts.enumerated().compactMap { j, s in
            var end = j + 1 < starts.count ? starts[j+1].0 : a.count
            while end > s.0 + s.1 && a[end-1] == 0 { end -= 1 }
            return end > s.0 + s.1 ? Data(a[(s.0+s.1)..<end]) : nil
        }
    }
    public static func avcc(_ units: [Data]) throws -> Data {
        var result = Data()
        for n in units where !n.isEmpty && [1,5,6].contains(n[n.startIndex] & 31) {
            guard n.count <= Int(UInt32.max) else { throw BrowserError.invalid("NALが大きすぎます") }
            var size = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }; result.append(n)
        }
        guard !result.isEmpty else { throw BrowserError.unsupported("H.264映像が含まれていません") }
        return result
    }
}

private extension Range where Bound == UInt64 { var count64: UInt64 { upperBound - lowerBound } }
