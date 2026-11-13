import Foundation

/// Display-side state of the shown picture, modelled on the original viewer's right-click menu.
///
/// The original keeps a picture state ("画像状態：正転 / 反転  N°") that is changed by 左右反転, 上下反転,
/// 時計回り / 反時計回り (a whole-degree angle entered by the user), 拡大, 縮小, 範囲拡大 and 移動.
/// A flip is a mirror plus a rotation, so the state is `mirrored` + `rotation`; zoom and pan select the
/// visible window of the source picture. One affine matrix maps source pixels to displayed pixels.
/// Exact zoom steps of the original are not decoded; `zoomStep` is a Mac-side choice.
public struct ViewTransform: Sendable, Codable, Equatable {
    public static let minimumZoom = 1.0
    public static let maximumZoom = 8.0
    public static let zoomStep = 1.25
    /// The original accepts only whole degrees in this range for 時計回り / 反時計回り.
    public static let angleInputRange: ClosedRange<Int> = 1...359
    /// Error text of the original angle prompt.
    public static let angleErrorMessage = "角度は1度から359度の間で入力してください。"

    public var mirrored = false
    /// Clockwise rotation of the displayed picture in degrees, normalised to 0..<360.
    public var rotation = 0.0
    public var zoom = 1.0
    /// Centre of the visible window inside the source picture (0...1 on both axes).
    public var centerX = 0.5
    public var centerY = 0.5

    public init() {}

