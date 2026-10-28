/// The GATT characteristic property bits from the Core Specification (Vol 3, Part G, 3.3.1.1),
/// plus CoreBluetooth's two encryption-required flags.
public struct CharacteristicProperties: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let broadcast = Self(rawValue: 0x0001)
    public static let read = Self(rawValue: 0x0002)
    public static let writeWithoutResponse = Self(rawValue: 0x0004)
    public static let write = Self(rawValue: 0x0008)
    public static let notify = Self(rawValue: 0x0010)
    public static let indicate = Self(rawValue: 0x0020)
    public static let authenticatedSignedWrites = Self(rawValue: 0x0040)
    public static let extendedProperties = Self(rawValue: 0x0080)
    public static let notifyEncryptionRequired = Self(rawValue: 0x0100)
    public static let indicateEncryptionRequired = Self(rawValue: 0x0200)

    private static let names: [(Self, String)] = [
        (.broadcast, "broadcast"),
        (.read, "read"),
        (.writeWithoutResponse, "write_without_response"),
        (.write, "write"),
        (.notify, "notify"),
        (.indicate, "indicate"),
        (.authenticatedSignedWrites, "authenticated_signed_writes"),
        (.extendedProperties, "extended_properties"),
        (.notifyEncryptionRequired, "notify_encryption_required"),
        (.indicateEncryptionRequired, "indicate_encryption_required"),
    ]

    /// Stable snake_case names, in bit order.
    public var names: [String] {
        Self.names.compactMap { contains($0.0) ? $0.1 : nil }
    }

    /// The inverse of `names`; names it does not know are skipped.
    public init(names: some Sequence<String>) {
        let known = Set(names)
        self = Self(Self.names.filter { known.contains($0.1) }.map(\.0))
    }
}

public struct GATTDescriptor: Hashable, Sendable {
    public let uuid: BLEUUID

    public init(uuid: BLEUUID) {
        self.uuid = uuid
    }

    /// Client Characteristic Configuration. CoreBluetooth owns it: writing it directly raises an
    /// Objective-C exception, so subscriptions go through `setNotifyValue` instead.
    public static let clientCharacteristicConfiguration = BLEUUID(0x2902)

    /// Characteristic User Description: the device's own name for a characteristic.
    public static let characteristicUserDescription = BLEUUID(0x2901)
}

public struct GATTCharacteristic: Hashable, Sendable {
    public let uuid: BLEUUID
    public let properties: CharacteristicProperties
    public let descriptors: [GATTDescriptor]
    /// The value of its 0x2901 descriptor, when discovery read it.
    public let userDescription: String?

    public init(
        uuid: BLEUUID,
        properties: CharacteristicProperties,
        descriptors: [GATTDescriptor] = [],
        userDescription: String? = nil
    ) {
        self.uuid = uuid
        self.properties = properties
        self.descriptors = descriptors
        self.userDescription = userDescription
    }

    public var hasUserDescription: Bool {
        descriptors.contains { $0.uuid == GATTDescriptor.characteristicUserDescription }
    }

    public func with(userDescription: String?) -> GATTCharacteristic {
        GATTCharacteristic(uuid: uuid, properties: properties, descriptors: descriptors, userDescription: userDescription)
    }
}

public struct GATTService: Hashable, Sendable {
    public let uuid: BLEUUID
    public let isPrimary: Bool
    public let characteristics: [GATTCharacteristic]

    public init(uuid: BLEUUID, isPrimary: Bool = true, characteristics: [GATTCharacteristic]) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}

/// A fully resolved characteristic: the backend acts on the first service with `service` and,
/// within it, the first characteristic with `characteristic`.
public struct CharacteristicAddress: Hashable, Sendable, CustomStringConvertible {
    public let peripheral: PeripheralID
    public let service: BLEUUID
    public let characteristic: BLEUUID

    public init(peripheral: PeripheralID, service: BLEUUID, characteristic: BLEUUID) {
        self.peripheral = peripheral
        self.service = service
        self.characteristic = characteristic
    }

