import Foundation

/// The two copies of a packet header: the D101 header in front of the packet and its D102 mirror behind it.
enum PacketMirror {
    /// Header bytes 0x40..<0x50 (trigger flags, G-sensor sample and cause mask) are completed after the header
    /// has been written, so the mirror, which is the final copy, may differ there. The original application
    /// reads the mirror. Every other byte must be identical.
    static let completedLater = 0x40..<0x50

    static func matches(header: Data, mirror: Data) -> Bool {
        guard header.count == 512, mirror.count == 512 else { return false }
        let h = header.startIndex, m = mirror.startIndex
        let lo = completedLater.lowerBound, hi = completedLater.upperBound
        let headerStart = header[(h + 4)..<(h + lo)], mirrorStart = mirror[(m + 4)..<(m + lo)]
        if headerStart != mirrorStart { return false }
        let headerEnd = header[(h + hi)..<(h + 512)], mirrorEnd = mirror[(m + hi)..<(m + 512)]
        return headerEnd == mirrorEnd
    }
}