    private enum CodingKeys: String, CodingKey { case mirrored, rotation, zoom, centerX, centerY }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Bool.self, forKey: .mirrored) { mirrored = value }
        if let value = try container.decodeIfPresent(Double.self, forKey: .rotation) { rotation = value }
        if let value = try container.decodeIfPresent(Double.self, forKey: .zoom) { zoom = value }
        if let value = try container.decodeIfPresent(Double.self, forKey: .centerX) { centerX = value }
        if let value = try container.decodeIfPresent(Double.self, forKey: .centerY) { centerY = value }
    }

    // MARK: Normalisation

    public static func normalizedAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        if angle >= 360 { angle -= 360 }
        return angle
    }

    /// Wraps a yaw angle to -180...180 (used by 前後反転, which turns the view by 180°).
    public static func wrappedYaw(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var angle = normalizedAngle(degrees)
        if angle > 180 { angle -= 360 }
        return angle
    }

    public var clamped: ViewTransform {
        var result = self
        result.rotation = Self.normalizedAngle(rotation)
        var scale = zoom.isFinite ? min(Self.maximumZoom, max(Self.minimumZoom, zoom)) : 1.0
        if abs(scale - 1) < 1e-9 { scale = 1 }
        result.zoom = scale
        let half = 0.5 / scale
        func bound(_ value: Double) -> Double { value.isFinite ? min(1 - half, max(half, value)) : 0.5 }
        result.centerX = bound(centerX)
        result.centerY = bound(centerY)
        return result
    }

    public var isIdentity: Bool {
        let state = clamped
        return !state.mirrored && (state.rotation < 1e-9 || state.rotation > 360 - 1e-9) && state.zoom == 1
    }

    // MARK: State label

    public var angleDegrees: Int { Int(Self.normalizedAngle(rotation).rounded()) % 360 }

    /// Text of the first context-menu line: "画像状態：正転", "画像状態：反転  90°" and so on.
    public var stateLabel: String {
        let state = mirrored ? "反転" : "正転"
        let angle = angleDegrees
        return angle == 0 ? "画像状態：\(state)" : "画像状態：\(state)  \(angle)°"
    }

    /// Parses the angle prompt; accepts full-width digits and returns nil outside 1...359.
    public static func parseAngleInput(_ text: String) -> Int? {
        var ascii = ""
        for scalar in text.unicodeScalars {
            if scalar.value >= 0xFF10 && scalar.value <= 0xFF19, let digit = Unicode.Scalar(scalar.value - 0xFEE0) {
                ascii.unicodeScalars.append(digit)
            } else if scalar == " " || scalar == "\u{3000}" || scalar == "\t" || scalar == "\n" {
                continue
            } else {
                ascii.unicodeScalars.append(scalar)
            }
        }
        guard !ascii.isEmpty, ascii.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }), let value = Int(ascii) else { return nil }
        return angleInputRange.contains(value) ? value : nil
    }

    // MARK: Operations

    public mutating func reset() { self = ViewTransform() }

    /// 左右反転: mirrors the displayed picture about its vertical centre line.
    public mutating func flipHorizontal() {
        mirrored.toggle()
        rotation = Self.normalizedAngle(-rotation)
    }

    /// 上下反転: mirrors the displayed picture about its horizontal centre line.
    public mutating func flipVertical() {
        mirrored.toggle()
        rotation = Self.normalizedAngle(180 - rotation)
    }

    public mutating func rotateClockwise(_ degrees: Double) { rotation = Self.normalizedAngle(rotation + degrees) }
    public mutating func rotateCounterClockwise(_ degrees: Double) { rotation = Self.normalizedAngle(rotation - degrees) }

    public mutating func setZoom(_ value: Double) {
        zoom = value
        self = clamped
    }
    public mutating func zoomIn() { setZoom(clamped.zoom * Self.zoomStep) }
    public mutating func zoomOut() { setZoom(clamped.zoom / Self.zoomStep) }

    /// 移動: the content under the pointer follows the pointer. Deltas and sizes are in display pixels.
    public mutating func pan(byDisplayDeltaX dx: Double, y dy: Double, width: Double, height: Double) {
        guard width > 0, height > 0, dx.isFinite, dy.isFinite else { return }
        self = clamped
        let m = matrix(width: width, height: height)
        let determinant = m.a * m.d - m.b * m.c
        guard abs(determinant) > 1e-12 else { return }
        let sourceDX = (m.d * dx - m.c * dy) / determinant
        let sourceDY = (-m.b * dx + m.a * dy) / determinant
        centerX -= sourceDX / width
        centerY -= sourceDY / height
        self = clamped
    }

    /// 範囲拡大: zooms so that the dragged rectangle (display pixels, y down) fills the picture.
    public mutating func zoomToDisplayRect(x: Double, y: Double, width rectWidth: Double, height rectHeight: Double, displayWidth: Double, displayHeight: Double) {
        let inputs = [x, y, rectWidth, rectHeight, displayWidth, displayHeight]
        guard inputs.allSatisfy({ $0.isFinite }), rectWidth > 0, rectHeight > 0, displayWidth > 0, displayHeight > 0 else { return }
        let fractionW = rectWidth / displayWidth, fractionH = rectHeight / displayHeight
        guard fractionW > 0.005, fractionH > 0.005 else { return }
        let before = clamped
        let m = before.matrix(width: displayWidth, height: displayHeight)
        let determinant = m.a * m.d - m.b * m.c
        guard abs(determinant) > 1e-12 else { return }
        let offsetX = (x + rectWidth / 2) - m.tx, offsetY = (y + rectHeight / 2) - m.ty
        let sourceX = (m.d * offsetX - m.c * offsetY) / determinant
        let sourceY = (-m.b * offsetX + m.a * offsetY) / determinant
        var next = before
        next.zoom = before.zoom * min(1 / fractionW, 1 / fractionH)
        next.centerX = sourceX / displayWidth
        next.centerY = sourceY / displayHeight
        self = next.clamped
    }

    /// 回転 (mouse mode): turns the picture by the angle swept by the pointer around a centre point.
    public mutating func rotate(dragFromX x0: Double, y y0: Double, toX x1: Double, y y1: Double, aroundX cx: Double, y cy: Double) {
        let start = atan2(y0 - cy, x0 - cx), end = atan2(y1 - cy, x1 - cx)
        guard start.isFinite, end.isFinite else { return }
        rotateClockwise((end - start) * 180 / .pi)
    }

    // MARK: Geometry

    public struct Matrix: Sendable, Equatable {
        public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
        public func apply(x: Double, y: Double) -> (x: Double, y: Double) { (a * x + c * y + tx, b * x + d * y + ty) }
    }

    /// Affine map from source pixels to displayed pixels (both y down, same size).
    public func matrix(width: Double, height: Double) -> Matrix {
        let state = clamped
        let radians = state.rotation * Double.pi / 180
        let side = state.mirrored ? -1.0 : 1.0
        let cosine = cos(radians), sine = sin(radians), scale = state.zoom
        let a = scale * side * cosine, b = scale * side * sine
        let c = -scale * sine, d = scale * cosine
        let px = state.centerX * width, py = state.centerY * height
        return Matrix(a: a, b: b, c: c, d: d, tx: width / 2 - (a * px + c * py), ty: height / 2 - (b * px + d * py))
    }
}
