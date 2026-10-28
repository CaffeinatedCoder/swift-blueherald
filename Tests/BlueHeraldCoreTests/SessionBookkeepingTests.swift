@testable import BlueHeraldCore
import Foundation
import Testing

// The session's bookkeeping, tested as plain values: no actor, no backend, no waiting.

@Suite("ScanRegistry")
struct ScanRegistryTests {
    func advertisement(_ peripheral: PeripheralID, name: String? = nil) -> Advertisement {
        Advertisement(peripheral: peripheral, name: name, rssi: -50)
    }

    func start(_ registry: inout ScanRegistry, stopAfter: Int? = nil) -> ScanID {
        let id = registry.nextID()
        registry.insert(ActiveScan(id: id, filter: .all, stopAfter: stopAfter))
        return id
    }

    @Test("ids count up and only running scans count against the limit")
    func capacity() throws {
        var registry = ScanRegistry()
        let first = start(&registry)
        let second = start(&registry)
        #expect([first, second].map(\.description) == ["scan-1", "scan-2"])
        #expect(throws: BLEError.scanLimitReached(limit: 2)) { try registry.ensureCapacity(limit: 2) }
        registry.finish(first)
        try registry.ensureCapacity(limit: 2)
        #expect(registry.activeIDs == [second])
    }

    @Test("the newest finished scans stay readable, running ones are never pruned")
    func pruning() throws {
        var registry = ScanRegistry()
        let running = start(&registry)
        var finished: [ScanID] = []
        for _ in 0..<(ScanRegistry.finishedCapacity + 3) {
            let id = start(&registry)
            registry.finish(id)
            finished.append(id)
        }
        _ = start(&registry)
        #expect(registry.isActive(running))
        for id in finished.prefix(3) {
            #expect(throws: BLEError.scanNotFound(id)) { try registry.snapshot(id, maxResults: 1) }
        }
        for id in finished.suffix(ScanRegistry.finishedCapacity) {
            _ = try registry.snapshot(id, maxResults: 1)
        }
    }

    @Test("a scan finishes when it reaches its target, and ignores peripherals past its limit")
    func targetAndLimit() throws {
        var registry = ScanRegistry()
        let id = start(&registry, stopAfter: 2)
        let peripherals = (0..<3).map { _ in PeripheralID(UUID()) }
        registry.record(advertisement(peripherals[0]), in: id, limit: 2)
        #expect(registry.isActive(id))
        registry.record(advertisement(peripherals[1]), in: id, limit: 2)
        #expect(!registry.isActive(id))

        let limited = start(&registry)
        for peripheral in peripherals {
            registry.record(advertisement(peripheral), in: limited, limit: 2)
        }
        let snapshot = try registry.snapshot(limited, maxResults: .max)
        #expect(snapshot.seenCount == 2)
        #expect(snapshot.ignoredCount == 1)
        // What any scan saw is remembered for connections, even past a scan's own limit.
        #expect(registry.seen.count == 3)
    }

    @Test("seen merges a peripheral's advertisements")
    func seenMerges() {
        var registry = ScanRegistry()
        let id = start(&registry)
        let peripheral = PeripheralID(UUID())
        registry.record(advertisement(peripheral, name: "Meter"), in: id, limit: 10)
        registry.record(advertisement(peripheral), in: id, limit: 10)
        #expect(registry.seen[peripheral]?.name == "Meter")
        #expect(registry.seen[peripheral]?.advertisementCount == 2)
    }

    @Test("stopping forgets the scan; waiting on a finished one is refused")
    func stop() async throws {
        var registry = ScanRegistry()
        let id = start(&registry)
        let final = try registry.stop(id, maxResults: 1)
        #expect(!final.isActive)
        #expect(throws: BLEError.scanNotFound(id)) { try registry.stop(id, maxResults: 1) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queued = registry.resumeWhenFinished(id, continuation)
            #expect(!queued)
            continuation.resume()
        }
    }
}

@Suite("ConnectionTable")
struct ConnectionTableTests {
    let peripheral = PeripheralID(UUID())

