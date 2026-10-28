public import Foundation

/// One advertising or scan-response packet, as the backend received it.
public struct Advertisement: Hashable, Sendable {
    public let peripheral: PeripheralID
    /// The advertised local name, falling back to the GAP name the platform has cached.
    /// Cleaned with `DeviceText`.
    public let name: String?
    /// `nil` when the controller reported no usable RSSI (CoreBluetooth's 127).
    public let rssi: Int?
    public let isConnectable: Bool?
    public let serviceUUIDs: [BLEUUID]
    public let manufacturerData: Data?
    public let serviceData: [BLEUUID: Data]
    public let txPowerLevel: Int?
    public let receivedAt: Date

    public init(
        peripheral: PeripheralID,
        name: String? = nil,
        rssi: Int? = nil,
        isConnectable: Bool? = nil,
        serviceUUIDs: [BLEUUID] = [],
        manufacturerData: Data? = nil,
        serviceData: [BLEUUID: Data] = [:],
        txPowerLevel: Int? = nil,
        receivedAt: Date = Date()
    ) {
        self.peripheral = peripheral
        self.name = DeviceText.clean(name)
        self.rssi = rssi
        self.isConnectable = isConnectable
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
        self.txPowerLevel = txPowerLevel
        self.receivedAt = receivedAt
    }
}

/// Everything a scan has learned about one peripheral, merged across its advertisements.
///
/// Advertising data arrives split: the name often comes only in the scan response and service
/// UUIDs only in the advertisement, so filters are applied to this merged view, never to a
/// single packet.
public struct DiscoveredPeripheral: Hashable, Sendable, Identifiable {
    public let id: PeripheralID
    public private(set) var name: String?
    public private(set) var rssi: Int?
    public private(set) var strongestRSSI: Int?
    public private(set) var isConnectable: Bool?
    public private(set) var serviceUUIDs: [BLEUUID]
    public private(set) var manufacturerData: Data?
    public private(set) var serviceData: [BLEUUID: Data]
    public private(set) var txPowerLevel: Int?
    public let firstSeen: Date
    public private(set) var lastSeen: Date
    public private(set) var advertisementCount: Int

    public init(_ advertisement: Advertisement) {
        id = advertisement.peripheral
        name = advertisement.name
        rssi = advertisement.rssi
        strongestRSSI = advertisement.rssi
        isConnectable = advertisement.isConnectable
        serviceUUIDs = advertisement.serviceUUIDs
        manufacturerData = advertisement.manufacturerData
        serviceData = advertisement.serviceData
        txPowerLevel = advertisement.txPowerLevel
        firstSeen = advertisement.receivedAt
        lastSeen = advertisement.receivedAt
        advertisementCount = 1
    }

    /// Folds a later packet in. Fields a packet omits keep their earlier value; RSSI tracks the
    /// latest reading and the strongest one seen.
    public mutating func merge(_ advertisement: Advertisement) {
        name = advertisement.name ?? name
        if let reading = advertisement.rssi {
            rssi = reading
            strongestRSSI = max(strongestRSSI ?? reading, reading)
        }
        isConnectable = advertisement.isConnectable ?? isConnectable
        for uuid in advertisement.serviceUUIDs where !serviceUUIDs.contains(uuid) {
            serviceUUIDs.append(uuid)
        }
        manufacturerData = advertisement.manufacturerData ?? manufacturerData
        serviceData.merge(advertisement.serviceData) { _, latest in latest }
        txPowerLevel = advertisement.txPowerLevel ?? txPowerLevel
        lastSeen = max(lastSeen, advertisement.receivedAt)
        advertisementCount += 1
    }

    /// The Bluetooth SIG company identifier: the first two manufacturer-data bytes, little-endian.
    public var manufacturerID: UInt16? {
        guard let data = manufacturerData, data.count >= 2 else { return nil }
        return UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
    }
}

/// Which peripherals a scan reports. Every criterion that is set must match.
public struct ScanFilter: Hashable, Sendable {
    /// Case- and diacritic-insensitive substring of the peripheral name.
    public let nameContains: String?
    /// Matches when the peripheral advertises any of these services. Empty means no constraint.
    public let serviceUUIDs: Set<BLEUUID>
    /// Minimum latest RSSI in dBm.
    public let minimumRSSI: Int?
    public let manufacturerID: UInt16?
    public let connectableOnly: Bool

    public init(
        nameContains: String? = nil,
        serviceUUIDs: Set<BLEUUID> = [],
        minimumRSSI: Int? = nil,
        manufacturerID: UInt16? = nil,
        connectableOnly: Bool = false
    ) {
        self.nameContains = nameContains.flatMap { $0.isEmpty ? nil : $0 }
        self.serviceUUIDs = serviceUUIDs
        self.minimumRSSI = minimumRSSI
        self.manufacturerID = manufacturerID
        self.connectableOnly = connectableOnly
    }

    public static let all = ScanFilter()

    public func matches(_ peripheral: DiscoveredPeripheral) -> Bool {
        if let nameContains {
            guard let name = peripheral.name,
                name.range(of: nameContains, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { return false }
        }
        if !serviceUUIDs.isEmpty {
            guard peripheral.serviceUUIDs.contains(where: serviceUUIDs.contains)
                || peripheral.serviceData.keys.contains(where: serviceUUIDs.contains)
            else { return false }
        }
        if let minimumRSSI {
            guard let rssi = peripheral.rssi, rssi >= minimumRSSI else { return false }
        }
        if let manufacturerID, peripheral.manufacturerID != manufacturerID {
            return false
        }
        if connectableOnly, peripheral.isConnectable != true {
            return false
        }
        return true
    }
}
