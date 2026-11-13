import Foundation

private struct AVIHeader {
    var data = Data()
    mutating func u16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func u32(_ value: UInt32) { for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) } }
    mutating func u64(_ value: UInt64) { for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) } }
    mutating func fourCC(_ value: String) { data.append(contentsOf: value.utf8) }
    mutating func patch(_ at: Int, _ value: UInt32) { for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
    mutating func chunk(_ id: String, _ bytes: Data) -> Int {
        fourCC(id); u32(UInt32(bytes.count)); let start = data.count; data.append(bytes)
        if bytes.count % 2 != 0 { data.append(0) }; return start
    }
    mutating func beginList(_ kind: String) -> Int { let at = data.count; fourCC("LIST"); u32(0); fourCC(kind); return at }
    mutating func endList(_ at: Int) { patch(at + 4, UInt32(data.count - at - 8)) }
}

public struct AVIWriteSummary: Codable, Sendable {
    public let width: Int, height: Int, frames: Int, audioSampleFrames: UInt64, segments: Int, bytes: UInt64
    public let codec = "Motion JPEG / OpenDML AVI"
}

/// Native, streaming OpenDML AVI writer. JPEG encoding is supplied by the macOS
/// caller. Indexes are bounded per RIFF segment; AVI >4 GiB uses AVIX segments.
/// A new hidden staging file is published only after all headers/indexes finish.
public final class MJPEGAVIWriter {
    private struct Entry { let stream: Int, at: UInt64, size: UInt32 }
    private struct IndexEntry { let at: UInt64, size: UInt32, duration: UInt32 }
    private let output: URL, staging: URL, handle: FileHandle
    private let width: Int, height: Int, fps: Double, expectedFrames: Int, audioFormat: PCMFormat?
    private let segmentLimit: UInt64, maximumSegments: Int
    private let mainHeader: Int, videoHeader: Int, audioHeader: Int?, totalFramesHeader: Int
    private let videoSuper: Int, audioSuper: Int?
    private var position: UInt64, riffStart: UInt64 = 0, moviStart: UInt64
    private var entries: [Entry] = [], videoIndexes: [IndexEntry] = [], audioIndexes: [IndexEntry] = []
    private var segmentFrames = 0, segmentAudio: UInt64 = 0, frameCount = 0, audioSamples: UInt64 = 0, largestChunk: UInt32 = 0
    private var finalized = false, closed = false
    public init(output: URL, width: Int, height: Int, framesPerSecond: Double, expectedFrames: Int,
                audioFormat: PCMFormat? = nil, segmentLimit: UInt64 = 1_000_000_000, maximumSegments: Int = 2048) throws {
        guard output.isFileURL, !output.standardizedFileURL.path.hasPrefix("/dev/"),
              !FileManager.default.fileExists(atPath: output.path), (1...8192).contains(width), (1...8192).contains(height),
              framesPerSecond.isFinite, (1...120).contains(framesPerSecond), expectedFrames > 0,
              UInt64(expectedFrames) <= UInt64(UInt32.max), (1...4096).contains(maximumSegments),
              audioFormat?.valid != false else { throw BrowserError.invalid("AVIの保存先・サイズ・音声形式が不正です") }
        self.output = output; self.width = width; self.height = height; fps = framesPerSecond
        self.expectedFrames = expectedFrames; self.audioFormat = audioFormat
        self.segmentLimit = max(256 * 1024, min(0x7fff0000, segmentLimit)); self.maximumSegments = maximumSegments
        var h = AVIHeader(); h.fourCC("RIFF"); h.u32(0); h.fourCC("AVI ")
        let hdrl = h.beginList("hdrl")
        mainHeader = h.chunk("avih", Data(count: 56))
        h.patch(mainHeader, UInt32((1_000_000 / framesPerSecond).rounded()))
        h.patch(mainHeader + 12, audioFormat == nil ? 0x10 : 0x110)
        h.patch(mainHeader + 24, audioFormat == nil ? 1 : 2)
        h.patch(mainHeader + 32, UInt32(width)); h.patch(mainHeader + 36, UInt32(height))
        func stream(_ audio: PCMFormat?, header: inout AVIHeader) -> (Int, Int) {
            let list = header.beginList("strl")
            var s = AVIHeader(); s.fourCC(audio == nil ? "vids" : "auds")
            if audio == nil { s.fourCC("MJPG") } else { s.u32(0) }
            s.u32(0); s.u16(0); s.u16(0); s.u32(0)
            let align = audio.map { $0.channels * $0.bitsPerSample / 8 } ?? 1
            s.u32(audio == nil ? 1_000_000 : UInt32(align))
            s.u32(audio.map { UInt32($0.bytesPerSecond) } ?? UInt32((framesPerSecond * 1_000_000).rounded()))
            s.u32(0); s.u32(0); s.u32(0); s.u32(UInt32.max); s.u32(audio == nil ? 0 : UInt32(align))
            s.u16(0); s.u16(0); s.u16(audio == nil ? UInt16(width) : 0); s.u16(audio == nil ? UInt16(height) : 0)
            let streamHeader = header.chunk("strh", s.data)
            var f = AVIHeader()
            if let audio {
                f.u16(1); f.u16(UInt16(audio.channels)); f.u32(UInt32(audio.sampleRate))
                f.u32(UInt32(audio.bytesPerSecond)); f.u16(UInt16(align)); f.u16(UInt16(audio.bitsPerSample)); f.u16(0)
            } else {
                f.u32(40); f.u32(UInt32(width)); f.u32(UInt32(height)); f.u16(1); f.u16(24)
                f.fourCC("MJPG"); f.u32(UInt32(width * height * 3)); f.u32(0); f.u32(0); f.u32(0); f.u32(0)
            }
            _ = header.chunk("strf", f.data)
            var index = AVIHeader(); index.u16(4); index.data.append(0); index.data.append(0); index.u32(0)
            index.fourCC(audio == nil ? "00dc" : "01wb"); index.u32(0); index.u32(0); index.u32(0)
            index.data.append(Data(count: maximumSegments * 16))
            let superIndex = header.chunk("indx", index.data)
            header.endList(list); return (streamHeader, superIndex)
        }
        (videoHeader, videoSuper) = stream(nil, header: &h)
        if let audioFormat { let pair = stream(audioFormat, header: &h); audioHeader = pair.0; audioSuper = pair.1 }
        else { audioHeader = nil; audioSuper = nil }
        let odml = h.beginList("odml"); totalFramesHeader = h.chunk("dmlh", Data(count: 248)); h.endList(odml)
        h.endList(hdrl); moviStart = UInt64(h.beginList("movi")); position = UInt64(h.data.count)
        staging = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.avi")
        try h.data.write(to: staging, options: .withoutOverwriting)
        do { handle = try FileHandle(forUpdating: staging); try handle.seekToEnd() }
        catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    deinit { if !closed { try? handle.close() }; if !finalized { try? FileManager.default.removeItem(at: staging) } }
    private func write(_ data: Data) throws { try handle.write(contentsOf: data); position += UInt64(data.count) }
    private func patch(_ at: UInt64, _ value: UInt32) throws {
        var h = AVIHeader(); h.u32(value); try handle.seek(toOffset: at); try handle.write(contentsOf: h.data); try handle.seek(toOffset: position)
    }
    private func chunk(_ id: String, _ data: Data) throws -> UInt64 {
        guard data.count <= Int(UInt32.max) else { throw BrowserError.invalid("AVIチャンクが大きすぎます") }
        let at = position; var h = AVIHeader(); h.fourCC(id); h.u32(UInt32(data.count)); try write(h.data); try write(data)
        if data.count % 2 != 0 { try write(Data([0])) }; return at
    }
    public func append(jpeg: Data, pcm: Data = Data()) throws {
        guard !closed, !finalized, frameCount < expectedFrames,
              jpeg.count >= 4, jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9]) else { throw BrowserError.invalid("AVIのJPEGまたはフレーム数が不正です") }
        let align = audioFormat.map { $0.channels * $0.bitsPerSample / 8 } ?? 1
        guard (audioFormat != nil || pcm.isEmpty), pcm.count % align == 0 else { throw BrowserError.invalid("AVIのPCM音声がサンプル境界と一致しません") }
        guard jpeg.count < Int(segmentLimit) - 1024, pcm.count < Int(segmentLimit) - 1024 else { throw BrowserError.invalid("AVIの単一チャンクがRIFF領域の上限を超えています") }
        let add = UInt64(jpeg.count + pcm.count + 20)
        // Reserve both OpenDML indexes and the first-segment legacy index.
        let reserve = UInt64((entries.count + 2) * (riffStart == 0 ? 24 : 8) + 128)
        if segmentFrames > 0, position - riffStart + add + reserve > segmentLimit {
            try finishSegment()
            guard videoIndexes.count < maximumSegments else { throw BrowserError.unsupported("AVIのセグメント上限を超えました。出力範囲を分けてください") }
            riffStart = position; var h = AVIHeader(); h.fourCC("RIFF"); h.u32(0); h.fourCC("AVIX")
            moviStart = position + UInt64(h.beginList("movi")); try write(h.data)
        }
        let video = try chunk("00dc", jpeg); entries.append(.init(stream: 0, at: video, size: UInt32(jpeg.count)))
        largestChunk = max(largestChunk, UInt32(jpeg.count)); segmentFrames += 1; frameCount += 1
        if !pcm.isEmpty {
            let audio = try chunk("01wb", pcm); entries.append(.init(stream: 1, at: audio, size: UInt32(pcm.count)))
            let samples = UInt64(pcm.count / align); segmentAudio += samples; audioSamples += samples
            guard audioSamples <= UInt64(UInt32.max) else { throw BrowserError.unsupported("AVI音声の長さが上限を超えています") }
        }
    }
    private func finishSegment() throws {
        guard segmentFrames > 0 else { return }
        let moviBytes = position - moviStart - 8
        guard moviBytes <= UInt64(UInt32.max) else { throw BrowserError.invalid("AVI movi領域が大きすぎます") }
        try patch(moviStart + 4, UInt32(moviBytes))
        for stream in 0...(audioFormat == nil ? 0 : 1) {
            let list = entries.filter { $0.stream == stream }; if list.isEmpty { continue }
            var h = AVIHeader(); h.u16(2); h.data.append(0); h.data.append(1); h.u32(UInt32(list.count))
            h.fourCC(stream == 0 ? "00dc" : "01wb"); h.u64(moviStart + 8); h.u32(0)
            for entry in list {
                let offset = entry.at + 8 - (moviStart + 8)
                guard offset <= UInt64(UInt32.max) else { throw BrowserError.invalid("AVI索引の範囲が不正です") }
                h.u32(UInt32(offset)); h.u32(entry.size)
            }
            let at = try chunk(stream == 0 ? "ix00" : "ix01", h.data)
            let item = IndexEntry(at: at, size: UInt32(h.data.count + 8), duration: stream == 0 ? UInt32(segmentFrames) : UInt32(segmentAudio))
            if stream == 0 { videoIndexes.append(item) } else { audioIndexes.append(item) }
        }
        if riffStart == 0 {
            var index = AVIHeader()
            for entry in entries {
                index.fourCC(entry.stream == 0 ? "00dc" : "01wb"); index.u32(entry.stream == 0 ? 0x10 : 0)
                index.u32(UInt32(entry.at - (moviStart + 8))); index.u32(entry.size)
            }
            _ = try chunk("idx1", index.data)
        }
        guard position - riffStart - 8 <= UInt64(UInt32.max) else { throw BrowserError.invalid("AVIのRIFFサイズが上限を超えています") }
        try patch(riffStart + 4, UInt32(position - riffStart - 8))
        entries.removeAll(keepingCapacity: true); segmentFrames = 0; segmentAudio = 0
    }
    public func finish() throws -> AVIWriteSummary {
        guard !closed, !finalized, frameCount == expectedFrames else { throw BrowserError.invalid("AVIの全フレームが確定していません") }
        try finishSegment()
        try patch(UInt64(mainHeader + 16), UInt32(frameCount)); try patch(UInt64(mainHeader + 28), largestChunk)
        try patch(UInt64(mainHeader + 4), UInt32(min(Double(UInt32.max), Double(largestChunk) * fps + Double(audioFormat?.bytesPerSecond ?? 0))))
        try patch(UInt64(videoHeader + 32), UInt32(frameCount)); try patch(UInt64(videoHeader + 36), largestChunk)
        try patch(UInt64(totalFramesHeader), UInt32(frameCount))
        if let audioHeader { try patch(UInt64(audioHeader + 32), UInt32(audioSamples)) }
        for (at, list) in [(videoSuper, videoIndexes), (audioSuper ?? 0, audioIndexes)] where at > 0 {
            try patch(UInt64(at + 4), UInt32(list.count))
            var data = AVIHeader()
            for item in list { data.u64(item.at); data.u32(item.size); data.u32(item.duration) }
            try handle.seek(toOffset: UInt64(at + 24)); try handle.write(contentsOf: data.data); try handle.seek(toOffset: position)
        }
        try handle.synchronize(); try handle.close(); closed = true
        guard !FileManager.default.fileExists(atPath: output.path) else { throw BrowserError.invalid("保存先に既存ファイルがあるため中止しました") }
        try FileManager.default.moveItem(at: staging, to: output); finalized = true
        return .init(width: width, height: height, frames: frameCount, audioSampleFrames: audioSamples, segments: videoIndexes.count, bytes: position)
    }
}
