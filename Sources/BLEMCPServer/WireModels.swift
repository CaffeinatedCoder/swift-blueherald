import BLEMCPCore
import Foundation

// The JSON contract agents see. Kept separate from the core model so the wire format stays
// stable while the domain evolves. Property names are camelCase here and snake_case on the wire;
// optional properties are omitted when nil.

struct UUIDReference: Encodable {
    let uuid: String
    let name: String?

    init(_ uuid: BLEUUID) {
        self.uuid = uuid.description
        self.name = AssignedNumbers.name(for: uuid)
    }
}

struct Bytes: Encodable {
    let hex: String
    /// Present only when the bytes read as printable UTF-8 text of at least two characters,
    /// ignoring trailing NUL padding. Shorter values are nearly always numbers: a battery level
    /// of 89 would read "Y", and a little-endian 36 padded with a NUL would read "$".
    /// Cut to `textLimit` characters; `hex` always holds the whole value.
    let utf8: String?
    /// Set when `utf8` was cut.
    let utf8Truncated: Bool?
    let length: Int

    static let textLimit = 128

    init(_ data: Data) {
        hex = Hex.encode(data)
        length = data.count
        let text = Self.printableText(data)
        if let text, text.count > Self.textLimit {
            utf8 = String(text.prefix(Self.textLimit))
            utf8Truncated = true
        } else {
            utf8 = text
            utf8Truncated = nil
        }
    }

    private static func printableText(_ data: Data) -> String? {
        let trimmed = data.reversed().drop { $0 == 0 }.reversed()
        guard !trimmed.isEmpty, let text = String(validating: trimmed, as: UTF8.self) else { return nil }
        let isPrintable = text.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.generalCategory.isControl || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }
        let looksLikeText = text.count >= 2 && text.contains { !$0.isWhitespace }
        return isPrintable && looksLikeText ? text : nil
    }
}

extension Unicode.GeneralCategory {
    fileprivate var isControl: Bool {
        switch self {
        case .control, .format, .unassigned, .privateUse, .surrogate: true
        default: false
        }
    }
}

struct ErrorSummary: Encodable {
    let code: String
    let message: String

    init(_ error: BLEError) {
        code = error.code
        message = error.message
    }
}

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
        name = peripheral.name
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

struct CharacteristicSummary: Encodable {
    let uuid: String
    /// The Bluetooth SIG name, for assigned UUIDs.
    let name: String?
    /// The device's own name, from its 0x2901 descriptor.
    let description: String?
    let properties: [String]
    let descriptors: [UUIDReference]

    init(_ characteristic: GATTCharacteristic) {
        uuid = characteristic.uuid.description
        name = AssignedNumbers.name(for: characteristic.uuid)
        description = characteristic.userDescription
        properties = characteristic.properties.names
        descriptors = characteristic.descriptors.map { UUIDReference($0.uuid) }
    }
}

struct ServiceSummary: Encodable {
    let uuid: String
    let name: String?
    let primary: Bool
    let characteristics: [CharacteristicSummary]

    init(_ service: GATTService) {
        uuid = service.uuid.description
        name = AssignedNumbers.name(for: service.uuid)
        primary = service.isPrimary
        characteristics = service.characteristics.map(CharacteristicSummary.init)
    }
}

struct WriteLimits: Encodable {
    let withResponse: Int
    let withoutResponse: Int
}

struct ConnectionReport: Encodable {
    let peripheralId: String
    let name: String?
    let state: String
    let connectedAt: Date?
    let maxWriteLength: WriteLimits?
    let subscriptions: [String]
    let services: [ServiceSummary]?
    let discoveryError: ErrorSummary?

    init(_ snapshot: ConnectionSnapshot, includeServices: Bool = true) {
        peripheralId = snapshot.id.description
        name = snapshot.name
        state = snapshot.state.rawValue
        connectedAt = snapshot.connectedAt
        maxWriteLength = snapshot.maximumWriteLength.map {
            WriteLimits(withResponse: $0.withResponse, withoutResponse: $0.withoutResponse)
        }
        subscriptions = snapshot.subscriptions.map(\.description)
        services = includeServices ? snapshot.services?.map(ServiceSummary.init) : nil
        discoveryError = snapshot.discoveryError.map(ErrorSummary.init)
    }
}

struct DisconnectReport: Encodable {
    let peripheralId: String
    let disconnected: Bool
    let wasConnected: Bool
}

struct ServicesReport: Encodable {
    let peripheralId: String
    let services: [ServiceSummary]
}

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

struct SubscriptionReport: Encodable {
    let subscriptionId: String
    let peripheralId: String
    let serviceUuid: String
    let characteristicUuid: String
    let characteristicName: String?
    let characteristicDescription: String?
    let mode: String
    let state: String
    let closedReason: String?
    let received: Int
    let dropped: Int
    let buffered: Int
    let createdAt: Date

    init(_ snapshot: SubscriptionSnapshot) {
        subscriptionId = snapshot.id.description
        peripheralId = snapshot.address.peripheral.description
        serviceUuid = snapshot.address.service.description
        characteristicUuid = snapshot.address.characteristic.description
        characteristicName = AssignedNumbers.name(for: snapshot.address.characteristic)
        characteristicDescription = snapshot.userDescription
        mode = snapshot.mode.rawValue
        switch snapshot.state {
        case .pending:
            state = "pending"
            closedReason = nil
        case .active:
            state = "active"
            closedReason = nil
        case .closed(let reason):
            state = "closed"
            closedReason = reason
        }
        received = snapshot.receivedCount
        dropped = snapshot.droppedCount
        buffered = snapshot.bufferedCount
        createdAt = snapshot.createdAt
    }
}

