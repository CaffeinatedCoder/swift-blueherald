public import BLEMCPCore
import Foundation
public import Logging

/// Server settings read from `BLE_MCP_*` environment variables, which is how MCP clients pass
/// configuration to stdio servers. Parsing is total: an invalid value fails startup with a
/// message naming the variable instead of being silently replaced by a default.
public struct ServerConfiguration: Sendable, Equatable {
    public let session: SessionConfiguration
    public let logLevel: Logger.Level
    /// Where to record a JSONL capture: a directory (one new file per run) or a file to append to.
    public let capturePath: String?
    /// Relaunch as our own responsible process so macOS asks for Bluetooth access on behalf of
    /// ble-mcp rather than the launching app (macOS only).
    public let disclaimResponsibility: Bool
    /// Play a capture instead of using Bluetooth.
    public let replay: Replay?

    /// Where a replay comes from and how it plays.
    public struct Replay: Sendable, Equatable {
        public let path: String
        /// 1 is recorded pace, 0 sends replies without delay.
        public let speed: Double
        /// Fail writes the capture does not make next.
        public let isStrict: Bool

        public init(path: String, speed: Double = 1, isStrict: Bool = false) {
            self.path = path
            self.speed = speed
            self.isStrict = isStrict
        }
    }

    public init(
        session: SessionConfiguration = SessionConfiguration(),
        logLevel: Logger.Level = .warning,
        capturePath: String? = nil,
        disclaimResponsibility: Bool = true,
        replay: Replay? = nil
    ) {
        self.session = session
        self.logLevel = logLevel
        self.capturePath = capturePath
        self.disclaimResponsibility = disclaimResponsibility
        self.replay = replay
    }

    /// - Parameter readFile: Reads files named by `*_FILE` variables; defaults to UTF-8 file reads,
    ///   injectable for tests.
    public init(
        environment: [String: String],
        readFile: ((String) throws -> String)? = nil
    ) throws(ConfigurationError) {
        let readFile = readFile ?? { try String(contentsOfFile: $0, encoding: .utf8) }
        let reader = EnvironmentReader(environment)
        let defaults = SessionConfiguration()
        session = SessionConfiguration(
            writePolicy: WritePolicy(
                isEnabled: try reader.bool("BLE_MCP_ALLOW_WRITES") ?? false,
                allowlist: Set(try reader.uuids("BLE_MCP_WRITE_ALLOWLIST")),
                denylist: Set(try reader.uuids("BLE_MCP_WRITE_DENYLIST")),
                allowedValues: try reader.frames(
                    "BLE_MCP_WRITE_VALUE_ALLOWLIST", file: "BLE_MCP_WRITE_VALUE_ALLOWLIST_FILE", readFile: readFile)),
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
        capturePath = reader.string("BLE_MCP_CAPTURE")
        disclaimResponsibility = try reader.bool("BLE_MCP_OWN_PERMISSION") ?? true
        let speed = try reader.number("BLE_MCP_REPLAY_SPEED", in: 0...1_000)
        let isStrict = try reader.bool("BLE_MCP_REPLAY_STRICT")
        if let path = reader.string("BLE_MCP_REPLAY") {
            replay = Replay(path: path, speed: speed ?? 1, isStrict: isStrict ?? false)
        } else {
            replay = nil
        }
    }

    /// Every variable the server reads, for `--help`.
    public static let variables: [(name: String, meaning: String)] = [
        ("BLE_MCP_ALLOW_WRITES", "1/true/yes enables ble_write and ble_write_descriptor (default: off)"),
        ("BLE_MCP_WRITE_ALLOWLIST", "comma-separated characteristic UUIDs that may be written with any value"),
        (
            "BLE_MCP_WRITE_VALUE_ALLOWLIST",
            "comma-separated characteristic:hex frames, e.g. ff01:abcd035e01d9; listed characteristics accept only these frames"
        ),
        (
            "BLE_MCP_WRITE_VALUE_ALLOWLIST_FILE",
            "file with one characteristic:hex frame per line (# starts a comment); merged with the above"
        ),
        ("BLE_MCP_WRITE_DENYLIST", "comma-separated characteristic UUIDs that are never written, whatever the allowlists say"),
        ("BLE_MCP_MAX_CONNECTIONS", "simultaneous connections, 1-32 (default: 4)"),
        ("BLE_MCP_MAX_SUBSCRIPTIONS", "active notification subscriptions, 1-512 (default: 32)"),
        ("BLE_MCP_MAX_SCANS", "concurrent background scans, 1-16 (default: 4)"),
        ("BLE_MCP_NOTIFICATION_BUFFER", "notifications kept per subscription (default: 1024)"),
        ("BLE_MCP_CONNECT_TIMEOUT_MS", "connection timeout in ms, 100-120000 (default: 15000)"),
        ("BLE_MCP_OPERATION_TIMEOUT_MS", "read/write/subscribe timeout in ms, 100-120000 (default: 10000)"),
        ("BLE_MCP_CAPTURE", "record writes, notifications and reads as JSONL: a directory gets one file per run, a file is appended to"),
        ("BLE_MCP_LOG_LEVEL", "trace, debug, info, notice, warning, error or critical; logs go to stderr (default: warning)"),
        ("BLE_MCP_OWN_PERMISSION", "0 makes macOS attribute Bluetooth access to the launching app instead of ble-mcp (default: 1)"),
        ("BLE_MCP_REPLAY", "play this JSONL capture instead of using Bluetooth; writes still need BLE_MCP_ALLOW_WRITES"),
        ("BLE_MCP_REPLAY_SPEED", "replay pace: 1 as recorded, 2 twice as fast, 0 without delays (default: 1)"),
        ("BLE_MCP_REPLAY_STRICT", "1 fails writes the capture does not make next, instead of accepting them without a reply"),
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

    func string(_ name: String) -> String? {
        raw(name)
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

    func number(_ name: String, in range: ClosedRange<Double>) throws(ConfigurationError) -> Double? {
        guard let value = raw(name) else { return nil }
        guard let number = Double(value), range.contains(number) else {
            throw ConfigurationError(
                variable: name, value: value, expected: "a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
        }
        return number
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

    /// `characteristic:hex` pairs from a variable and from the file another variable names.
    func frames(
        _ name: String,
        file fileVariable: String,
        readFile: (String) throws -> String
    ) throws(ConfigurationError) -> [BLEUUID: Set<Data>] {
        var frames: [BLEUUID: Set<Data>] = [:]
        if let value = raw(name) {
            for entry in value.split(separator: ",") {
                let (uuid, frame) = try Self.frame(entry, variable: name, value: value)
                frames[uuid, default: []].insert(frame)
            }
        }
        if let path = raw(fileVariable) {
            let contents: String
            do {
                contents = try readFile(path)
            } catch {
                throw ConfigurationError(variable: fileVariable, value: path, expected: "a readable file (\(error.localizedDescription))")
            }
            for line in contents.split(whereSeparator: \.isNewline) {
                let entry = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
                guard !entry.isEmpty else { continue }
                let (uuid, frame) = try Self.frame(entry[...], variable: fileVariable, value: String(line))
                frames[uuid, default: []].insert(frame)
            }
        }
        return frames
    }

    private static func frame(_ entry: Substring, variable: String, value: String) throws(ConfigurationError) -> (BLEUUID, Data) {
        let parts = entry.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let uuid = BLEUUID(parts[0]), let frame = Hex.decode(parts[1]), !frame.isEmpty else {
            throw ConfigurationError(
                variable: variable, value: value, expected: "characteristic:hex frames such as ff01:abcd035e01d9")
        }
        return (uuid, frame)
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
