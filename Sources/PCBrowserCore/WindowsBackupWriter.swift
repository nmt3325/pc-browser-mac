import Foundation

/// How a Windows-compatible backup run is laid out. Everything here was recovered from genuine
/// PC Browser 1.9.60.0 backups of a real Q-01 card (see docs/windows-bak-format.md); nothing is invented:
///  * one part (`.bak`) never repeats record data of another part, but every part repeats the MBR,
///    the control sector pair and the mirror pair (last two sectors of the recording partition);
///  * a record block ("chunk") is `[D103/D105 header pair][packets][D106/D104 trailer pair]`, stored as its own extent;
///  * the first chunk of a recording whose block start was overwritten begins at its first intact packet;
///  * all selected recordings form ONE chunk stream that is cut into parts: a part is closed when the next unit of the
///    stream would push the chunk bytes over `maxChunkBytesPerPart` (a unit is one chunk, or a short block cut by the
///    ring end together with its continuation after the wrap); a part may therefore hold the end of one recording
///    and the start of the next (observed with two adjacent recordings, parts of up to 12 chunks / 17 table entries);
///    when a recording ends with the part already fuller than `maxChunkBytesPerPart - recordingBoundaryReserveBytes`
///    the original starts the next part first and names it with the values of the recording that just ended
///    (counter of its first packet, clock of its last packet);
///  * the extent table lists MBR, control pair, the chunks in stream order (NOT sorted: a ring wrap puts a higher
///    sector range before a lower one) and finally the mirror pair;
///  * names are `<%010u frame counter of the first packet of the recording that contains the part's first packet>_<yyyyMMdd>_<HHmmss of the part's first packet>.bak`
///    inside a folder named `<yyyyMMdd_HHmmss>` (start of the run, local time).
public struct WindowsBackupOptions: Sendable {
    /// Observed limit: every genuine part boundary decided by size is consistent with any value in
    /// [246,630,400, 246,795,776) bytes of chunk data; 481,800 sectors is a round value inside that window.
    public var maxChunkBytesPerPart: UInt64
    /// No chunk-count limit exists in the genuine data: parts hold 6 to 12 chunks (the 12-chunk part has 17 table entries)
    /// and every close was decided by size. `Int.max` therefore means "unlimited"; tests pass small values.
    public var maxChunksPerPart: Int
    /// Before a further recording starts, the original closes the current part when it is already so full that the
    /// next recording might not fit comfortably. Observed boundaries (chunk bytes already in the part): closed at
    /// 212,123,648 although the next chunk of 21,054,464 would still have fit; continued at 196,988,928 (next chunk
    /// 21,141,504) and at 153,884,160. Every value in (34,557,952, 49,692,672] reproduces all three observations;
    /// 40 MiB is a round value inside that window (the exact rule is not known).
    public var recordingBoundaryReserveBytes: UInt64
    /// Frames per camera block (450 on the Q-01 at 30 fps). A block that the ring end cut in two (a short block ending at
    /// the end of the ring plus its continuation after the wrap, whose frame ordinal is not a multiple of this number)
    /// was never separated by the original's part boundaries (genuine run: a part with 222.7 MB / 11 chunks was closed
    /// although the 7.7 MB short block would have fit; both pieces then opened the next part). 0 turns the rule off.
    public var blockFrameCount: Int
    /// `nil` picks a random key index like the original; tests and byte-for-byte comparisons pass one explicitly.
    public var keyIndex: UInt8?
    public var created: Date
    public var timeZone: TimeZone
    public init(maxChunkBytesPerPart: UInt64 = 246_681_600, maxChunksPerPart: Int = .max, recordingBoundaryReserveBytes: UInt64 = 41_943_040,
                blockFrameCount: Int = 450, keyIndex: UInt8? = nil, created: Date = Date(), timeZone: TimeZone = .current) {
        self.maxChunkBytesPerPart = maxChunkBytesPerPart; self.maxChunksPerPart = maxChunksPerPart
        self.recordingBoundaryReserveBytes = recordingBoundaryReserveBytes; self.blockFrameCount = blockFrameCount
        self.keyIndex = keyIndex; self.created = created; self.timeZone = timeZone
    }
}

public struct WindowsBackupChunk: Sendable, Equatable {
    public let sectors: Range<UInt64>
    public let packets: Int
    public let hasHeaderPair: Bool
    public let hasTrailerPair: Bool
    public let firstClock: CardTimestamp?
    /// Index into the selected recordings (set by `WindowsBackupWriter.plan`).
    public var recording: Int = 0
    /// Frame ordinal inside the session (0x98 of the block header pair); nil when the header pair was overwritten.
    public var firstOrdinal: UInt32? = nil
    public var bytes: UInt64 { (sectors.upperBound-sectors.lowerBound)*512 }
}

