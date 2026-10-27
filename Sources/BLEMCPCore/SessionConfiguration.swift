/// Which writes the session performs. Read-only unless explicitly enabled.
public struct WritePolicy: Hashable, Sendable {
    public let isEnabled: Bool
    /// Characteristic UUIDs that may be written. Empty means every writable characteristic.
    /// Descriptor writes are checked against the UUID of the characteristic that owns them.
    public let allowlist: Set<BLEUUID>

    public init(isEnabled: Bool, allowlist: Set<BLEUUID> = []) {
        self.isEnabled = isEnabled
        self.allowlist = allowlist
    }

    public static let readOnly = WritePolicy(isEnabled: false)

    public func permits(_ characteristic: BLEUUID) -> Bool {
        isEnabled && (allowlist.isEmpty || allowlist.contains(characteristic))
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

    public init(
        poweredOn: Duration = .seconds(10),
        connect: Duration = .seconds(15),
        discovery: Duration = .seconds(30),
        operation: Duration = .seconds(10)
    ) {
        self.poweredOn = poweredOn
        self.connect = connect
        self.discovery = discovery
        self.operation = operation
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
