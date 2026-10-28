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

    /// The elements, oldest first.
    public var elements: [Element] {
        (0..<count).map { storage[(head + $0) % capacity]! }
    }

    /// Removes and returns the oldest element that satisfies `predicate`; the rest keep their order.
    public mutating func removeFirst(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        guard let offset = try elements.firstIndex(where: predicate) else { return nil }
        let removed = storage[(head + offset) % capacity]
        // Close the gap by shifting the newer elements one slot towards the head.
        for position in offset..<(count - 1) {
            storage[(head + position) % capacity] = storage[(head + position + 1) % capacity]
        }
        storage[(head + count - 1) % capacity] = nil
        count -= 1
        return removed
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
