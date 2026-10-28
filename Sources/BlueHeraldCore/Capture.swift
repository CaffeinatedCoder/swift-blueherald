public import Foundation

/// One thing the session did or saw on the radio, for a capture to record.
///
/// Captures exist to turn an agent's probing session into a replayable fixture, so they hold
/// what crossed the air (writes, notifications, reads) plus the context needed to read them:
/// links coming and going, notifications being switched, and markers the agent placed.
public struct CaptureEvent: Sendable {
    public enum Kind: Hashable, Sendable {
        /// What scans last saw of a peripheral, recorded as the session connects to it so a replay
        /// can advertise the device under test (and only that device).
        case advertisement(DiscoveredPeripheral)
        case connected(PeripheralID, name: String?)
        /// The attribute table discovery found, with the 0x2901 names when they were read.
        case discovered(PeripheralID, [GATTService])
        case disconnected(PeripheralID, reason: String?)
        case notificationsEnabled(CharacteristicAddress, NotificationMode)
        case notificationsDisabled(CharacteristicAddress)
        /// Recorded before the value goes out, so a capture keeps requests ahead of their replies.
        case write(CharacteristicAddress, Data, WriteMode)
        case descriptorWrite(DescriptorAddress, Data)
        /// A write recorded above that the peripheral or the link then failed.
        case writeFailed(CharacteristicAddress, descriptor: BLEUUID?, BLEError)
        case notification(CharacteristicAddress, Data)
        case read(CharacteristicAddress, Data)
        case descriptorRead(DescriptorAddress, Data)
        /// A label the agent placed, typically before the next step of an experiment.
        case marker(note: String, fields: [String: CaptureValue])
    }

    public let time: Date
    public let kind: Kind

    public init(time: Date, kind: Kind) {
        self.time = time
        self.kind = kind
    }
}

/// A scalar a marker can carry.
public enum CaptureValue: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
}

/// Receives capture events in the order they happened.
///
/// The session calls `record` on its own executor, so implementations hand the event off (to a
/// queue, say) instead of doing I/O in the call.
public protocol CaptureSink: Sendable {
    /// Where the capture goes, for a status report.
    var destination: String { get }

    func record(_ event: CaptureEvent)
}
