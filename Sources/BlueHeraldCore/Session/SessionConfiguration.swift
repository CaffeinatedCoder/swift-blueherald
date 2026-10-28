public import Foundation

/// Which writes the session performs. Read-only unless explicitly enabled.
///
/// Rules, in order:
/// 1. Nothing is written unless `isEnabled`.
/// 2. A characteristic on the `denylist` is never written.
/// 3. A characteristic with entries in `allowedValues` accepts exactly those frames and nothing else.
/// 4. Once any allowlist is configured, only what it lists is writable; with none, every
///    characteristic is. So a value allowlist on its own already locks all other characteristics.
///
/// Descriptor writes are checked against the characteristic that owns the descriptor, and are
/// refused on frame-restricted characteristics, since only the listed frames were permitted there.
public struct WritePolicy: Hashable, Sendable {
    public let isEnabled: Bool
    /// Characteristics whose every value may be written.
    public let allowlist: Set<BLEUUID>
    /// Characteristics that are never written, whatever the allowlists say.
    public let denylist: Set<BLEUUID>
    /// Characteristics restricted to exact frames.
    public let allowedValues: [BLEUUID: Set<Data>]

    public init(
        isEnabled: Bool,
        allowlist: Set<BLEUUID> = [],
        denylist: Set<BLEUUID> = [],
        allowedValues: [BLEUUID: Set<Data>] = [:]
    ) {
        self.isEnabled = isEnabled
        self.allowlist = allowlist
        self.denylist = denylist
        self.allowedValues = allowedValues
    }

    public static let readOnly = WritePolicy(isEnabled: false)

    private var isRestricted: Bool {
        !allowlist.isEmpty || !allowedValues.isEmpty
    }

    /// Throws unless `value` may be written to `characteristic`.
    public func checkWrite(_ value: Data, to characteristic: BLEUUID) throws(BLEError) {
        guard isEnabled else { throw .writesDisabled }
        guard !denylist.contains(characteristic) else { throw .writeDenied(characteristic) }
        if let frames = allowedValues[characteristic] {
            guard frames.contains(value) else {
                throw .writeValueNotAllowed(characteristic, value: value, allowed: frames.sorted { $0.lexicographicallyPrecedes($1) })
            }
            return
        }
        guard !isRestricted || allowlist.contains(characteristic) else { throw .writeNotAllowed(characteristic) }
    }

    /// Throws unless descriptors of `characteristic` may be written.
    public func checkDescriptorWrite(on characteristic: BLEUUID) throws(BLEError) {
        guard isEnabled else { throw .writesDisabled }
        guard !denylist.contains(characteristic) else { throw .writeDenied(characteristic) }
        guard allowedValues[characteristic] == nil, !isRestricted || allowlist.contains(characteristic) else {
            throw .writeNotAllowed(characteristic)
        }
    }
}

public struct SessionLimits: Hashable, Sendable {
    public let maxConnections: Int
    public let maxSubscriptions: Int
    public let maxScans: Int
    /// Notifications kept per subscription; the oldest are dropped first.
    public let notificationBufferCapacity: Int
    /// Distinct peripherals one scan tracks before it starts ignoring new ones.
    public let maxPeripheralsPerScan: Int

    public init(
        maxConnections: Int = 4,
        maxSubscriptions: Int = 32,
        maxScans: Int = 4,
        notificationBufferCapacity: Int = 1024,
        maxPeripheralsPerScan: Int = 2048
    ) {
        self.maxConnections = maxConnections
        self.maxSubscriptions = maxSubscriptions
        self.maxScans = maxScans
        self.notificationBufferCapacity = notificationBufferCapacity
        self.maxPeripheralsPerScan = maxPeripheralsPerScan
    }
}

public struct SessionTimeouts: Hashable, Sendable {
    /// Waiting for the adapter to power on, which includes the first-launch permission prompt.
    public let poweredOn: Duration
    public let connect: Duration
    /// Full service, characteristic and descriptor discovery.
    public let discovery: Duration
    /// A single read, write, subscription change or RSSI read.
    public let operation: Duration
    /// How long a status request waits for someone to answer a Bluetooth permission prompt
    /// before reporting it. Short, because a person has to act.
    public let permissionPrompt: Duration

    public init(
        poweredOn: Duration = .seconds(10),
        connect: Duration = .seconds(15),
        discovery: Duration = .seconds(30),
        operation: Duration = .seconds(10),
        permissionPrompt: Duration = .seconds(2)
    ) {
        self.poweredOn = poweredOn
        self.connect = connect
        self.discovery = discovery
        self.operation = operation
        self.permissionPrompt = permissionPrompt
    }
}

public struct SessionConfiguration: Hashable, Sendable {
    public let writePolicy: WritePolicy
    public let limits: SessionLimits
    public let timeouts: SessionTimeouts

    public init(
        writePolicy: WritePolicy = .readOnly,
        limits: SessionLimits = SessionLimits(),
        timeouts: SessionTimeouts = SessionTimeouts()
    ) {
        self.writePolicy = writePolicy
        self.limits = limits
        self.timeouts = timeouts
    }
}
