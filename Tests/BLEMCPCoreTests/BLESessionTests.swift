import BLEMCPCore
import BLEMCPTestSupport
import Foundation
import Testing

@Suite("BLESession")
struct BLESessionTests {
    let meter = Fixtures.meter()
    let central: FakeCentral

    init() {
        central = FakeCentral(devices: [meter, Fixtures.beacon()])
    }

    func makeSession(_ configuration: SessionConfiguration = SessionConfiguration()) async -> BLESession {
        let session = BLESession(central: central, configuration: configuration)
        await session.start()
        return session
    }

    func selector(_ characteristic: BLEUUID, service: BLEUUID? = nil) -> CharacteristicSelector {
        CharacteristicSelector(peripheral: meter.id, service: service, characteristic: characteristic)
    }

    // MARK: Scanning

    @Test("a scan reports devices strongest first, with names from scan responses")
    func scanSortsAndMerges() async throws {
        let session = await makeSession()
        let snapshot = try await session.scan(duration: .milliseconds(50))
        #expect(snapshot.peripherals.map(\.name) == ["BB-500 Meter", "Beacon"])
        #expect(snapshot.peripherals.first?.serviceUUIDs == [Fixtures.uartService])
        #expect(snapshot.seenCount == 2)
        #expect(!snapshot.isActive)
        #expect(await central.activeScanCount == 0)
    }

    @Test("filters apply and stop_after ends the scan early")
    func scanStopsAfterMatch() async throws {
        let session = await makeSession()
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = try await session.scan(
            filter: ScanFilter(serviceUUIDs: [Fixtures.uartService]), duration: .seconds(30), stopAfter: 1)
        #expect(clock.now - started < .seconds(5))
        #expect(snapshot.peripherals.map(\.id) == [meter.id])
        #expect(snapshot.matchedCount == 1)
    }

