import CoreGraphics
import PCBrowserCore

/// Applies the flip / rotation / zoom state to a finished picture with CoreGraphics.
/// The picture keeps its size; areas outside the rotated source are black.
enum ViewTransformRenderer {
    static func apply(_ image: CGImage, _ transform: ViewTransform) -> CGImage? {
        let state = transform.clamped
        if state.isIdentity { return image }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let m = state.matrix(width: Double(width), height: Double(height))
        // Work in a top-left origin: flip once, apply the matrix, then flip the picture itself back.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(CGAffineTransform(a: CGFloat(m.a), b: CGFloat(m.b), c: CGFloat(m.c), d: CGFloat(m.d), tx: CGFloat(m.tx), ty: CGFloat(m.ty)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Deterministic self-check used by `--view-check` in CI: renders a synthetic picture through every
    /// operation and compares pixel colours at known positions. Returns one entry per check.
    static func selfCheck() -> [(name: String, passed: Bool, detail: String)] {
        var results: [(name: String, passed: Bool, detail: String)] = []
        let size = 64
        // Quadrant picture: top-left red, top-right green, bottom-left blue, bottom-right white.
        guard let source = quadrantImage(size: size) else { return [("source", false, "cannot create source")] }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] { rgb(image, x, y) }
        func near(_ a: [Int], _ b: [Int]) -> Bool { a.count == 3 && b.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) <= 8 } }
        let red = [255, 0, 0], green = [0, 255, 0], blue = [0, 0, 255], white = [255, 255, 255]
        let q1 = size / 4, q3 = size * 3 / 4   // sample points inside each quadrant
        func record(_ name: String, _ transform: ViewTransform, _ expected: [(Int, Int, [Int])]) {
            guard let out = apply(source, transform) else { results.append((name, false, "render failed")); return }
            var failures: [String] = []
            for (x, y, colour) in expected where !near(pixel(out, x, y), colour) { failures.append("(\(x),\(y)) \(pixel(out, x, y)) != \(colour)") }
            results.append((name, failures.isEmpty, failures.joined(separator: "; ")))
        }
        var identity = ViewTransform()
        record("identity", identity, [(q1, q1, red), (q3, q1, green), (q1, q3, blue), (q3, q3, white)])
        var flipH = identity; flipH.flipHorizontal()
        record("flipHorizontal", flipH, [(q1, q1, green), (q3, q1, red), (q1, q3, white), (q3, q3, blue)])
        var flipV = identity; flipV.flipVertical()
        record("flipVertical", flipV, [(q1, q1, blue), (q3, q1, white), (q1, q3, red), (q3, q3, green)])
        var clockwise = identity; clockwise.rotateClockwise(90)
        record("rotateClockwise90", clockwise, [(q1, q1, blue), (q3, q1, red), (q1, q3, white), (q3, q3, green)])
        var counter = identity; counter.rotateCounterClockwise(90)
        record("rotateCounterClockwise90", counter, [(q1, q1, green), (q3, q1, white), (q1, q3, red), (q3, q3, blue)])
        var half = identity; half.rotateClockwise(180)
        record("rotate180", half, [(q1, q1, white), (q3, q1, blue), (q1, q3, green), (q3, q3, red)])
        var zoomed = identity; zoomed.zoomToDisplayRect(x: 0, y: 0, width: Double(size) / 2, height: Double(size) / 2, displayWidth: Double(size), displayHeight: Double(size))
        record("areaZoomTopLeft", zoomed, [(q1, q1, red), (q3, q3, red), (q3, q1, red), (q1, q3, red)])
        var panned = identity; panned.setZoom(2); panned.pan(byDisplayDeltaX: -Double(size) / 2, y: 0, width: Double(size), height: Double(size))
        record("zoom2PanRight", panned, [(q1, q1, green), (q3, q1, green), (q1, q3, white), (q3, q3, white)])
        var mixed = identity; mixed.flipHorizontal(); mixed.rotateClockwise(90)
        record("flipThenRotate", mixed, [(q1, q1, white), (q3, q1, green), (q1, q3, blue), (q3, q3, red)])
        identity.reset()
        record("resetIsIdentity", identity, [(q1, q1, red), (q3, q3, white)])
        return results
    }

    private static func quadrantImage(size: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let half = CGFloat(size / 2)
        // CoreGraphics origin is bottom-left: the top row of the picture is y in [half, size).
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: half, width: half, height: half))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: half, y: half, width: half, height: half))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: half, height: half))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: half, y: 0, width: half, height: half))
        return context.makeImage()
    }

    /// Reads one pixel (top-left origin) by redrawing the picture into a known RGBA buffer.
    static func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return [] }
        var buffer = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            // Place the requested pixel at the single-pixel context's origin.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return drawn ? [Int(buffer[0]), Int(buffer[1]), Int(buffer[2])] : []
    }
}
