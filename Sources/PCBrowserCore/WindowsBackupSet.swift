import Foundation

/// A folder of BDRBACKUP___ parts written by one backup run, merged into one read-only virtual image.
///
/// The original PC Browser 1.9.60.0 splits a backup into several independent `.bak` files
/// (`<device number>_<yyyyMMdd>_<HHmmss>.bak`) inside a folder named after the start of the run.
/// Every part repeats the MBR, the control sector pair and the mirror pair of the card, so a part is
/// a self-contained partial image. Overlaps between parts are accepted only when their bytes are
/// identical; a mismatch means the folder mixes different cards or different backups.
public final class WindowsBackupSet: ByteSource, @unchecked Sendable {
    public let parts: [WindowsBackupSource]
    public let partNames: [String]
    public let byteCount: UInt64
    public var isPartialCopy: Bool { true }
    public var scanRanges: [Range<UInt64>]? { merged }
    public var extentCount: Int { parts.reduce(0) { $0+$1.extents.count } }
    public var storedByteCount: UInt64 { parts.reduce(0) { $0+$1.storedByteCount } }
    private struct Piece: Sendable { let lower: UInt64; let upper: UInt64; let part: Int }
    private let pieces: [Piece]
    private let merged: [Range<UInt64>]

    public convenience init(urls: [URL]) throws {
        var parts: [WindowsBackupSource] = []
        for url in urls { parts.append(try WindowsBackupSource(url:url)) }
        try self.init(parts:parts,names:urls.map(\.lastPathComponent))
    }

    public init(parts: [WindowsBackupSource], names: [String]) throws {
        guard !parts.isEmpty, parts.count == names.count, parts.count <= 4096 else {
            throw BrowserError.invalid("BAKファイルがないか、数が不正です")
        }
        struct Item { let lower: UInt64; let upper: UInt64; let part: Int }
        var items: [Item] = []
        for (i,p) in parts.enumerated() {
            for e in p.extents { items.append(Item(lower:e.sourceOffset,upper:e.sourceOffset+e.length,part:i)) }
        }
        items.sort {
            if $0.lower != $1.lower { return $0.lower < $1.lower }
            if $0.upper != $1.upper { return $0.upper > $1.upper }
            return $0.part < $1.part
        }
        var pieces: [Piece] = [], cursor: UInt64 = 0
        for item in items {
            // Sorted by start, so everything below `cursor` and above `item.lower` is already owned.
            if item.lower < cursor {
                try Self.verifyOverlap(parts:parts,pieces:pieces,lower:item.lower,upper:min(item.upper,cursor),part:item.part)
            }
            if item.upper > cursor {
                pieces.append(Piece(lower:max(item.lower,cursor),upper:item.upper,part:item.part))
                cursor = item.upper
            }
        }
        var merged: [Range<UInt64>] = []
        for p in pieces {
            if let last = merged.last, last.upperBound == p.lower { merged[merged.count-1] = last.lowerBound..<p.upper }
            else { merged.append(p.lower..<p.upper) }
        }
        self.parts = parts
        self.partNames = names
        self.pieces = pieces
        self.merged = merged
        self.byteCount = parts.map(\.byteCount).max() ?? 0
    }

    private static func firstPiece(_ pieces: [Piece], endingAfter offset: UInt64) -> Int {
        var low = 0, high = pieces.count
        while low < high {
            let mid = (low+high)/2
            if pieces[mid].upper <= offset { low = mid+1 } else { high = mid }
        }
        return low
    }

    private static func verifyOverlap(parts: [WindowsBackupSource], pieces: [Piece], lower: UInt64, upper: UInt64, part: Int) throws {
        var at = lower, index = firstPiece(pieces,endingAfter:lower)
        while at < upper, index < pieces.count {
            let p = pieces[index]
            if p.lower >= upper { break }
            let lo = max(at,p.lower), hi = min(upper,p.upper)
            var position = lo
            while position < hi {
                let n = Int(min(4*1024*1024,hi-position))
                guard try parts[p.part].read(at:position,count:n) == parts[part].read(at:position,count:n) else {
                    throw BrowserError.invalid("BAKファイル同士で重複範囲の内容が一致しません。別のカード、または別のバックアップのファイルが同じフォルダーに混在している可能性があります")
                }
                position += UInt64(n)
            }
            if hi > at { at = hi }
            index += 1
        }
    }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, count <= 64*1024*1024, offset <= byteCount, UInt64(count) <= byteCount-offset else {
            throw BrowserError.truncated("BAKの読み取り範囲が不正です")
        }
        var out = Data(count:count)
        let end = offset+UInt64(count)
        var index = Self.firstPiece(pieces,endingAfter:offset)
        while index < pieces.count {
            let p = pieces[index]
            if p.lower >= end { break }
            let lo = max(offset,p.lower), hi = min(end,p.upper)
            if lo < hi {
                out.replaceSubrange(Int(lo-offset)..<Int(hi-offset),with:try parts[p.part].read(at:lo,count:Int(hi-lo)))
            }
            index += 1
        }
        return out
    }
}

/// Locates the `.bak` parts of a backup folder without following symbolic links.
public enum WindowsBackupFolder {
    public static func isBackupFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom:url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount:12)) == WindowsBackupSource.magic
    }

    /// Direct children whose signature is BDRBACKUP___, ordered by file name.
    public static func files(in directory: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])
        return entries.filter { $0.pathExtension.lowercased() == "bak" && isBackupFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The folder itself when it directly holds parts, otherwise its only child folder that does.
    /// Several dated child folders are ambiguous (each one is a separate backup run), so the user must choose one.
    public static func resolve(_ directory: URL) throws -> [URL] {
        let direct = try files(in:directory)
        if !direct.isEmpty { return direct }
        let children = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])
        var candidates: [(URL,[URL])] = []
        for child in children.sorted(by:{ $0.lastPathComponent < $1.lastPathComponent }) {
            guard let v = try? child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]), v.isDirectory == true, v.isSymbolicLink != true else { continue }
            let list = try files(in:child)
            if !list.isEmpty { candidates.append((child,list)) }
        }
        if candidates.count > 1 {
            let names = candidates.prefix(6).map { $0.0.lastPathComponent }.joined(separator:"、")
            throw BrowserError.invalid("複数のバックアップフォルダーがあります。日時名のフォルダー（\(names)など）を1つ選択してください")
        }
        return candidates.first?.1 ?? []
    }
}
