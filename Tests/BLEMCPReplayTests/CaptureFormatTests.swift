import BLEMCPCore
import BLEMCPReplay
import BLEMCPServer
import BLEMCPTestSupport
import Foundation
import Testing

/// Captures written by `JSONLCaptureFile` and read back by the replay and the diff, including the
/// cases a capture meets outside the happy path: several devices, shared UUIDs, appended runs,
/// cut-off files, markers and Windows line endings.
@Suite("Capture format", .timeLimit(.minutes(1)))
struct CaptureFormatTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ble-mcp-format-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let peripheral = PeripheralID(UUID(uuidString: "9D290B5A-71BE-5F31-2DB0-81271E936393")!)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    func address(_ characteristic: BLEUUID, service: BLEUUID = BLEUUID(0xFF00)) -> CharacteristicAddress {
        CharacteristicAddress(peripheral: peripheral, service: service, characteristic: characteristic)
    }

    func at(_ seconds: Double, _ kind: CaptureEvent.Kind, from origin: Date? = nil) -> CaptureEvent {
        CaptureEvent(time: (origin ?? start).addingTimeInterval(seconds), kind: kind)
    }

    func capture(_ path: String, startedAt origin: Date? = nil, _ events: [CaptureEvent]) throws {
        let file = try JSONLCaptureFile(path: path, startedAt: origin ?? start)
        events.forEach(file.record)
        file.flush()
    }

    func append(_ bytes: Data, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.close()
    }

    @Test("a capture of two connected meters replays each meter's exchange on that meter")
    func twoDevices() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = path("two.jsonl")
        let a = Fixtures.meter()
        let b = Fixtures.meter()
        let device = FakeCentral(devices: [a, b])
        await device.setResponder(delay: .milliseconds(20)) { address, frame in
            [
                (
                    CharacteristicAddress(peripheral: address.peripheral, service: Fixtures.uartService, characteristic: Fixtures.uartTX),
                    Data([address.peripheral == a.id ? 0xA0 : 0xB0]) + frame
                )
            ]
        }
        // Both are connected; A is connected first, so for the old format B was the device "last mentioned".
        func exchange(on central: some BLECentral, capture: (any CaptureSink)?) async throws -> [Data?] {
            let session = BLESession(
                central: central, configuration: SessionConfiguration(writePolicy: WritePolicy(isEnabled: true)), capture: capture)
            await session.start()
            _ = try await session.connect(a.id)
            _ = try await session.connect(b.id)
            var replies: [Data?] = []
            for (id, frame) in [(a.id, UInt8(1)), (b.id, 2), (a.id, 3)] {
                replies.append(
                    try await session.transact(
                        Data([frame]),
                        to: CharacteristicSelector(peripheral: id, characteristic: Fixtures.uartRX),
                        replyOn: CharacteristicSelector(peripheral: id, characteristic: Fixtures.uartTX),
                        timeout: .seconds(1)
                    ).reply?.value)
            }
            await session.shutdown()
            return replies
        }
        let capture = try JSONLCaptureFile(path: path)
        let recorded = try await exchange(on: device, capture: capture)
        capture.flush()
        #expect(recorded == [Data([0xA0, 1]), Data([0xB0, 2]), Data([0xA0, 3])])

        let replay = ReplayCentral(try CaptureRecording(contentsOf: path), options: ReplayCentral.Options(speed: 0))
        #expect(replay.script.devices.allSatisfy { !$0.services.isEmpty })
        #expect(try await exchange(on: replay, capture: nil) == recorded)
        #expect(await replay.report()?.divergences.map(\.message) == [])
    }

    @Test("same-UUID characteristics in two services are told apart by the diff and the replay")
    func sameUUIDTwoServices() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (left, right) = (path("left.jsonl"), path("right.jsonl"))
        try capture(left, [at(1, .write(address(BLEUUID(0xFF01), service: BLEUUID(0xFF00)), Data([0x01]), .withResponse))])
        try capture(right, [at(1, .write(address(BLEUUID(0xFF01), service: BLEUUID(0xFE00)), Data([0x01]), .withResponse))])
        let diff = CaptureDiff(try CaptureRecording(contentsOf: left), try CaptureRecording(contentsOf: right))
        #expect(!diff.isIdentical)
        #expect(diff.summary(leftName: "l", rightName: "r").contains("- line 2: tx   ff00/ff01 01"))

        // An older capture without services still compares by characteristic alone.
        let old = try CaptureRecording(jsonl: #"{"t": 1.000, "dir": "tx", "uuid": "ff01", "hex": "01"}"#)
        #expect(CaptureDiff(old, try CaptureRecording(contentsOf: right)).isIdentical)

        // Two services with the same UUIDs: the reply recorded for one is not played for the other.
        let replies = path("replies.jsonl")
        try capture(
            replies,
            [
                at(0.1, .connected(peripheral, name: nil)),
                at(0.2, .notificationsEnabled(address(BLEUUID(0xFF02), service: BLEUUID(0xFF00)), .notify)),
                at(0.3, .notificationsEnabled(address(BLEUUID(0xFF02), service: BLEUUID(0xFE00)), .notify)),
                at(1, .write(address(BLEUUID(0xFF01), service: BLEUUID(0xFF00)), Data([0x01]), .withResponse)),
                at(1.1, .notification(address(BLEUUID(0xFF02), service: BLEUUID(0xFF00)), Data([0xAA]))),
            ])
        let script = ReplayScript(try CaptureRecording(contentsOf: replies))
        #expect(script.devices.only?.services.map(\.uuid) == [BLEUUID(0xFF00), BLEUUID(0xFE00)])
        #expect(script.triggers.last?.service == BLEUUID(0xFF00))
        #expect(script.triggers.last?.replies.only?.reply == .notification(BLEUUID(0xFF02), Data([0xAA]), service: BLEUUID(0xFF00)))
    }

    @Test("runs appended to one file keep their replies, and their delays, to themselves")
    func appendedRuns() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = path("appended.jsonl")
        // Run 1 is killed after a write that got no reply: no disconnected row.
        try capture(
            path,
            [
                at(0.1, .connected(peripheral, name: "BB-500")),
                at(5, .write(address(BLEUUID(0xFF01)), Data([0x01]), .withResponse)),
            ])
        // Run 2, an hour later, starts mid-stream with a notification.
        let later = start.addingTimeInterval(3600)
        try capture(
            path, startedAt: later,
            [
                at(0.1, .connected(peripheral, name: "BB-500"), from: later),
                at(0.5, .notification(address(BLEUUID(0xFF02)), Data([0x02])), from: later),
            ])
        let script = ReplayScript(try CaptureRecording(contentsOf: path))
        #expect(script.triggers.map(\.request) == [.write(BLEUUID(0xFF01), Data([0x01])), .subscribe(BLEUUID(0xFF02))])
        #expect(script.triggers.first?.replies.isEmpty == true, "run 2's notification became run 1's reply")
        #expect(script.triggers.flatMap(\.replies).map(\.delay) == [0])
    }

    @Test("a capture cut off mid-row loads every complete row, and says what it left out")
    func truncatedLastLine() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = path("cut.jsonl")
        try capture(
            path,
            [
                at(1, .write(address(BLEUUID(0xFF01)), Data([0x01]), .withResponse)),
                at(2, .notification(address(BLEUUID(0xFF02)), Data([0x02]))),
            ])
        try append(Data(#"{"t": 3.000, "dir": "rx", "uu"#.utf8), to: path)
        let recording = try CaptureRecording(contentsOf: path)
        #expect(recording.rows.count == 3)
        #expect(recording.warnings.count == 1)
        #expect(recording.warnings.first?.hasPrefix("Line 4 was left out") == true)
    }

    @Test("a capture cut inside a UTF-8 sequence loads every complete row")
    func truncatedMidUTF8() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = path("utf8.jsonl")
        try capture(path, [at(1, .connected(peripheral, name: "Wärme"))])
        try append(Data(#"{"t": 2.000, "dir": "info", "note": "connected", "name": "W"#.utf8) + Data([0xC3]), to: path)
        let recording = try CaptureRecording(contentsOf: path)
        #expect(recording.rows.count == 2)
        #expect(recording.rows.last?.name == "Wärme")
        #expect(recording.warnings.count == 1)
    }

    @Test("a broken row followed by more rows is still an error, with its line")
    func brokenMiddleLine() {
        #expect(throws: CaptureReadError.self) {
            try CaptureRecording(jsonl: #"{"t": 0}"# + "\n" + #"{"t": "# + "\n" + #"{"t": 1}"# + "\n")
        }
        let error = #expect(throws: CaptureReadError.self) { try CaptureRecording(jsonl: "{}\nnot json\n{}\n") }
        #expect(error?.line == 2)
    }

    @Test("CRLF line endings load as separate rows")
    func crlf() throws {
        let text =
            #"{"t": 0.000, "dir": "tx", "uuid": "ff01", "hex": "01"}"# + "\r\n" + #"{"t": 0.100, "dir": "rx", "uuid": "ff02", "hex": "02"}"#
            + "\r\n"
        let recording = try CaptureRecording(jsonl: text)
        #expect(recording.rows.map(\.meaning) == [.write(BLEUUID(0xFF01), Data([1]), nil), .notification(BLEUUID(0xFF02), Data([2]))])
        #expect(recording.warnings.isEmpty)
    }

    @Test("a marker named like an event, or like the start of a run, is only a marker")
    func markersAreNotEvents() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = path("marker.jsonl")
        try capture(
            path,
            [
                at(0.1, .connected(peripheral, name: "BB-500")),
                at(1, .write(address(BLEUUID(0xFF01)), Data([0x01]), .withResponse)),
                at(1.1, .marker(note: "disconnected", fields: ["reason": .string("battery pulled for step 3")])),
                at(1.2, .marker(note: "capture started", fields: [:])),
                at(1.3, .marker(note: "notify enabled on ff03", fields: [:])),
                at(2, .notification(address(BLEUUID(0xFF02)), Data([0x02]))),
            ])
        let recording = try CaptureRecording(contentsOf: path)
        #expect(recording.rows.filter(\.isMarker).map(\.meaning) == [.other, .other, .other])
        let script = ReplayScript(recording)
        #expect(script.triggers.map(\.request) == [.write(BLEUUID(0xFF01), Data([0x01]))])
        #expect(script.triggers.only?.replies.map(\.reply) == [.notification(BLEUUID(0xFF02), Data([0x02]), service: BLEUUID(0xFF00))])
    }

    @Test("a device scans under the name it advertised and connects under the name it gave")
    func advertisedName() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = path("names.jsonl")
        try capture(
            path,
            [
                at(0.1, .advertisement(DiscoveredPeripheral(Advertisement(peripheral: peripheral, name: "BLEMCP-Test", rssi: -50)))),
                at(0.2, .connected(peripheral, name: "iPhone")),
            ])
        let central = ReplayCentral(try CaptureRecording(contentsOf: path), options: ReplayCentral.Options(speed: 0))
        let session = BLESession(central: central)
        await session.start()
        let scan = try await session.scan(filter: ScanFilter(nameContains: "BLEMCP"), duration: .milliseconds(100))
        #expect(scan.peripherals.map(\.id) == [peripheral])
        #expect(try await session.connect(peripheral, discover: false).name == "iPhone")
    }
}
