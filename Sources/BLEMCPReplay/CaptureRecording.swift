public import BLEMCPCore
public import Foundation

/// A JSONL capture loaded back: what ble-mcp records with `BLE_MCP_CAPTURE`, and the fixtures
/// swift-dragoman's probe scripts write, which share the format.
///
/// Loading is strict about structure (every line must be a JSON object) and lenient about
/// content: a field with an unexpected type is treated as absent, since marker fields are free-form.
public struct CaptureRecording: Sendable {
    /// The file it came from, if any.
    public let source: String?
    public let rows: [CaptureRow]

    public init(rows: [CaptureRow], source: String? = nil) {
        self.rows = rows
        self.source = source
    }

    public init(contentsOf path: String) throws(CaptureReadError) {
        let path = NSString(string: path).expandingTildeInPath
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CaptureReadError(source: path, line: nil, reason: error.localizedDescription)
        }
        try self.init(jsonl: text, source: path)
    }

    public init(jsonl text: String, source: String? = nil) throws(CaptureReadError) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var rows: [CaptureRow] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard line.contains(where: { !$0.isWhitespace }) else { continue }
            do {
                rows.append(CaptureRow(try decoder.decode(RawRow.self, from: Data(line.utf8)), line: offset + 1))
            } catch {
                throw CaptureReadError(source: source, line: offset + 1, reason: "not a JSON object")
            }
        }
        self.init(rows: rows, source: source)
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

    public let peripheral: PeripheralID?
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
        peripheral: PeripheralID? = nil,
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
        self.peripheral = peripheral
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
        guard let note else { return .other }
        switch note {
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
    @Lenient var peripheral: String?
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
            peripheral: raw.peripheral.flatMap { PeripheralID($0) },
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
