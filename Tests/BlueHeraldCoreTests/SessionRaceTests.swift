import BlueHeraldCore
import BlueHeraldTestSupport
import Foundation
import Testing

/// Calls that overlap: a second call arriving while the first still waits on the radio.
@Suite("Overlapping calls", .timeLimit(.minutes(1)))
struct SessionRaceTests {
    let meter = Fixtures.meter()
    let central: FakeCentral
    let auth = Data([0xAB, 0xCD, 0x03, 0xFD, 0x02, 0x78])
    let ack = Data([0xAB, 0xCD, 0x04, 0xFF, 0x00, 0x02, 0x7B])

    init() {
        central = FakeCentral(devices: [meter])
    }

    var tx: CharacteristicAddress {
        CharacteristicAddress(peripheral: meter.id, service: Fixtures.uartService, characteristic: Fixtures.uartTX)
    }

    func selector(_ characteristic: BLEUUID) -> CharacteristicSelector {
        CharacteristicSelector(peripheral: meter.id, service: nil, characteristic: characteristic)
    }

    func makeSession() async throws -> BLESession {
        let session = BLESession(central: central, configuration: SessionConfiguration(writePolicy: WritePolicy(isEnabled: true)))
        await session.start()
        _ = try await session.connect(meter.id)
        return session
    }

    /// Starts a subscription whose CCCD write takes `delay`, and returns once it is pending.
    func pendingSubscription(on session: BLESession) async throws -> Task<SubscriptionSnapshot, any Error> {
        let selector = selector(Fixtures.uartTX)
        let first = Task { try await session.subscribe(selector) }
        try await waitUntil { await session.status().subscriptions.contains { $0.state == .pending } }
        return first
    }

    @Test("a transact that joins a subscription still being enabled waits for it, and catches the reply")
    func transactJoinsPendingSubscription() async throws {
        let session = try await makeSession()
        let (tx, ack) = (tx, ack)
        await central.setResponder { _, _ in [(tx, ack)] }
        await central.setNotificationBehavior(.succeed, delay: .milliseconds(300))
        let first = try await pendingSubscription(on: session)

        let result = try await session.transact(
            auth, to: selector(Fixtures.uartRX), replyOn: selector(Fixtures.uartTX), timeout: .seconds(2))
        #expect(result.reply?.value == ack)
        #expect(result.subscription.state == .active)
        #expect(try await first.value.id == result.subscription.id)
    }

