import Foundation

/// The session's connections and recent link losses, with the rules that need no actor: the
/// connection limit, which `connect` call owns an entry, and why a peripheral is not connected.
struct ConnectionTable: Sendable {
    private var entries: [PeripheralID: Connection] = [:]
    private(set) var linkLosses: [PeripheralID: LinkLoss] = [:]
    private var lastAttempt: UInt64 = 0

    static let linkLossCapacity = 64

    subscript(id: PeripheralID) -> Connection? {
        get { entries[id] }
        set { entries[id] = newValue }
    }

    var count: Int { entries.count }

    /// In a stable order, for listings.
    var ids: [PeripheralID] {
        entries.keys.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    var newestLinkLossesFirst: [LinkLoss] {
        linkLosses.values.sorted { $0.at > $1.at }
    }

    func ensureCapacity(limit: Int) throws(BLEError) {
        guard entries.count < limit else { throw .connectionLimitReached(limit: limit) }
    }

    /// Creates a connecting entry and returns the attempt that owns it.
    mutating func begin(_ id: PeripheralID, name: String?) -> UInt64 {
        lastAttempt += 1
        entries[id] = Connection(id: id, name: name, attempt: lastAttempt)
        return lastAttempt
    }

    func isOwned(_ id: PeripheralID, by attempt: UInt64) -> Bool {
        entries[id]?.attempt == attempt
    }

    /// Removes the entry only if `attempt` still owns it: after a disconnect it may belong to a
    /// newer attempt.
    mutating func abandon(_ id: PeripheralID, attempt: UInt64) {
        if isOwned(id, by: attempt) { entries[id] = nil }
    }

    /// The link is up; an earlier loss of it no longer applies.
    mutating func markConnected(_ id: PeripheralID, name: String?) {
        entries[id]?.markConnected(name: name)
        linkLosses[id] = nil
    }

    mutating func remove(_ id: PeripheralID) -> Connection? {
        entries.removeValue(forKey: id)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Removes the entry, and remembers the loss if the link had been established. Returns the
    /// removed entry.
    mutating func lose(_ id: PeripheralID, reason: String?, at date: Date = .now) -> Connection? {
        guard let connection = entries.removeValue(forKey: id) else { return nil }
        if connection.state == .connected {
            linkLosses[id] = LinkLoss(peripheral: id, name: connection.name, reason: reason, at: date)
            if linkLosses.count > Self.linkLossCapacity, let oldest = linkLosses.values.min(by: { $0.at < $1.at }) {
                linkLosses[oldest.peripheral] = nil
            }
        }
        return connection
    }

    func requireConnected(_ id: PeripheralID) throws(BLEError) -> Connection {
        guard let connection = entries[id], connection.state == .connected else {
            // Saying why beats a bare "not connected": the agent may never have seen the drop.
            if entries[id] == nil, let loss = linkLosses[id] {
                throw .linkLost(id, reason: loss.reason, at: loss.at)
            }
            throw .notConnected(id)
        }
        return connection
    }
}

struct Connection: Sendable {
    let id: PeripheralID
    /// Which `connect` call created the entry.
    let attempt: UInt64
    var name: String?
    var state = ConnectionState.connecting
    var connectedAt: Date?
    var services: [GATTService]?
    /// Whether `services` carries the 0x2901 names.
    var hasUserDescriptions = false
    var discoveryError: BLEError?

    init(id: PeripheralID, name: String?, attempt: UInt64) {
        self.id = id
        self.attempt = attempt
        self.name = name
    }

    mutating func markConnected(name: String?) {
        state = .connected
        connectedAt = .now
        self.name = name ?? self.name
    }

    func snapshot(subscriptions: [SubscriptionID], maximumWriteLength: WriteLengths?) -> ConnectionSnapshot {
        ConnectionSnapshot(
            id: id,
            name: name,
            state: state,
            connectedAt: connectedAt,
            services: services,
            discoveryError: discoveryError,
            subscriptions: subscriptions,
            maximumWriteLength: maximumWriteLength)
    }
}
