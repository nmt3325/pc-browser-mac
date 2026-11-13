import Foundation
import CryptoKit

public struct ImageCopySummary: Codable, Sendable {
    public let bytes: UInt64, sha256: String, readbackVerified: Bool
}
/// Copies the input bytes into a new regular image file. This is not a raw-device
/// restore or proof that the input acquisition contains every sector of an SD.
public enum ImageCopy {
    public static func write(source: any ByteSource, to output: URL, chunkBytes: Int = 4 * 1024 * 1024,
                             cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> ImageCopySummary {
        guard output.isFileURL, !output.standardizedFileURL.path.hasPrefix("/dev/"),
              !FileManager.default.fileExists(atPath: output.path), !source.isPartialCopy,
              source.scanRanges == nil, source.byteCount >= 512, source.byteCount <= UInt64(Int64.max),
              (512...16 * 1024 * 1024).contains(chunkBytes) else { throw BrowserError.invalid("複製先が不正、既存ファイル、または入力が部分バックアップです。新しい通常ファイルへの完全な入力バイトの複製のみ可能です") }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: output.deletingLastPathComponent().path),
           let free = attributes[.systemFreeSize] as? NSNumber,
           free.uint64Value < source.byteCount { throw BrowserError.io("複製先の空き容量が不足しています（入力の全バイト分が必要です）") }
        let staging = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.img")
        try Data().write(to: staging, options: .withoutOverwriting)
        var closed = false, committed = false
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: staging) }
        catch { try? FileManager.default.removeItem(at: staging); throw error }
        defer { if !closed { try? handle.close() }; if !committed { try? FileManager.default.removeItem(at: staging) } }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < source.byteCount {
            if cancelled() { throw BrowserError.io("イメージ複製をキャンセルしました") }
            let count = Int(min(UInt64(chunkBytes), source.byteCount - offset)), data = try source.read(at: offset, count: count)
            guard data.count == count else { throw BrowserError.truncated("複製元の読み取りが途中で終了しました") }
            try handle.write(contentsOf: data); hash.update(data: data); offset += UInt64(count)
            progress(Double(offset) / Double(source.byteCount) * 0.8)
        }
        try handle.synchronize(); try handle.close(); closed = true
        let expected = hash.finalize(), readback = try FileByteSource(url: staging)
        offset = 0; var verification = SHA256()
        while offset < readback.byteCount {
            if cancelled() { throw BrowserError.io("イメージ複製の読み戻し検証をキャンセルしました") }
            let count = Int(min(UInt64(chunkBytes), readback.byteCount - offset))
            verification.update(data: try readback.read(at: offset, count: count)); offset += UInt64(count)
            progress(0.8 + Double(offset) / Double(source.byteCount) * 0.2)
        }
        guard readback.byteCount == source.byteCount, verification.finalize() == expected else { throw BrowserError.io("複製のSHA-256読み戻し検証に失敗しました") }
        if cancelled() { throw BrowserError.io("イメージ複製をキャンセルしました") }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw BrowserError.io("保存先にファイルが作成されたため中止しました") }
        try FileManager.default.moveItem(at: staging, to: output); committed = true
        return .init(bytes: source.byteCount, sha256: expected.map { String(format: "%02x", $0) }.joined(), readbackVerified: true)
    }
}
