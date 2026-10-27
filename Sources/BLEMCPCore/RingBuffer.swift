/// A fixed-capacity FIFO that overwrites its oldest element when full.
///
/// Notification bursts must never grow memory without bound, and the newest samples are the
/// ones worth keeping, so appending to a full buffer evicts instead of failing.
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        storage = Array(repeating: nil, count: capacity)
    }

    public var capacity: Int { storage.count }
    public var isEmpty: Bool { count == 0 }

    public var first: Element? {
        isEmpty ? nil : storage[head]
    }

    /// Appends `element` and returns the element it evicted, if the buffer was full.
    @discardableResult
    public mutating func append(_ element: Element) -> Element? {
        let tail = (head + count) % capacity
        if count == capacity {
            let evicted = storage[tail]
            storage[tail] = element
            head = (head + 1) % capacity
            return evicted
        }
        storage[tail] = element
        count += 1
        return nil
    }

    public mutating func popFirst() -> Element? {
        guard !isEmpty else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return element
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
