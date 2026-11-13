/// Small, cost-bounded LRU for decoded frames. Never caches a whole recording.
/// The owner supplies the decoded image's byte cost, not its compressed size.
public struct FrameCache<Value> {
    private struct Entry { let value: Value; let bytes: Int }
    private var entries: [Int: Entry] = [:]
    private var order: [Int] = [] // Least recently used first.
    private let maximumBytes: Int
    private let maximumCount: Int
    public private(set) var totalBytes = 0
    public var count: Int { entries.count }

    public init(maximumBytes: Int, maximumCount: Int) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumCount = max(0, maximumCount)
    }

    public mutating func value(at index: Int) -> Value? {
        guard let entry = entries[index] else { return nil }
        order.removeAll { $0 == index }
        order.append(index)
        return entry.value
    }

    public mutating func insert(_ value: Value, at index: Int, bytes: Int) {
        remove(index)
        guard bytes > 0, bytes <= maximumBytes, maximumCount > 0 else { return }
        // Subtract before comparing, so even Int.max limits cannot overflow.
        while totalBytes > maximumBytes - bytes || count >= maximumCount {
            guard let oldest = order.first else { break }
            remove(oldest)
        }
        entries[index] = Entry(value: value, bytes: bytes)
        order.append(index)
        totalBytes += bytes
    }

    private mutating func remove(_ index: Int) {
        if let old = entries.removeValue(forKey: index) { totalBytes -= old.bytes }
        order.removeAll { $0 == index }
    }
}