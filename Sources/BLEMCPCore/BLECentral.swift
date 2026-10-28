public import Foundation

/// The adapter state, mirroring `CBManagerState`.
public enum CentralState: String, Hashable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff = "powered_off"
    case poweredOn = "powered_on"
    /// Not yet ready because macOS is asking whether this process may use Bluetooth, which
    /// needs a person to answer.
    case awaitingPermission = "awaiting_permission"

    /// Not ready yet, but expected to become ready without anyone stepping in.
    public var isSettling: Bool {
        self == .unknown || self == .resetting
    }
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

    /// - Parameter name: The GAP name, cleaned with `DeviceText`.
    public init(id: PeripheralID, name: String?) {
        self.id = id
        self.name = DeviceText.clean(name)
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

    /// What a backend that is not a radio wants `ble_status` to show; `nil` for a real adapter.
    func report() async -> BackendReport?
}

extension BLECentral {
    public func report() async -> BackendReport? { nil }
}

/// The state of a simulated backend, such as a replay: where its script came from, how far the
/// session's calls have followed it, and where they left it.
public struct BackendReport: Hashable, Sendable {
    public struct Divergence: Hashable, Sendable {
        public let at: Date
        public let message: String

        public init(at: Date, message: String) {
            self.at = at
            self.message = message
        }
    }

    /// What the backend is, e.g. `replay`.
    public let kind: String
    /// The file it plays, if any.
    public let source: String?
    /// Recorded requests (writes and subscriptions) the session's calls have matched.
    public let matchedRequests: Int
    public let recordedRequests: Int
    /// Calls the script had no recorded answer for, oldest first.
    public let divergences: [Divergence]

    public init(kind: String, source: String?, matchedRequests: Int, recordedRequests: Int, divergences: [Divergence]) {
        self.kind = kind
        self.source = source
        self.matchedRequests = matchedRequests
        self.recordedRequests = recordedRequests
        self.divergences = divergences
    }
}
