public import BLEMCPCore
import Foundation
public import Logging

/// Server settings read from `BLE_MCP_*` environment variables, which is how MCP clients pass
/// configuration to stdio servers. Parsing is total: an invalid value fails startup with a
/// message naming the variable instead of being silently replaced by a default.
public struct ServerConfiguration: Sendable, Equatable {
    public let session: SessionConfiguration
    public let logLevel: Logger.Level
    /// Relaunch as our own responsible process so macOS asks for Bluetooth access on behalf of
    /// ble-mcp rather than the launching app (macOS only).
    public let disclaimResponsibility: Bool

    public init(
        session: SessionConfiguration = SessionConfiguration(),
        logLevel: Logger.Level = .warning,
        disclaimResponsibility: Bool = true
    ) {
        self.session = session
        self.logLevel = logLevel
        self.disclaimResponsibility = disclaimResponsibility
    }

    public init(environment: [String: String]) throws(ConfigurationError) {
        let reader = EnvironmentReader(environment)
        let defaults = SessionConfiguration()
        session = SessionConfiguration(
            writePolicy: WritePolicy(
                isEnabled: try reader.bool("BLE_MCP_ALLOW_WRITES") ?? false,
                allowlist: Set(try reader.uuids("BLE_MCP_WRITE_ALLOWLIST"))),
            limits: SessionLimits(
                maxConnections: try reader.int("BLE_MCP_MAX_CONNECTIONS", in: 1...32) ?? defaults.limits.maxConnections,
                maxSubscriptions: try reader.int("BLE_MCP_MAX_SUBSCRIPTIONS", in: 1...512) ?? defaults.limits.maxSubscriptions,
                maxScans: try reader.int("BLE_MCP_MAX_SCANS", in: 1...16) ?? defaults.limits.maxScans,
                notificationBufferCapacity: try reader.int("BLE_MCP_NOTIFICATION_BUFFER", in: 1...1_000_000)
                    ?? defaults.limits.notificationBufferCapacity),
            timeouts: SessionTimeouts(
                poweredOn: defaults.timeouts.poweredOn,
                connect: try reader.milliseconds("BLE_MCP_CONNECT_TIMEOUT_MS") ?? defaults.timeouts.connect,
                discovery: defaults.timeouts.discovery,
                operation: try reader.milliseconds("BLE_MCP_OPERATION_TIMEOUT_MS") ?? defaults.timeouts.operation))
        logLevel = try reader.logLevel("BLE_MCP_LOG_LEVEL") ?? .warning
        disclaimResponsibility = try reader.bool("BLE_MCP_OWN_PERMISSION") ?? true
    }

    /// Every variable the server reads, for `--help`.
    public static let variables: [(name: String, meaning: String)] = [
        ("BLE_MCP_ALLOW_WRITES", "1/true/yes enables ble_write and ble_write_descriptor (default: off)"),
        ("BLE_MCP_WRITE_ALLOWLIST", "comma-separated characteristic UUIDs that may be written (default: all)"),
        ("BLE_MCP_MAX_CONNECTIONS", "simultaneous connections, 1-32 (default: 4)"),
        ("BLE_MCP_MAX_SUBSCRIPTIONS", "active notification subscriptions, 1-512 (default: 32)"),
        ("BLE_MCP_MAX_SCANS", "concurrent background scans, 1-16 (default: 4)"),
        ("BLE_MCP_NOTIFICATION_BUFFER", "notifications kept per subscription (default: 1024)"),
        ("BLE_MCP_CONNECT_TIMEOUT_MS", "connection timeout in ms, 100-120000 (default: 15000)"),
        ("BLE_MCP_OPERATION_TIMEOUT_MS", "read/write/subscribe timeout in ms, 100-120000 (default: 10000)"),
        ("BLE_MCP_LOG_LEVEL", "trace, debug, info, notice, warning, error or critical; logs go to stderr (default: warning)"),
        ("BLE_MCP_OWN_PERMISSION", "0 makes macOS attribute Bluetooth access to the launching app instead of ble-mcp (default: 1)"),
    ]
}

public struct ConfigurationError: Error, Equatable, CustomStringConvertible {
    public let variable: String
    public let value: String
    public let expected: String

    public var description: String {
        "Invalid \(variable)=\"\(value)\": expected \(expected)."
    }
}

private struct EnvironmentReader {
    let environment: [String: String]

    init(_ environment: [String: String]) {
        self.environment = environment
    }

    private func raw(_ name: String) -> String? {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    func bool(_ name: String) throws(ConfigurationError) -> Bool? {
        guard let value = raw(name) else { return nil }
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw ConfigurationError(variable: name, value: value, expected: "1, true, yes, on, 0, false, no or off")
        }
    }

    func int(_ name: String, in range: ClosedRange<Int>) throws(ConfigurationError) -> Int? {
        guard let value = raw(name) else { return nil }
        guard let int = Int(value), range.contains(int) else {
            throw ConfigurationError(variable: name, value: value, expected: "an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return int
    }

    func milliseconds(_ name: String) throws(ConfigurationError) -> Duration? {
        try int(name, in: 100...120_000).map { .milliseconds($0) }
    }

    func uuids(_ name: String) throws(ConfigurationError) -> [BLEUUID] {
        guard let value = raw(name) else { return [] }
        var uuids: [BLEUUID] = []
        for part in value.split(separator: ",") {
            guard let uuid = BLEUUID(part) else {
                throw ConfigurationError(variable: name, value: value, expected: "comma-separated Bluetooth UUIDs such as 2A19,FFE1")
            }
            uuids.append(uuid)
        }
        return uuids
    }

    func logLevel(_ name: String) throws(ConfigurationError) -> Logger.Level? {
        guard let value = raw(name) else { return nil }
        guard let level = Logger.Level(rawValue: value.lowercased()) else {
            throw ConfigurationError(
                variable: name, value: value,
                expected: Logger.Level.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return level
    }
}