    @Test("a stale attempt cannot remove the entry a newer attempt owns")
    func attempts() {
        var table = ConnectionTable()
        let first = table.begin(peripheral, name: nil)
        _ = table.remove(peripheral)
        let second = table.begin(peripheral, name: nil)
        #expect(second > first)
        table.abandon(peripheral, attempt: first)
        #expect(table.isOwned(peripheral, by: second))
        table.abandon(peripheral, attempt: second)
        #expect(table[peripheral] == nil)
    }

    @Test("a link counts as up for the attempt that established it, and only while it lasts")
    func connectedByAttempt() {
        var table = ConnectionTable()
        let first = table.begin(peripheral, name: nil)
        let connecting = table.isConnected(peripheral, by: first)
        table.markConnected(peripheral, name: nil)
        let up = table.isConnected(peripheral, by: first)
        _ = table.lose(peripheral, reason: nil)
        let second = table.begin(peripheral, name: nil)
        table.markConnected(peripheral, name: nil)
        #expect(!connecting && up)
        #expect(!table.isConnected(peripheral, by: first))
        #expect(table.isConnected(peripheral, by: second))
    }

    @Test("connecting entries count against the limit")
    func capacity() {
        var table = ConnectionTable()
        _ = table.begin(peripheral, name: nil)
        #expect(throws: BLEError.connectionLimitReached(limit: 1)) { try table.ensureCapacity(limit: 1) }
    }

    @Test("losing an established link is remembered and explained, a failed attempt is not")
    func linkLoss() throws {
        var table = ConnectionTable()
        _ = table.begin(peripheral, name: "Meter")
        table.markConnected(peripheral, name: nil)
        _ = try table.requireConnected(peripheral)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let lost = table.lose(peripheral, reason: "timeout", at: at)
        #expect(lost?.name == "Meter")
        #expect(throws: BLEError.linkLost(peripheral, reason: "timeout", at: at)) { try table.requireConnected(peripheral) }

        _ = table.begin(peripheral, name: nil)
        #expect(throws: BLEError.notConnected(peripheral)) { try table.requireConnected(peripheral) }
        table.markConnected(peripheral, name: nil)
        #expect(table.linkLosses.isEmpty)

        let other = PeripheralID(UUID())
        _ = table.begin(other, name: nil)
        _ = table.lose(other, reason: "refused")
        #expect(throws: BLEError.notConnected(other)) { try table.requireConnected(other) }
    }

    @Test("only the newest link losses are kept")
    func linkLossCapacity() {
        var table = ConnectionTable()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let peripherals = (0...ConnectionTable.linkLossCapacity).map { _ in PeripheralID(UUID()) }
        for (offset, id) in peripherals.enumerated() {
            _ = table.begin(id, name: nil)
            table.markConnected(id, name: nil)
            _ = table.lose(id, reason: nil, at: start.addingTimeInterval(Double(offset)))
        }
        #expect(table.linkLosses.count == ConnectionTable.linkLossCapacity)
        #expect(table.linkLosses[peripherals[0]] == nil)
        #expect(table.newestLinkLossesFirst.first?.peripheral == peripherals.last)
    }
}

@Suite("SubscriptionTable")
struct SubscriptionTableTests {
    let peripheral = PeripheralID(UUID())
    var battery: CharacteristicAddress {
        CharacteristicAddress(peripheral: peripheral, service: BLEUUID(0x180F), characteristic: BLEUUID(0x2A19))
    }
    var uart: CharacteristicAddress {
        CharacteristicAddress(peripheral: peripheral, service: BLEUUID(0xFF00), characteristic: BLEUUID(0xFF02))
    }

    func add(_ table: inout SubscriptionTable, _ address: CharacteristicAddress, capacity: Int = 8) -> SubscriptionID {
        table.add(on: address, userDescription: nil, mode: .notify, capacity: capacity)
    }

    @Test("ids count up, and closed subscriptions free their slot")
    func capacity() throws {
        var table = SubscriptionTable()
        let id = add(&table, battery)
        #expect(id.description == "sub-1")
        #expect(table.open(at: battery)?.id == id)
        #expect(throws: BLEError.subscriptionLimitReached(limit: 1)) { try table.ensureCapacity(limit: 1) }
        let closed = table.close(of: peripheral, reason: "gone")
        #expect(closed == [id])
        try table.ensureCapacity(limit: 1)
        #expect(table.open(at: battery) == nil)
    }

