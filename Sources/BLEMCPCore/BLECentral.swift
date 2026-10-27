public import Foundation

/// The adapter state, mirroring `CBManagerState`.
public enum CentralState: String, Hashable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff = "powered_off"
    case poweredOn = "powered_on"
}

/// Out-of-band events the backend reports between calls.
public enum CentralEvent: Sendable {
    case stateChanged(CentralState)
    /// Reported for links that were established; failed connection attempts surface as errors.
    case disconnected(PeripheralID, reason: String?)
    /// A notification or indication on a characteristic whose notifications are enabled.
    case valueUpdated(CharacteristicAddress, Data, receivedAt: Date)
}

public struct ConnectedPeripheral: Hashable, Sendable {
    public let id: PeripheralID
    public let name: String?

    public init(id: PeripheralID, name: String?) {
        self.id = id
        self.name = name
    }
}

/// A Bluetooth LE central the session drives. CoreBluetooth implements it in production,
/// a scripted fake in tests, and a BlueZ backend could on Linux.
///
/// Contract:
/// - Every async requirement must return promptly with `BLEError.cancelled` when its task is
///   cancelled. The session enforces deadlines by cancelling, so a backend that ignores
///   cancellation turns a timeout into a hang.
/// - Backends do not apply their own timeouts; the session owns them.
/// - `events` has a single consumer, the session.
public protocol BLECentral: Sendable {
    var events: AsyncStream<CentralEvent> { get }

    func state() async -> CentralState

    /// Returns once the adapter is powered on. Throws `.bluetoothUnavailable` straight away for
    /// states that will not change without the user (unsupported, unauthorized, powered off).
    func waitUntilPoweredOn() async throws(BLEError)

    /// Streams every advertisement until the stream's consumer stops iterating. Concurrent calls
    /// share one radio scan.
    func scan() async throws(BLEError) -> AsyncStream<Advertisement>

    func connect(_ peripheral: PeripheralID) async throws(BLEError) -> ConnectedPeripheral

    /// Starts tearing the link down (or abandons a pending connection attempt) and fails the
    /// peripheral's in-flight operations. Does not wait for the controller's confirmation and
    /// reports no `disconnected` event for it. Never throws: an absent link is the goal.
    func disconnect(_ peripheral: PeripheralID) async

    /// Discovers all services, characteristics and descriptors.
    func discoverServices(of peripheral: PeripheralID) async throws(BLEError) -> [GATTService]

    func read(_ characteristic: CharacteristicAddress) async throws(BLEError) -> Data

    func write(_ value: Data, to characteristic: CharacteristicAddress, mode: WriteMode) async throws(BLEError)

    func read(_ descriptor: DescriptorAddress) async throws(BLEError) -> Data

    func write(_ value: Data, to descriptor: DescriptorAddress) async throws(BLEError)

    func setNotifications(_ enabled: Bool, for characteristic: CharacteristicAddress) async throws(BLEError)

    func readRSSI(of peripheral: PeripheralID) async throws(BLEError) -> Int

    /// The largest value one write can carry, which depends on the negotiated ATT MTU.
    func maximumWriteLength(for peripheral: PeripheralID, mode: WriteMode) async throws(BLEError) -> Int
}
