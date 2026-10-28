import BLEMCPCore
import BLEMCPReplay
import BLEMCPServer
import BLEMCPTestSupport
import Foundation
import Testing

@Suite("Record, replay, diff", .timeLimit(.minutes(1)))
struct RoundTripTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ble-mcp-roundtrip-\(UUID().uuidString)")
    let meter = Fixtures.meter()

    var rx: CharacteristicSelector { CharacteristicSelector(peripheral: meter.id, characteristic: Fixtures.uartRX) }
    var tx: CharacteristicSelector { CharacteristicSelector(peripheral: meter.id, characteristic: Fixtures.uartTX) }
    var battery: CharacteristicSelector { CharacteristicSelector(peripheral: meter.id, characteristic: Fixtures.batteryLevel) }

    /// What an agent does in both runs: find the meter, read, and run two exchanges.
    func experiment(on central: some BLECentral, capturingTo path: String) async throws -> [Data?] {
        let capture = try JSONLCaptureFile(path: path)
        let session = BLESession(
            central: central, configuration: SessionConfiguration(writePolicy: WritePolicy(isEnabled: true)), capture: capture)
        await session.start()
        let scan = try await session.scan(filter: ScanFilter(nameContains: "BB-500"), duration: .seconds(1), stopAfter: 1)
        #expect(scan.peripherals.map(\.id) == [meter.id])
        _ = try await session.connect(meter.id)
        _ = try await session.read(battery)
        var replies: [Data?] = []
        for frame in [Data([0x01]), Data([0x02])] {
            replies.append(try await session.transact(frame, to: rx, replyOn: tx, timeout: .seconds(2)).reply?.value)
        }
        await session.shutdown()
        capture.flush()
        return replies
    }

    @Test("a replayed session against its own capture records the same traffic, attribute table and all")
    func roundTrip() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.jsonl").path
        let replayed = directory.appendingPathComponent("replayed.jsonl").path

        let device = FakeCentral(devices: [meter, Fixtures.beacon()])
        let tx = CharacteristicAddress(peripheral: meter.id, service: Fixtures.uartService, characteristic: Fixtures.uartTX)
        await device.setResponder(delay: .milliseconds(20)) { _, frame in [(tx, Data([0xA0]) + frame)] }
        let recorded = try await experiment(on: device, capturingTo: original)
        #expect(recorded == [Data([0xA0, 0x01]), Data([0xA0, 0x02])])

        let recording = try CaptureRecording(contentsOf: original)
        let replay = ReplayCentral(recording, options: ReplayCentral.Options(speed: 0))
        // Only the meter was connected, so the beacon is not in the capture.
        let device0 = try #require(replay.script.devices.only)
        #expect(!device0.isInferred)
        #expect(device0.name == "BB-500 Meter")
        #expect(device0.manufacturerData == Data([0x59, 0x00, 0x01]))
        #expect(device0.advertisedServices == [Fixtures.uartService])
        // The recorded table keeps its services, properties and 0x2901 names.
        #expect(device0.services.map(\.uuid) == Fixtures.services.map(\.uuid))
        #expect(device0.services.last?.characteristics.map(\.userDescription) == ["Data In", "Data Out"])
        #expect(device0.services.last?.characteristics.first?.properties == [.write, .writeWithoutResponse])

        let replayedReplies = try await experiment(on: replay, capturingTo: replayed)
        #expect(replayedReplies == recorded)
        let diff = CaptureDiff(recording, try CaptureRecording(contentsOf: replayed))
        #expect(diff.isIdentical, "\(diff.summary(leftName: "original", rightName: "replayed"))")
        #expect(diff.left.count == 5)
        #expect(await replay.report()?.divergences.isEmpty == true)
    }
}

@Suite("Capture diff")
struct CaptureDiffTests {
    func recording(_ text: String) throws -> CaptureRecording {
        try CaptureRecording(jsonl: text)
    }

    @Test("timing, notes and info rows do not count")
    func ignoresTiming() throws {
        let left = try recording(
            """
            {"t": 0, "dir": "info", "note": "capture started"}
            {"t": 1, "dir": "tx", "uuid": "ff01", "hex": "01", "note": "auth"}
            {"t": 1.2, "dir": "rx", "uuid": "ff02", "hex": "02"}
            """)
        let right = try recording(
            """
            {"t": 5, "dir": "tx", "uuid": "FF01", "hex": "01", "mode": "with_response"}
            {"t": 5, "dir": "info", "note": "select AC V", "select": "G"}
            {"t": 9, "dir": "rx", "uuid": "0000ff02-0000-1000-8000-00805f9b34fb", "hex": "02"}
            """)
        let diff = CaptureDiff(left, right)
        #expect(diff.isIdentical)
        #expect(diff.summary(leftName: "a", rightName: "b").hasSuffix("Identical: 2 entries in the same order."))
    }

    @Test("changes come out in capture order with their line numbers")
    func changes() throws {
        let left = try recording(
            """
            {"t": 1, "dir": "tx", "uuid": "ff01", "hex": "01"}
            {"t": 2, "dir": "rx", "uuid": "ff02", "hex": "aa"}
            {"t": 3, "dir": "info", "uuid": "2a19", "hex": "57", "note": "read"}
            """)
        let right = try recording(
            """
            {"t": 1, "dir": "tx", "uuid": "ff01", "hex": "01"}
            {"t": 2, "dir": "rx", "uuid": "ff02", "hex": "bb"}
            {"t": 3, "dir": "info", "uuid": "2a19", "hex": "57", "note": "read"}
            {"t": 4, "dir": "rx", "uuid": "ff02", "hex": "cc"}
            """)
        let diff = CaptureDiff(left, right)
        let entry = { (line: Int, hex: String) in
            CaptureDiff.Located(entry: CaptureDiff.Entry(kind: .rx, characteristic: BLEUUID(0xFF02), value: Hex.decode(hex)!), line: line)
        }
        #expect(diff.changes == [.removed(entry(2, "aa")), .inserted(entry(2, "bb")), .inserted(entry(4, "cc"))])
        #expect(
            diff.summary(leftName: "a", rightName: "b", limit: 2) == """
                - a: 1 tx, 1 rx, 1 read
                + b: 1 tx, 2 rx, 1 read
                1 only on the left, 2 only on the right:
                - line 2: rx   ff02 aa
                + line 2: rx   ff02 bb
                … and 1 more.
                """)
        #expect(CaptureDiff(left, right, kinds: [.tx, .read]).isIdentical)
    }
}
