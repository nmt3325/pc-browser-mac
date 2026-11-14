import Foundation

/// How far ahead of the sound clock the player asks for a picture.
///
/// A picture reaches the screen some time after it is asked for (decoding, conversion, the wait for the main thread). If the player asks for
/// the frame that is due *now*, the picture on the screen is late by that time, and on a slow machine by a lot. The player keeps a moving
/// average of the measured time and asks for the frame that will be due when the picture appears, so the picture is in step with the
/// sound as closely as the machine allows. The time of one picture is capped, so a stall cannot throw the picture far ahead of the sound.
public struct PlaybackLatency: Equatable, Sendable {
    public static let maximumSeconds = 0.5
    public static let smoothing = 0.3
    public private(set) var seconds = 0.0

    public init() {}

    /// Adds the time one picture took from the request to the screen. Values that are not finite or are negative are ignored.
    public mutating func record(_ took: Double) {
        guard took.isFinite, took >= 0 else { return }
        seconds = seconds * (1 - Self.smoothing) + min(Self.maximumSeconds, took) * Self.smoothing
    }

    /// Seconds of the recording that pass while a picture is prepared, at the playback speed `rate` (0.5 ... 16).
    public func lead(rate: Double) -> Double { rate.isFinite && rate > 0 ? seconds * rate : 0 }
}