    @Test("background scans have their own ids, limits and results")
    func backgroundScans() async throws {
        let session = await makeSession(SessionConfiguration(limits: SessionLimits(maxScans: 1)))
        let id = try await session.startScan()
        await #expect(throws: BLEError.scanLimitReached(limit: 1)) {
            try await session.startScan()
        }
        try await waitUntil { try await session.scanResults(id).seenCount == 2 }
        let final = try await session.stopScan(id, maxResults: 1)
        #expect(final.peripherals.count == 1)
        #expect(final.matchedCount == 2)
        await #expect(throws: BLEError.scanNotFound(id)) {
            try await session.scanResults(id)
        }
    }

    @Test("scanning needs a powered-on adapter")
    func scanNeedsPower() async {
        let central = FakeCentral(state: .poweredOff)
        let session = BLESession(central: central)
        await #expect(throws: BLEError.bluetoothUnavailable(.poweredOff)) {
            try await session.scan(duration: .milliseconds(10))
        }
    }

    // MARK: Connections and GATT

    @Test("connect discovers the attribute table and reads values")
    func connectAndRead() async throws {
        let session = await makeSession()
        let connection = try await session.connect(meter.id)
        #expect(connection.state == .connected)
        #expect(connection.services?.count == 3)
        #expect(connection.maximumWriteLength == WriteLengths(withResponse: 512, withoutResponse: 20))

        let battery = try await session.read(selector(Fixtures.batteryLevel))
        #expect(battery.value == Data([87]))
        #expect(battery.address.service == Fixtures.batteryService)
    }

    // MARK: User descriptions

    func descriptions(_ services: [GATTService]?) -> [BLEUUID: String] {
        Dictionary(
            uniqueKeysWithValues: (services ?? []).flatMap(\.characteristics).compactMap { characteristic in
                characteristic.userDescription.map { (characteristic.uuid, $0) }
            })
    }

    @Test("connecting reads the 0x2901 names, trimmed")
    func userDescriptionsOnConnect() async throws {
        let session = await makeSession()
        let connection = try await session.connect(meter.id)
        #expect(
            descriptions(connection.services) == [
                Fixtures.batteryLevel: "Battery", Fixtures.uartRX: "Data In", Fixtures.uartTX: "Data Out",
            ])
        #expect(await central.descriptorReads == 3)
    }

    @Test("names can be skipped, and fetched later without rediscovery")
    func userDescriptionsLater() async throws {
        let session = await makeSession()
        let connection = try await session.connect(meter.id, userDescriptions: false)
        #expect(descriptions(connection.services).isEmpty)
        #expect(await central.descriptorReads == 0)

        // A read discovers nothing new and still reads no names.
        _ = try await session.read(selector(Fixtures.batteryLevel))
        #expect(await central.descriptorReads == 0)

        let services = try await session.discoverServices(of: meter.id)
        #expect(descriptions(services).count == 3)
        _ = try await session.discoverServices(of: meter.id)
        #expect(await central.descriptorReads == 3, "names are cached with the attribute table")
    }

    @Test("names that cannot be read are left out without failing discovery")
    func userDescriptionsBestEffort() async throws {
        await central.setDescriptorReadBehavior(.hang)
        let session = await makeSession(SessionConfiguration(timeouts: SessionTimeouts(operation: .milliseconds(50))))
        let connection = try await session.connect(meter.id)
        #expect(connection.services?.count == 3)
        #expect(connection.discoveryError == nil)
        #expect(descriptions(connection.services).isEmpty)
    }

    @Test("reading a characteristic without the read property explains why")
    func readNeedsProperty() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        await #expect(throws: BLEError.propertyNotSupported(characteristic: Fixtures.uartTX, required: "read", available: ["notify"])) {
            try await session.read(selector(Fixtures.uartTX))
        }
    }

    @Test("operations on unconnected peripherals fail fast")
    func notConnected() async {
        let session = await makeSession()
        await #expect(throws: BLEError.notConnected(meter.id)) {
            try await session.read(selector(Fixtures.batteryLevel))
        }
    }

    @Test("the connection limit holds")
    func connectionLimit() async throws {
        let beacon = Fixtures.beacon()
        let central = FakeCentral(devices: [meter, beacon])
        let session = BLESession(central: central, configuration: SessionConfiguration(limits: SessionLimits(maxConnections: 1)))
        _ = try await session.connect(meter.id)
        await #expect(throws: BLEError.connectionLimitReached(limit: 1)) {
            try await session.connect(beacon.id)
        }
    }

    @Test("a connection that never completes times out and frees its slot")
    func connectTimeout() async throws {
        await central.setConnectBehavior(.hang)
        let session = await makeSession(
            SessionConfiguration(
                limits: SessionLimits(maxConnections: 1),
                timeouts: SessionTimeouts(connect: .milliseconds(100))))
        await #expect(throws: BLEError.timedOut(operation: "Connecting to \(meter.id)", after: .milliseconds(100))) {
            try await session.connect(meter.id)
        }
        await central.setConnectBehavior(.succeed)
        let connection = try await session.connect(meter.id)
        #expect(connection.state == .connected)
    }

    @Test("a hanging read is cancelled at the operation timeout")
    func readTimeout() async throws {
        let session = await makeSession(SessionConfiguration(timeouts: SessionTimeouts(operation: .milliseconds(100))))
        _ = try await session.connect(meter.id)
        await central.setReadBehavior(.hang)
        await #expect(throws: BLEError.timedOut(operation: "Reading 2A19", after: .milliseconds(100))) {
            try await session.read(selector(Fixtures.batteryLevel))
        }
    }

    // MARK: Writes

    @Test("writes are refused unless enabled")
    func writesDisabledByDefault() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        await #expect(throws: BLEError.writesDisabled) {
            try await session.write(Data([1]), to: selector(Fixtures.uartRX))
        }
        #expect(await central.writes.isEmpty)
    }

    @Test("the allowlist limits which characteristics can be written")
    func allowlist() async throws {
        let session = await makeSession(
            SessionConfiguration(writePolicy: WritePolicy(isEnabled: true, allowlist: [Fixtures.uartRX])))
        _ = try await session.connect(meter.id)

        let receipt = try await session.write(Data([0x01, 0x02]), to: selector(Fixtures.uartRX))
        #expect(receipt.mode == .withResponse)
        #expect(receipt.byteCount == 2)

        await #expect(throws: BLEError.writeNotAllowed(Fixtures.batteryLevel)) {
            try await session.write(Data([1]), to: selector(Fixtures.batteryLevel))
        }
        #expect(await central.writes.map(\.value) == [Data([0x01, 0x02])])
    }

    @Test("a frame allowlist admits exactly its frames and nothing reaches the radio otherwise")
    func frameAllowlist() async throws {
        let poll = Data([0xAB, 0xCD, 0x03, 0x5E, 0x01, 0xD9])
        let clearLog = Data([0xAB, 0xCD, 0x03, 0x63, 0x01, 0xDE])
        let session = await makeSession(
            SessionConfiguration(writePolicy: WritePolicy(isEnabled: true, allowedValues: [Fixtures.uartRX: [poll]])))
        _ = try await session.connect(meter.id)

        _ = try await session.write(poll, to: selector(Fixtures.uartRX))
        await #expect(throws: BLEError.writeValueNotAllowed(Fixtures.uartRX, value: clearLog, allowed: [poll])) {
            try await session.write(clearLog, to: selector(Fixtures.uartRX))
        }
        // A value allowlist alone locks every other characteristic.
        await #expect(throws: BLEError.writeNotAllowed(Fixtures.batteryLevel)) {
            try await session.write(Data([1]), to: selector(Fixtures.batteryLevel))
        }
        #expect(await central.writes.map(\.value) == [poll])
    }

    @Test("writes larger than the negotiated MTU allows are refused")
    func payloadTooLarge() async throws {
        let session = await makeSession(SessionConfiguration(writePolicy: WritePolicy(isEnabled: true)))
        _ = try await session.connect(meter.id)
        await #expect(throws: BLEError.payloadTooLarge(size: 21, maximum: 20)) {
            try await session.write(Data(count: 21), to: selector(Fixtures.uartRX), mode: .withoutResponse)
        }
    }

    @Test("the CCCD cannot be written directly")
    func reservedDescriptor() async throws {
        let session = await makeSession(SessionConfiguration(writePolicy: WritePolicy(isEnabled: true)))
        _ = try await session.connect(meter.id)
        await #expect(throws: BLEError.reservedDescriptor(GATTDescriptor.clientCharacteristicConfiguration)) {
            try await session.writeDescriptor(
                Data([1, 0]), to: GATTDescriptor.clientCharacteristicConfiguration, of: selector(Fixtures.batteryLevel))
        }
    }

    // MARK: Notifications

    @Test("notifications are buffered and returned in arrival order across subscriptions")
    func notificationsInOrder() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        let battery = try await session.subscribe(selector(Fixtures.batteryLevel))
        let uart = try await session.subscribe(selector(Fixtures.uartTX))
        #expect(battery.state == .active)
        #expect(try await session.subscribe(selector(Fixtures.batteryLevel)).id == battery.id)

        let batteryAddress = battery.address
        let uartAddress = uart.address
        await central.notify(Data([1]), from: batteryAddress)
        await central.notify(Data([2]), from: uartAddress)
        await central.notify(Data([3]), from: batteryAddress)
        try await waitUntil { try await session.notifications(maxCount: 0).remaining == 3 }

        let all = try await session.notifications(maxCount: 10)
        #expect(all.notifications.map(\.value) == [Data([1]), Data([2]), Data([3])])
        #expect(all.notifications.map(\.subscription) == [battery.id, uart.id, battery.id])
        #expect(all.remaining == 0)
    }

    @Test("a full buffer drops the oldest values and says how many")
    func overflow() async throws {
        let session = await makeSession(SessionConfiguration(limits: SessionLimits(notificationBufferCapacity: 2)))
        _ = try await session.connect(meter.id)
        let subscription = try await session.subscribe(selector(Fixtures.uartTX))
        for byte in UInt8(1)...5 {
            await central.notify(Data([byte]), from: subscription.address)
        }
        try await waitUntil { await session.status().subscriptions.first?.receivedCount == 5 }

        let batch = try await session.notifications(from: subscription.id, maxCount: 10)
        #expect(batch.notifications.map(\.value) == [Data([4]), Data([5])])
        #expect(batch.dropped == 3)
        #expect(try await session.notifications(from: subscription.id, maxCount: 10).dropped == 0)
    }

    @Test("waiting returns as soon as a notification arrives")
    func waitWakesUp() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        let subscription = try await session.subscribe(selector(Fixtures.uartTX))
        let central = central
        let address = subscription.address

        async let batch = session.notifications(from: subscription.id, maxCount: 10, waitUpTo: .seconds(30))
        try await Task.sleep(for: .milliseconds(50))
        await central.notify(Data([0x42]), from: address)
        let result = try await batch
        #expect(result.notifications.map(\.value) == [Data([0x42])])
    }

    @Test("waiting gives up after wait_ms")
    func waitTimesOut() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        let subscription = try await session.subscribe(selector(Fixtures.uartTX))
        let batch = try await session.notifications(from: subscription.id, maxCount: 10, waitUpTo: .milliseconds(50))
        #expect(batch.notifications.isEmpty)
        guard case .nothingArrived(let waited) = batch.wait else {
            Issue.record("expected an expired wait, got \(batch.wait)")
            return
        }
        #expect(waited >= .milliseconds(50))
    }

    @Test("a wait with no open subscription returns at once and says why")
    func waitSkipped() async throws {
        let session = await makeSession()
        let clock = ContinuousClock()
        let start = clock.now
        let batch = try await session.notifications(maxCount: 10, waitUpTo: .seconds(30))
        #expect(clock.now - start < .seconds(5))
        #expect(batch.wait == .skipped)
        // Without a requested wait there is nothing to explain.
        #expect(try await session.notifications(maxCount: 10).wait == .none)
    }

    @Test("a lost link closes subscriptions but keeps their buffered values")
    func disconnectKeepsBuffer() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        let subscription = try await session.subscribe(selector(Fixtures.uartTX))
        await central.notify(Data([7]), from: subscription.address)
        try await waitUntil { try await session.notifications(maxCount: 0).remaining == 1 }

        await central.dropLink(to: meter.id)
        var events = session.events.makeAsyncIterator()
        guard case .peripheralDisconnected(let id, let name, _) = await events.next() else {
            Issue.record("expected a disconnect event")
            return
        }
        #expect(id == meter.id)
        #expect(name == "BB-500 Meter")
        #expect(await session.connectionSnapshots().isEmpty)

        let batch = try await session.notifications(from: subscription.id, maxCount: 10, waitUpTo: .seconds(5))
        #expect(batch.notifications.map(\.value) == [Data([7])])
        guard case .closed = batch.subscriptions.first?.state else {
            Issue.record("subscription should be closed")
            return
        }
        // Closed and drained: the subscription is gone now.
        await #expect(throws: BLEError.subscriptionNotFound(subscription.id)) {
            try await session.notifications(from: subscription.id, maxCount: 1)
        }
    }

    @Test("unsubscribing turns notifications off on the device")
    func unsubscribe() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        let subscription = try await session.subscribe(selector(Fixtures.uartTX))
        #expect(await central.notifying.contains(subscription.address))
        let final = try await session.unsubscribe(subscription.id)
        #expect(final.state == .closed(reason: "unsubscribed"))
        #expect(await central.notifying.isEmpty)
    }

    @Test("disconnecting reports whether there was a link, and needs none")
    func disconnectWithoutLink() async throws {
        let session = await makeSession()
        #expect(await session.disconnect(meter.id) == false)
        #expect(await central.disconnectRequests.isEmpty)
        _ = try await session.connect(meter.id)
        #expect(await session.disconnect(meter.id))
        #expect(await session.disconnect(meter.id) == false)
        #expect(await central.disconnectRequests == [meter.id])
    }

    // MARK: Adapter

    @Test("status waits for a backend that has not reported the adapter state yet")
    func statusSettles() async {
        let central = FakeCentral(state: .unknown)
        let session = BLESession(central: central)
        let report = Task {
            try await Task.sleep(for: .milliseconds(50))
            await central.changeState(to: .poweredOn)
        }
        #expect(await session.status().adapterState == .poweredOn)
        _ = await report.result
    }

    @Test("status keeps waiting for a slow adapter past the permission-prompt wait")
    func statusWaitsForSlowAdapter() async {
        // Measured on a relaunch after an update: the adapter needed more than 2 s to report.
        let central = FakeCentral(state: .unknown)
        let timeouts = SessionTimeouts(poweredOn: .seconds(5), permissionPrompt: .milliseconds(20))
        let session = BLESession(central: central, configuration: SessionConfiguration(timeouts: timeouts))
        let report = Task {
            try await Task.sleep(for: .milliseconds(300))
            await central.changeState(to: .poweredOn)
        }
        #expect(await session.status().adapterState == .poweredOn)
        _ = await report.result
    }

    @Test("a pending permission prompt is reported as such, after a short wait")
    func statusAwaitingPermission() async {
        let central = FakeCentral(state: .awaitingPermission)
        let timeouts = SessionTimeouts(poweredOn: .seconds(30), permissionPrompt: .milliseconds(50))
        let session = BLESession(central: central, configuration: SessionConfiguration(timeouts: timeouts))
        let clock = ContinuousClock()
        let start = clock.now
        let status = await session.status()
        #expect(status.adapterState == .awaitingPermission)
        #expect(clock.now - start < .seconds(5))
        #expect(BLEError.bluetoothUnavailable(.awaitingPermission).hint?.contains("accept the prompt") == true)
        #expect(BLEError.bluetoothUnavailable(.unknown).hint?.contains("permission") == false)
    }

    @Test("status gives up on an adapter that stays silent")
    func statusStaysUnknown() async {
        let central = FakeCentral(state: .unknown)
        let timeouts = SessionTimeouts(poweredOn: .milliseconds(50))
        let session = BLESession(central: central, configuration: SessionConfiguration(timeouts: timeouts))
        #expect(await session.status().adapterState == .unknown)
    }

    @Test("the adapter powering off drops every connection")
    func powerOff() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        await central.changeState(to: .poweredOff)
        try await waitUntil { await session.connectionSnapshots().isEmpty }
        #expect(await session.status().linkLosses.map(\.reason) == ["Bluetooth became powered_off"])
    }

    @Test("a dropped link is reported with its reason and time until the peripheral reconnects")
    func linkLoss() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        let dropped = Date.now
        await central.dropLink(to: meter.id, reason: "connection timeout")
        try await waitUntil { await session.connectionSnapshots().isEmpty }

        do {
            _ = try await session.read(selector(Fixtures.batteryLevel))
            Issue.record("the read should fail")
        } catch {
            guard case .linkLost(let id, let reason, let at) = error else {
                Issue.record("expected linkLost, got \(error)")
                return
            }
            #expect(id == meter.id)
            #expect(reason == "connection timeout")
            #expect(at >= dropped)
            #expect(error.code == "disconnected")
            #expect(error.message.contains("connection timeout"))
        }
        let loss = try #require(await session.status().linkLosses.first)
        #expect(loss.name == "BB-500 Meter")

        _ = try await session.connect(meter.id)
        _ = try await session.read(selector(Fixtures.batteryLevel))
        #expect(await session.status().linkLosses.isEmpty)
    }

    @Test("a disconnect the agent asked for is not a link loss")
    func requestedDisconnect() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        await session.disconnect(meter.id)
        await #expect(throws: BLEError.notConnected(meter.id)) {
            try await session.read(self.selector(Fixtures.batteryLevel))
        }
        #expect(await session.status().linkLosses.isEmpty)
    }

    @Test("shutdown disconnects everything and refuses new work")
    func shutdown() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        await session.shutdown()
        #expect(await central.disconnectRequests == [meter.id])
        await #expect(throws: BLEError.cancelled) {
            try await session.connect(meter.id)
        }
    }
}

/// Polls `condition` until it holds; fails the test after `timeout`.
func waitUntil(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
}
