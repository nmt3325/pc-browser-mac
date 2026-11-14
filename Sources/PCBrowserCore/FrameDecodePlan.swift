import Foundation

/// How the video renderer reaches a requested frame. The decoder keeps the reference frames of the P frames it has already decoded, so
/// moving on from the last decoded frame only needs the frames in between to be decoded.
///
/// - Playing on the sound clock skips display frames whenever a frame arrives late. The skipped frames must still be decoded (later P
///   frames refer to them) but nobody sees them, so only the frame that is shown is converted to a picture. Converting every one of them
///   made a slow machine fall further and further behind the sound.
/// - A restart (a seek, a step back, reverse play, or a keyframe that lies ahead of the decoder) decodes from the keyframe. Only as many
///   of the last frames as the picture cache can hold are converted: reverse play then finds the frames before the target in the cache,
///   and no picture is made that would be evicted again at once.
public struct FrameDecodePlan: Equatable, Sendable {
    /// Start a new decoder at `decodeFrom` (a keyframe) instead of continuing the current one.
    public let restart: Bool
    /// First frame to decode. The target is the last one.
    public let decodeFrom: Int
    /// First frame that is also converted to a picture; the frames before it are only decoded.
    public let convertFrom: Int

    public static func make(target: Int, lastDecoded: Int, keyframe: Int, hasDecoder: Bool, cacheCapacity: Int) -> FrameDecodePlan {
        let key = max(0, min(keyframe, target))
        // A decoder that already stands on the target (or beyond it) cannot hand out the picture: decode again from the keyframe.
        let restart = !hasDecoder || target <= lastDecoded || key - 1 > lastDecoded
        let decodeFrom = restart ? key : lastDecoded + 1
        let convertFrom = restart ? max(decodeFrom, target - max(1, cacheCapacity) + 1) : target
        return FrameDecodePlan(restart: restart, decodeFrom: decodeFrom, convertFrom: convertFrom)
    }
}