    @Test("a subscribe that joins one that then fails does not return its dead subscription")
    func joinFailedSubscription() async throws {
        let session = try await makeSession()
        await central.setNotificationBehavior(.fail(.backendFailure("CCCD write rejected")), delay: .milliseconds(200))
        let first = try await pendingSubscription(on: session)

        // The joiner tries again itself, and this peripheral rejects that too.
        await #expect(throws: BLEError.backendFailure("CCCD write rejected")) {
            try await session.subscribe(selector(Fixtures.uartTX))
        }
        await #expect(throws: BLEError.self) { try await first.value }
        #expect(await session.status().subscriptions.isEmpty)
    }

    @Test("a subscribe that joins one that then fails gets its own, when the peripheral accepts it")
    func joinRetries() async throws {
        let session = try await makeSession()
        await central.setNotificationBehavior(.fail(.backendFailure("CCCD write rejected")), delay: .milliseconds(200))
        let first = try await pendingSubscription(on: session)
        let central = central
        let joiner = Task {
            // Accept from the joiner's own attempt on.
            try await Task.sleep(for: .milliseconds(100))
            await central.setNotificationBehavior(.succeed)
        }
        let second = try await session.subscribe(selector(Fixtures.uartTX))
        try await joiner.value
        await #expect(throws: BLEError.self) { try await first.value }
        #expect(second.state == .active)
        _ = try await session.notifications(from: second.id, maxCount: 10)
    }

    @Test("a cancelled transact returns at once instead of waiting out its timeout")
    func cancelledTransact() async throws {
        let session = try await makeSession()
        let selector = selector
        let (auth, clock) = (auth, ContinuousClock())
        let started = clock.now
        let task = Task {
            try await session.transact(auth, to: selector(Fixtures.uartRX), replyOn: selector(Fixtures.uartTX), timeout: .seconds(3))
        }
        try await waitUntil { await central.writes.count == 1 }
        task.cancel()
        await #expect(throws: BLEError.cancelled) { try await task.value }
        #expect(clock.now - started < .seconds(1))
    }

    @Test("a stale connect attempt that ends does not remove a newer attempt's entry")
    func staleConnect() async throws {
        let session = BLESession(central: central)
        await session.start()
        await central.setConnectBehavior(.hang)

        let first = Task { try await session.connect(meter.id, discover: false) }
        try await waitUntil { await central.connectAttempts == 1 }
        #expect(await session.disconnect(meter.id))
        let second = Task { try await session.connect(meter.id, discover: false) }
        try await waitUntil { await central.connectAttempts == 2 }

        first.cancel()
        _ = await first.result

        // The second attempt is still in flight, so it is still tracked, and a third is refused.
        #expect(await session.connectionSnapshots().map(\.id) == [meter.id])
        await #expect(throws: BLEError.alreadyConnecting(meter.id)) {
            try await session.connect(meter.id, discover: false)
        }
        #expect(await central.connectAttempts == 2)
        second.cancel()
        _ = await second.result
        #expect(await session.connectionSnapshots().isEmpty)
    }

    /// Connects without discovery, starts `discovery` with `checkpoint` held, then drops the link
    /// and connects again while it waits. Returns the stale discovery, still held.
    func discoveryAcrossReconnect(
        _ session: BLESession,
        holding checkpoint: FakeCentral.Checkpoint,
        survivingLinkLoss: Bool = false,
        beforeReconnecting change: @Sendable () async -> Void = {},
        _ discovery: @escaping @Sendable () async throws -> [GATTService]
    ) async throws -> Task<[GATTService], any Error> {
        let (central, id) = (central, meter.id)
        _ = try await session.connect(id, discover: false)
        await central.hold(checkpoint, survivingLinkLoss: survivingLinkLoss)
        let stale = Task { try await discovery() }
        try await waitUntil { await central.waiting[checkpoint] == 1 }
        await central.dropLink(to: id)
        try await waitUntil { await session.connectionSnapshots().isEmpty }
        await change()
        _ = try await session.connect(id, discover: false)
        return stale
    }

    @Test("a discovery that fails after a reconnect leaves no error on the new connection")
    func staleDiscoveryError() async throws {
        let session = BLESession(central: central)
        await session.start()
        let id = meter.id
        let stale = try await discoveryAcrossReconnect(session, holding: .discoverServices) {
            try await session.discoverServices(of: id, userDescriptions: false)
        }
        await central.release(.discoverServices)
        await #expect(throws: BLEError.self) { try await stale.value }

        let connection = try await session.connectionSnapshot(id)
        #expect(connection.discoveryError == nil)
        #expect(connection.services == nil)
    }

    @Test("a discovery answered after a reconnect does not give the new connection the old table")
    func staleDiscoveryTable() async throws {
        let session = BLESession(central: central)
        await session.start()
        let (central, id) = (central, meter.id)
        // The device comes back with another table, as a bootloader would.
        let bootloader = Fixtures.services.filter { $0.uuid == Fixtures.uartService }
        let stale = try await discoveryAcrossReconnect(
            session, holding: .discoverServices, survivingLinkLoss: true,
            beforeReconnecting: { await central.setServices(bootloader, of: id) }
        ) {
            try await session.discoverServices(of: id, userDescriptions: false)
        }
        await central.release(.discoverServices)
        _ = await stale.result

        #expect(try await session.connectionSnapshot(id).services == nil)
        let services = try await session.discoverServices(of: id, userDescriptions: false)
        #expect(services.map(\.uuid) == [Fixtures.uartService])
    }

    @Test("names read partly over a dropped link do not stand in for the new connection's names")
    func staleUserDescriptions() async throws {
        let session = BLESession(central: central)
        await session.start()
        let id = meter.id
        let stale = try await discoveryAcrossReconnect(session, holding: .descriptorRead) {
            try await session.discoverServices(of: id, userDescriptions: true)
        }
        await central.release(.descriptorRead)
        await #expect(throws: BLEError.self) { try await stale.value }

        let services = try await session.discoverServices(of: id)
        let names = services.flatMap(\.characteristics).compactMap(\.userDescription).sorted()
        #expect(names == ["Battery", "Data In ", "Data Out"])
    }

    @Test("a scan waiting for the adapter when the session shuts down never starts")
    func scanAfterShutdown() async throws {
        let central = FakeCentral(state: .unknown, devices: [meter])
        let session = BLESession(central: central)
        await session.start()
        let scan = Task { try await session.startScan() }
        try await Task.sleep(for: .milliseconds(50))
        await session.shutdown()
        await central.changeState(to: .poweredOn)
        await #expect(throws: BLEError.cancelled) { try await scan.value }
        try await waitUntil { await central.activeScanCount == 0 }
    }

    @Test("a connect waiting for the adapter when the session shuts down never reaches the radio")
    func connectAfterShutdown() async throws {
        let central = FakeCentral(state: .unknown, devices: [meter])
        let session = BLESession(central: central)
        await session.start()
        let connect = Task { try await session.connect(meter.id, discover: false) }
        try await Task.sleep(for: .milliseconds(50))
        await session.shutdown()
        await central.changeState(to: .poweredOn)
        await #expect(throws: BLEError.cancelled) { try await connect.value }
        #expect(await central.connectAttempts == 0)
        #expect(await session.status().connections.isEmpty)
    }

    @Test("a connect in flight when the session shuts down leaves no link")
    func connectDuringShutdown() async throws {
        // FakeCentral's hang ends only on cancellation; CoreBluetooth fails it on disconnect.
        let session = BLESession(
            central: central, configuration: SessionConfiguration(timeouts: SessionTimeouts(connect: .milliseconds(200))))
        await session.start()
        await central.setConnectBehavior(.hang)
        let connect = Task { try await session.connect(meter.id, discover: false) }
        try await waitUntil { await central.connectAttempts == 1 }
        await session.shutdown()
        await #expect(throws: BLEError.self) { try await connect.value }
        #expect(await central.disconnectRequests.contains(meter.id))
        #expect(await session.status().connections.isEmpty)
    }
}
