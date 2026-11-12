import Foundation
import AppKit
import VideoToolbox
import CoreImage
import PCBrowserCore

final class NativeVideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private let lock = NSLock()
    private var output: CVPixelBuffer?
    private var callbackStatus: OSStatus = 0
    private let context = CIContext()
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    private func configure(_ units: [Data]) throws {
        guard let sps = units.first(where: { $0.first.map { $0 & 31 == 7 } ?? false }),
              let pps = units.first(where: { $0.first.map { $0 & 31 == 8 } ?? false }) else {
            throw BrowserError.unsupported("この位置にはSPS/PPSがありません。直前のIフレームから再生してください")
        }
        let a = Array(sps), b = Array(pps)
        var desc: CMVideoFormatDescription?
        let status = a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in
            let pointers = [ap.baseAddress!, bp.baseAddress!]
            let sizes = [a.count, b.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        } }
        guard status == noErr, let desc else { throw BrowserError.unsupported("H.264形式を読み取れません (\(status))") }
        format = desc
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            guard let ref else { return }
            let decoder = Unmanaged<NativeVideoDecoder>.fromOpaque(ref).takeUnretainedValue()
            decoder.lock.lock(); decoder.callbackStatus = status; decoder.output = image; decoder.lock.unlock()
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var decoder: VTDecompressionSession?
        let rc = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: desc, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback, decompressionSessionOut: &decoder)
        guard rc == noErr, let decoder else { throw BrowserError.unsupported("macOSの映像デコーダーを作成できません (\(rc))") }
        session = decoder
    }
    func decode(_ data: Data, ordinal: Int, fps: Int) throws -> CGImage {
        let units = AnnexB.units(data)
        if session == nil { try configure(units) }
        guard let session, let format else { throw BrowserError.io("デコーダーの初期化に失敗しました") }
        let avcc = try AnnexB.avcc(units)
        var block: CMBlockBuffer?
        var rc = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard rc == noErr, let block else { throw BrowserError.io("映像バッファーを作成できません (\(rc))") }
        rc = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard rc == noErr else { throw BrowserError.io("映像バッファーへコピーできません (\(rc))") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps)), presentationTimeStamp: CMTime(value: Int64(ordinal), timescale: Int32(fps)), decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        rc = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard rc == noErr, let sample else { throw BrowserError.io("映像サンプルを作成できません (\(rc))") }
        lock.lock(); output = nil; callbackStatus = 0; lock.unlock()
        var flags = VTDecodeInfoFlags()
        rc = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: VTDecodeFrameFlags(rawValue: 0), frameRefcon: nil, infoFlagsOut: &flags)
        guard rc == noErr else { throw BrowserError.unsupported("映像のデコードに失敗しました (\(rc))") }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        lock.lock(); var image = output; var status = callbackStatus; lock.unlock()
        if image == nil {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            lock.lock(); image = output; status = callbackStatus; lock.unlock()
        }
        guard status == noErr, let image else { throw BrowserError.unsupported("この映像フレームを表示できません (\(status))") }
        let ci = CIImage(cvPixelBuffer: image)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { throw BrowserError.io("映像を画面へ変換できません") }
        return cg
    }
}

actor FrameRenderer {
    private let source: FileByteSource
    private let packets: [FramePacket]
    private var decoder: NativeVideoDecoder?
    private var last = -1
    init(source: FileByteSource, packets: [FramePacket]) { self.source = source; self.packets = packets }
    func render(_ index: Int) throws -> CGImage {
        guard packets.indices.contains(index) else { throw BrowserError.invalid("フレーム番号が範囲外です") }
        if decoder == nil || index != last + 1 {
            guard let start = stride(from: index, through: 0, by: -1).first(where: { packets[$0].isIntra }) else {
                throw BrowserError.unsupported("直前のIフレームが見つかりません。次の録画を選択してください")
            }
            decoder = NativeVideoDecoder(); last = start - 1
        }
        var result: CGImage?
        for i in (last+1)...index {
            let p = packets[i]
            let data = try source.read(at: p.payloadOffset, count: p.videoBytes)
            result = try decoder!.decode(data, ordinal: i, fps: 30); last = i
        }
        guard let result else { throw BrowserError.io("フレームが取得できません") }
        return result
    }
}

enum InspectionCLI {
    static func value(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i+1 < args.count else { return nil }; return args[i+1]
    }
    static func run(_ args: [String]) -> Int32 {
        do {
            guard let path = value("--inspect", in: args) else { return 64 }
            let url = URL(fileURLWithPath: path)
            let before = try FileManager.default.attributesOfItem(atPath: path)
            let source = try FileByteSource(url: url)
            let limit = value("--scan-limit", in: args).flatMap(UInt64.init)
            let result = try ImageScanner.scan(source, limitBytes: limit)
            var report: [String: Any] = ["source_bytes": source.byteCount, "control_lba": result.control.sector,
                "first_record_lba": result.control.firstRecordSector, "recordings": result.recordings.count,
                "validated_frames": result.frameCount, "partial_scan": result.isPartialScan,
                "rejected_candidates": result.rejectedCandidates, "mode": "O_RDONLY", "scanned_bytes": result.scannedBytes, "timing_note": "Playback timing is provisional; packet field 0x1E8 is not interpreted as FPS."]
            if args.contains("--decode-check") {
                var decoded = 0, width = 0, height = 0
                for recording in result.recordings {
                    let decoder = NativeVideoDecoder()
                    guard let first = recording.packets.firstIndex(where: { $0.isIntra }) else { continue }
                    for (j,p) in recording.packets.enumerated() where j >= first {
                        let data = try source.read(at: p.payloadOffset, count: p.videoBytes)
                        let image = try decoder.decode(data, ordinal: j, fps: 30)
                        width = image.width; height = image.height
                        if decoded == 0, let png = value("--png", in: args) {
                            let rep = NSBitmapImageRep(cgImage: image)
                            guard let bytes = rep.representation(using: .png, properties: [:]) else { throw BrowserError.io("PNGを作成できません") }
                            try bytes.write(to: URL(fileURLWithPath: png))
                        }
                        decoded += 1
                    }
                }
                report["native_videotoolbox_decoded_frames"] = decoded; report["width"] = width; report["height"] = height
            }
            let after = try FileManager.default.attributesOfItem(atPath: path)
            report["input_size_and_mtime_unchanged"] = (before[.size] as? NSNumber) == (after[.size] as? NSNumber) && (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date)
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
            if let file = value("--report", in: args) { try bytes.write(to: URL(fileURLWithPath: file)) }
            print(String(decoding: bytes, as: UTF8.self)); return 0
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }
}
