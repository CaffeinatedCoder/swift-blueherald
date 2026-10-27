import BLEMCPCore
import MCP

enum ConnectionTools {
    private static let peripheral = CommonArguments.peripheral

    static let status = ToolDefinition(
        name: "ble_status",
        title: "Bluetooth status",
        description: """
            Reports the Bluetooth adapter state, whether writes are enabled, the server limits, and \
            every active scan, connection and subscription. Call it first when something fails.
            """,
        effect: .readOnly,
        idempotent: true
    ) { _, session in
        StatusReport(await session.status())
    }

    static let connect: ToolDefinition = {
        let discover = Argument.optional(
            "discover", as: Bool.self, "Also discover services, characteristics and descriptors.", default: true)
        return ToolDefinition(
            name: "ble_connect",
            title: "Connect to a device",
            description: """
                Connects to a peripheral found by ble_scan and, by default, discovers its full attribute \
                table. Returns the services, characteristics with their properties, and the largest \
                value one write can carry. Connecting to an already connected peripheral returns its \
                current state.
                """,
            arguments: [peripheral, discover],
            effect: .stateful,
            idempotent: true
        ) { arguments, session in
            ConnectionReport(try await session.connect(try arguments[peripheral], discover: try arguments[discover]))
        }
    }()

    static let disconnect = ToolDefinition(
        name: "ble_disconnect",
        title: "Disconnect from a device",
        description: "Disconnects a peripheral. Its subscriptions close; their buffered notifications stay readable.",
        arguments: [peripheral],
        effect: .stateful
    ) { arguments, session in
        let id = try arguments[peripheral]
        try await session.disconnect(id)
        return DisconnectReport(peripheralId: id.description, disconnected: true)
    }

    static let connections = ToolDefinition(
        name: "ble_connections",
        title: "List connections",
        description: "Lists connected peripherals with their subscriptions and write limits.",
        effect: .readOnly,
        idempotent: true
    ) { _, session in
        ConnectionsReport(connections: await session.connectionSnapshots().map { ConnectionReport($0, includeServices: false) })
    }

    static let discover: ToolDefinition = {
        let refresh = Argument.optional(
            "refresh", as: Bool.self, "Discover again instead of returning the cached table.", default: false)
        return ToolDefinition(
            name: "ble_discover",
            title: "Discover services",
            description: """
                Returns the attribute table of a connected peripheral: services, characteristics with \
                their properties (read, write, notify, ...) and descriptors. Well-known UUIDs carry a name.
                """,
            arguments: [peripheral, refresh],
            effect: .readOnly,
            idempotent: true
        ) { arguments, session in
            let id = try arguments[peripheral]
            let services = try await session.discoverServices(of: id, refresh: try arguments[refresh])
            return ServicesReport(peripheralId: id.description, services: services.map(ServiceSummary.init))
        }
    }()

    static let rssi = ToolDefinition(
        name: "ble_rssi",
        title: "Read signal strength",
        description: "Reads the current RSSI (dBm) of a connected peripheral.",
        arguments: [peripheral],
        effect: .readOnly,
        idempotent: true
    ) { arguments, session in
        let id = try arguments[peripheral]
        return RSSIReport(peripheralId: id.description, rssi: try await session.readRSSI(of: id))
    }
}

struct ConnectionsReport: Encodable {
    let connections: [ConnectionReport]
}
