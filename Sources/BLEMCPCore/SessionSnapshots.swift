public import Foundation

// Immutable views of session state. Everything the session hands out is one of these values,
// so callers never share mutable state with the actor.

public struct ScanSnapshot: Sendable {
    public let id: ScanID
    public let filter: ScanFilter
    public let isActive: Bool
    public let startedAt: Date
    public let endedAt: Date?
    /// Matching peripherals, strongest signal first, truncated to the requested count.
    public let peripherals: [DiscoveredPeripheral]
    /// Matching peripherals before truncation.
    public let matchedCount: Int
    /// Every distinct peripheral the scan heard, matching or not.
    public let seenCount: Int
    /// New peripherals ignored after the per-scan table filled up.
    public let ignoredCount: Int
}

public enum ConnectionState: String, Hashable, Sendable {
    case connecting
    case connected
}

public struct WriteLengths: Hashable, Sendable {
    public let withResponse: Int
    public let withoutResponse: Int

    public init(withResponse: Int, withoutResponse: Int) {
        self.withResponse = withResponse
        self.withoutResponse = withoutResponse
    }
}

public struct ConnectionSnapshot: Sendable {
    public let id: PeripheralID
    public let name: String?
    public let state: ConnectionState
    public let connectedAt: Date?
    /// `nil` until discovery has run.
    public let services: [GATTService]?
    public let discoveryError: BLEError?
    public let subscriptions: [SubscriptionID]
    public let maximumWriteLength: WriteLengths?
}

public enum SubscriptionState: Hashable, Sendable {
    /// Notifications are being enabled on the peripheral.
    case pending
    case active
    /// No longer receiving; buffered notifications can still be read.
    case closed(reason: String)
}

public struct SubscriptionSnapshot: Hashable, Sendable {
    public let id: SubscriptionID
    public let address: CharacteristicAddress
    public let mode: NotificationMode
    public let state: SubscriptionState
    public let createdAt: Date
    public let receivedCount: Int
    public let droppedCount: Int
    public let bufferedCount: Int
}

public struct ValueNotification: Hashable, Sendable {
    public let subscription: SubscriptionID
    /// Session-wide arrival order, so notifications from several subscriptions interleave correctly.
    public let sequence: UInt64
    public let address: CharacteristicAddress
    public let value: Data
    public let receivedAt: Date
}

public struct NotificationBatch: Sendable {
    public let notifications: [ValueNotification]
    /// Notifications still buffered in the subscriptions that were read.
    public let remaining: Int
    /// Notifications the buffers overwrote since the previous read of these subscriptions.
    public let dropped: Int
    /// The state of each subscription read, after the read.
    public let subscriptions: [SubscriptionSnapshot]
}

public struct CharacteristicValue: Sendable {
    public let address: CharacteristicAddress
    public let properties: CharacteristicProperties
    public let value: Data
    public let readAt: Date
}

public struct DescriptorValue: Sendable {
    public let address: DescriptorAddress
    public let value: Data
    public let readAt: Date
}

public struct WriteReceipt: Sendable {
    public let address: CharacteristicAddress
    /// Set for descriptor writes.
    public let descriptor: BLEUUID?
    public let byteCount: Int
    /// `nil` for descriptor writes, which are always acknowledged.
    public let mode: WriteMode?
}

public struct SessionStatus: Sendable {
    public let adapterState: CentralState
    public let configuration: SessionConfiguration
    public let activeScans: [ScanID]
    public let connections: [ConnectionSnapshot]
    public let subscriptions: [SubscriptionSnapshot]
}

/// Things that happen without a request, for the server to forward to the client.
public enum SessionEvent: Sendable {
    case adapterStateChanged(CentralState)
    case peripheralDisconnected(PeripheralID, name: String?, reason: String?)
}
