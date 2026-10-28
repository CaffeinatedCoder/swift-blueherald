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
        try await waitUntil { capture.events.count == 5 }
        _ = try await session.read(selector(Fixtures.batteryLevel))
        try await session.unsubscribe(subscription.id)
        await session.disconnect(meter.id)

        let rx = address(Fixtures.uartRX)
        let tx = address(Fixtures.uartTX)
        // Discovery read the 0x2901 names; that is bookkeeping, not part of the capture.
        #expect(
            capture.kinds == [
                .connected(meter.id, name: "BB-500 Meter"),
                .notificationsEnabled(tx, .notify),
                .marker(note: "select AC V", fields: ["select": .string("G"), "expect_mode": .integer(1)]),
                .write(rx, Data([0xAB, 0xCD]), .withResponse),
                .notification(tx, Data([0x01])),
                .read(address(Fixtures.batteryLevel, in: Fixtures.batteryService), Data([87])),
                .notificationsDisabled(tx),
                .disconnected(meter.id, reason: "disconnected on request"),
            ])
        // A notification is stamped when it arrived, not when the session got to it.
        #expect(capture.events[4].time == receivedAt)
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
            capture.kinds.dropFirst() == [
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
        try await waitUntil { capture.events.count == 2 }
        _ = try await session.connect(meter.id)
        await session.shutdown()
        #expect(
            capture.kinds == [
                .connected(meter.id, name: "BB-500 Meter"),
                .disconnected(meter.id, reason: "connection timeout"),
                .connected(meter.id, name: "BB-500 Meter"),
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
