import BlueHeraldCore
import BlueHeraldReplay
import Foundation
import Testing

/// The first 40 rows of a BB-500 function sweep recorded by swift-dragoman's probe script: no
/// `gatt` or `advertisement` rows, `notify enabled on ff02` only in the note, no write modes.
enum BB500 {
    static let peripheral = PeripheralID("9D290B5A-71BE-5F31-2DB0-81271E936393")!
    static let request = BLEUUID(0xFF01)
    static let reply = BLEUUID(0xFF02)
    static let auth = Data([0xAB, 0xCD, 0x03, 0xFD, 0x02, 0x78])
    static let ack = Data([0xAB, 0xCD, 0x04, 0xFF, 0x00, 0x02, 0x7B])
    static let serialRequest = Data([0xAB, 0xCD, 0x03, 0x00, 0x01, 0x7B])
    static let liveRequest = Data([0xAB, 0xCD, 0x03, 0x5E, 0x01, 0xD9])
    /// The clock frame each live reply ends with; its seconds byte ticks during the recording.
    static let clocks = [
        "abcd0a07140f03110d3b25022d", "abcd0a07140f03110d3b25022d", "abcd0a07140f03110d3b25022d", "abcd0a07140f03110d3b26022e",
    ]

    static func recording() throws -> CaptureRecording {
        let url = try #require(Bundle.module.url(forResource: "bb500-sweep-start", withExtension: "jsonl", subdirectory: "Fixtures"))
        return try CaptureRecording(contentsOf: url.path)
    }

    static func selector(_ characteristic: BLEUUID) -> CharacteristicSelector {
        CharacteristicSelector(peripheral: peripheral, characteristic: characteristic)
    }
}

/// A session over a replay with writes on, connected to `peripheral`.
func replaySession(
    _ recording: CaptureRecording,
    peripheral: PeripheralID = BB500.peripheral,
    options: ReplayCentral.Options = ReplayCentral.Options(speed: 0),
    capture: (any CaptureSink)? = nil
) async throws -> (BLESession, ReplayCentral) {
    let central = ReplayCentral(recording, options: options)
    let session = BLESession(
        central: central, configuration: SessionConfiguration(writePolicy: WritePolicy(isEnabled: true)), capture: capture)
    await session.start()
    _ = try await session.connect(peripheral)
    return (session, central)
}

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

@Suite("Capture loading")
struct CaptureLoadingTests {
    @Test("swift-dragoman fixtures load, with the subscription read from the note")
    func dragomanFixture() throws {
        let recording = try BB500.recording()
        #expect(recording.rows.count == 40)
        #expect(recording.rows[0].meaning == .device(BB500.peripheral))
        #expect(recording.rows[1].meaning == .notificationsEnabled(BB500.reply, .notify))
        #expect(recording.rows[2].meaning == .write(BB500.request, BB500.auth, nil))
        #expect(recording.rows[3].meaning == .notification(BB500.reply, BB500.ack))
        #expect(recording.rows[3].time == 3.09)
        // `"select": null` is a marker field, not a problem.
        #expect(recording.rows[10].note == "baseline")
    }

