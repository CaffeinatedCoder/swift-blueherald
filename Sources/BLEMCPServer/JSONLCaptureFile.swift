#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public import BLEMCPCore
import Dispatch
public import Foundation
public import Logging
import Synchronization

/// A `CaptureSink` that writes JSON lines in the format swift-dragoman's `CaptureLog` loads as a
/// test fixture: `{"t": seconds, "dir": "tx"|"rx"|"info", "uuid": "ff01", "hex": "abcd", "note": …}`,
/// where `t` counts from the start of the capture and marker fields ride on `info` rows.
///
/// Each row is a single `write(2)` to a file opened for appending, so rows land in the order
/// they were recorded and everything recorded before a crash is already on disk. Formatting and
/// I/O run on a serial queue, off the session's executor.
public final class JSONLCaptureFile: CaptureSink {
    public let destination: String
    private let descriptor: Int32
    private let start: Date
    private let queue = DispatchQueue(label: "ble-mcp.capture", qos: .utility)
    private let logger: Logger
    private let hasFailed = Atomic(false)

    /// Opens a capture and records a first `info` row that says when and by what it started.
    ///
    /// - Parameter path: An existing directory gets a new file per run, named after the start
    ///   time. Any other path names a file that is created, or appended to if it exists.
    public init(path: String, startedAt start: Date = .now, logger: Logger = Logger(label: "ble-mcp")) throws(CaptureFileError) {
        let path = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            (descriptor, destination) = try Self.createFile(in: path, startedAt: start)
        } else {
            descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw CaptureFileError(path: path, errno: errno) }
            destination = path
        }
        self.start = start
        self.logger = logger
        let line = CaptureLine(startedAt: start)
        queue.async { [self] in
            append(line.text)
        }
    }

    deinit {
        close(descriptor)
    }

    public func record(_ event: CaptureEvent) {
        queue.async { [self] in
            append(CaptureLine(event, since: start).text)
        }
    }

    /// Returns once every event recorded so far is in the file.
    public func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        guard !hasFailed.load(ordering: .relaxed) else { return }
        var bytes = Array(line.utf8)
        bytes.append(UInt8(ascii: "\n"))
        let failure: Int32? = bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                } else if errno != EINTR {
                    return errno
                }
            }
            return nil
        }
        if let failure {
            // A full disk must not take the server down; the capture just ends, loudly, once.
            hasFailed.store(true, ordering: .relaxed)
            logger.error(
                "capture stopped",
                metadata: ["path": "\(destination)", "error": "\(String(cString: strerror(failure)))"])
        }
    }

    private static func createFile(in directory: String, startedAt start: Date) throws(CaptureFileError) -> (Int32, String) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let two = { (value: Int?) in String(format: "%02d", value ?? 0) }
        let stamp = "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))-\(two(parts.hour))\(two(parts.minute))\(two(parts.second))"
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        // Two servers started in the same second must not share, or clobber, a file.
        for attempt in 1...100 {
            let name = "\(BLEMCPServer.name)-\(stamp)" + (attempt == 1 ? "" : "-\(attempt)") + ".jsonl"
            let path = base.appendingPathComponent(name).path
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
            if descriptor >= 0 { return (descriptor, path) }
            guard errno == EEXIST else { throw CaptureFileError(path: path, errno: errno) }
        }
        throw CaptureFileError(path: directory, errno: EEXIST)
    }
}

public struct CaptureFileError: Error, CustomStringConvertible {
    public let path: String
    public let reason: String

    init(path: String, errno code: Int32) {
        self.path = path
        self.reason = String(cString: strerror(code))
    }

    public var description: String {
        "Cannot open the capture file \(path): \(reason)."
    }
}

/// One capture row. Keys come out in a fixed order (`t`, `dir`, `uuid`, `hex`, `note`, then the
/// rest sorted) so captures read well and diff cleanly.
///
/// Rows about an attribute carry its `peripheral` and `service`, so captures of several devices,
/// or of characteristics that share a UUID, can be told apart. The agent's markers carry
/// `"marker": true`, so a note that reads like one of the writer's (`disconnected`, say) is never
/// taken for that event, and the row that starts each run is the writer's own `capture started`.
struct CaptureLine {
    /// Keys the format defines; marker fields may not use them.
    static let reservedKeys: Set<String> = ["t", "dir", "uuid", "hex", "note", "marker"]