    @Test("sequence numbers run across subscriptions, and only open ones receive")
    func sequence() {
        var table = SubscriptionTable()
        let a = add(&table, battery)
        let b = add(&table, uart)
        let first = table.record(Data([1]), from: battery, receivedAt: .now)
        let second = table.record(Data([2]), from: uart, receivedAt: .now)
        #expect(first == a && second == b)
        #expect(table.lastSequence == 2)
        let stranger = CharacteristicAddress(peripheral: PeripheralID(UUID()), service: BLEUUID(0x180F), characteristic: BLEUUID(0x2A19))
        let unsubscribed = table.record(Data([3]), from: stranger, receivedAt: .now)
        _ = table.close(of: peripheral, reason: "gone")
        let afterClose = table.record(Data([4]), from: battery, receivedAt: .now)
        #expect(unsubscribed == nil && afterClose == nil)
        #expect(table.lastSequence == 2)
    }

    @Test("a closed subscription stays readable until drained, then goes")
    func closedThenDrained() {
        var table = SubscriptionTable()
        let id = add(&table, battery)
        _ = table.record(Data([1]), from: battery, receivedAt: .now)
        _ = table.close(of: peripheral, reason: "gone")
        #expect(table.bufferedCount(in: id) == 1)
        #expect(!table.canReceive(in: id))
        let drained = table.drain(id, maxCount: 10)
        #expect(drained.notifications.map(\.value) == [Data([1])])
        #expect(table[id] == nil)
    }

    @Test("discarding an old subscription leaves a newer one on the same characteristic")
    func discardKeepsNewer() {
        var table = SubscriptionTable()
        let old = add(&table, battery)
        _ = table.close(of: peripheral, reason: "gone")
        let new = add(&table, battery)
        table.discard(old)
        #expect(table.open(at: battery)?.id == new)
        table.discard(new)
        #expect(table.open(at: battery) == nil)
    }

    @Test("draining merges every buffer in arrival order and reports drops once")
    func drainOrder() {
        var table = SubscriptionTable()
        _ = add(&table, battery, capacity: 2)
        _ = add(&table, uart)
        for (index, address) in [battery, uart, battery, uart, battery].enumerated() {
            _ = table.record(Data([UInt8(index)]), from: address, receivedAt: .now)
        }
        let first = table.drain(nil, maxCount: 3)
        #expect(first.notifications.map(\.sequence) == [2, 3, 4])
        #expect(first.remaining == 1)
        #expect(first.dropped == 1)
        let second = table.drain(nil, maxCount: 3)
        #expect(second.notifications.map(\.sequence) == [5])
        #expect(second.dropped == 0)
    }

    @Test("a pending subscription activates once; a reply is taken by prefix after the mark")
    func activateAndTake() {
        var table = SubscriptionTable()
        let id = add(&table, uart)
        let activated = table.activate(id)
        let again = table.activate(id)
        #expect(activated && !again)
        _ = table.record(Data([0xAA, 1]), from: uart, receivedAt: .now)
        let window = table.replyWindow(sentAt: .distantPast)
        _ = table.record(Data([0xBB, 2]), from: uart, receivedAt: .now)
        _ = table.record(Data([0xAA, 3]), from: uart, receivedAt: .now)
        #expect(table.unmatched(on: id, in: window, prefix: Data([0xAA])) == 1)
        let reply = table.takeFirst(on: id, in: window, prefix: Data([0xAA]))
        let none = table.takeFirst(on: id, in: window, prefix: Data([0xAA]))
        #expect(reply?.value == Data([0xAA, 3]))
        #expect(none == nil)
        #expect(table.bufferedCount(in: id) == 2)
    }