public struct WindowsBackupPartPlan: Sendable {
    public let fileName: String
    public let chunks: [WindowsBackupChunk]
    public var chunkBytes: UInt64 { chunks.reduce(0) { $0+$1.bytes } }
}

public struct WindowsBackupPlan: Sendable {
    public let folderName: String
    public let created: [UInt8]
    /// Sorted: MBR, control sector, the sector after it, then (optionally) the mirror pair.
    public let fixedSectors: [Range<UInt64>]
    public let parts: [WindowsBackupPartPlan]
    /// Table order of one part, exactly like the original: MBR, control pair, chunks in stream order, mirror pair.
    public func extents(for part: WindowsBackupPartPlan) -> [Range<UInt64>] {
        Array(fixedSectors.prefix(3))+part.chunks.map(\.sectors)+Array(fixedSectors.dropFirst(3))
    }
    public var totalBytes: UInt64 {
        parts.reduce(UInt64(0)) { total,part in total+extents(for:part).reduce(UInt64(0)) { $0+($1.upperBound-$1.lowerBound)*512 } }
    }
}

public enum WindowsBackupLayout {
    static let headerMagics: Set<UInt32> = [0xFFFFD103,0xFFFFD105]
    static let trailerMagics: Set<UInt32> = [0xFFFFD104,0xFFFFD106]

    static func magic(_ source: any ByteSource, sector: UInt64) throws -> UInt32 {
        guard sector < source.byteCount/512 else { return 0 }
        return try Bytes(source.read(at:sector*512,count:4)).le32(0)
    }

