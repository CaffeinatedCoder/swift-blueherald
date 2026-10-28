public import BlueHeraldCore
public import Foundation

/// A JSONL capture loaded back: what blueherald records with `BLUEHERALD_CAPTURE`, and the fixtures
/// swift-dragoman's probe scripts write, which share the format.
///
/// Loading is strict about structure (every line must be a JSON object) and lenient about
/// content: a field with an unexpected type is treated as absent, since marker fields are free-form.
/// Lines may end in `\n` or `\r\n`. A last line with no newline that is not a JSON object is a
/// row the writer was cut off in (a crash, a full disk): it is left out and named in `warnings`.
public struct CaptureRecording: Sendable {
    /// The file it came from, if any.
    public let source: String?
    public let rows: [CaptureRow]
    /// What was left out while loading.
    public let warnings: [String]

    public init(rows: [CaptureRow], source: String? = nil, warnings: [String] = []) {
        self.rows = rows
        self.source = source
        self.warnings = warnings
    }

    public init(contentsOf path: String) throws(CaptureReadError) {
        let path = NSString(string: path).expandingTildeInPath
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CaptureReadError(source: path, line: nil, reason: error.localizedDescription)
        }
        try self.init(jsonl: data, source: path)
    }

    public init(jsonl text: String, source: String? = nil) throws(CaptureReadError) {
        try self.init(jsonl: Data(text.utf8), source: source)
    }

    /// Lines are split as bytes and decoded one at a time, so a byte sequence cut short only
    /// affects its own line.
    public init(jsonl data: Data, source: String? = nil) throws(CaptureReadError) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var rows: [CaptureRow] = []
        var warnings: [String] = []
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (offset, line) in lines.enumerated() {
            let line = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
            guard line.contains(where: { !Self.isWhitespace($0) }) else { continue }
            do {
                rows.append(CaptureRow(try decoder.decode(RawRow.self, from: line), line: offset + 1))
            } catch {
                // The last element of the split follows the last newline: it is unterminated.
                guard offset == lines.count - 1 else {
                    throw CaptureReadError(source: source, line: offset + 1, reason: "not a JSON object")
                }
                warnings.append(
                    "Line \(offset + 1) was left out: it ends without a newline and is not a JSON object, as when a capture is cut off mid-write."
                )
            }
        }
        self.init(rows: rows, source: source, warnings: warnings)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }
}

public struct CaptureReadError: Error, Hashable, CustomStringConvertible {
    public let source: String?
    public let line: Int?
    public let reason: String

    public var description: String {
        "Cannot read the capture \(source ?? "text")\(line.map { " at line \($0)" } ?? ""): \(reason)."
    }
}

/// One capture line, with the fields the replay and the diff use parsed into domain types.
public struct CaptureRow: Hashable, Sendable {
    public enum Direction: String, Hashable, Sendable {
        case tx, rx, info
    }

    /// 1-based line number in the source.
    public let line: Int
    /// Seconds since the capture started.
    public let time: Double
    public let direction: Direction
    public let characteristic: BLEUUID?
    public let value: Data?
    public let note: String?
    /// A label the agent placed. Its note is free text, never read as an event.
    public let isMarker: Bool

    public let peripheral: PeripheralID?
    /// The characteristic's service, on rows about an attribute; older captures have none.
    public let service: BLEUUID?
    public let name: String?
    public let reason: String?
    public let mode: WriteMode?
    public let descriptor: BLEUUID?
    public let rssi: Int?
    public let isConnectable: Bool?
    public let txPowerLevel: Int?
    public let advertisedServices: [BLEUUID]
    public let manufacturerData: Data?
    public let serviceData: [BLEUUID: Data]
    /// Only on `gatt` rows.
    public let services: [GATTService]?

    public init(
        line: Int,
        time: Double,
        direction: Direction,
        characteristic: BLEUUID? = nil,
        value: Data? = nil,
        note: String? = nil,
        isMarker: Bool = false,
        peripheral: PeripheralID? = nil,
        service: BLEUUID? = nil,
        name: String? = nil,
        reason: String? = nil,
        mode: WriteMode? = nil,
        descriptor: BLEUUID? = nil,
        rssi: Int? = nil,
        isConnectable: Bool? = nil,
        txPowerLevel: Int? = nil,
        advertisedServices: [BLEUUID] = [],
        manufacturerData: Data? = nil,
        serviceData: [BLEUUID: Data] = [:],
        services: [GATTService]? = nil
    ) {
        self.line = line
        self.time = time
        self.direction = direction
        self.characteristic = characteristic
        self.value = value
        self.note = note
        self.isMarker = isMarker
        self.peripheral = peripheral
        self.service = service
        self.name = name
        self.reason = reason
        self.mode = mode
        self.descriptor = descriptor
        self.rssi = rssi
        self.isConnectable = isConnectable
        self.txPowerLevel = txPowerLevel
        self.advertisedServices = advertisedServices
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
        self.services = services
    }

    /// What the row records, read from its direction and note the way the writer produces them.
    public enum Meaning: Hashable, Sendable {
        case write(BLEUUID, Data, WriteMode?)
        case notification(BLEUUID, Data)
        case read(BLEUUID, Data)
        case descriptorRead(BLEUUID, descriptor: BLEUUID, Data)
        case notificationsEnabled(BLEUUID, NotificationMode)
        case notificationsDisabled(BLEUUID)
        case advertisement(PeripheralID)
        case connected(PeripheralID?, name: String?)
        case gatt(PeripheralID?, [GATTService])
        case disconnected(PeripheralID?, reason: String?)
        /// swift-dragoman's probe scripts open with `device <identifier>`.
        case device(PeripheralID)
        /// The first row of a run. A file a server appended to holds one run after another, each
        /// with its clock starting at 0.
        case runStarted
        case other
    }