    @Test("a reply window holds what came after its mark and was received no earlier than the write")
    func replyWindow() {
        var table = SubscriptionTable()
        let id = add(&table, uart)
        _ = table.activate(id)
        let sentAt = Date.now
        _ = table.record(Data([1]), from: uart, receivedAt: sentAt)
        let window = table.replyWindow(sentAt: sentAt)
        // Received before the write, recorded after the mark: handed over late.
        _ = table.record(Data([2]), from: uart, receivedAt: sentAt - 0.001)
        _ = table.record(Data([3]), from: uart, receivedAt: sentAt)
        #expect(table.unmatched(on: id, in: window, prefix: Data([0xFF])) == 1)
        #expect(table.takeFirst(on: id, in: window, prefix: Data())?.value == Data([3]))
        #expect(table.takeFirst(on: id, in: window, prefix: Data()) == nil)
    }
}

@Suite("WaiterQueue")
struct WaiterQueueTests {
    let a = SubscriptionID(rawValue: 1)
    let b = SubscriptionID(rawValue: 2)

    @Test("a notification wakes its own waiters and those waiting on any, nobody else")
    func take() {
        var queue = WaiterQueue<String>()
        queue.add("on a", token: queue.nextToken(), waitingFor: a)
        queue.add("on b", token: queue.nextToken(), waitingFor: b)
        queue.add("on any", token: queue.nextToken(), waitingFor: nil)
        let woken = queue.take(for: a)
        let rest = queue.takeAll()
        #expect(woken == ["on a", "on any"])
        #expect(rest == ["on b"])
        #expect(queue.isEmpty)
    }

    @Test("settling a subscription wakes only the calls joining it")
    func joiners() {
        var queue = WaiterQueue<String>()
        queue.add("joining a", token: queue.nextToken(), waitingFor: a)
        queue.add("on any", token: queue.nextToken(), waitingFor: nil)
        let joiners = queue.takeJoiners(of: a)
        let rest = queue.takeAll()
        #expect(joiners == ["joining a"])
        #expect(rest == ["on any"])
    }

    @Test("a timed-out waiter is removed once, by its token")
    func remove() {
        var queue = WaiterQueue<String>()
        let token = queue.nextToken()
        queue.add("timed", token: token, waitingFor: a)
        let first = queue.remove(token)
        let second = queue.remove(token)
        #expect(first == "timed")
        #expect(second == nil)
    }
}

@Suite("TransactionQueue")
struct TransactionQueueTests {
    let a = SubscriptionID(rawValue: 1)
    let b = SubscriptionID(rawValue: 2)

    @Test("a free subscription is taken at once; a busy one is handed on in arrival order")
    func handOver() {
        var queue = TransactionQueue<String>()
        let first = queue.enter(a, token: queue.nextToken(), waker: "first")
        let onB = queue.enter(b, token: queue.nextToken(), waker: "on b")
        let second = queue.enter(a, token: queue.nextToken(), waker: "second")
        let third = queue.enter(a, token: queue.nextToken(), waker: "third")
        #expect(first && onB && !second && !third)
        #expect(queue.leave(a) == "second")
        // Still busy: handed over, not freed, so a newcomer queues behind the third.
        let newcomer = queue.enter(a, token: queue.nextToken(), waker: "newcomer")
        #expect(!newcomer)
        #expect(queue.leave(a) == "third")
        #expect(queue.leave(a) == "newcomer")
        #expect(queue.leave(a) == nil)
        let again = queue.enter(a, token: queue.nextToken(), waker: "again")
        #expect(again)
    }

    @Test("a waiter that gives up is withdrawn once, and not if it was already handed the subscription")
    func withdraw() {
        var queue = TransactionQueue<String>()
        _ = queue.enter(a, token: queue.nextToken(), waker: "holder")
        let waiting = queue.nextToken()
        _ = queue.enter(a, token: waiting, waker: "waiting")
        let handed = queue.nextToken()
        _ = queue.enter(a, token: handed, waker: "handed")
        #expect(queue.withdraw(waiting) == "waiting")
        #expect(queue.withdraw(waiting) == nil)
        #expect(queue.leave(a) == "handed")
        #expect(queue.withdraw(handed) == nil)
        #expect(queue.takeAll().isEmpty)
    }
}