    @Test("a field of an unexpected type is dropped, a line that is not an object fails with its number")
    func leniency() throws {
        let recording = try CaptureRecording(
            jsonl: #"""
                {"t": "soon", "dir": "tx", "uuid": "ff01", "hex": "0102", "rssi": "strong", "mode": 7}

                {"t": 1.5, "dir": "sideways", "note": "read", "uuid": "2a19", "hex": "57"}
                """#)
        #expect(recording.rows.map(\.line) == [1, 3])
        #expect(recording.rows[0].meaning == .write(BLEUUID(0xFF01), Data([1, 2]), nil))
        #expect(recording.rows[0].time == 0)
        #expect(recording.rows[1].meaning == .read(BLEUUID(0x2A19), Data([0x57])))

        let error = #expect(throws: CaptureReadError.self) {
            try CaptureRecording(jsonl: "{\"t\": 1}\n[1, 2]\n", source: "test")
        }
        #expect(error?.description == "Cannot read the capture test at line 2: not a JSON object.")
        #expect(throws: CaptureReadError.self) {
            try CaptureRecording(contentsOf: "/nonexistent/capture.jsonl")
        }
    }
}

@Suite("Replay script")
struct ReplayScriptTests {
    @Test("a capture without a gatt row gets an attribute table inferred from its rows")
    func inference() throws {
        let script = ReplayScript(try BB500.recording())
        let device = try #require(script.devices.only)
        #expect(device.id == BB500.peripheral)
        #expect(device.isInferred)
        #expect(
            device.services == [
                GATTService(
                    uuid: ReplayScript.inferredService,
                    characteristics: [
                        GATTCharacteristic(
                            uuid: BB500.reply, properties: .notify,
                            descriptors: [GATTDescriptor(uuid: GATTDescriptor.clientCharacteristicConfiguration)]),
                        // No mode was recorded, so both kinds of write are allowed.
                        GATTCharacteristic(uuid: BB500.request, properties: [.write, .writeWithoutResponse]),
                    ])
            ])
        let subscription = try #require(script.triggers.first)
        #expect(subscription.request == .subscribe(BB500.reply))
        #expect(subscription.line == 2)
        #expect(subscription.replies.isEmpty)
        let auth = script.triggers[1]
        #expect(auth.request == .write(BB500.request, BB500.auth))
        #expect(auth.replies.count == 1)
        #expect(auth.replies[0].reply == .notification(BB500.reply, BB500.ack))
        #expect(abs(auth.replies[0].delay - 0.225) < 0.0001)
        // The serial request is answered by an ACK and the serial number in two parts.
        #expect(script.triggers[2].replies.count == 3)
        #expect(script.triggers.count == 14)
    }

    @Test("a capture that names no device is played as one inferred peripheral")
    func anonymous() throws {
        let script = ReplayScript(
            try CaptureRecording(
                jsonl: #"{"t": 1, "dir": "tx", "uuid": "ff01", "hex": "01"}"# + "\n"
                    + #"{"t": 1.2, "dir": "rx", "uuid": "ff02", "hex": "02"}"#))
        #expect(script.devices.map(\.id) == [ReplayScript.inferredPeripheral])
        #expect(script.triggers.only?.replies.only?.reply == .notification(BLEUUID(0xFF02), Data([2])))
    }

    @Test("notifications before any request are played when the agent subscribes")
    func leadingNotifications() throws {
        let script = ReplayScript(
            try CaptureRecording(
                jsonl: #"{"t": 1, "dir": "rx", "uuid": "ff02", "hex": "01"}"# + "\n"
                    + #"{"t": 2, "dir": "rx", "uuid": "ff02", "hex": "02"}"#))
        let trigger = try #require(script.triggers.only)
        #expect(trigger.request == .subscribe(BLEUUID(0xFF02)))
        #expect(trigger.replies.map(\.delay) == [0, 1])
    }
}

@Suite("Replay", .timeLimit(.minutes(1)))
struct ReplayCentralTests {
    @Test("the BB-500 answers its auth frame the way it did, through ble_transact's path")
    func transact() async throws {
        let (session, _) = try await replaySession(try BB500.recording())
        let exchange = try await session.transact(
            BB500.auth, to: BB500.selector(BB500.request), replyOn: BB500.selector(BB500.reply), timeout: .seconds(2))
        #expect(exchange.reply?.value == BB500.ack)
        #expect(exchange.write.mode == .withResponse)

        // The capture authenticated once; a second auth gets the same answer.
        let again = try await session.transact(
            BB500.auth, to: BB500.selector(BB500.request), replyOn: BB500.selector(BB500.reply), timeout: .seconds(2))
        #expect(again.reply?.value == BB500.ack)
    }

    @Test("a repeated request gets each recorded reply in turn, then the last one again")
    func repeatedRequests() async throws {
        let (session, central) = try await replaySession(try BB500.recording())
        let subscription = try await session.subscribe(BB500.selector(BB500.reply))
        var clocks: [String] = []
        for _ in 0..<5 {
            _ = try await session.write(BB500.liveRequest, to: BB500.selector(BB500.request), mode: .withoutResponse)
            var replies: [Data] = []
            try await waitUntil {
                replies += try await session.notifications(from: subscription.id, maxCount: 10).notifications.map(\.value)
                return replies.count >= 2
            }
            clocks.append(Hex.encode(replies[1]))
        }
        // The fixture holds seven live requests; the first four are compared.
        #expect(Array(clocks.prefix(4)) == BB500.clocks)
        let report = try #require(await central.report())
        #expect(report.kind == "replay")
        #expect(report.divergences.isEmpty)
        // The subscription and five live requests matched; auth and the serial request were skipped.
        #expect(report.matchedRequests == 6)
    }

    @Test("a frame the capture never sent is accepted without a reply and reported")
    func unknownWrite() async throws {
        let (session, central) = try await replaySession(try BB500.recording())
        let exchange = try await session.transact(
            Data([0x01]), to: BB500.selector(BB500.request), replyOn: BB500.selector(BB500.reply), timeout: .milliseconds(100))
        #expect(exchange.reply == nil)
        let report = try #require(await central.report())
        #expect(report.divergences.map(\.message) == ["No recorded write of 01 to FF01; the write was accepted without a reply."])
        let status = await session.status()
        #expect(status.backend == report)
    }

    @Test("strict replay fails a write the capture does not make next, and names the one it does")
    func strict() async throws {
        let (session, _) = try await replaySession(try BB500.recording(), options: ReplayCentral.Options(speed: 0, isStrict: true))
        _ = try await session.subscribe(BB500.selector(BB500.reply))
        await #expect(
            throws: BLEError.backendFailure(
                "Strict replay: write of abcd035e01d9 to FF01 is not what the capture does next; the next recorded write is write of abcd03fd0278 to FF01 (line 3)."
            )
        ) {
            try await session.write(BB500.liveRequest, to: BB500.selector(BB500.request))
        }
        let exchange = try await session.transact(
            BB500.auth, to: BB500.selector(BB500.request), replyOn: BB500.selector(BB500.reply), timeout: .seconds(2))
        #expect(exchange.reply?.value == BB500.ack)
    }

    @Test("replies keep their recorded delays, scaled by the speed")
    func pacing() async throws {
        let recording = try CaptureRecording(
            jsonl: """
                {"t": 0, "dir": "info", "note": "notify enabled on ff02"}
                {"t": 1, "dir": "tx", "uuid": "ff01", "hex": "01"}
                {"t": 1.4, "dir": "rx", "uuid": "ff02", "hex": "02"}
                """)
        let peripheral = ReplayScript.inferredPeripheral
        let selector = { (uuid: UInt16) in CharacteristicSelector(peripheral: peripheral, characteristic: BLEUUID(uuid)) }
        for (speed, least, most) in [(2.0, 150, 1_000), (0.0, 0, 150)] {
            let (session, _) = try await replaySession(recording, peripheral: peripheral, options: ReplayCentral.Options(speed: speed))
            let exchange = try await session.transact(Data([1]), to: selector(0xFF01), replyOn: selector(0xFF02), timeout: .seconds(2))
            let latency = try #require(exchange.latency)
            #expect(latency >= .milliseconds(least) && latency < .milliseconds(most), "speed \(speed): \(latency)")
        }
    }

    @Test("a read returns the latest value recorded up to the session's place in the capture")
    func readsFollowTheTimeline() async throws {
        let recording = try CaptureRecording(
            jsonl: """
                {"t": 0, "dir": "info", "uuid": "3333", "hex": "ffff", "note": "read"}
                {"t": 1, "dir": "tx", "uuid": "3333", "hex": "0102", "mode": "with_response"}
                {"t": 2, "dir": "info", "uuid": "3333", "hex": "0102", "note": "read"}
                """)
        let peripheral = ReplayScript.inferredPeripheral
        let target = CharacteristicSelector(peripheral: peripheral, characteristic: BLEUUID(0x3333))
        let (session, central) = try await replaySession(recording, peripheral: peripheral)
        #expect(try await session.read(target).value == Data([0xFF, 0xFF]))
        #expect(try await session.read(target).value == Data([0xFF, 0xFF]))
        _ = try await session.write(Data([0x01, 0x02]), to: target)
        #expect(try await session.read(target).value == Data([0x01, 0x02]))
        #expect(try await session.read(target).value == Data([0x01, 0x02]))
        #expect(await central.report()?.divergences.isEmpty == true)
    }

    @Test("subscribing starts a recorded stream; a recorded link loss drops the link again")
    func streamAndLinkLoss() async throws {
        let id = PeripheralID(UUID())
        let recording = try CaptureRecording(
            jsonl: """
                {"t": 0, "dir": "info", "note": "connected", "peripheral": "\(id)", "name": "Thermometer"}
                {"t": 1, "dir": "info", "uuid": "2a1c", "note": "indicate enabled on 2a1c"}
                {"t": 1.01, "dir": "rx", "uuid": "2a1c", "hex": "01"}
                {"t": 1.02, "dir": "rx", "uuid": "2a1c", "hex": "02"}
                {"t": 1.03, "dir": "info", "note": "disconnected", "peripheral": "\(id)", "reason": "connection timeout"}
                """)
        let (session, _) = try await replaySession(recording, peripheral: id, options: ReplayCentral.Options(speed: 1))
        let connection = try await session.connectionSnapshot(id)
        #expect(connection.name == "Thermometer")
        let subscription = try await session.subscribe(CharacteristicSelector(peripheral: id, characteristic: BLEUUID(0x2A1C)))
        #expect(subscription.mode == .indicate)
        try await waitUntil { await session.status().linkLosses.count == 1 }
        let batch = try await session.notifications(from: subscription.id, maxCount: 10)
        #expect(batch.notifications.map(\.value) == [Data([1]), Data([2])])
        #expect(await session.status().linkLosses.first?.reason == "connection timeout")
    }

    @Test("disconnecting cancels replies still on their way")
    func disconnectCancels() async throws {
        let recording = try CaptureRecording(
            jsonl: """
                {"t": 0, "dir": "info", "note": "notify enabled on ff02"}
                {"t": 0.3, "dir": "rx", "uuid": "ff02", "hex": "01"}
                """)
        let peripheral = ReplayScript.inferredPeripheral
        let (session, _) = try await replaySession(recording, peripheral: peripheral, options: ReplayCentral.Options(speed: 1))
        _ = try await session.subscribe(CharacteristicSelector(peripheral: peripheral, characteristic: BLEUUID(0xFF02)))
        await session.disconnect(peripheral)
        _ = try await session.connect(peripheral)
        let subscription = try await session.subscribe(CharacteristicSelector(peripheral: peripheral, characteristic: BLEUUID(0xFF02)))
        // The second subscription replays the stream from the start, so exactly one value arrives.
        let batch = try await session.notifications(from: subscription.id, maxCount: 10, waitUpTo: .milliseconds(600))
        #expect(batch.notifications.map(\.value) == [Data([1])])
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await session.notifications(from: subscription.id, maxCount: 10).notifications.isEmpty)
    }

    @Test("scans see the recorded devices; unknown peripherals stay unknown")
    func scanning() async throws {
        let central = ReplayCentral(try BB500.recording())
        let session = BLESession(central: central)
        await session.start()
        let scan = try await session.scan(duration: .milliseconds(50))
        #expect(scan.peripherals.map(\.id) == [BB500.peripheral])
        let stranger = PeripheralID(UUID())
        await #expect(throws: BLEError.unknownPeripheral(stranger)) {
            _ = try await session.connect(stranger)
        }
    }
}

extension Collection {
    /// The single element, or `nil` when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
