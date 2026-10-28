import BLEMCPCore
import BLEMCPServer
import BLEMCPTestSupport
import Foundation
import MCP
import Testing

/// Drives the server through a real MCP client over the SDK's in-memory transport, so these
/// tests cover the JSON-RPC handshake, schemas, argument decoding and result encoding together.
@Suite("MCP end to end")
struct EndToEndTests {
    let meter = Fixtures.meter()

    func connectedClient(
        writes: WritePolicy = .readOnly,
        capture: (any CaptureSink)? = nil
    ) async throws -> (Client, FakeCentral) {
        let central = FakeCentral(devices: [meter, Fixtures.beacon()])
        let session = BLESession(central: central, configuration: SessionConfiguration(writePolicy: writes), capture: capture)
        await session.start()
        let server = await BLEMCPServer(session: session).makeServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "tests", version: "1.0")
        _ = try await client.connect(transport: clientTransport)
        return (client, central)
    }

    /// Calls a tool and decodes the JSON text content into a dictionary.
    func call(_ client: Client, _ tool: String, _ arguments: [String: Value] = [:]) async throws -> (json: [String: Any], isError: Bool) {
        let (content, isError) = try await client.callTool(name: tool, arguments: arguments)
        guard case .text(let text, _, _) = try #require(content.first) else {
            Issue.record("expected text content")
            return ([:], true)
        }
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return (try #require(json), isError ?? false)
    }

    @Test("write tools are only listed when writes are enabled")
    func writeToolsHidden() async throws {
        let (readOnly, _) = try await connectedClient()
        let readOnlyNames = Set(try await readOnly.listTools().tools.map(\.name))
        #expect(readOnlyNames.count == 15)
        #expect(!readOnlyNames.contains("ble_write"))

        let (writable, _) = try await connectedClient(writes: WritePolicy(isEnabled: true))
        let tools = try await writable.listTools().tools
        #expect(tools.count == 17)
        let write = try #require(tools.first { $0.name == "ble_write" })
        #expect(write.annotations.destructiveHint == true)
        #expect(write.annotations.readOnlyHint == false)
    }

    @Test("status reports the adapter and the policy")
    func status() async throws {
        let (client, _) = try await connectedClient()
        let (json, isError) = try await call(client, "ble_status")
        #expect(!isError)
        #expect(json["adapter_state"] as? String == "powered_on")
        let policy = try #require(json["policy"] as? [String: Any])
        #expect(policy["writes_enabled"] as? Bool == false)
        let server = try #require(json["server"] as? [String: Any])
        #expect(server["started_at"] is String)
    }

    @Test("disconnecting without a link and waiting without a subscription explain themselves")
    func emptyHanded() async throws {
        let (client, _) = try await connectedClient()
        let (disconnect, disconnectError) = try await call(
            client, "ble_disconnect", ["peripheral_id": .string(meter.id.description)])
        #expect(!disconnectError)
        #expect(disconnect["was_connected"] as? Bool == false)

        let (batch, batchError) = try await call(client, "ble_notifications", ["wait_ms": 10_000])
        #expect(!batchError)
        let note = try #require(batch["note"] as? String)
        #expect(note.contains("ble_subscribe"))

        let (read, _) = try await call(
            client, "ble_read", ["peripheral_id": .string(meter.id.description), "characteristic_uuid": "2a19"])
        let error = try #require(read["error"] as? [String: Any])
        #expect(error["code"] as? String == "not_connected")
        #expect((error["hint"] as? String)?.contains("restart") == true)
    }

    @Test("scan, connect and read a value through MCP")
    func scanConnectRead() async throws {
        let (client, _) = try await connectedClient()

        let (scan, _) = try await call(client, "ble_scan", ["name": "bb-500", "duration_ms": 1_000, "stop_after": 1])
        let devices = try #require(scan["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        let peripheralID = try #require(devices.first?["peripheral_id"] as? String)
        #expect(peripheralID == meter.id.description)
        let manufacturer = try #require(devices.first?["manufacturer"] as? [String: Any])
        #expect(manufacturer["company"] as? String == "Nordic Semiconductor")

        let (connection, connectError) = try await call(client, "ble_connect", ["peripheral_id": .string(peripheralID)])
        #expect(!connectError)
        let services = try #require(connection["services"] as? [[String: Any]])
        #expect(services.compactMap { $0["name"] as? String } == ["Device Information", "Battery", "Nordic UART Service"])
        let uart = try #require(services.last?["characteristics"] as? [[String: Any]])
        #expect(uart.compactMap { $0["description"] as? String } == ["Data In", "Data Out"])

        let (battery, _) = try await call(
            client, "ble_read", ["peripheral_id": .string(peripheralID), "characteristic_uuid": "2a19"])
        let value = try #require(battery["value"] as? [String: Any])
        #expect(value["hex"] as? String == "57")
        // One byte is a number, not the text "W".
        #expect(value["utf8"] == nil)
        #expect(battery["characteristic_name"] as? String == "Battery Level")
        #expect(battery["characteristic_description"] as? String == "Battery")

        let (manufacturerName, _) = try await call(
            client, "ble_read", ["peripheral_id": .string(peripheralID), "characteristic_uuid": "0x2A29"])
        let text = try #require(manufacturerName["value"] as? [String: Any])
        #expect(text["utf8"] as? String == "Voltcraft")
    }

    @Test("domain errors come back as tool errors with a code and a hint")
    func toolErrors() async throws {
        let (client, _) = try await connectedClient()
        _ = try await call(client, "ble_connect", ["peripheral_id": .string(meter.id.description), "discover": false])

        let (json, isError) = try await call(
            client, "ble_read", ["peripheral_id": .string(meter.id.description), "characteristic_uuid": "2A00"])
        #expect(isError)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "characteristic_not_found")
        #expect(error["hint"] as? String == "Call ble_discover to list the attribute table.")
    }

    @Test("bad arguments come back as tool errors, unknown tools as protocol errors")
    func argumentErrors() async throws {
        let (client, _) = try await connectedClient()
        let (json, isError) = try await call(client, "ble_scan", ["duration_ms": 5])
        #expect(isError)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_arguments")
        #expect(error["message"] as? String == "Argument 'duration_ms' must be between 100 and 60000, got 5.")

        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(name: "ble_write", arguments: [:])
        }
    }

    @Test("the capture tool is offered only while capturing, and guards the format's own keys")
    func captureMark() async throws {
        let (plain, _) = try await connectedClient()
        #expect(!(try await plain.listTools().tools.map(\.name).contains("ble_capture_mark")))

        let capture = RecordingCapture()
        let (client, _) = try await connectedClient(capture: capture)
        #expect(try await client.listTools().tools.map(\.name).contains("ble_capture_mark"))
        let (status, _) = try await call(client, "ble_status")
        #expect(status["capture_path"] as? String == "memory")

        let (refused, refusedError) = try await call(
            client, "ble_capture_mark", ["note": "step", "fields": ["dir": "tx", "select": "G"]])
        #expect(refusedError)
        let error = try #require(refused["error"] as? [String: Any])
        #expect(error["message"] as? String == "Field 'dir' is reserved by the capture format; pick another name.")

        let (marked, markError) = try await call(
            client, "ble_capture_mark", ["note": "select AC V", "fields": ["select": "G", "expect_mode": 1, "skip": .null]])
        #expect(!markError)
        #expect(marked["marked"] as? Bool == true)
        #expect(capture.kinds == [.marker(note: "select AC V", fields: ["select": .string("G"), "expect_mode": .integer(1)])])
    }

    @Test("writes, subscriptions and notifications through MCP")
    func writeSubscribeNotify() async throws {
        let (client, central) = try await connectedClient(writes: WritePolicy(isEnabled: true))
        let id = Value.string(meter.id.description)
        _ = try await call(client, "ble_connect", ["peripheral_id": id])

        let (write, writeError) = try await call(
            client, "ble_write", ["peripheral_id": id, "characteristic_uuid": "6E400002-B5A3-F393-E0A9-E50E24DCCA9E", "value": "0x01 0x02"])
        #expect(!writeError)
        #expect(write["bytes_written"] as? Int == 2)
        #expect(await central.writes.map(\.value) == [Data([1, 2])])

        let (subscription, _) = try await call(
            client, "ble_subscribe", ["peripheral_id": id, "characteristic_uuid": "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"])
        let subscriptionID = try #require(subscription["subscription_id"] as? String)
        #expect(subscriptionID == "sub-1")
        #expect(subscription["characteristic_description"] as? String == "Data Out")

        let (empty, _) = try await call(client, "ble_notifications", ["wait_ms": 100])
        #expect((empty["notifications"] as? [Any])?.isEmpty == true)
        #expect((empty["note"] as? String)?.hasPrefix("Waited 1") == true)

        let address = CharacteristicAddress(peripheral: meter.id, service: Fixtures.uartService, characteristic: Fixtures.uartTX)
        let sender = Task {
            try await Task.sleep(for: .milliseconds(50))
            await central.notify(Data("hi".utf8), from: address)
        }
        let (batch, _) = try await call(
            client, "ble_notifications", ["subscription_id": .string(subscriptionID), "wait_ms": 5_000])
        try await sender.value
        let notifications = try #require(batch["notifications"] as? [[String: Any]])
        let value = try #require(notifications.first?["value"] as? [String: Any])
        #expect(value["hex"] as? String == "6869")
        #expect(value["utf8"] as? String == "hi")
        #expect(batch["note"] == nil)

        // A little-endian 36 padded with a NUL is not the text "$".
        await central.notify(Data([0x24, 0x00]), from: address)
        let (padded, _) = try await call(client, "ble_notifications", ["wait_ms": 5_000])
        let number = try #require((padded["notifications"] as? [[String: Any]])?.first?["value"] as? [String: Any])
        #expect(number["hex"] as? String == "2400")
        #expect(number["utf8"] == nil)
    }
}
