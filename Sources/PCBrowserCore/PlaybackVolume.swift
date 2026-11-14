import Foundation

/// The volume model of the original viewer (PC Browser 1.9.60.0: 音量小さく 0x44b1a0, 音量大きく 0x44b250, slider at 0x411983).
///
/// The original keeps one level per viewer (this+0x52f4), starts at 33, and each command moves it by 10 inside 8...58, so the 51 slider
/// positions are `level - 8`. The sound level in percent is `2 × level − 16`. The attenuation handed to DirectShow is
/// `Int(log10(percent / 100) × 10 × 100)` hundredths of a decibel (-10000 = silent at 0 %, 0 above 100 %), i.e. the percentage is a
/// power ratio. The Mac player takes a linear amplitude, which for the same attenuation is `sqrt(percent / 100)`.
public enum PlaybackVolume {
    public static let minimumLevel = 8
    public static let maximumLevel = 58
    public static let defaultLevel = 33
    public static let commandStep = 10

    public static func clamped(_ level: Int) -> Int { min(maximumLevel, max(minimumLevel, level)) }
    public static func down(_ level: Int) -> Int { clamped(level - commandStep) }
    public static func up(_ level: Int) -> Int { clamped(level + commandStep) }
    public static func percent(level: Int) -> Int { 2 * clamped(level) - 16 }

    /// Slider fraction 0...1 of a level, and the nearest level of a fraction.
    public static func fraction(level: Int) -> Double { Double(clamped(level) - minimumLevel) / Double(maximumLevel - minimumLevel) }
    public static func level(fraction: Double) -> Int {
        let f = min(1, max(0, fraction.isFinite ? fraction : 0))
        return clamped(minimumLevel + Int((f * Double(maximumLevel - minimumLevel)).rounded()))
    }

    public static func attenuationHundredthsOfDecibel(level: Int) -> Int {
        let p = percent(level: level)
        if p > 100 { return 0 }
        if p <= 0 { return -10_000 }
        return Int(log10(Double(p) / 100.0) * 10.0 * 100.0)
    }

    /// Linear amplitude (0...1) with the attenuation the original applies.
    public static func amplitude(level: Int) -> Double {
        let hundredths = attenuationHundredthsOfDecibel(level: level)
        if hundredths <= -10_000 { return 0 }
        return pow(10, Double(hundredths) / 100.0 / 20.0)
    }
    public static func amplitude(fraction: Double) -> Double { amplitude(level: level(fraction: fraction)) }
}