struct NotificationEntry: Encodable {
    let subscriptionId: String
    let seq: UInt64
    let receivedAt: Date
    let value: Bytes

    init(_ notification: ValueNotification) {
        subscriptionId = notification.subscription.description
        seq = notification.sequence
        receivedAt = notification.receivedAt
        value = Bytes(notification.value)
    }
}

struct NotificationsReport: Encodable {
    let notifications: [NotificationEntry]
    let remaining: Int
    let dropped: Int
    let subscriptions: [SubscriptionReport]
    let note: String?

    init(_ batch: NotificationBatch) {
        notifications = batch.notifications.map(NotificationEntry.init)
        remaining = batch.remaining
        dropped = batch.dropped
        subscriptions = batch.subscriptions.map(SubscriptionReport.init)
        note =
            switch batch.wait {
            case .none:
                nil
            case .skipped:
                "Returned without waiting: no open subscription can deliver notifications. Call ble_subscribe first."
            case .nothingArrived(let waited)
            where batch.subscriptions.allSatisfy({ if case .closed = $0.state { true } else { false } }):
                "Waited \(Int((waited / .milliseconds(1)).rounded())) ms; the subscription closed meanwhile (see closed_reason)."
            case .nothingArrived(let waited):
                "Waited \(Int((waited / .milliseconds(1)).rounded())) ms and nothing arrived."
            }
    }
}

struct RSSIReport: Encodable {
    let peripheralId: String
    let rssi: Int
}

struct StatusReport: Encodable {
    struct Server: Encodable {
        let name: String
        let version: String
        /// Connections and subscriptions do not survive a restart; this tells an agent one happened.
        let startedAt: Date
    }

    struct Policy: Encodable {
        struct Frames: Encodable {
            let characteristic: String
            let frames: [String]
        }

        let writesEnabled: Bool
        let writeAllowlist: [String]?
        let writeValueAllowlist: [Frames]?
        let writeDenylist: [String]?

        init(_ policy: WritePolicy) {
            writesEnabled = policy.isEnabled
            writeAllowlist = policy.allowlist.isEmpty ? nil : policy.allowlist.sorted().map(\.description)
            writeValueAllowlist =
                policy.allowedValues.isEmpty
                ? nil
                : policy.allowedValues.sorted { $0.key < $1.key }.map { characteristic, frames in
                    Frames(characteristic: characteristic.description, frames: frames.map { Hex.encode($0) }.sorted())
                }
            writeDenylist = policy.denylist.isEmpty ? nil : policy.denylist.sorted().map(\.description)
        }
    }

    struct LinkLossReport: Encodable {
        let peripheralId: String
        let name: String?
        let reason: String?
        let at: Date
    }

    struct BackendReportWire: Encodable {
        struct Divergence: Encodable {
            let at: Date
            let message: String
        }

        let kind: String
        let source: String?
        let matchedRequests: Int
        let recordedRequests: Int
        let divergences: [Divergence]

        init(_ report: BackendReport) {
            kind = report.kind
            source = report.source
            matchedRequests = report.matchedRequests
            recordedRequests = report.recordedRequests
            divergences = report.divergences.map { Divergence(at: $0.at, message: $0.message) }
        }
    }

    struct Limits: Encodable {
        let maxConnections: Int
        let maxSubscriptions: Int
        let maxScans: Int
        let notificationBuffer: Int
    }

    let server: Server
    /// The JSONL capture file, when the server records one.
    let capturePath: String?
    let adapterState: String
    let hint: String?
    let policy: Policy
    let limits: Limits
    let activeScans: [String]
    let connections: [ConnectionReport]
    let subscriptions: [SubscriptionReport]
    /// Links a peripheral or the adapter dropped since, newest first; cleared on reconnect.
    let linkLosses: [LinkLossReport]
    /// Only for a simulated backend: a replay says which capture it plays and how far it got.
    let backend: BackendReportWire?

    init(_ status: SessionStatus) {
        let configuration = status.configuration
        server = Server(name: BLEMCPServer.name, version: BLEMCPServer.version, startedAt: status.startedAt)
        capturePath = status.captureDestination
        adapterState = status.adapterState.rawValue
        hint = status.adapterState == .poweredOn ? nil : BLEError.bluetoothUnavailable(status.adapterState).hint
        policy = Policy(configuration.writePolicy)
        limits = Limits(
            maxConnections: configuration.limits.maxConnections,
            maxSubscriptions: configuration.limits.maxSubscriptions,
            maxScans: configuration.limits.maxScans,
            notificationBuffer: configuration.limits.notificationBufferCapacity)
        activeScans = status.activeScans.map(\.description)
        connections = status.connections.map { ConnectionReport($0, includeServices: false) }
        subscriptions = status.subscriptions.map(SubscriptionReport.init)
        linkLosses = status.linkLosses.map {
            LinkLossReport(peripheralId: $0.peripheral.description, name: $0.name, reason: $0.reason, at: $0.at)
        }
        backend = status.backend.map(BackendReportWire.init)
    }
}