    public var meaning: Meaning {
        switch direction {
        case .tx:
            guard let characteristic, let value else { return .other }
            return .write(characteristic, value, mode)
        case .rx:
            guard let characteristic, let value else { return .other }
            return .notification(characteristic, value)
        case .info:
            return infoMeaning
        }
    }

    private var infoMeaning: Meaning {
        guard let note, !isMarker else { return .other }
        switch note {
        case "capture started":
            return .runStarted
        case "read":
            if let characteristic, let value { return .read(characteristic, value) }
        case "descriptor read":
            if let characteristic, let descriptor, let value { return .descriptorRead(characteristic, descriptor: descriptor, value) }
        case "advertisement":
            if let peripheral { return .advertisement(peripheral) }
        case "connected":
            return .connected(peripheral, name: name)
        case "gatt":
            if let services { return .gatt(peripheral, services) }
        case "disconnected":
            return .disconnected(peripheral, reason: reason)
        default:
            for mode in [NotificationMode.notify, .indicate] {
                let prefix = "\(mode.rawValue) enabled on "
                if note.hasPrefix(prefix), let uuid = characteristic ?? BLEUUID(note.dropFirst(prefix.count)) {
                    return .notificationsEnabled(uuid, mode)
                }
            }
            let disabled = "notifications disabled on "
            if note.hasPrefix(disabled), let uuid = characteristic ?? BLEUUID(note.dropFirst(disabled.count)) {
                return .notificationsDisabled(uuid)
            }
            if note.hasPrefix("device "), let id = PeripheralID(note.dropFirst("device ".count)) {
                return .device(id)
            }
        }
        return .other
    }
}

// MARK: - Decoding

/// The line as JSON. Every field is optional and decoded leniently, see `Lenient`.
private struct RawRow: Decodable {
    struct Service: Decodable {
        @Lenient var uuid: String?
        @Lenient var primary: Bool?
        @Lenient var characteristics: [Characteristic]?
    }

    struct Characteristic: Decodable {
        @Lenient var uuid: String?
        @Lenient var properties: [String]?
        @Lenient var descriptors: [String]?
        @Lenient var description: String?
    }

    @Lenient var t: Double?
    @Lenient var dir: String?
    @Lenient var uuid: String?
    @Lenient var hex: String?
    @Lenient var note: String?
    @Lenient var marker: Bool?
    @Lenient var peripheral: String?
    @Lenient var service: String?
    @Lenient var name: String?
    @Lenient var reason: String?
    @Lenient var mode: String?
    @Lenient var descriptor: String?
    @Lenient var rssi: Int?
    @Lenient var connectable: Bool?
    @Lenient var txPower: Int?
    @Lenient var advertisedServices: [String]?
    @Lenient var manufacturer: String?
    @Lenient var serviceData: [String: String]?
    @Lenient var services: [Service]?
}

/// Decodes a value of the wrong type, or `null`, as absent instead of failing the line.
@propertyWrapper
private struct Lenient<Value: Decodable>: Decodable {
    var wrappedValue: Value?

    init(from decoder: any Decoder) throws {
        wrappedValue = try? decoder.singleValueContainer().decode(Value.self)
    }
}

extension KeyedDecodingContainer {
    fileprivate func decode<Value>(_ type: Lenient<Value>.Type, forKey key: Key) throws -> Lenient<Value> {
        try decodeIfPresent(type, forKey: key) ?? Lenient(wrappedValue: nil)
    }
}

extension Lenient {
    fileprivate init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }
}

extension CaptureRow {
    fileprivate init(_ raw: RawRow, line: Int) {
        let uuid = { (text: String?) in text.flatMap { BLEUUID($0) } }
        self.init(
            line: line,
            time: raw.t ?? 0,
            direction: raw.dir.flatMap(Direction.init(rawValue:)) ?? .info,
            characteristic: uuid(raw.uuid),
            value: raw.hex.flatMap { Hex.decode($0) },
            note: raw.note,
            isMarker: raw.marker ?? false,
            peripheral: raw.peripheral.flatMap { PeripheralID($0) },
            service: uuid(raw.service),
            name: raw.name,
            reason: raw.reason,
            mode: raw.mode.flatMap(WriteMode.init(rawValue:)),
            descriptor: uuid(raw.descriptor),
            rssi: raw.rssi,
            isConnectable: raw.connectable,
            txPowerLevel: raw.txPower,
            advertisedServices: (raw.advertisedServices ?? []).compactMap { BLEUUID($0) },
            manufacturerData: raw.manufacturer.flatMap { Hex.decode($0) },
            serviceData: Dictionary(
                (raw.serviceData ?? [:]).compactMap { key, value in
                    BLEUUID(key).flatMap { uuid in Hex.decode(value).map { (uuid, $0) } }
                },
                uniquingKeysWith: { first, _ in first }),
            services: raw.services.map { services in
                services.compactMap { service in
                    guard let serviceUUID = uuid(service.uuid) else { return nil }
                    return GATTService(
                        uuid: serviceUUID,
                        isPrimary: service.primary ?? true,
                        characteristics: (service.characteristics ?? []).compactMap { characteristic in
                            guard let characteristicUUID = uuid(characteristic.uuid) else { return nil }
                            return GATTCharacteristic(
                                uuid: characteristicUUID,
                                properties: CharacteristicProperties(names: characteristic.properties ?? []),
                                descriptors: (characteristic.descriptors ?? []).compactMap(uuid).map(GATTDescriptor.init),
                                userDescription: characteristic.description)
                        })
                }
            })
    }
}
