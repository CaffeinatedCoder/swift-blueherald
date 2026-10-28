import BLEMCPCore
import BLEMCPTestSupport
import Foundation
import Testing

@Suite("Capture")
struct CaptureTests {
    let meter = Fixtures.meter()
    let central: FakeCentral
    let capture = RecordingCapture()

    init() {
        central = FakeCentral(devices: [meter])
    }

    func makeSession(writes: WritePolicy = WritePolicy(isEnabled: true)) async -> BLESession {
        let session = BLESession(central: central, configuration: SessionConfiguration(writePolicy: writes), capture: capture)
        await session.start()
        return session
    }

    func address(_ characteristic: BLEUUID, in service: BLEUUID = Fixtures.uartService) -> CharacteristicAddress {
        CharacteristicAddress(peripheral: meter.id, service: service, characteristic: characteristic)
    }

    func selector(_ characteristic: BLEUUID) -> CharacteristicSelector {
        CharacteristicSelector(peripheral: meter.id, service: nil, characteristic: characteristic)
    }

    @Test("a session records what crossed the air and why, in order")
    func recordsInOrder() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        let subscription = try await session.subscribe(selector(Fixtures.uartTX))
        await session.mark("select AC V", fields: ["select": .string("G"), "expect_mode": .integer(1)])
        _ = try await session.write(Data([0xAB, 0xCD]), to: selector(Fixtures.uartRX))
        let receivedAt = Date(timeIntervalSinceNow: -0.25)
        await central.notify(Data([0x01]), from: subscription.address, at: receivedAt)
        let capture = capture
        try await waitUntil { capture.events.count == 6 }
        _ = try await session.read(selector(Fixtures.batteryLevel))
        try await session.unsubscribe(subscription.id)
        await session.disconnect(meter.id)

        let rx = address(Fixtures.uartRX)
        let tx = address(Fixtures.uartTX)
        // Discovery read the 0x2901 names; the reads are bookkeeping, the table with the names is
        // what a replay needs.
        #expect(
            capture.kinds == [
                .connected(meter.id, name: "BB-500 Meter"),
                .discovered(meter.id, Self.describedServices),
                .notificationsEnabled(tx, .notify),
                .marker(note: "select AC V", fields: ["select": .string("G"), "expect_mode": .integer(1)]),
                .write(rx, Data([0xAB, 0xCD]), .withResponse),
                .notification(tx, Data([0x01])),
                .read(address(Fixtures.batteryLevel, in: Fixtures.batteryService), Data([87])),
                .notificationsDisabled(tx),
                .disconnected(meter.id, reason: "disconnected on request"),
            ])
        // A notification is stamped when it arrived, not when the session got to it.
        #expect(capture.events[5].time == receivedAt)
    }

    /// `Fixtures.services` the way discovery reports them: with the trimmed 0x2901 names.
    static let describedServices = Fixtures.services.map { service in
        GATTService(
            uuid: service.uuid, isPrimary: service.isPrimary,
            characteristics: service.characteristics.map { characteristic in
                let names = [Fixtures.batteryLevel: "Battery", Fixtures.uartRX: "Data In", Fixtures.uartTX: "Data Out"]
                return characteristic.with(userDescription: names[characteristic.uuid])
            })
    }

    @Test("connecting records what the scan saw of the device, and the table once per discovery")
    func advertisementAndTable() async throws {
        let session = await makeSession()
        _ = try await session.scan(duration: .milliseconds(50))
        _ = try await session.connect(meter.id)
        _ = try await session.connect(meter.id)
        _ = try await session.discoverServices(of: meter.id)

        let kinds = capture.kinds
        try #require(kinds.count == 3)
        guard case .advertisement(let advertised) = kinds[0] else {
            Issue.record("expected the advertisement first, got \(kinds[0])")
            return
        }
        #expect(advertised.id == meter.id)
        #expect(advertised.name == "BB-500 Meter")
        #expect(advertised.serviceUUIDs == [Fixtures.uartService])
        #expect(advertised.manufacturerData == Data([0x59, 0x00, 0x01]))
        // The second connect and the cached discovery found nothing new.
        #expect(Array(kinds.dropFirst()) == [.connected(meter.id, name: "BB-500 Meter"), .discovered(meter.id, Self.describedServices)])

        _ = try await session.discoverServices(of: meter.id, refresh: true)
        #expect(capture.kinds.last == .discovered(meter.id, Self.describedServices))
    }

    @Test("a failed write follows its tx row; a refused one never gets a row")
    func failedAndRefusedWrites() async throws {
        let session = await makeSession(writes: WritePolicy(isEnabled: true, denylist: [Fixtures.batteryLevel]))
        _ = try await session.connect(meter.id)
        await central.setWriteBehavior(.fail(.backendFailure("boom")))
        await #expect(throws: BLEError.backendFailure("boom")) {
            try await session.write(Data([0x01]), to: selector(Fixtures.uartRX))
        }
        await #expect(throws: BLEError.writeDenied(Fixtures.batteryLevel)) {
            try await session.write(Data([0x02]), to: selector(Fixtures.batteryLevel))
        }
        #expect(
            capture.kinds.dropFirst(2) == [
                .write(address(Fixtures.uartRX), Data([0x01]), .withResponse),
                .writeFailed(address(Fixtures.uartRX), descriptor: nil, .backendFailure("boom")),
            ])
    }

    @Test("a lost link and a shutdown are recorded with their reasons")
    func linkEnds() async throws {
        let session = await makeSession()
        _ = try await session.connect(meter.id)
        await central.dropLink(to: meter.id, reason: "connection timeout")
        let capture = capture
        try await waitUntil { capture.events.count == 3 }
        _ = try await session.connect(meter.id)
        await session.shutdown()
        #expect(
            capture.kinds == [
                .connected(meter.id, name: "BB-500 Meter"),
                .discovered(meter.id, Self.describedServices),
                .disconnected(meter.id, reason: "connection timeout"),
                .connected(meter.id, name: "BB-500 Meter"),
                .discovered(meter.id, Self.describedServices),
                .disconnected(meter.id, reason: "server shutting down"),
            ])
    }

    @Test("without a sink, marking is a no-op and status names no capture")
    func noSink() async {
        let session = BLESession(central: central)
        await session.mark("ignored")
        #expect(session.captureDestination == nil)
        #expect(await session.status().captureDestination == nil)
    }
}
