import BlueHeraldCore
import BlueHeraldTestSupport
import Foundation
import Testing

@Suite("Request and reply")
struct TransactTests {
    let meter = Fixtures.meter()
    let central: FakeCentral
    // The BB-500's known-device auth and its ACK.
    let auth = Data([0xAB, 0xCD, 0x03, 0xFD, 0x02, 0x78])
    let ack = Data([0xAB, 0xCD, 0x04, 0xFF, 0x00, 0x02, 0x7B])

    init() {
        central = FakeCentral(devices: [meter])
    }

    var rx: CharacteristicAddress {
        CharacteristicAddress(peripheral: meter.id, service: Fixtures.uartService, characteristic: Fixtures.uartRX)
    }
    var tx: CharacteristicAddress {
        CharacteristicAddress(peripheral: meter.id, service: Fixtures.uartService, characteristic: Fixtures.uartTX)
    }

    func selector(_ characteristic: BLEUUID) -> CharacteristicSelector {
        CharacteristicSelector(peripheral: meter.id, service: nil, characteristic: characteristic)
    }

    func makeSession(writes: WritePolicy = WritePolicy(isEnabled: true), capture: (any CaptureSink)? = nil) async throws -> BLESession {
        let session = BLESession(central: central, configuration: SessionConfiguration(writePolicy: writes), capture: capture)
        await session.start()
        _ = try await session.connect(meter.id)
        return session
    }

    func exchange(_ session: BLESession, prefix: Data = Data(), timeout: Duration = .seconds(5)) async throws(BLEError) -> Transaction {
        try await session.transact(
            auth, to: selector(Fixtures.uartRX), replyOn: selector(Fixtures.uartTX), prefix: prefix, timeout: timeout)
    }

    @Test("the reply comes back in the same call and is taken out of the buffer")
    func reply() async throws {
        let session = try await makeSession()
        let (tx, ack) = (tx, ack)
        await central.setResponder(delay: .milliseconds(30)) { _, _ in [(tx, ack)] }
        let result = try await exchange(session)
        #expect(result.reply?.value == ack)
        #expect(result.reply?.address == tx)
        #expect(try #require(result.latency) >= .milliseconds(25))
        #expect(result.unmatched == 0)
        #expect(result.subscription.state == .active)
        #expect(await central.writes.map(\.value) == [auth])
        #expect(try await session.notifications(maxCount: 10).notifications.isEmpty)
    }

    @Test("a reply sent before the write even returns is not missed")
    func immediateReply() async throws {
        let session = try await makeSession()
        let (tx, ack) = (tx, ack)
        await central.setResponder { _, _ in [(tx, ack)] }
        #expect(try await exchange(session).reply?.value == ack)
    }

    @Test("only a reply with the prefix counts; the others stay buffered")
    func prefix() async throws {
        let session = try await makeSession()
        let (tx, ack) = (tx, ack)
        await central.setResponder(delay: .milliseconds(10)) { _, _ in [(tx, Data([0x01, 0x02])), (tx, ack)] }
        let result = try await exchange(session, prefix: Data([0xAB, 0xCD, 0x04]))
        #expect(result.reply?.value == ack)
        #expect(result.unmatched == 1)
        #expect(try await session.notifications(maxCount: 10).notifications.map(\.value) == [Data([0x01, 0x02])])
    }

    @Test("a notification from before the write is not taken for the reply")
    func earlierNotification() async throws {
        let session = try await makeSession()
        let subscription = try await session.subscribe(selector(Fixtures.uartTX))
        let stale = Data([0xAB, 0xCD, 0x04, 0x00])
        await central.notify(stale, from: subscription.address)
        try await waitUntil { try await session.notifications(maxCount: 0).remaining == 1 }

        let (tx, ack) = (tx, ack)
        await central.setResponder(delay: .milliseconds(10)) { _, _ in [(tx, ack)] }
        let result = try await exchange(session, prefix: Data([0xAB, 0xCD, 0x04]))
        #expect(result.reply?.value == ack)
        #expect(result.subscription.id == subscription.id)
        #expect(try await session.notifications(maxCount: 10).notifications.map(\.value) == [stale])
    }

    @Test("no answer is not an error: the write happened and the reply is missing")
    func noReply() async throws {
        let session = try await makeSession()
        let result = try await exchange(session, timeout: .milliseconds(50))
        #expect(result.reply == nil)
        #expect(result.latency == nil)
        #expect(await central.writes.count == 1)
    }

    @Test("a refused frame neither subscribes nor writes")
    func refused() async throws {
        let session = try await makeSession(writes: WritePolicy(isEnabled: true, allowedValues: [Fixtures.uartRX: [Data([0x00])]]))
        await #expect(throws: BLEError.writeValueNotAllowed(Fixtures.uartRX, value: auth, allowed: [Data([0x00])])) {
            try await exchange(session)
        }
        #expect(await central.notifying.isEmpty)
        #expect(await central.writes.isEmpty)
    }

    @Test("a link lost while waiting is reported as such, not as silence")
    func linkLostWhileWaiting() async throws {
        let session = try await makeSession()
        let (central, id) = (central, meter.id)
        let drop = Task {
            try await Task.sleep(for: .milliseconds(50))
            await central.dropLink(to: id, reason: "connection timeout")
        }
        do {
            _ = try await exchange(session)
            Issue.record("expected the exchange to fail")
        } catch {
            guard case .linkLost(_, let reason, _) = error else {
                Issue.record("expected linkLost, got \(error)")
                return
            }
            #expect(reason == "connection timeout")
        }
        _ = await drop.result
    }

    @Test("the capture holds the request before its reply")
    func captured() async throws {
        let capture = RecordingCapture()
        let session = try await makeSession(capture: capture)
        let (tx, ack) = (tx, ack)
        await central.setResponder { _, _ in [(tx, ack)] }
        _ = try await exchange(session)
        #expect(Array(capture.kinds.suffix(2)) == [.write(rx, auth, .withResponse), .notification(tx, ack)])
    }
}
