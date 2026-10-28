import BLEMCPCore
@testable import BLEMCPServer
import Foundation
import Logging
import MCP
import Testing

@Suite("Tool arguments")
struct ArgumentTests {
    static let duration = Argument.integer("duration_ms", "test", in: 100...60_000, default: 5_000)
    static let uuids = Argument.optional("service_uuids", as: [BLEUUID].self, "test")
    static let peripheral = Argument.required("peripheral_id", as: PeripheralID.self, "test")
    static let declared: [any ArgumentDeclaration] = [duration, uuids, peripheral]

    func arguments(_ values: [String: Value]) throws(ToolError) -> ToolArguments {
        try ToolArguments(values, declared: Self.declared)
    }

    @Test("integers arrive as ints, integral doubles or numeric strings", arguments: [Value.int(2_500), .double(2_500), .string("2500")])
    func lenientIntegers(value: Value) throws {
        #expect(try arguments(["duration_ms": value])[Self.duration] == 2_500)
    }

    @Test("fractional and out-of-range integers are rejected", arguments: [Value.double(2_500.5), .int(99), .string("lots"), .double(.infinity)])
    func strictIntegers(value: Value) throws {
        #expect(throws: ToolError.self) {
            try arguments(["duration_ms": value])[Self.duration]
        }
    }

    @Test("absent and null fall back to the default")
    func defaults() throws {
        #expect(try arguments([:])[Self.duration] == 5_000)
        #expect(try arguments(["duration_ms": .null])[Self.duration] == 5_000)
    }

    @Test("UUID lists accept arrays, single values and comma-separated strings")
    func uuidLists() throws {
        let expected = [BLEUUID(0x180F), BLEUUID(0x180A)]
        #expect(try arguments(["service_uuids": ["180F", "180A"]])[Self.uuids] == expected)
        #expect(try arguments(["service_uuids": "180F, 0x180a"])[Self.uuids] == expected)
        #expect(try arguments(["service_uuids": "180F"])[Self.uuids] == [BLEUUID(0x180F)])
    }

    @Test("missing required arguments are named")
    func missingRequired() throws {
        do {
            _ = try arguments([:])[Self.peripheral]
            Issue.record("expected an error")
        } catch {
            guard case .invalidArguments(let message) = error else { throw error }
            #expect(message == "Missing required argument 'peripheral_id'.")
        }
    }

    @Test("unknown arguments are rejected with the valid names")
    func unknownArguments() {
        do {
            _ = try arguments(["timeout": 5])
            Issue.record("expected an error")
        } catch {
            guard case .invalidArguments(let message) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(message == "Unknown argument 'timeout'. Valid arguments: duration_ms, service_uuids, peripheral_id.")
        }
    }

    @Test("every built-in tool has a closed object schema whose required names exist")
    func schemas() throws {
        for definition in BLEMCPServer.builtInTools {
            let schema = try #require(definition.tool.inputSchema.objectValue, "\(definition.name)")
            #expect(schema["type"] == "object")
            #expect(schema["additionalProperties"] == false)
            let properties = try #require(schema["properties"]?.objectValue)
            for required in schema["required"]?.arrayValue ?? [] {
                #expect(properties[try #require(required.stringValue)] != nil, "\(definition.name)")
            }
            #expect(definition.name.hasPrefix("ble_"))
        }
        #expect(Set(BLEMCPServer.builtInTools.map(\.name)).count == BLEMCPServer.builtInTools.count)
    }
}

@Suite("Server configuration")
struct ServerConfigurationTests {
    @Test("an empty environment gives safe defaults")
    func defaults() throws {
        let configuration = try ServerConfiguration(environment: [:])
        #expect(configuration.session == SessionConfiguration())
        #expect(!configuration.session.writePolicy.isEnabled)
        #expect(configuration.logLevel == .warning)
        #expect(configuration.disclaimResponsibility)
    }

