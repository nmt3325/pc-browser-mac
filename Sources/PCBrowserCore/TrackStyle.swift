import Foundation

public struct TrackStyle: Codable, Equatable, Sendable {
    public var showRoute = true, showPoints = false
    public var lineRGB = "2783DE", pointRGB = "D5803B"
    public var alpha = 255, width = 4.0, pointScale = 0.6, density = 1
    public init() {}
    public var clamped: TrackStyle {
        var s = self
        s.alpha = min(255, max(0, alpha)); s.width = width.isFinite ? min(10, max(1, width)) : 4
        s.pointScale = pointScale.isFinite ? min(3, max(0.1, pointScale)) : 0.6
        s.density = min(30, max(1, density))
        func rgb(_ value: String, _ fallback: String) -> String {
            value.count == 6 && value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) ? value.uppercased() : fallback
        }
        s.lineRGB = rgb(lineRGB, "2783DE"); s.pointRGB = rgb(pointRGB, "D5803B")
        return s
    }
    public func kmlColor(points: Bool = false) -> String {
        let s = clamped, rgb = Array((points ? s.pointRGB : s.lineRGB).utf8)
        return String(format: "%02x", s.alpha) + String(decoding: rgb[4...5] + rgb[2...3] + rgb[0...1], as: UTF8.self).lowercased()
    }
}
