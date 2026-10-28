import Foundation

/// The session's subscriptions and their notification buffers, with the rules that need no
/// actor: id allocation, one open subscription per characteristic, the subscription limit, the
/// session-wide sequence numbers, and reading the buffers back in arrival order.
struct SubscriptionTable: Sendable {
    private var entries: [SubscriptionID: Subscription] = [:]
    /// Only open subscriptions are here, so a closed one never receives again.
    private var byAddress: [CharacteristicAddress: SubscriptionID] = [:]
    private var lastID = 0
    /// The sequence number of the latest notification recorded, across all subscriptions.
    private(set) var lastSequence: UInt64 = 0

    subscript(id: SubscriptionID) -> Subscription? {
        entries[id]
    }

    /// The open subscription on `address`, if any.
    func open(at address: CharacteristicAddress) -> Subscription? {
        byAddress[address].flatMap { entries[$0] }
    }

    var snapshots: [SubscriptionSnapshot] {
        entries.values.map(\.snapshot).sorted { $0.id < $1.id }
    }

    func ids(of peripheral: PeripheralID) -> [SubscriptionID] {
        entries.values.filter { $0.address.peripheral == peripheral }.map(\.id).sorted()
    }

    func ensureCapacity(limit: Int) throws(BLEError) {
        guard entries.values.count(where: \.isOpen) < limit else { throw .subscriptionLimitReached(limit: limit) }
    }

    /// Adds a pending subscription on `address` under the next id.
    mutating func add(
        on address: CharacteristicAddress, userDescription: String?, mode: NotificationMode, capacity: Int
    ) -> SubscriptionID {
        lastID += 1
        let id = SubscriptionID(rawValue: lastID)
        entries[id] = Subscription(id: id, address: address, userDescription: userDescription, mode: mode, capacity: capacity)
        byAddress[address] = id
        return id
    }

    /// Turns a pending subscription active. Returns `false` when it is no longer pending: it was
    /// closed or discarded meanwhile.
    mutating func activate(_ id: SubscriptionID) -> Bool {
        guard entries[id]?.state == .pending else { return false }
        entries[id]?.state = .active
        return true
    }

    /// Forgets the subscription and anything it buffered. Returns what it was.
    @discardableResult
    mutating func discard(_ id: SubscriptionID) -> Subscription? {
        guard let subscription = entries.removeValue(forKey: id) else { return nil }
        if byAddress[subscription.address] == id {
            byAddress[subscription.address] = nil
        }
        return subscription
    }

    /// Closes the peripheral's open subscriptions, keeping what they buffered readable. Returns
    /// the ids it closed.
    mutating func close(of peripheral: PeripheralID, reason: String) -> [SubscriptionID] {
        var closed: [SubscriptionID] = []
        for (id, subscription) in entries where subscription.address.peripheral == peripheral && subscription.isOpen {
            entries[id]?.state = .closed(reason: reason)
            byAddress[subscription.address] = nil
            closed.append(id)
        }
        return closed
    }

    /// Buffers a notification for the open subscription on `address` under the next sequence
    /// number. Returns that subscription, or `nil` when nobody subscribed.
    mutating func record(_ value: Data, from address: CharacteristicAddress, receivedAt: Date) -> SubscriptionID? {
        guard let id = byAddress[address] else { return nil }
        lastSequence += 1
        entries[id]?.record(
            ValueNotification(subscription: id, sequence: lastSequence, address: address, value: value, receivedAt: receivedAt))
        return id
    }

    /// Removes and returns the first notification after `mark` that starts with `prefix`.
    mutating func takeFirst(on id: SubscriptionID, after mark: UInt64, prefix: Data) -> ValueNotification? {
        entries[id]?.buffer.removeFirst { $0.sequence > mark && $0.value.starts(with: prefix) }
    }

    /// Buffered notifications after `mark` that do not start with `prefix`.
    func unmatched(on id: SubscriptionID, after mark: UInt64, prefix: Data) -> Int {
        entries[id]?.buffer.elements.count { $0.sequence > mark && !$0.value.starts(with: prefix) } ?? 0
    }

    func bufferedCount(in id: SubscriptionID?) -> Int {
        entries.values.filter { id == nil || $0.id == id }.reduce(0) { $0 + $1.buffer.count }
    }

    func canReceive(in id: SubscriptionID?) -> Bool {
        entries.values.contains { (id == nil || $0.id == id) && $0.isOpen }
    }

    struct Drained {
        let notifications: [ValueNotification]
        let remaining: Int
        let dropped: Int
        let subscriptions: [SubscriptionSnapshot]
    }

