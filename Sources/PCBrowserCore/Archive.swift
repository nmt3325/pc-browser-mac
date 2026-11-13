import Foundation
import CryptoKit

public struct ArchiveSegment: Codable, Sendable {
    public let sourceOffset: UInt64
    public let length: UInt64
    public let storageOffset: UInt64
    public init(sourceOffset: UInt64, length: UInt64, storageOffset: UInt64) {
        self.sourceOffset = sourceOffset; self.length = length; self.storageOffset = storageOffset
    }
}
public struct ArchiveManifest: Codable, Sendable {
    public let formatVersion: Int
    public let sourceBytes: UInt64
    public let sourceName: String
    public let partial: Bool
    public let payloadSHA256: String
    public let segments: [ArchiveSegment]
    public init(sourceBytes: UInt64, sourceName: String, payloadSHA256: String, segments: [ArchiveSegment]) {
        formatVersion = 1; self.sourceBytes = sourceBytes; self.sourceName = sourceName
        partial = true; self.payloadSHA256 = payloadSHA256; self.segments = segments
    }
}

/// A selected-recording backup. Missing regions are virtual zeros, never invented recordings.
/// The manifest must identify the copy as partial, even when all currently indexed clips are selected.
public final class ArchiveSource: ByteSource, @unchecked Sendable {
    public let manifest: ArchiveManifest
    private let payload: FileByteSource
    private let verificationLock = NSLock()
    private var verified = false
    public var isHashVerified: Bool { verificationLock.lock(); defer { verificationLock.unlock() }; return verified }
    public var byteCount: UInt64 { manifest.sourceBytes }
    public var isPartialCopy: Bool { true }
    public var scanRanges: [Range<UInt64>]? { manifest.segments.map { $0.sourceOffset..<($0.sourceOffset + $0.length) } }
    public init(url: URL, verifyHash: Bool = true) throws {
        let m = url.appendingPathComponent("manifest.json"), p = url.appendingPathComponent("payload.bin")
        let values = try m.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8*1024*1024 else {
            throw BrowserError.invalid("バックアップのマニフェストが不正です")
        }
        manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: m))
        payload = try FileByteSource(url: p)
        guard manifest.formatVersion == 1, manifest.partial, manifest.sourceBytes >= 1024,
              manifest.sourceBytes <= UInt64(Int64.max), !manifest.segments.isEmpty,
              manifest.payloadSHA256.count == 64 else { throw BrowserError.unsupported("未対応のバックアップ形式です") }
        var sourceEnd: UInt64 = 0, storedEnd: UInt64 = 0
        for s in manifest.segments {
            guard s.sourceOffset >= sourceEnd, s.sourceOffset % 512 == 0, s.length > 0, s.length % 512 == 0,
                  s.sourceOffset <= byteCount, s.length <= byteCount-s.sourceOffset,
                  s.storageOffset == storedEnd, s.storageOffset <= payload.byteCount, s.length <= payload.byteCount-s.storageOffset else {
                throw BrowserError.invalid("バックアップのセグメント範囲が不正です")
            }
            sourceEnd = s.sourceOffset+s.length; storedEnd += s.length
        }
        guard storedEnd == payload.byteCount else { throw BrowserError.invalid("バックアップの長さが一致しません") }
        if verifyHash { try verifyPayload() }
    }
    /// The GUI defers this full-payload read so it never blocks the first catalog.
    /// A deferred archive is visibly unverified until this succeeds.
    public func verifyPayload(cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        var hasher = SHA256(), at: UInt64 = 0
        while at < payload.byteCount {
            if cancelled() { throw BrowserError.io("バックアップの照合をキャンセルしました") }
            let n = Int(min(2*1024*1024,payload.byteCount-at))
            hasher.update(data:try payload.read(at:at,count:n)); at += UInt64(n)
            progress(Double(at)/Double(payload.byteCount))
        }
        guard hasher.finalize().map({String(format:"%02x",$0)}).joined() == manifest.payloadSHA256.lowercased() else {
            throw BrowserError.invalid("バックアップのSHA-256が一致しません")
        }
        verificationLock.lock(); verified = true; verificationLock.unlock()
    }
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, count <= 64*1024*1024, offset <= byteCount, UInt64(count) <= byteCount-offset else {
            throw BrowserError.truncated("バックアップの読み取り範囲が不正です")
        }
        var out = Data(count: count)
        let end = offset+UInt64(count)
        var low = 0, high = manifest.segments.count
        while low < high {
            let mid = (low+high)/2, segment = manifest.segments[mid]
            if segment.sourceOffset+segment.length <= offset { low = mid+1 } else { high = mid }
        }
        for s in manifest.segments.dropFirst(low) {
            if s.sourceOffset >= end { break }
            if s.sourceOffset+s.length <= offset { continue }
            let lo = max(offset,s.sourceOffset), hi = min(end,s.sourceOffset+s.length)
            let data = try payload.read(at:s.storageOffset+lo-s.sourceOffset,count:Int(hi-lo))
            out.replaceSubrange(Int(lo-offset)..<Int(hi-offset),with:data)
        }
        return out
    }
}
public enum SourceOpener {
    public static func open(_ url: URL, verifyArchiveHash: Bool = true) throws -> any ByteSource {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            if !FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
                let parts = try WindowsBackupFolder.resolve(url)
                if !parts.isEmpty { return try WindowsBackupSet(urls:parts) }
            }
            return try ArchiveSource(url:url,verifyHash:verifyArchiveHash)
        }
        let file = try FileByteSource(url: url)
        if try file.read(at:0,count:12) == WindowsBackupSource.magic { return try WindowsBackupSource(storage:file) }
        if url.pathExtension.lowercased() == "bak" { throw BrowserError.invalid("対応するBAKの署名がありません") }
        return file
    }
}
public enum ArchiveWriter {
    /// Creates a new compact directory atomically. Neither an existing destination nor the source is overwritten.
    public static func write(source: any ByteSource, index: ImageIndex, recordings: [Recording], name: String, to destination: URL,
                             cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws {
        guard !recordings.isEmpty, !FileManager.default.fileExists(atPath: destination.path) else {
            throw BrowserError.invalid("空の選択または既存の出力先にはバックアップできません")
        }
        var ranges: [Range<UInt64>] = [0..<512, (index.control.sector*512)..<((index.control.sector+2)*512)]
        // Mirror pair of the recording partition, so the archive can later be written as a genuine-layout BAK.
        for r in try WindowsBackupLayout.fixedSectors(source:source,control:index.control.sector) { ranges.append((r.lowerBound*512)..<(r.upperBound*512)) }
        for r in recordings {
            guard r.isLoaded, !r.packets.isEmpty else { throw BrowserError.invalid("バックアップ前に選択録画の索引を読み込んでください") }
            for record in Set(r.packets.map(\.recordSector)) {
                ranges.append((UInt64(record)*512)..<((UInt64(record)+2)*512))
            }
            for p in r.packets { ranges.append((p.headerSector*512)..<((p.trailerSector+1)*512)) }
            // Block header and trailer pairs next to the packets (D103/D105 ... D106/D104) belong to the block.
            for chunk in try WindowsBackupLayout.chunks(for:r,source:source) { ranges.append((chunk.sectors.lowerBound*512)..<(chunk.sectors.upperBound*512)) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<UInt64>] = []
        for r in ranges {
            guard r.upperBound <= source.byteCount else { throw BrowserError.invalid("バックアップ範囲が入力を超えています") }
            if let last = merged.last, r.lowerBound <= last.upperBound { merged[merged.count-1] = last.lowerBound..<max(last.upperBound,r.upperBound) }
            else { merged.append(r) }
        }
        let total = merged.reduce(UInt64(0)) { $0+$1.upperBound-$1.lowerBound }
        let fm = FileManager.default, parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".pcbrowser-\(UUID().uuidString).partial",isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at:staging) } }
        let file = staging.appendingPathComponent("payload.bin")
        guard fm.createFile(atPath:file.path,contents:nil) else { throw BrowserError.io("バックアップを作成できません") }
        let h = try FileHandle(forWritingTo:file)
        defer { try? h.close() }
        var sha = SHA256(), stored: UInt64 = 0, segments: [ArchiveSegment] = []
        for r in merged {
            segments.append(.init(sourceOffset:r.lowerBound,length:r.upperBound-r.lowerBound,storageOffset:stored))
            var at = r.lowerBound
            while at < r.upperBound {
                if cancelled() { throw BrowserError.io("バックアップをキャンセルしました") }
                let n = Int(min(2*1024*1024,r.upperBound-at)), data = try source.read(at:at,count:n)
                try h.write(contentsOf:data);sha.update(data:data);at += UInt64(n);stored += UInt64(n)
                progress(total > 0 ? Double(stored)/Double(total) : 1)
            }
        }
        try h.synchronize()
        let manifest = ArchiveManifest(sourceBytes:source.byteCount,sourceName:name,payloadSHA256:sha.finalize().map{String(format:"%02x",$0)}.joined(),segments:segments)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(manifest).write(to:staging.appendingPathComponent("manifest.json"),options:.atomic)
        try fm.moveItem(at:staging,to:destination);committed = true
    }
}
