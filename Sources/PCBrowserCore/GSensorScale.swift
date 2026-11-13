import Foundation

/// The four "加速度センサースケール" levels of the original (menu commands 330–333).
/// Tick labels were read from the original painters: acceleration ±1.0…±4.0 and
/// gyro ±36…±144 at full scale with half-scale marks.
public enum GSensorScale: Int, CaseIterable, Sendable, Codable {
    case enlarged = 1, standard = 2, reduced1 = 3, reduced2 = 4
    public init?(commandID: Int) { self.init(rawValue: commandID - 329) }
    public var commandID: Int { 329 + rawValue }
    public var label: String {
        switch self {
        case .enlarged: return "拡大"
        case .standard: return "標準"
        case .reduced1: return "縮小1"
        case .reduced2: return "縮小2"
        }
    }
    public var accelerationFullScale: Double { Double(rawValue) }
    public var gyroFullScale: Double { 36 * Double(rawValue) }
    public var accelerationTickValues: [Double] { let f = accelerationFullScale; return [f, f / 2, -f / 2, -f] }
    public var gyroTickValues: [Double] { let f = gyroFullScale; return [f, f / 2, -f / 2, -f] }
    public var accelerationTickLabels: [String] { accelerationTickValues.map { String(format: "%.1f", $0) } }
    public var gyroTickLabels: [String] { gyroTickValues.map { String(format: "%.0f", $0) } }
}

/// Optional, user-supplied raw→physical factors. The original's raw→physical
/// factor is not known, so nothing is converted unless a factor is entered.
public struct SensorCalibration: Codable, Sendable, Equatable {
    public var accelerationCountsPerUnit: Double?
    public var gyroCountsPerUnit: Double?
    public init(accelerationCountsPerUnit: Double? = nil, gyroCountsPerUnit: Double? = nil) {
        self.accelerationCountsPerUnit = accelerationCountsPerUnit
        self.gyroCountsPerUnit = gyroCountsPerUnit
    }
    public var isCalibrated: Bool { usable(accelerationCountsPerUnit) != nil || usable(gyroCountsPerUnit) != nil }
    public func acceleration(raw: Int) -> Double? { usable(accelerationCountsPerUnit).map { Double(raw) / $0 } }
    public func gyro(raw: Int) -> Double? { usable(gyroCountsPerUnit).map { Double(raw) / $0 } }
    private func usable(_ factor: Double?) -> Double? {
        guard let factor, factor.isFinite, factor > 0 else { return nil }
        return factor
    }
}