    @Test("every variable is read")
    func parsesEverything() throws {
        let configuration = try ServerConfiguration(environment: [
            "BLE_MCP_ALLOW_WRITES": "yes",
            "BLE_MCP_WRITE_ALLOWLIST": "2a19, 6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
            "BLE_MCP_MAX_CONNECTIONS": "2",
            "BLE_MCP_MAX_SUBSCRIPTIONS": "8",
            "BLE_MCP_MAX_SCANS": "1",
            "BLE_MCP_NOTIFICATION_BUFFER": "64",
            "BLE_MCP_CONNECT_TIMEOUT_MS": "3000",
            "BLE_MCP_OPERATION_TIMEOUT_MS": "1500",
            "BLE_MCP_LOG_LEVEL": "DEBUG",
            "BLE_MCP_OWN_PERMISSION": "0",
            "BLE_MCP_CAPTURE": "~/captures",
        ])
        #expect(!configuration.disclaimResponsibility)
        #expect(configuration.capturePath == "~/captures")
        let session = configuration.session
        #expect(session.writePolicy == WritePolicy(isEnabled: true, allowlist: [BLEUUID(0x2A19), BLEUUID("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")!]))
        #expect(session.limits == SessionLimits(maxConnections: 2, maxSubscriptions: 8, maxScans: 1, notificationBufferCapacity: 64))
        #expect(session.timeouts.connect == .milliseconds(3_000))
        #expect(session.timeouts.operation == .milliseconds(1_500))
        #expect(configuration.logLevel == .debug)
    }

    @Test("frame allowlists merge the variable and the file; the denylist is read")
    func frames() throws {
        let file = """
            # BB-500: harmless commands only
            ff01:abcd03fd0278   # auth
            FF01: ab cd 03 5e 01 d9

            """
        let configuration = try ServerConfiguration(
            environment: [
                "BLE_MCP_WRITE_VALUE_ALLOWLIST": "ff01:abcd035e01d9, 0xFF01:0xab 0xcd",
                "BLE_MCP_WRITE_VALUE_ALLOWLIST_FILE": "/frames.txt",
                "BLE_MCP_WRITE_DENYLIST": "ff03,fff1",
            ],
            readFile: { path in
                #expect(path == "/frames.txt")
                return file
            })
        let policy = configuration.session.writePolicy
        #expect(
            policy.allowedValues == [
                BLEUUID(0xFF01): [
                    Data([0xAB, 0xCD, 0x03, 0x5E, 0x01, 0xD9]), Data([0xAB, 0xCD]), Data([0xAB, 0xCD, 0x03, 0xFD, 0x02, 0x78]),
                ]
            ])
        #expect(policy.denylist == [BLEUUID(0xFF03), BLEUUID(0xFFF1)])
    }

    @Test("an unreadable frame file is a configuration error")
    func unreadableFrameFile() {
        struct Missing: Error {}
        do {
            _ = try ServerConfiguration(
                environment: ["BLE_MCP_WRITE_VALUE_ALLOWLIST_FILE": "/nope"], readFile: { _ in throw Missing() })
            Issue.record("expected an error")
        } catch {
            #expect(error.variable == "BLE_MCP_WRITE_VALUE_ALLOWLIST_FILE")
        }
    }

    @Test(
        "invalid values fail with the variable name",
        arguments: [
            ("BLE_MCP_ALLOW_WRITES", "maybe"),
            ("BLE_MCP_WRITE_ALLOWLIST", "2a19,nope"),
            ("BLE_MCP_WRITE_VALUE_ALLOWLIST", "ff01"),
            ("BLE_MCP_WRITE_VALUE_ALLOWLIST", "ff01:abc"),
            ("BLE_MCP_WRITE_VALUE_ALLOWLIST", "ff01:"),
            ("BLE_MCP_WRITE_DENYLIST", "ff0g"),
            ("BLE_MCP_MAX_CONNECTIONS", "0"),
            ("BLE_MCP_OPERATION_TIMEOUT_MS", "fast"),
            ("BLE_MCP_LOG_LEVEL", "loud"),
        ])
    func rejects(variable: String, value: String) {
        do {
            _ = try ServerConfiguration(environment: [variable: value])
            Issue.record("expected \(variable)=\(value) to be rejected")
        } catch {
            #expect(error.variable == variable)
            #expect(error.value == value)
        }
    }
}
