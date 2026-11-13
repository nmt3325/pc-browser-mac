import Foundation

/// Sampling is anchored at the first selected frame. Gaps do not cause a burst
/// of catch-up frames; each source frame is selected at most once.
public enum FrameSampling {
    public static func indices(starts: [Double], range: Range<Int>, everyFrames: Int = 1,
                               everySeconds: Double? = nil) throws -> [Int] {
        guard range.lowerBound >= 0, range.upperBound <= starts.count, everyFrames > 0 else {
            throw BrowserError.invalid("静止画の範囲またはフレーム間隔が不正です")
        }
        guard !range.isEmpty else { return [] }
        var previous = -Double.infinity
        for i in range {
            guard starts[i].isFinite, starts[i] >= previous else { throw BrowserError.invalid("静止画の時刻が不正です") }
            previous = starts[i]
        }
        if let interval = everySeconds {
            guard interval.isFinite, interval > 0 else { throw BrowserError.invalid("秒間隔は正の有限値で指定してください") }
            let base = starts[range.lowerBound]
            var target = base, result: [Int] = []
            for i in range where starts[i] + 1e-9 >= target {
                result.append(i)
                target = base + (floor(max(0, starts[i] - base) / interval + 1e-9) + 1) * interval
            }
            return result
        }
        var result: [Int] = [], i = range.lowerBound
        while i < range.upperBound {
            result.append(i)
            let (next, overflow) = i.addingReportingOverflow(everyFrames)
            if overflow { break }; i = next
        }
        return result
    }
}

/// AVI uses a constant frame rate. Repeated source frames fill clock gaps so
/// audio is not compressed in time. No source timestamp is modified.
public struct ConstantRateSchedule: Sendable {
    public let framesPerSecond: Double, duration: Double, outputFrameCount: Int
    public let range: Range<Int>
    private let starts: [Double], base: Double
    public init(starts: [Double], range: Range<Int>, framesPerSecond fps: Double) throws {
        guard fps.isFinite, (1...120).contains(fps), !range.isEmpty,
              range.lowerBound >= 0, range.upperBound <= starts.count else { throw BrowserError.invalid("AVIの時刻またはフレーム範囲が不正です") }
        var last = -Double.infinity
        for i in range { guard starts[i].isFinite, starts[i] >= last else { throw BrowserError.invalid("AVIの時刻が逆行しています") }; last = starts[i] }
        let base = starts[range.lowerBound], duration = starts[range.upperBound - 1] - base + 1 / fps
        let count = ceil(duration * fps - 1e-8)
        guard duration > 0, count.isFinite, count > 0, count <= Double(UInt32.max) else { throw BrowserError.invalid("AVIの長さが上限を超えています") }
        self.starts = starts; self.range = range; self.base = base
        framesPerSecond = fps; self.duration = duration; outputFrameCount = Int(count)
    }
    public func sourceIndex(for outputFrame: Int) -> Int {
        let t = base + Double(max(0, min(outputFrameCount - 1, outputFrame))) / framesPerSecond
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi { let mid = (lo + hi) / 2; if starts[mid] <= t + 1e-9 { lo = mid + 1 } else { hi = mid } }
        return max(range.lowerBound, min(range.upperBound - 1, lo - 1))
    }
}
