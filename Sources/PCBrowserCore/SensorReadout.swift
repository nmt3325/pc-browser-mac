import Foundation

/// Acceleration readout rules of the original viewer. They were established by feeding controlled raw values
/// (synthetic numbers written into a scratch copy of a recording) to the original program and reading its panel:
/// the number shown is `raw / 1000` G, truncated toward zero to hundredths, with the sign kept.
public enum SensorReadout {
    /// Counts per G: 250 counts read 0.25, 500 counts read 0.50.
    public static let accelerationCountsPerG = 1000
    /// Axis order of the three header words (X, Y, Z) and the label colours of the original panel (red, green, blue).
    public static let axisNames = ["X", "Y", "Z"]

    /// Hundredths of a G, truncated toward zero (the original truncates; it does not round).
    public static func accelerationHundredths(raw: Int) -> Int { raw / (accelerationCountsPerG / 100) }

    /// "0.25", "-0.25", "1.99" (1999 counts), "0.99" (999 counts) and "-0.00" for a small negative reading:
    /// the sign of a truncated-to-zero negative value is kept, as in the original.
    public static func accelerationText(raw: Int) -> String {
        let magnitude = abs(accelerationHundredths(raw: raw))
        let fraction = magnitude % 100
        return (raw < 0 ? "-" : "") + String(magnitude / 100) + "." + (fraction < 10 ? "0" : "") + String(fraction)
    }

    /// Untruncated value used for the graph.
    public static func accelerationG(raw: Int) -> Double { Double(raw) / Double(accelerationCountsPerG) }

    /// X, Y, Z readout texts of one packet.
    public static func accelerationTexts(_ raw: [Int16]) -> [String] { raw.prefix(3).map { accelerationText(raw: Int($0)) } }
}
