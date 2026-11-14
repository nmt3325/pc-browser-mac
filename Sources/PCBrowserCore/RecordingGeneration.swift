import Foundation

/// The three recording areas of the control sector's region table, in the order of their generation counters.
public enum RecordingRegionKind: Int, CaseIterable, Sendable {
    case normal = 0, event = 1, history = 2
    public var label: String {
        switch self {
        case .normal: return "常時録画"
        case .event: return "イベント記録"
        case .history: return "履歴記録"
        }
    }
}

/// The generation byte of the control sector (offset 0, repeated at 0x1FF) and its three region counters (normal, event, history).
/// The original's 「録画データ削除」 never erases data: it raises the generation byte and sets each counter above the generation of the
/// data it had loaded, and readers then skip what is not newer. See docs/recording-data-operations.md.
public struct GenerationState: Equatable, Sendable {
    public let generation: UInt8
    public let counters: [UInt32]
    public init(generation: UInt8, counters: [UInt32]) { self.generation = generation; self.counters = counters }
    public func counter(_ kind: RecordingRegionKind) -> UInt32 { counters[kind.rawValue] }
}

/// What the first header of a region says about the newest ring lap stored there.
public struct RegionHead: Equatable, Sendable {
    public let kind: RecordingRegionKind
    public let sector: UInt64
    /// Byte 0xA0 of a stream header (compared with the card generation); nil for the journal, which carries no stamp.
    public let stamp: UInt8?
    /// Ring lap generation: dword 0x1F8 of a stream header, upper half of dword 0xC4 of the first journal record.
    public let generation: UInt32
}

/// A region the original skips because its data predates the last 削除／初期化.
public struct HiddenRegion: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The head header's stamp is not the card generation (low byte).
        case staleStamp(stamp: UInt8, generation: UInt8)
        /// The newest ring lap is not newer than the region counter.
        case notNewerThanCounter(generation: UInt32, counter: UInt32)
    }
    public let kind: RecordingRegionKind
    public let reason: Reason
    public var text: String {
        switch reason {
        case let .staleStamp(stamp, generation):
            return "\(kind.label)（世代印\(stamp)・カードの世代\(generation)）"
        case let .notNewerThanCounter(generation, counter):
            return "\(kind.label)（世代\(generation)・削除時の基準値\(counter)）"
        }
    }
}

public struct GenerationReport: Equatable, Sendable {
    public let state: GenerationState
    public let heads: [RegionHead]
    public let hidden: [HiddenRegion]
    /// Regions whose newest generation was read from a head that is still visible.
    public var loaded: [RegionHead] { heads.filter { head in !hidden.contains { $0.kind == head.kind } } }
}

/// Reader side of the generation scheme. Proven with the original at generation 1: a region is listed only while its head header carries
/// the card generation as stamp AND the head generation is above that region's counter. Anything that cannot be judged (no checksummed
/// control sector, no recognisable head header) leaves the region visible: only positive evidence hides recordings.
public enum RecordingGeneration {
    static let streamHeaderMagics: Set<UInt32> = [0xFFFFD103, 0xFFFFD105]
    static let journalMagics: Set<UInt32> = [0xFFFFE201, 0xFFFFE202]
    static let stampOffset = 0xA0, headerGenerationOffset = 0x1F8, selfSectorOffset = 0x1E0, journalLapOffset = 0xC4

    /// nil unless this is a checksummed single-channel control sector whose generation byte equals its copy and is at least 1.
    public static func state(control: [UInt8], channel: [UInt8]) -> GenerationState? {
        let offsets = RecordingSettingsCodec.Offset.self
        guard control.count == 512, channel.count == 512, control[offsets.channelCount] == 1,
              Array(control[1..<18]) == RecordingSettingsCodec.marker, Array(control[0x1EC..<0x1FD]) == RecordingSettingsCodec.marker else { return nil }
        let stored = UInt16(control[offsets.checksum]) | UInt16(control[offsets.checksum + 1]) << 8
        guard stored == RecordingSettingsCodec.checksum(control: control, channels: [channel]) else { return nil }
        let g = control[offsets.generation]
        guard g >= 1, control[offsets.generationTail] == g else { return nil }
        return GenerationState(generation: g, counters: offsets.generationCounters.map { RecordingSettingsCodec.counter(control, $0) })
    }

    /// The head header of every region the control table defines. Only well-formed headers count (stream magic and self-referencing sector,
    /// journal magic); anything else yields no head for that region.
    static func heads(in source: any ByteSource, control: [UInt8]) -> [RegionHead] {
        guard control.count == 512 else { return [] }
        let table = RecordingRegionTable(sector: control)
        let sectors = source.byteCount / 512
        func read(_ sector: UInt32) -> Data? {
            guard sector != 0, UInt64(sector) < sectors, let d = try? source.read(at: UInt64(sector) * 512, count: 512), d.count == 512 else { return nil }
            return d
        }
        var result: [RegionHead] = []
        for (kind, start) in [(RecordingRegionKind.normal, table.normalStart), (RecordingRegionKind.event, table.eventStart)] {
            guard let h = read(start) else { continue }
            let b = Bytes(h)
            guard let magic = try? b.le32(0), streamHeaderMagics.contains(magic), let own = try? b.le32(selfSectorOffset), own == start,
                  let generation = try? b.le32(headerGenerationOffset), let stamp = try? b.u8(stampOffset) else { continue }
            result.append(RegionHead(kind: kind, sector: UInt64(start), stamp: stamp, generation: generation))
        }
        if let h = read(table.journalStart) {
            let b = Bytes(h)
            if let magic = try? b.le32(0), journalMagics.contains(magic), let word = try? b.le32(journalLapOffset) {
                result.append(RegionHead(kind: .history, sector: UInt64(table.journalStart), stamp: nil, generation: word >> 16))
            }
        }
        return result
    }

    /// The regions that are NOT listed, with the reason.
    static func evaluate(state: GenerationState, heads: [RegionHead]) -> [HiddenRegion] {
        var hidden: [HiddenRegion] = []
        for head in heads {
            if let stamp = head.stamp, stamp != state.generation {
                hidden.append(HiddenRegion(kind: head.kind, reason: .staleStamp(stamp: stamp, generation: state.generation)))
            } else if head.generation <= state.counter(head.kind) {
                hidden.append(HiddenRegion(kind: head.kind, reason: .notNewerThanCounter(generation: head.generation, counter: state.counter(head.kind))))
            }
        }
        return hidden
    }

    /// Judges the card behind `source`; nil when no checksummed control sector can be read at `controlSector`.
    public static func report(in source: any ByteSource, controlSector: UInt64) -> GenerationReport? {
        guard controlSector + 1 < source.byteCount / 512,
              let c = try? source.read(at: controlSector * 512, count: 512), let ch = try? source.read(at: (controlSector + 1) * 512, count: 512),
              let current = state(control: [UInt8](c), channel: [UInt8](ch)) else { return nil }
        let found = heads(in: source, control: [UInt8](c))
        return GenerationReport(state: current, heads: found, hidden: evaluate(state: current, heads: found))
    }
}