    public var description: String { "\(peripheral)/\(service)/\(characteristic)" }
}

public struct DescriptorAddress: Hashable, Sendable, CustomStringConvertible {
    public let characteristic: CharacteristicAddress
    public let descriptor: BLEUUID

    public init(characteristic: CharacteristicAddress, descriptor: BLEUUID) {
        self.characteristic = characteristic
        self.descriptor = descriptor
    }

    public var description: String { "\(characteristic)/\(descriptor)" }
}

/// What a caller asks for: a characteristic UUID, optionally narrowed to one service.
public struct CharacteristicSelector: Hashable, Sendable {
    public let peripheral: PeripheralID
    public let service: BLEUUID?
    public let characteristic: BLEUUID

    public init(peripheral: PeripheralID, service: BLEUUID? = nil, characteristic: BLEUUID) {
        self.peripheral = peripheral
        self.service = service
        self.characteristic = characteristic
    }
}

public enum WriteMode: String, Hashable, Sendable {
    case withResponse = "with_response"
    case withoutResponse = "without_response"
}

public enum NotificationMode: String, Hashable, Sendable {
    case notify
    case indicate
}

public struct ResolvedCharacteristic: Hashable, Sendable {
    public let address: CharacteristicAddress
    public let characteristic: GATTCharacteristic
}

/// Resolves selectors against a discovered attribute table. Pure, so every ambiguity and
/// not-found path is unit-testable without a radio.
public enum GATTResolver {
    public static func resolve(
        _ selector: CharacteristicSelector,
        in services: [GATTService]
    ) throws(BLEError) -> ResolvedCharacteristic {
        if let serviceUUID = selector.service {
            let candidates = services.filter { $0.uuid == serviceUUID }
            guard !candidates.isEmpty else {
                throw .serviceNotFound(serviceUUID, available: unique(services.map(\.uuid)))
            }
            for service in candidates {
                if let characteristic = service.characteristics.first(where: { $0.uuid == selector.characteristic }) {
                    return ResolvedCharacteristic(
                        address: CharacteristicAddress(
                            peripheral: selector.peripheral, service: service.uuid, characteristic: characteristic.uuid),
                        characteristic: characteristic)
                }
            }
            throw .characteristicNotFound(
                selector.characteristic, service: serviceUUID,
                available: unique(candidates.flatMap { $0.characteristics.map(\.uuid) }))
        }

        let matches = services.compactMap { service in
            service.characteristics.first { $0.uuid == selector.characteristic }.map { (service, $0) }
        }
        guard let (service, characteristic) = matches.first else {
            throw .characteristicNotFound(
                selector.characteristic, service: nil,
                available: unique(services.flatMap { $0.characteristics.map(\.uuid) }))
        }
        let owningServices = unique(matches.map(\.0.uuid))
        guard owningServices.count == 1 else {
            throw .ambiguousCharacteristic(selector.characteristic, services: owningServices)
        }
        return ResolvedCharacteristic(
            address: CharacteristicAddress(
                peripheral: selector.peripheral, service: service.uuid, characteristic: characteristic.uuid),
            characteristic: characteristic)
    }

    public static func resolve(
        descriptor uuid: BLEUUID,
        of resolved: ResolvedCharacteristic
    ) throws(BLEError) -> DescriptorAddress {
        guard resolved.characteristic.descriptors.contains(where: { $0.uuid == uuid }) else {
            throw .descriptorNotFound(
                uuid, characteristic: resolved.address.characteristic,
                available: resolved.characteristic.descriptors.map(\.uuid))
        }
        return DescriptorAddress(characteristic: resolved.address, descriptor: uuid)
    }

    private static func unique(_ uuids: [BLEUUID]) -> [BLEUUID] {
        var seen = Set<BLEUUID>()
        return uuids.filter { seen.insert($0).inserted }
    }
}