    private var fields: [(String, String)] = []

    /// The first row of a run: when it started and what wrote it.
    init(startedAt start: Date) {
        append("t", Self.seconds(0))
        info(
            note: "capture started",
            [
                "server": .string("\(BLEMCPServer.name) \(BLEMCPServer.version)"),
                "started_at": .string(start.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
            ])
    }

    init(_ event: CaptureEvent, since start: Date) {
        append("t", Self.seconds(event.time.timeIntervalSince(start)))
        switch event.kind {
        case .advertisement(let peripheral):
            info(
                note: "advertisement",
                [
                    "peripheral": .string(peripheral.id.description), "name": peripheral.name.map(CaptureValue.string),
                    "rssi": peripheral.rssi.map(CaptureValue.integer), "connectable": peripheral.isConnectable.map(CaptureValue.bool),
                    "tx_power": peripheral.txPowerLevel.map(CaptureValue.integer),
                    "manufacturer": peripheral.manufacturerData.map { .string(Hex.encode($0)) },
                ],
                json: [
                    "advertised_services": peripheral.serviceUUIDs.isEmpty ? nil : Self.array(peripheral.serviceUUIDs.map { Self.string(Self.uuid($0)) }),
                    "service_data": peripheral.serviceData.isEmpty
                        ? nil : Self.object(peripheral.serviceData.map { (Self.uuid($0.key), Self.string(Hex.encode($0.value))) }.sorted { $0.0 < $1.0 }),
                ])
        case .connected(let peripheral, let name):
            info(note: "connected", ["peripheral": .string(peripheral.description), "name": name.map(CaptureValue.string)])
        case .discovered(let peripheral, let services):
            info(note: "gatt", ["peripheral": .string(peripheral.description)], json: ["services": Self.services(services)])
        case .disconnected(let peripheral, let reason):
            info(note: "disconnected", ["peripheral": .string(peripheral.description), "reason": reason.map(CaptureValue.string)])
        case .notificationsEnabled(let address, let mode):
            info(
                address.characteristic, note: "\(mode.rawValue) enabled on \(Self.uuid(address.characteristic))",
                Self.location(address))
        case .notificationsDisabled(let address):
            info(address.characteristic, note: "notifications disabled on \(Self.uuid(address.characteristic))", Self.location(address))
        case .write(let address, let value, let mode):
            row("tx", address, value, ["mode": .string(mode.rawValue)])
        case .descriptorWrite(let address, let value):
            info(
                address.characteristic.characteristic, value, note: "descriptor write",
                Self.location(address.characteristic, ["descriptor": .string(Self.uuid(address.descriptor))]))
        case .writeFailed(let address, let descriptor, let error):
            info(
                address.characteristic, note: "write failed: \(error.message)",
                Self.location(address, ["descriptor": descriptor.map { .string(Self.uuid($0)) }, "code": .string(error.code)]))
        case .notification(let address, let value):
            row("rx", address, value)
        case .read(let address, let value):
            info(address.characteristic, value, note: "read", Self.location(address))
        case .descriptorRead(let address, let value):
            info(
                address.characteristic.characteristic, value, note: "descriptor read",
                Self.location(address.characteristic, ["descriptor": .string(Self.uuid(address.descriptor))]))
        case .marker(let note, let markerFields):
            var fields = markerFields.filter { !Self.reservedKeys.contains($0.key) }.mapValues(Optional.some)
            fields["marker"] = .bool(true)
            info(note: note, fields)
        }
    }

    /// Where an attribute row's characteristic is, merged into its other fields.
    private static func location(_ address: CharacteristicAddress, _ fields: [String: CaptureValue?] = [:]) -> [String: CaptureValue?] {
        fields.merging(["peripheral": .string(address.peripheral.description), "service": .string(uuid(address.service))]) { own, _ in own }
    }

    var text: String {
        "{" + fields.map { "\(Self.string($0.0)): \($0.1)" }.joined(separator: ", ") + "}"
    }

    private mutating func row(_ direction: String, _ address: CharacteristicAddress, _ value: Data, _ extra: [String: CaptureValue?] = [:]) {
        append("dir", Self.string(direction))
        append("uuid", Self.string(Self.uuid(address.characteristic)))
        append("hex", Self.string(Hex.encode(value)))
        appendSorted(Self.location(address, extra).compactMapValues { $0.map(Self.json) })
    }

    /// - Parameter json: Fields already encoded as JSON, for the nested values only replays read;
    ///   sorted in with `extra`.
    private mutating func info(
        _ characteristic: BLEUUID? = nil,
        _ value: Data? = nil,
        note: String,
        _ extra: [String: CaptureValue?] = [:],
        json: [String: String?] = [:]
    ) {
        append("dir", Self.string("info"))
        if let characteristic { append("uuid", Self.string(Self.uuid(characteristic))) }
        if let value { append("hex", Self.string(Hex.encode(value))) }
        append("note", Self.string(note))
        var encoded = extra.compactMapValues { $0.map(Self.json) }
        encoded.merge(json.compactMapValues { $0 }) { scalar, _ in scalar }
        appendSorted(encoded)
    }

    private mutating func appendSorted(_ encoded: [String: String]) {
        for (key, value) in encoded.sorted(by: { $0.key < $1.key }) {
            append(key, value)
        }
    }

    private mutating func append(_ key: String, _ json: String) {
        fields.append((key, json))
    }

    /// Lowercase, short for SIG UUIDs: `ff01`, `2a19`, `6e400001-b5a3-f393-e0a9-e50e24dcca9e`.
    static func uuid(_ uuid: BLEUUID) -> String {
        uuid.description.lowercased()
    }

    /// Milliseconds are as fine as the radio timing that matters here.
    private static func seconds(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1000).rounded()))
        let fraction = String(milliseconds % 1000)
        return "\(milliseconds / 1000)." + String(repeating: "0", count: 3 - fraction.count) + fraction
    }

    /// `[{"uuid": "180f", "primary": true, "characteristics": [{"uuid": "2a19", "properties": ["read"],
    /// "descriptors": ["2902"], "description": "Battery"}]}]`
    private static func services(_ services: [GATTService]) -> String {
        array(
            services.map { service in
                object([
                    ("uuid", string(uuid(service.uuid))),
                    ("primary", service.isPrimary ? "true" : "false"),
                    (
                        "characteristics",
                        array(
                            service.characteristics.map { characteristic in
                                var fields = [
                                    ("uuid", string(uuid(characteristic.uuid))),
                                    ("properties", array(characteristic.properties.names.map(string))),
                                    ("descriptors", array(characteristic.descriptors.map { string(uuid($0.uuid)) })),
                                ]
                                if let description = characteristic.userDescription {
                                    fields.append(("description", string(description)))
                                }
                                return object(fields)
                            })
                    ),
                ])
            })
    }

    private static func array(_ elements: [String]) -> String {
        "[" + elements.joined(separator: ", ") + "]"
    }

    /// Keys come out in the given order; `pairs` values are already JSON.
    private static func object(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\(string($0.0)): \($0.1)" }.joined(separator: ", ") + "}"
    }

    private static func json(_ value: CaptureValue) -> String {
        switch value {
        case .string(let text): string(text)
        case .integer(let int): String(int)
        case .number(let double) where double.isFinite: "\(double)"
        case .number: "null"
        case .bool(let bool): bool ? "true" : "false"
        }
    }

    private static func string(_ text: String) -> String {
        var escaped = "\""
        escaped.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case let control where control.value < 0x20:
                escaped += "\\u" + String(repeating: "0", count: 4 - String(control.value, radix: 16).count)
                    + String(control.value, radix: 16)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }
}
