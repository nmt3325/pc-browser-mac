import Foundation

public struct PCMFormat: Sendable, Codable, Equatable {
    public let sampleRate: Int, channels: Int, bitsPerSample: Int
    public init(sampleRate: Int = 8000, channels: Int = 1, bitsPerSample: Int = 8) { self.sampleRate=sampleRate;self.channels=channels;self.bitsPerSample=bitsPerSample }
    public static func recordFormat(source: any ByteSource, recording: Recording) throws -> PCMFormat {
        let h = try source.read(at:UInt64(recording.recordSector)*512,count:512), b = Bytes(h)
        let type = try b.le32(0)
        guard type == 0xFFFFD103 || type == 0xFFFFD105 else { throw BrowserError.unsupported("録画の音声形式ヘッダーがありません") }
        // WAVE_FORMAT_PCM; Windows DirectSound VA 0x4B52A0 multiplies the stored rate by 100.
        let format = PCMFormat(sampleRate:Int(try b.le16(0x16))*100,channels:Int(try b.u8(0x18)),bitsPerSample:Int(try b.u8(0x19)))
        guard format.valid else { throw BrowserError.unsupported("未対応の録画音声形式です（\(format.description)）") }
        return format
    }
    public var bytesPerSecond: Int { sampleRate*channels*bitsPerSample/8 }
    public var valid: Bool { [8000,11025,16000,22050,24000,32000,44100,48000].contains(sampleRate) && (1...2).contains(channels) && [8,16].contains(bitsPerSample) }
    public var description: String { "PCM \(sampleRate) Hz / \(bitsPerSample) bit / \(channels) ch" }
}
public struct AudioClip: Sendable {
    public let samples: Data
    public let format: PCMFormat
    public var duration: Double { Double(samples.count)/Double(format.bytesPerSecond) }
    public static func load(source: any ByteSource, packets: [FramePacket], format: PCMFormat) throws -> AudioClip {
        guard format.valid else { throw BrowserError.unsupported("未対応のPCM形式です") }
        let total = packets.reduce(0) { $0+$1.auxiliaryBytes }
        guard total > 0, total <= 64*1024*1024 else { throw BrowserError.unsupported("音声がないか、1録画の音声が64 MiBを超えています") }
        var data = Data();data.reserveCapacity(total)
        for p in packets where p.auxiliaryBytes > 0 { data.append(try source.read(at:p.auxiliaryOffset,count:p.auxiliaryBytes)) }
        let block = format.channels*format.bitsPerSample/8
        guard data.count%block == 0 else { throw BrowserError.invalid("PCMサンプルの境界が一致しません") }
        return .init(samples:data,format:format)
    }
    public func wav(range: Range<Double>? = nil) throws -> Data {
        guard format.valid, samples.count <= Int(UInt32.max)-44 else { throw BrowserError.invalid("WAVのサイズまたは形式が不正です") }
        var pcm = samples
        if let r = range {
            guard r.lowerBound.isFinite, r.upperBound.isFinite, r.lowerBound >= 0, r.lowerBound < r.upperBound, r.upperBound <= duration+0.001 else { throw BrowserError.invalid("音声の出力範囲が不正です") }
            let block = format.channels*format.bitsPerSample/8
            let lo = Int(r.lowerBound*Double(format.bytesPerSecond))/block*block
            let hi = min(pcm.count,Int(r.upperBound*Double(format.bytesPerSecond))/block*block)
            pcm = pcm.subdata(in:lo..<hi)
        }
        var out = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ v:T) { var n=v.littleEndian;withUnsafeBytes(of:&n) { out.append(contentsOf:$0) } }
        le(UInt32(pcm.count+36));out.append(Data("WAVEfmt ".utf8));le(UInt32(16));le(UInt16(1));le(UInt16(format.channels))
        le(UInt32(format.sampleRate));le(UInt32(format.bytesPerSecond));le(UInt16(format.channels*format.bitsPerSample/8));le(UInt16(format.bitsPerSample))
        out.append(Data("data".utf8));le(UInt32(pcm.count));out.append(pcm);return out
    }
}
