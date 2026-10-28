#if canImport(CoreBluetooth)
import BLEMCPCore
@preconcurrency import CoreBluetooth
import Foundation

extension BLEUUID {
    init(_ uuid: CBUUID) {
        self = BLEUUID(bigEndianBytes: uuid.data) ?? BLEUUID(uuid.uuidString) ?? BLEUUID(rawValue: 0)
    }

    var cbUUID: CBUUID {
        CBUUID(string: description)
    }
}

extension CentralState {
    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

extension GATTService {
    init(_ service: CBService) {
        self.init(
            uuid: BLEUUID(service.uuid),
            isPrimary: service.isPrimary,
            characteristics: (service.characteristics ?? []).map(GATTCharacteristic.init))
    }
}

extension GATTCharacteristic {
    init(_ characteristic: CBCharacteristic) {
        self.init(
            uuid: BLEUUID(characteristic.uuid),
            properties: CharacteristicProperties(rawValue: UInt16(truncatingIfNeeded: characteristic.properties.rawValue)),
            descriptors: (characteristic.descriptors ?? []).map { GATTDescriptor(uuid: BLEUUID($0.uuid)) })
    }
}

extension Advertisement {
    /// Converts CoreBluetooth's untyped advertisement dictionary on the delegate queue, so only
    /// a `Sendable` value crosses into the actor.
    init(peripheral: CBPeripheral, data: [String: Any], rssi: NSNumber) {
        let serviceUUIDs =
            (data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let serviceData = (data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
        let reading = rssi.intValue
        self.init(
            peripheral: PeripheralID(peripheral.identifier),
            name: data[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            rssi: reading == 127 ? nil : reading,
            isConnectable: (data[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
            serviceUUIDs: serviceUUIDs.map(BLEUUID.init),
            manufacturerData: data[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceData: Dictionary(serviceData.map { (BLEUUID($0.key), $0.value) }) { first, _ in first },
            txPowerLevel: (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            receivedAt: .now)
    }
}

extension BLEError {
    /// Maps a CoreBluetooth or ATT error from a delegate callback. Pairing problems get their
    /// own codes: CoreBluetooth has no pairing API, so the error is all an agent gets to see.
    package init(_ error: any Error, during operation: String) {
        if let failure = Self(pairingFailure: error) {
            self = failure
        } else if let error = error as? CBATTError,
            [.insufficientAuthentication, .insufficientEncryption, .insufficientEncryptionKeySize].contains(error.code)
        {
            self = .pairingRequired(operation: operation, reason: error.localizedDescription)
        } else {
            let error = error as NSError
            self = .attributeError(operation: operation, code: error.code, message: error.localizedDescription)
        }
    }

    /// The peripheral no longer has this Mac's keys, or encrypting the link timed out (for
    /// instance because nobody confirmed the pairing dialog).
    package init?(pairingFailure error: (any Error)?) {
        guard let error = error as? CBError, [.peerRemovedPairingInformation, .encryptionTimedOut].contains(error.code) else {
            return nil
        }
        self = .pairingFailed(reason: error.localizedDescription)
    }
}

extension CBDescriptor {
    /// CoreBluetooth decodes some descriptors into Foundation objects (`NSString` for 0x2901,
    /// `NSNumber` for 0x2900, 0x2902 and 0x2903). Re-encode those to the bytes on the wire.
    var wireValue: Data {
        switch value {
        case let data as Data:
            return data
        case let string as String:
            return Data(string.utf8)
        case let number as NSNumber:
            return withUnsafeBytes(of: number.uint16Value.littleEndian) { Data($0) }
        default:
            return Data()
        }
    }
}
#endif
