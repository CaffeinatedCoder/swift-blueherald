import BLEMCPCore
import BLEMCPServer
import BLEMCPTestSupport
import Foundation
import Testing

@Suite("JSONL capture file")
struct CaptureFileTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ble-mcp-tests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let peripheral = PeripheralID(UUID(uuidString: "9D290B5A-71BE-5F31-2DB0-81271E936393")!)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func lines(of path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func address(_ characteristic: BLEUUID, service: BLEUUID = BLEUUID(0xFF00)) -> CharacteristicAddress {
        CharacteristicAddress(peripheral: peripheral, service: service, characteristic: characteristic)
    }

    func at(_ seconds: Double, _ kind: CaptureEvent.Kind) -> CaptureEvent {
        CaptureEvent(time: start.addingTimeInterval(seconds), kind: kind)
    }

    @Test("rows come out the way swift-dragoman's fixtures are written")
    func format() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try JSONLCaptureFile(path: directory.path, startedAt: start)
        let uart = BLEUUID("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")!
        for event in [
            at(0.124, .connected(peripheral, name: "BB-500")),
            at(2.865, .notificationsEnabled(address(BLEUUID(0xFF02)), .notify)),
            at(2.865, .write(address(BLEUUID(0xFF01)), Data([0xAB, 0xCD, 0x03, 0xFD, 0x02, 0x78]), .withResponse)),
            at(3.09, .notification(address(BLEUUID(0xFF02)), Data([0xAB, 0xCD, 0x04, 0xFF, 0x00, 0x02, 0x7B]))),
            at(
                9.328,
                .marker(note: "select AC V", fields: ["select": .string("G"), "expect_mode": .integer(1), "hex": .string("dropped")])),
            at(10, .read(address(uart, service: Fixtures.uartService), Data())),
            at(11.5, .writeFailed(address(BLEUUID(0xFF01)), descriptor: nil, .disconnected(peripheral, reason: nil))),
            at(12, .marker(note: "quote \" and\nnewline", fields: ["ok": .bool(true), "ratio": .number(0.5), "marker": .bool(false)])),
            at(61, .disconnected(peripheral, reason: "server shutting down")),
        ] {
            capture.record(event)
        }
        capture.flush()

        #expect(capture.destination.hasPrefix(directory.path + "/ble-mcp-"))
        #expect(capture.destination.hasSuffix(".jsonl"))
        let rows = try lines(of: capture.destination)
        #expect(rows.first?.hasPrefix(#"{"t": 0.000, "dir": "info", "note": "capture started", "server": "ble-mcp "#) == true)
        #expect(
            Array(rows.dropFirst()) == [
                #"{"t": 0.124, "dir": "info", "note": "connected", "name": "BB-500", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393"}"#,
                #"{"t": 2.865, "dir": "info", "uuid": "ff02", "note": "notify enabled on ff02", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "service": "ff00"}"#,
                #"{"t": 2.865, "dir": "tx", "uuid": "ff01", "hex": "abcd03fd0278", "mode": "with_response", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "service": "ff00"}"#,
                #"{"t": 3.090, "dir": "rx", "uuid": "ff02", "hex": "abcd04ff00027b", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "service": "ff00"}"#,
                #"{"t": 9.328, "dir": "info", "note": "select AC V", "expect_mode": 1, "marker": true, "select": "G"}"#,
                #"{"t": 10.000, "dir": "info", "uuid": "6e400003-b5a3-f393-e0a9-e50e24dcca9e", "hex": "", "note": "read", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "service": "6e400001-b5a3-f393-e0a9-e50e24dcca9e"}"#,
                #"{"t": 11.500, "dir": "info", "uuid": "ff01", "note": "write failed: Peripheral 9D290B5A-71BE-5F31-2DB0-81271E936393 disconnected.", "code": "disconnected", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "service": "ff00"}"#,
                #"{"t": 12.000, "dir": "info", "note": "quote \" and\nnewline", "marker": true, "ok": true, "ratio": 0.5}"#,
                #"{"t": 61.000, "dir": "info", "note": "disconnected", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "reason": "server shutting down"}"#,
            ])
        // Every row is JSON on its own, with `t` as a number, which is all a fixture loader needs.
        for row in rows {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])
            #expect(object["t"] is Double)
        }
    }

    @Test("the advertisement and the attribute table get nested rows that replays read and CaptureLog skips")
    func nestedRows() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try JSONLCaptureFile(path: directory.path, startedAt: start)
        var advertised = DiscoveredPeripheral(
            Advertisement(
                peripheral: peripheral, name: "BB-500", rssi: -50, isConnectable: true, serviceUUIDs: [BLEUUID(0xFFF0)],
                manufacturerData: Data([0x59, 0x00]), serviceData: [BLEUUID(0xFE95): Data([0x01])]))
        advertised.merge(Advertisement(peripheral: peripheral, rssi: -48))
        capture.record(at(0.1, .advertisement(advertised)))
        capture.record(
            at(
                0.2,
                .discovered(
                    peripheral,
                    [
                        GATTService(
                            uuid: BLEUUID(0xFFF0),
                            characteristics: [
                                GATTCharacteristic(
                                    uuid: BLEUUID(0xFF01), properties: [.write, .writeWithoutResponse],
                                    descriptors: [GATTDescriptor(uuid: BLEUUID(0x2901))], userDescription: "Data \"in\""),
                                GATTCharacteristic(uuid: BLEUUID(0xFF02), properties: .notify),
                            ])
                    ])))
        capture.flush()
        let rows = try lines(of: capture.destination).dropFirst()
        #expect(
            Array(rows) == [
                #"{"t": 0.100, "dir": "info", "note": "advertisement", "advertised_services": ["fff0"], "connectable": true, "manufacturer": "5900", "name": "BB-500", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "rssi": -48, "service_data": {"fe95": "01"}}"#,
                #"{"t": 0.200, "dir": "info", "note": "gatt", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "services": [{"uuid": "fff0", "primary": true, "characteristics": [{"uuid": "ff01", "properties": ["write_without_response", "write"], "descriptors": ["2901"], "description": "Data \"in\""}, {"uuid": "ff02", "properties": ["notify"], "descriptors": []}]}]}"#,
            ])
        for row in rows {
            #expect(try JSONSerialization.jsonObject(with: Data(row.utf8)) is [String: Any])
        }
    }

    @Test("a file is appended to, and each run starts with its own info row")
    func appends() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("probe.jsonl").path
        try "{\"t\": 0.5, \"dir\": \"info\", \"note\": \"earlier run\"}\n".write(toFile: path, atomically: true, encoding: .utf8)
        let capture = try JSONLCaptureFile(path: path, startedAt: start)
        capture.record(at(1, .notification(address(BLEUUID(0xFF02)), Data([0x01]))))
        capture.flush()
        #expect(capture.destination == path)
        let rows = try lines(of: path)
        #expect(rows.count == 3)
        #expect(rows[0].contains("earlier run"))
        #expect(rows[1].contains("capture started"))
        #expect(
            rows[2]
                == #"{"t": 1.000, "dir": "rx", "uuid": "ff02", "hex": "01", "peripheral": "9D290B5A-71BE-5F31-2DB0-81271E936393", "service": "ff00"}"#
        )
    }

    @Test("two runs started in the same second get separate files")
    func separateFiles() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try JSONLCaptureFile(path: directory.path, startedAt: start)
        let second = try JSONLCaptureFile(path: directory.path, startedAt: start)
        #expect(first.destination != second.destination)
        #expect(second.destination.hasSuffix("-2.jsonl"))
    }

    @Test("a path that cannot be opened fails with the path and the reason")
    func unopenable() {
        let path = directory.appendingPathComponent("missing/probe.jsonl").path
        #expect {
            _ = try JSONLCaptureFile(path: path)
        } throws: { error in
            (error as? CaptureFileError)?.description == "Cannot open the capture file \(path): No such file or directory."
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
