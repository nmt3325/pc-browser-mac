import AppKit
import CoreGraphics
import CoreText
import PCBrowserCore

/// Builds the 16分割表示 sheet (`FrameHistorySheet`) of one recording from decoded frames.
///
/// Every tile is the whole raw picture shrunk to a fixed width. The shrunk tiles are kept, so playing or stepping
/// forward decodes only the newest frame instead of sixteen, and stepping back only the oldest one. Tiles before
/// the start of the recording stay empty (the original draws its logo there; the logo is not reproduced).
actor FrameHistoryComposer {
    private var tiles: [Int: CGImage] = [:]
    private let pictureWidth = 640

    /// The sheet whose last tile is frame `current`, which the caller has already decoded as `currentFrame`.
    func compose(current: Int, frameCount: Int, currentFrame: CGImage, renderer: FrameRenderer) async throws -> CGImage {
        let wanted = FrameHistorySheet.tileFrames(current: current, frameCount: frameCount)
        let size = FrameHistorySheet.pictureSize(sourceWidth: currentFrame.width, sourceHeight: currentFrame.height, width: pictureWidth)
        var picked: [Int: CGImage] = [:]
        // Oldest first: the decoder only ever moves forward from the nearest keyframe.
        for case let index? in wanted {
            try Task.checkCancellation()
            if let cached = tiles[index], cached.width == size.width, cached.height == size.height { picked[index] = cached; continue }
            let picture: CGImage
            if index == current { picture = currentFrame } else { picture = try await renderer.render(index) }
            guard let tile = Self.shrink(picture, width: size.width, height: size.height) else {
                throw BrowserError.io("16分割表示の縮小画像を作成できません")
            }
            tiles[index] = tile; picked[index] = tile
        }
        // Keep a margin of older tiles so that scrubbing back a few frames does not decode them again.
        let low = current - 2 * FrameHistorySheet.tileCount, high = current + FrameHistorySheet.tileCount
        tiles = tiles.filter { $0.key >= low && $0.key < high }
        return try Self.draw(wanted, tiles: picked, size: size)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func shrink(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func draw(_ frames: [Int?], tiles: [Int: CGImage], size: (width: Int, height: Int)) throws -> CGImage {
        let layout = FrameHistorySheet.layout(pictureWidth: size.width, pictureHeight: size.height)
        guard let context = makeContext(width: layout.width, height: layout.height) else { throw BrowserError.io("16分割表示を作成できません") }
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        context.interpolationQuality = .high
        // The layout counts from the top left; CoreGraphics counts from the bottom left.
        func rect(_ place: FrameHistorySheet.Placement) -> CGRect {
            CGRect(x: place.x, y: layout.height - place.y - place.height, width: place.width, height: place.height)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 22, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1)]
        for (slot, frame) in frames.enumerated() {
            let picture = rect(layout.pictures[slot])
            guard let frame, let tile = tiles[frame] else {
                context.setFillColor(CGColor(gray: 0.1, alpha: 1)); context.fill(picture); continue
            }
            context.draw(tile, in: picture)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: FrameHistorySheet.label(frame: frame), attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, []), area = rect(layout.labels[slot])
            context.textPosition = CGPoint(x: area.midX - bounds.width / 2 - bounds.minX,
                                           y: area.minY + (area.height - bounds.height) / 2 - bounds.minY)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw BrowserError.io("16分割表示を作成できません") }
        return image
    }
}
