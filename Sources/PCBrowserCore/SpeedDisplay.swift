import Foundation

/// Speed unit selected by the original "速度表示選択" menu (GPS speed / knot).
public enum SpeedUnit: String, CaseIterable, Sendable, Codable {
    case kilometersPerHour, knots
    /// Constant used by the original knot display (km/h × 0.539956803).
    public static let knotsPerKilometerPerHour = 0.539956803
    public var label: String { self == .knots ? "knot" : "km/h" }
    public func value(fromKMH kmh: Double) -> Double { self == .knots ? kmh * Self.knotsPerKilometerPerHour : kmh }
    public func text(fromKMH kmh: Double) -> String { String(format: "%.2f", value(fromKMH: kmh)) + " " + label }
    /// The original meter shows the unit value truncated to an unsigned 16-bit integer.
    public func legacyMeterValue(fromKMH kmh: Double) -> Int {
        let v = value(fromKMH: kmh)
        guard v.isFinite, v > 0 else { return 0 }
        return Int(min(v, 65535))
    }
}
