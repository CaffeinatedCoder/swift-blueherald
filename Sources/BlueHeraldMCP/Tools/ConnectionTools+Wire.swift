import BlueHeraldCore
import Foundation

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
        server = Server(name: BlueHeraldServer.name, version: BlueHeraldServer.version, startedAt: status.startedAt)
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