    /// Takes up to `maxCount` notifications from one subscription or all of them, oldest first,
    /// resets their drop counts, and forgets closed subscriptions that are fully read.
    mutating func drain(_ id: SubscriptionID?, maxCount: Int) -> Drained {
        let ids = id.map { [$0] } ?? entries.keys.sorted()
        var collected: [ValueNotification] = []
        collected.reserveCapacity(min(maxCount, 256))

        // k-way merge on the session-wide sequence number; k is bounded by maxSubscriptions.
        while collected.count < maxCount {
            var next: SubscriptionID?
            var lowest = UInt64.max
            for candidate in ids {
                if let head = entries[candidate]?.buffer.first, head.sequence < lowest {
                    next = candidate
                    lowest = head.sequence
                }
            }
            guard let next, let notification = entries[next]?.buffer.popFirst() else { break }
            collected.append(notification)
        }

        var dropped = 0
        var remaining = 0
        var snapshots: [SubscriptionSnapshot] = []
        for candidate in ids {
            guard let subscription = entries[candidate] else { continue }
            dropped += subscription.droppedSinceLastRead
            remaining += subscription.buffer.count
            entries[candidate]?.droppedSinceLastRead = 0
            snapshots.append(subscription.snapshot)
            if !subscription.isOpen, subscription.buffer.isEmpty {
                // Closed and fully read: nothing left to report.
                entries[candidate] = nil
            }
        }
        return Drained(notifications: collected, remaining: remaining, dropped: dropped, subscriptions: snapshots)
    }
}

struct Subscription: Sendable {
    let id: SubscriptionID
    let address: CharacteristicAddress
    let userDescription: String?
    let mode: NotificationMode
    let createdAt = Date.now
    var state = SubscriptionState.pending
    var buffer: RingBuffer<ValueNotification>
    var receivedCount = 0
    var droppedCount = 0
    var droppedSinceLastRead = 0

    init(id: SubscriptionID, address: CharacteristicAddress, userDescription: String?, mode: NotificationMode, capacity: Int) {
        self.id = id
        self.address = address
        self.userDescription = userDescription
        self.mode = mode
        buffer = RingBuffer(capacity: capacity)
    }

    var isOpen: Bool {
        if case .closed = state { false } else { true }
    }

    mutating func record(_ notification: ValueNotification) {
        receivedCount += 1
        if buffer.append(notification) != nil {
            droppedCount += 1
            droppedSinceLastRead += 1
        }
    }

    var snapshot: SubscriptionSnapshot {
        SubscriptionSnapshot(
            id: id,
            address: address,
            userDescription: userDescription,
            mode: mode,
            state: state,
            createdAt: createdAt,
            receivedCount: receivedCount,
            droppedCount: droppedCount,
            bufferedCount: buffer.count)
    }
}

/// Calls waiting for a notification, or for a pending subscription to settle. Generic over what
/// wakes a waiter so the selection rules can be tested without continuations.
struct WaiterQueue<Waker: Sendable>: Sendable {
    private struct Waiter: Sendable {
        let token: UInt64
        /// `nil` waits for any subscription.
        let subscription: SubscriptionID?
        let waker: Waker
    }

    private var waiters: [Waiter] = []
    private var lastToken: UInt64 = 0

    var isEmpty: Bool { waiters.isEmpty }

    /// A token is taken before the waiter is added, so its timeout can name it.
    mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }

    mutating func add(_ waker: Waker, token: UInt64, waitingFor subscription: SubscriptionID?) {
        waiters.append(Waiter(token: token, subscription: subscription, waker: waker))
    }

    /// The waiter with `token`, if it is still waiting.
    mutating func remove(_ token: UInt64) -> Waker? {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return nil }
        return waiters.remove(at: index).waker
    }

    /// Everyone a notification on `id` concerns: its own waiters and those waiting on any.
    mutating func take(for id: SubscriptionID) -> [Waker] {
        take { $0.subscription == nil || $0.subscription == id }
    }

    /// Only the waiters on `id` itself, which wait for it to settle; a wait on any subscription is
    /// left alone, since nothing arrived.
    mutating func takeJoiners(of id: SubscriptionID) -> [Waker] {
        take { $0.subscription == id }
    }

    mutating func takeAll() -> [Waker] {
        take { _ in true }
    }

    private mutating func take(where matches: (Waiter) -> Bool) -> [Waker] {
        guard !waiters.isEmpty else { return [] }
        let ready = waiters.filter(matches).map(\.waker)
        waiters.removeAll(where: matches)
        return ready
    }
}
