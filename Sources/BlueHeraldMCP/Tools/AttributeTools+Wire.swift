import BlueHeraldCore
import Foundation

struct ValueReport: Encodable {
    let peripheralId: String
    let serviceUuid: String
    let characteristicUuid: String
    let characteristicName: String?
    /// The device's own 0x2901 name for the characteristic, as discovery reported it.
    let characteristicDescription: String?
    let descriptorUuid: String?
    let descriptorName: String?
    let value: Bytes
    let readAt: Date

    init(_ reading: CharacteristicValue) {
        peripheralId = reading.address.peripheral.description
        serviceUuid = reading.address.service.description
        characteristicUuid = reading.address.characteristic.description
        characteristicName = AssignedNumbers.name(for: reading.address.characteristic)
        characteristicDescription = reading.userDescription
        descriptorUuid = nil
        descriptorName = nil
        value = Bytes(reading.value)
        readAt = reading.readAt
    }

    init(_ reading: DescriptorValue) {
        let characteristic = reading.address.characteristic
        peripheralId = characteristic.peripheral.description
        serviceUuid = characteristic.service.description
        characteristicUuid = characteristic.characteristic.description
        characteristicName = AssignedNumbers.name(for: characteristic.characteristic)
        characteristicDescription = nil
        descriptorUuid = reading.address.descriptor.description
        descriptorName = AssignedNumbers.name(for: reading.address.descriptor)
        value = Bytes(reading.value)
        readAt = reading.readAt
    }
}

struct TransactReport: Encodable {
    struct Reply: Encodable {
        let serviceUuid: String
        let characteristicUuid: String
        let seq: UInt64
        let receivedAt: Date
        let latencyMs: Int?
        let value: Bytes
    }

    let peripheralId: String
    let serviceUuid: String
    let characteristicUuid: String
    let bytesWritten: Int
    let mode: String?
    let reply: Reply?
    /// Notifications on the reply characteristic after the write that did not match; still buffered.
    let unmatched: Int
    let subscriptionId: String
    let note: String?

    init(_ transaction: Transaction, prefix: Data) {
        let write = transaction.write
        peripheralId = write.address.peripheral.description
        serviceUuid = write.address.service.description
        characteristicUuid = write.address.characteristic.description
        bytesWritten = write.byteCount
        mode = write.mode?.rawValue
        reply = transaction.reply.map {
            Reply(
                serviceUuid: $0.address.service.description,
                characteristicUuid: $0.address.characteristic.description,
                seq: $0.sequence,
                receivedAt: $0.receivedAt,
                latencyMs: transaction.latency.map { Int(($0 / .milliseconds(1)).rounded()) },
                value: Bytes($0.value))
        }
        unmatched = transaction.unmatched
        subscriptionId = transaction.subscription.id.description
        let others =
            transaction.unmatched == 0
            ? ""
            : transaction.unmatched == 1
                ? " 1 other notification arrived and stays readable with ble_notifications."
                : " \(transaction.unmatched) other notifications arrived and stay readable with ble_notifications."
        if transaction.reply == nil {
            let characteristic = transaction.subscription.address.characteristic
            let matching = prefix.isEmpty ? "" : " starting with \(Hex.encode(prefix))"
            let waited = Int((transaction.timeout / .milliseconds(1)).rounded())
            note = "The frame was written, but no reply on \(characteristic)\(matching) arrived within \(waited) ms." + others
        } else {
            note = others.isEmpty ? nil : String(others.dropFirst())
        }
    }
}

struct WriteReport: Encodable {
    let peripheralId: String
    let serviceUuid: String
    let characteristicUuid: String
    let descriptorUuid: String?
    let bytesWritten: Int
    let mode: String?

    init(_ receipt: WriteReceipt) {
        peripheralId = receipt.address.peripheral.description
        serviceUuid = receipt.address.service.description
        characteristicUuid = receipt.address.characteristic.description
        descriptorUuid = receipt.descriptor?.description
        bytesWritten = receipt.byteCount
        mode = receipt.mode?.rawValue
    }
}
