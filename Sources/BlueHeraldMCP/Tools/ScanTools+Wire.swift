import BlueHeraldCore
import Foundation

struct Manufacturer: Encodable {
    let companyId: String
    let company: String?
    let data: String
}

struct ServiceDataEntry: Encodable {
    let uuid: String
    let name: String?
    let data: String
}

struct DeviceSummary: Encodable {
    let peripheralId: String
    let name: String?
    let rssi: Int?
    let strongestRssi: Int?
    let connectable: Bool?
    let txPower: Int?
    /// Omitted when empty, like every other absent field, to keep scan results compact.
    let services: [UUIDReference]?
    let manufacturer: Manufacturer?
    let serviceData: [ServiceDataEntry]?
    let advertisementCount: Int
    let lastSeen: Date

    init(_ peripheral: DiscoveredPeripheral) {
        peripheralId = peripheral.id.description
        name = DeviceText.clean(peripheral.name)
        rssi = peripheral.rssi
        strongestRssi = peripheral.strongestRSSI
        connectable = peripheral.isConnectable
        txPower = peripheral.txPowerLevel
        services = peripheral.serviceUUIDs.isEmpty ? nil : peripheral.serviceUUIDs.map(UUIDReference.init)
        manufacturer = peripheral.manufacturerData.map { data in
            let id = peripheral.manufacturerID
            return Manufacturer(
                companyId: id.map { "0x" + Hex.encode([UInt8($0 >> 8), UInt8($0 & 0xFF)]).uppercased() } ?? "unknown",
                company: id.flatMap(AssignedNumbers.companyName(for:)),
                data: Hex.encode(data))
        }
        serviceData =
            peripheral.serviceData.isEmpty
            ? nil
            : peripheral.serviceData
                .sorted { $0.key < $1.key }
                .map { ServiceDataEntry(uuid: $0.key.description, name: AssignedNumbers.name(for: $0.key), data: Hex.encode($0.value)) }
        advertisementCount = peripheral.advertisementCount
        lastSeen = peripheral.lastSeen
    }
}

struct ScanReport: Encodable {
    let scanId: String
    let active: Bool
    let startedAt: Date
    let endedAt: Date?
    let matched: Int
    let seen: Int
    let ignored: Int?
    let truncated: Bool
    let devices: [DeviceSummary]

    init(_ snapshot: ScanSnapshot) {
        scanId = snapshot.id.description
        active = snapshot.isActive
        startedAt = snapshot.startedAt
        endedAt = snapshot.endedAt
        matched = snapshot.matchedCount
        seen = snapshot.seenCount
        ignored = snapshot.ignoredCount > 0 ? snapshot.ignoredCount : nil
        truncated = snapshot.peripherals.count < snapshot.matchedCount
        devices = snapshot.peripherals.map(DeviceSummary.init)
    }
}

struct ScanStarted: Encodable {
    let scanId: String
}
