import Foundation

/// 表示 ▸ 画面表示 ▸ 16分割表示 of the original application: a 4 × 4 sheet of the sixteen most recent frames.
///
/// Behaviour observed in the original 1.9.60.0 (FDR model selected, one recording loaded):
/// * every tile shows the *whole raw picture* (both lens circles, no re-projection) with its 1-based frame number
///   below it;
/// * the tiles run row by row from the oldest frame (top left) to the current frame (bottom right), i.e. frames
///   `current-15 … current`; stepping one frame forward moves every picture one tile back and puts the new frame
///   in the last tile, stepping back does the opposite;
/// * a tile for which there is no earlier frame stays empty (the original draws its logo there).
///
/// The entry is enabled only for models of the FDR capability class (see `isAvailable(capability:)`); the other
/// classes show the item grayed out. Everything here is pure geometry and frame arithmetic, so it is unit tested
/// without a GPU; the drawing lives in the Mac target.
public enum FrameHistorySheet {
    public static let columns = 4
    public static let rows = 4
    public static var tileCount: Int { columns * rows }

    /// Frame index of every tile, row-major from the top left. `nil` marks a tile without a frame (before the
    /// start of the recording, or when `current` is not a frame of the recording).
    public static func tileFrames(current: Int, frameCount: Int) -> [Int?] {
        guard frameCount > 0, (0..<frameCount).contains(current) else { return Array(repeating: nil, count: tileCount) }
        return (0..<tileCount).map { (slot: Int) -> Int? in
            let index = current - (tileCount - 1) + slot
            return index >= 0 ? index : nil
        }
    }

    /// The frames that exist in the window ending at `current`, oldest first (the decode order).
    public static func requiredFrames(current: Int, frameCount: Int) -> [Int] {
        tileFrames(current: current, frameCount: frameCount).compactMap { $0 }
    }

    /// The number printed below a tile: the original counts frames from 1.
    public static func label(frame: Int) -> String { String(frame + 1) }

    /// Models whose capability class (`capability & 0x3000`) is 0x1000 are the FDR family. In the original the
    /// 16分割 and 1画面 entries are enabled for them while a recording is loaded; with a Q-01 (class 0x2000) both are
    /// grayed out. The classes 0 and 0x3000 (BU/FA/BDR/SN) were not observed, so they stay disabled here.
    public static func isAvailable(capability: Int) -> Bool { capability & 0x3000 == 0x1000 }

    /// Position and size (in pixels, origin at the top left) of one tile picture and its number.
    public struct Placement: Equatable, Sendable {
        public let x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    }

    public struct Layout: Equatable, Sendable {
        public let width: Int, height: Int
        public let pictures: [Placement]
        public let labels: [Placement]
    }

    /// Geometry of the sheet for pictures of `pictureWidth × pictureHeight` pixels: a `gap` between and around all
    /// cells, and a strip of `labelHeight` pixels below each picture for its frame number.
    public static func layout(pictureWidth: Int, pictureHeight: Int, labelHeight: Int = 30, gap: Int = 4) -> Layout {
        let cellHeight = pictureHeight + labelHeight
        var pictures: [Placement] = [], labels: [Placement] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = gap + column * (pictureWidth + gap), y = gap + row * (cellHeight + gap)
                pictures.append(Placement(x: x, y: y, width: pictureWidth, height: pictureHeight))
                labels.append(Placement(x: x, y: y + pictureHeight, width: pictureWidth, height: labelHeight))
            }
        }
        return Layout(width: columns * pictureWidth + (columns + 1) * gap,
                      height: rows * cellHeight + (rows + 1) * gap, pictures: pictures, labels: labels)
    }

    /// Size of a tile picture for a source picture: `width` pixels wide with the source aspect ratio, even height.
    public static func pictureSize(sourceWidth: Int, sourceHeight: Int, width: Int = 640) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0, width > 0 else { return (width: max(width, 2), height: max(width, 2) / 2 * 2) }
        let height = max(2, Int((Double(width) * Double(sourceHeight) / Double(sourceWidth)).rounded()) / 2 * 2)
        return (width: width, height: height)
    }
}

extension LegacyModel {
    /// Whether the original enables 表示 ▸ 画面表示 ▸ 16分割表示 for this model.
    public var supportsFrameHistorySheet: Bool { FrameHistorySheet.isAvailable(capability: capability) }
}
