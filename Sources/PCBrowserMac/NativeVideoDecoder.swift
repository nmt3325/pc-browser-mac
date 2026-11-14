import Foundation
import AppKit
import VideoToolbox
import CoreImage
import PCBrowserCore

/// The frame has no picture (empty or zero-filled video area, or only delimiters/parameter sets). The recording is still usable for its
/// clock, GPS, sensors and reports, so callers show this as a notice in the preview instead of a decoder error.
struct VideoUnavailableError: LocalizedError, Equatable {
    var errorDescription: String? { "この位置には映像データがありません（映像領域が空、または画像を含みません）。時刻・GPS・センサーなどの情報は表示できます" }
}

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
        if AnnexB.isPictureless(data, units: units) { throw VideoUnavailableError() }
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
    private let source: any ByteSource
    private let packets: [FramePacket]
    private let fps: Int
    private var decoder: NativeVideoDecoder?
    private var last = -1
    private var cached: CGImage?
    // Reverse/step-back must not construct a new VT/CI session for every
    // previously displayed frame. Bound decoded memory independently of the
    // recording length (a 2560x1080 BGRA frame costs about 10.5 MiB).
    private var recentFrames = FrameCache<CGImage>(maximumBytes: 96 * 1024 * 1024, maximumCount: 12)
    init(source: any ByteSource, packets: [FramePacket]) {
        self.source = source; self.packets = packets
        fps = max(1, packets.compactMap { $0.telemetry.clock?.nominalFPS }.first ?? 30)
    }
    func render(_ index: Int) throws -> CGImage {
        guard packets.indices.contains(index) else { throw BrowserError.invalid("フレーム番号が範囲外です") }
        // A cache hit does not move `last`: it describes the decoder's state,
        // not the frame currently displayed by the UI.
        if let image = recentFrames.value(at: index) { return image }
        if index == last, let cached { return cached }
        guard let start = stride(from: index, through: 0, by: -1).first(where: { packets[$0].isIntra }) else {
            throw BrowserError.unsupported("直前のIフレームが見つかりません。次の録画を選択してください")
        }
        // Audio-clock playback may skip display frames. Reuse the decoder while
        // advancing through those P frames instead of repeatedly decoding the GOP.
        // A later keyframe still makes a large forward seek inexpensive.
        if decoder == nil || index < last || start > last + 1 {
            decoder = NativeVideoDecoder(); last = start - 1; cached = nil
        }
        var result: CGImage?
        for i in (last+1)...index {
            let p = packets[i]
            let data = try source.read(at: p.payloadOffset, count: p.videoBytes)
            let image = try decoder!.decode(data, ordinal: i, fps: fps)
            result = image; last = i; cached = image
            let cost = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
            if !cost.overflow { recentFrames.insert(image, at: i, bytes: cost.partialValue) }
        }
        guard let result else { throw BrowserError.io("フレームが取得できません") }
        cached = result
        return result
    }
}