    /// MBR, then the control header and the sector after it; the mirror pair is added only when the MBR
    /// really contains the recording partition that starts at the control sector.
    public static func fixedSectors(source: any ByteSource, control: UInt64) throws -> [Range<UInt64>] {
        var result: [Range<UInt64>] = [0..<1,control..<control+1,control+1..<control+2]
        let b = Bytes(try source.read(at:0,count:512)), sectors = source.byteCount/512
        for i in 0..<4 {
            let o = 446+i*16, first = UInt64(try b.le32(o+8)), count = UInt64(try b.le32(o+12))
            if first == control, count >= 4, first+count <= sectors {
                result.append(first+count-2..<first+count-1)
                result.append(first+count-1..<first+count)
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// One chunk per record block of the recording, in recording order.
    public static func chunks(for recording: Recording, source: any ByteSource) throws -> [WindowsBackupChunk] {
        guard recording.isLoaded, !recording.packets.isEmpty else { throw BrowserError.invalid("バックアップ前に選択録画の索引を読み込んでください") }
        let packets = recording.packets, limit = source.byteCount/512
        var result: [WindowsBackupChunk] = [], index = 0
        while index < packets.count {
            let record = packets[index].recordSector
            var end = index
            while end+1 < packets.count, packets[end+1].recordSector == record { end += 1 }
            let first = packets[index], last = packets[end]
            var lower = first.headerSector, upper = last.trailerSector+1
            var header = false, trailer = false, ordinal: UInt32? = nil
            if UInt64(record)+2 == first.headerSector, headerMagics.contains(try magic(source,sector:UInt64(record))) {
                lower = UInt64(record); header = true
                ordinal = try Bytes(source.read(at:UInt64(record)*512,count:512)).le32(0x98)
            }
            if upper+2 <= limit, trailerMagics.contains(try magic(source,sector:upper)) { upper += 2; trailer = true }
            guard upper <= limit else { throw BrowserError.invalid("バックアップ範囲が入力を超えています") }
            result.append(.init(sectors:lower..<upper,packets:end-index+1,hasHeaderPair:header,hasTrailerPair:trailer,firstClock:first.telemetry.clock,firstOrdinal:ordinal))
            index = end+1
        }
        return result
    }

    /// Frame serial number stored at 0x1D4 of every packet header; continues across recordings of a card.
    public static func frameCounter(source: any ByteSource, packetSector: UInt64) throws -> UInt32 {
        try Bytes(source.read(at:packetSector*512,count:512)).le32(0x1D4)
    }
}

public enum WindowsBackupWriter {
    static func stamp(_ date: Date, zone: TimeZone) -> (text: String, bytes: [UInt8]) {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second],from:date)
        let y = c.year ?? 2000, mo = c.month ?? 1, d = c.day ?? 1, h = c.hour ?? 0, mi = c.minute ?? 0, s = c.second ?? 0
        return (String(format:"%04d%02d%02d_%02d%02d%02d",y,mo,d,h,mi,s),[UInt8(y%100),UInt8(mo),UInt8(d),UInt8(h),UInt8(mi),UInt8(s)])
    }

    public static func plan(source: any ByteSource, index: ImageIndex, recordings: [Recording], options: WindowsBackupOptions = .init()) throws -> WindowsBackupPlan {
        guard !recordings.isEmpty else { throw BrowserError.invalid("バックアップする録画が選択されていません") }
        guard options.maxChunkBytesPerPart >= 512, options.maxChunksPerPart >= 1 else { throw BrowserError.invalid("パートの上限サイズが小さすぎます") }
        let fixed = try WindowsBackupLayout.fixedSectors(source:source,control:index.control.sector)
        var perRecording: [[WindowsBackupChunk]] = [], counters: [UInt32] = [], lastClocks: [CardTimestamp?] = []
        for (number,recording) in recordings.enumerated() {
            var chunks = try WindowsBackupLayout.chunks(for:recording,source:source)
            for k in chunks.indices { chunks[k].recording = number }
            perRecording.append(chunks)
            counters.append(try WindowsBackupLayout.frameCounter(source:source,packetSector:recording.packets[0].headerSector))
            lastClocks.append(recording.packets[recording.packets.count-1].telemetry.clock)
        }
        var parts: [WindowsBackupPartPlan] = [], names = Set<String>()
        var current: [WindowsBackupChunk] = [], bytes: UInt64 = 0
        var inherited: (counter: UInt32, clock: CardTimestamp?)? = nil
        func flush() throws {
            guard let first = current.first else { return }
            var counter = inherited?.counter ?? counters[first.recording]
            guard let clock = inherited?.clock ?? first.firstClock else { throw BrowserError.invalid("カード時計がないためBAKファイル名を作れません") }
            func name(_ counter: UInt32) -> String {
                String(format:"%010u_%04d%02d%02d_%02d%02d%02d.bak",counter,clock.year,clock.month,clock.day,clock.hour,clock.minute,clock.second)
            }
            // File names are labels only; a clash (impossible in genuine data) is resolved by advancing the counter.
            while names.contains(name(counter)) { counter &+= 1 }
            names.insert(name(counter))
            parts.append(.init(fileName:name(counter),chunks:current)); current = []; bytes = 0; inherited = nil
        }
        for (number,chunks) in perRecording.enumerated() {
            if number > 0, !current.isEmpty, bytes+options.recordingBoundaryReserveBytes > options.maxChunkBytesPerPart {
                try flush()
                inherited = (counters[number-1],lastClocks[number-1])
            }
            var k = 0
            while k < chunks.count {
                var unit = [chunks[k]]
                while k+unit.count < chunks.count, continuesBlock(chunks[k+unit.count],after:unit[unit.count-1],blockFrames:options.blockFrameCount) {
                    unit.append(chunks[k+unit.count])
                }
                let unitBytes = unit.reduce(UInt64(0)) { $0+$1.bytes }
                // A unit is never split, even when it alone exceeds the limits; an empty part always accepts it.
                if !current.isEmpty, (unit.count > options.maxChunksPerPart-current.count || bytes+unitBytes > options.maxChunkBytesPerPart) { try flush() }
                current.append(contentsOf:unit); bytes += unitBytes; k += unit.count
            }
        }
        try flush()
        let run = stamp(options.created,zone:options.timeZone)
        let plan = WindowsBackupPlan(folderName:run.text,created:run.bytes,fixedSectors:fixed,parts:parts)
        for part in parts {
            let extents = plan.extents(for:part).sorted { $0.lowerBound < $1.lowerBound }
            for (a,b) in zip(extents,extents.dropFirst()) where a.upperBound > b.lowerBound {
                throw BrowserError.invalid("バックアップ範囲が重なっています。録画の選択が重複していないか確認してください")
            }
            if let last = extents.last, last.upperBound > source.byteCount/512 { throw BrowserError.invalid("バックアップ範囲が入力を超えています") }
        }
        return plan
    }

    /// True when `chunk` is the continuation, after the ring wrap, of the short block `previous` of the same recording:
    /// its frame ordinal follows directly and is not aligned to the block size.
    static func continuesBlock(_ chunk: WindowsBackupChunk, after previous: WindowsBackupChunk, blockFrames: Int) -> Bool {
        guard blockFrames > 0, chunk.recording == previous.recording, let a = previous.firstOrdinal, let b = chunk.firstOrdinal,
              Int(b) == Int(a)+previous.packets, Int(b) % blockFrames != 0,
              chunk.sectors.lowerBound < previous.sectors.lowerBound else { return false }
        return true
    }

    static func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded:value >> ($0*8)) } }

    /// Creates `<parent>/<yyyyMMdd_HHmmss>/` atomically. Existing outputs and the source are never touched.
    @discardableResult
    public static func write(source: any ByteSource, plan: WindowsBackupPlan, options: WindowsBackupOptions = .init(), to parent: URL,
                             protecting: [URL] = [], cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> URL {
        let destination = parent.appendingPathComponent(plan.folderName,isDirectory:true)
        if case .refused(let reason) = WriteGuard.checkNewOutput(destination,protecting:protecting) { throw BrowserError.invalid(reason) }
        let keyIndex = options.keyIndex ?? UInt8.random(in:0...255), key = WindowsBackupSource.xorTable[Int(keyIndex)]
        let fm = FileManager.default
        let staging = parent.appendingPathComponent(".pcbrowser-\(UUID().uuidString).partial",isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at:staging) } }
        let total = max(1,plan.totalBytes)
        var written: UInt64 = 0
        for part in plan.parts {
            let extents = plan.extents(for:part)
            let tableEnd = UInt64(48+extents.count*32)
            let dataBytes = extents.reduce(UInt64(0)) { $0+($1.upperBound-$1.lowerBound)*512 }
            var header = Data(count:48)
            header.replaceSubrange(0..<12,with:WindowsBackupSource.magic)
            header[12] = 1
            for (i,v) in plan.created.prefix(6).enumerated() { header[16+i] = v }
            header[22] = keyIndex
            header.replaceSubrange(24..<32,with:le64(UInt64(extents.count)))
            header.replaceSubrange(32..<40,with:le64(tableEnd+dataBytes))
            var table = Data(capacity:extents.count*32), stored = tableEnd
            for r in extents {
                let start = r.lowerBound*512, length = (r.upperBound-r.lowerBound)*512
                table.append(contentsOf:le64(start)+le64(start+length-1)+le64(stored)+le64(length))
                stored += length
            }
            BackupXOR.apply(&table,key:key)
            let url = staging.appendingPathComponent(part.fileName)
            guard fm.createFile(atPath:url.path,contents:nil) else { throw BrowserError.io("BAKファイルを作成できません") }
            let handle = try FileHandle(forWritingTo:url)
            defer { try? handle.close() }
            try handle.write(contentsOf:header); try handle.write(contentsOf:table)
            for r in extents {
                var at = r.lowerBound*512
                let end = r.upperBound*512
                while at < end {
                    if cancelled() { throw BrowserError.io("バックアップをキャンセルしました") }
                    let n = Int(min(2*1024*1024,end-at))
                    var data = try source.read(at:at,count:n)
                    BackupXOR.apply(&data,key:key)
                    try handle.write(contentsOf:data)
                    at += UInt64(n); written += UInt64(n)
                    progress(min(1,Double(written)/Double(total)))
                }
            }
            try handle.synchronize()
        }
        try fm.moveItem(at:staging,to:destination)
        committed = true
        return destination
    }

    public struct Verification: Sendable, Equatable {
        public let parts: Int, extents: Int, bytes: UInt64
    }

    /// Re-opens every written part and compares each extent with the source byte for byte.
    public static func verify(source: any ByteSource, plan: WindowsBackupPlan, folder: URL, cancelled: () -> Bool = { false }) throws -> Verification {
        var extentCount = 0, compared: UInt64 = 0
        for part in plan.parts {
            let bak = try WindowsBackupSource(url:folder.appendingPathComponent(part.fileName))
            let extents = plan.extents(for:part)
            guard bak.extents.map({ $0.sourceOffset..<($0.sourceOffset+$0.length) }) == extents.sorted(by:{ $0.lowerBound < $1.lowerBound }).map({ $0.lowerBound*512..<$0.upperBound*512 }) else {
                throw BrowserError.invalid("書き出したBAKの範囲が計画と一致しません: \(part.fileName)")
            }
            for r in extents {
                var at = r.lowerBound*512
                let end = r.upperBound*512
                while at < end {
                    if cancelled() { throw BrowserError.io("照合をキャンセルしました") }
                    let n = Int(min(2*1024*1024,end-at))
                    guard try bak.read(at:at,count:n) == source.read(at:at,count:n) else {
                        throw BrowserError.invalid("書き出したBAKの内容が入力と一致しません: \(part.fileName)")
                    }
                    at += UInt64(n); compared += UInt64(n)
                }
                extentCount += 1
            }
        }
        return Verification(parts:plan.parts.count,extents:extentCount,bytes:compared)
    }
}
