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
    public static func locate(in source: ByteSource) throws -> ControlHeader {
        let mbr = try source.read(at: 0, count: 512)
        let parts = try PartitionTable.parse(mbr, diskBytes: source.byteCount)
        let candidates = [legacySector] + parts.map { UInt64($0.firstSector) + UInt64($0.sectorCount) }
        let marker = Data("YP_FORMAT_1.01__\0".utf8)
        for lba in Array(Set(candidates)).sorted() {
            guard lba < source.byteCount / 512 else { continue }
            let h = try source.read(at: lba * 512, count: 512)
            guard h.subdata(in: 1..<18) == marker, h.subdata(in: 0x1EC..<0x1FD) == marker else { continue }
            let first = UInt64(try Bytes(h).le32(0x1BE))
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
    public let cardTime: String
    public var payloadOffset: UInt64 { (headerSector + 1) * 512 }
    public var isIntra: Bool { codingKind == 2 }
    public static func parse(_ h: Data, sector: UInt64, diskBytes: UInt64) throws -> FramePacket {
        guard h.count == 512 else { throw BrowserError.truncated("パケットヘッダーが不足しています") }
        let b = Bytes(h)
        guard try b.le32(0) == 0xFFFFD101 else { throw BrowserError.invalid("映像パケットの署名が不正です") }
        let seq = try b.le32(4), selfSector = UInt64(try b.le32(0x1B0)), tail = UInt64(try b.le32(0x1B4))
        let span = UInt64(try b.le32(0x1AC)), n = UInt64(try b.le32(0x1A6)), aux = UInt64(try b.le32(0x1BC))
        guard selfSector == sector, tail > sector + 1, tail < diskBytes / 512,
              tail - sector + 1 == span, try b.le32(0x1FC) == seq else { throw BrowserError.invalid("映像パケットの参照範囲が不正です") }
        let capacity = (tail - sector - 1) * 512
        guard n > 0, n <= 16 * 1024 * 1024, n <= capacity, aux <= 65536,
              (n + 511) / 512 * 512 + aux <= capacity else { throw BrowserError.invalid("映像または補助データの長さが不正です") }
        let rate = try b.le32(0x1E8)
        let t = try (0xA..<0x10).map { try b.u8($0) }
        let validTime = (1...12).contains(Int(t[1])) && (1...31).contains(Int(t[2])) && t[3] < 24 && t[4] < 60 && t[5] < 60
        let time = validTime ? String(format: "%04d-%02d-%02d %02d:%02d:%02d", 2000 + Int(t[0]), Int(t[1]), Int(t[2]), Int(t[3]), Int(t[4]), Int(t[5])) : "時刻不明"
        return FramePacket(headerSector: sector, trailerSector: tail, sequence: seq, recordSector: try b.le32(0x1B8), channel: try b.u8(8), codingKind: try b.u8(9), videoBytes: Int(n), auxiliaryBytes: Int(aux), rawField1E8: rate, cardTime: time)
    }
}

public struct Recording: Identifiable, Sendable {
    public let id: String
    public let recordSector: UInt32
    public let channel: UInt8
    public var packets: [FramePacket]
    public var startTime: String { packets.first?.cardTime ?? "時刻不明" }
    public var endTime: String { packets.last?.cardTime ?? "時刻不明" }
    public var videoBytes: Int { packets.reduce(0) { $0 + $1.videoBytes } }
}
public struct ImageIndex: Sendable {
    public let control: ControlHeader
    public let recordings: [Recording]
    public let scannedBytes: UInt64
    public let isPartialScan: Bool
    public let rejectedCandidates: Int
    public var frameCount: Int { recordings.reduce(0) { $0 + $1.packets.count } }
}

public enum ImageScanner {
    /// All offsets are source-absolute. A limited scan is explicitly reported as partial.
    public static func scan(_ source: ByteSource, limitBytes: UInt64? = nil,
                            cancelled: () -> Bool = { false },
                            progress: (UInt64, UInt64, Int) -> Void = { _, _, _ in }) throws -> ImageIndex {
        let control = try ControlHeader.locate(in: source)
        let start = control.firstRecordSector * 512
        let end = start + min(limitBytes ?? source.byteCount, source.byteCount - start)
        var sector = control.firstRecordSector, cacheStart = UInt64.max, cache = Data()
        var groups: [String: Recording] = [:], count = 0, rejected = 0
        var lastProgress: UInt64 = 0
        func header(_ offset: UInt64) throws -> Data {
            guard offset <= end, 512 <= end - offset else { throw BrowserError.truncated("走査範囲の終端です") }
            if cacheStart == UInt64.max || offset < cacheStart || offset - cacheStart + 512 > UInt64(cache.count) {
                cacheStart = offset
                cache = try source.read(at: offset, count: Int(min(4 * 1024 * 1024, end - offset)))
            }
            let i = Int(offset - cacheStart)
            return cache.subdata(in: i..<(i + 512))
        }
        while sector < end / 512 {
            if cancelled() { throw BrowserError.io("走査をキャンセルしました") }
            let offset = sector * 512, h = try header(offset), b = Bytes(h)
            if try b.le32(0) == 0xFFFFD101 {
                do {
                    let packet = try FramePacket.parse(h, sector: sector, diskBytes: source.byteCount)
                    if packet.trailerSector * 512 + 512 > end { break }
                    let mirror = try header(packet.trailerSector * 512)
                    guard try Bytes(mirror).le32(0) == 0xFFFFD102, h.dropFirst(4) == mirror.dropFirst(4) else {
                        throw BrowserError.invalid("対になるパケットヘッダーが一致しません")
                    }
                    let key = "\(packet.recordSector)-\(packet.channel)"
                    if groups[key] == nil { groups[key] = Recording(id: key, recordSector: packet.recordSector, channel: packet.channel, packets: []) }
                    groups[key]!.packets.append(packet); count += 1
                    sector = packet.trailerSector + 1
                } catch { rejected += 1; sector += 1 }
            } else { sector += 1 }
            let covered = min(sector * 512, end) - start
            if covered - min(covered, lastProgress) >= 8 * 1024 * 1024 {
                progress(covered, end - start, count); lastProgress = covered
            }
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
        let covered = min(sector * 512, end) - start
        progress(covered, end - start, count)
        return ImageIndex(control: control, recordings: recordings, scannedBytes: covered,
                          isPartialScan: end < source.byteCount, rejectedCandidates: rejected)
    }
}

public enum AnnexB {
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
