import Foundation

/// The session's scans and everything they have seen, with the rules that need no actor: id
/// allocation, the concurrent-scan limit, the cap on peripherals per scan and on the merged
/// `seen` cache, and how many finished scans stay readable.
struct ScanRegistry: Sendable {
    private(set) var scans: [ScanID: ActiveScan] = [:]
    /// Everything scans have seen of each peripheral, merged: names for connections, and the
    /// advertisement a capture records when the session connects.
    private(set) var seen: [PeripheralID: DiscoveredPeripheral] = [:]
    private var lastID = 0

    static let seenCapacity = 4096
    static let finishedCapacity = 8

    var activeIDs: [ScanID] {
        scans.values.filter(\.isActive).map(\.id).sorted()
    }

    func isActive(_ id: ScanID) -> Bool {
        scans[id]?.isActive == true
    }

    func ensureCapacity(limit: Int) throws(BLEError) {
        guard scans.values.count(where: \.isActive) < limit else { throw .scanLimitReached(limit: limit) }
    }

    /// The id the next `insert` must use; callers need it before the scan's tasks exist.
    mutating func nextID() -> ScanID {
        lastID += 1
        return ScanID(rawValue: lastID)
    }

    /// Adds the scan and forgets the oldest finished scans beyond `finishedCapacity`.
    mutating func insert(_ scan: ActiveScan) {
        scans[scan.id] = scan
        let finished = scans.values.filter { !$0.isActive }.sorted { $0.id < $1.id }
        for old in finished.dropLast(Self.finishedCapacity) {
            scans[old.id] = nil
        }
    }

    /// Merges the advertisement into `seen` and into the scan, and finishes the scan once it
    /// reaches its `stopAfter` target.
    mutating func record(_ advertisement: Advertisement, in id: ScanID, limit: Int) {
        let peripheral = advertisement.peripheral
        if seen[peripheral] != nil {
            seen[peripheral]?.merge(advertisement)
        } else if seen.count < Self.seenCapacity {
            seen[peripheral] = DiscoveredPeripheral(advertisement)
        }
        if scans[id]?.record(advertisement, limit: limit) == true {
            scans[id]?.finish()
        }
    }

    mutating func finish(_ id: ScanID) {
        scans[id]?.finish()
    }

    /// Finishes every scan; finished scans stay readable.
    mutating func finishAll() {
        for id in scans.keys {
            scans[id]?.finish()
        }
    }

    /// Finishes every scan and forgets them.
    mutating func closeAll() {
        finishAll()
        scans.removeAll()
    }

    func snapshot(_ id: ScanID, maxResults: Int) throws(BLEError) -> ScanSnapshot {
        guard let scan = scans[id] else { throw .scanNotFound(id) }
        return scan.snapshot(maxResults: maxResults)
    }

    /// Finishes the scan if it is running, forgets it and returns its final results.
    mutating func stop(_ id: ScanID, maxResults: Int) throws(BLEError) -> ScanSnapshot {
        guard var scan = scans.removeValue(forKey: id) else { throw .scanNotFound(id) }
        scan.finish()
        return scan.snapshot(maxResults: maxResults)
    }

    /// Queues `continuation` to be resumed when the scan finishes. Returns `false`, leaving the
    /// caller to resume it, when the scan is not running.
    mutating func resumeWhenFinished(_ id: ScanID, _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        guard isActive(id) else { return false }
        scans[id]?.completionWaiters.append(continuation)
        return true
    }
}

struct ActiveScan: Sendable {
    let id: ScanID
    let filter: ScanFilter
    let stopAfter: Int?
    let startedAt = Date.now
    var endedAt: Date?
    var peripherals: [PeripheralID: DiscoveredPeripheral] = [:]
    var matched: Set<PeripheralID> = []
    var ignored = 0
    var consumer: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: ScanID, filter: ScanFilter, stopAfter: Int?) {
        self.id = id
        self.filter = filter
        self.stopAfter = stopAfter
    }

    var isActive: Bool { endedAt == nil }

    /// Merges the advertisement; returns whether the scan reached its `stopAfter` target.
    mutating func record(_ advertisement: Advertisement, limit: Int) -> Bool {
        guard isActive else { return false }
        let id = advertisement.peripheral
        if peripherals[id]?.merge(advertisement) == nil {
            guard peripherals.count < limit else {
                ignored += 1
                return false
            }
            peripherals[id] = DiscoveredPeripheral(advertisement)
        }
        if let peripheral = peripherals[id], filter.matches(peripheral) {
            matched.insert(id)
        }
        return stopAfter.map { matched.count >= $0 } ?? false
    }

    mutating func finish() {
        guard isActive else { return }
        endedAt = .now
        consumer?.cancel()
        timer?.cancel()
        consumer = nil
        timer = nil
        completionWaiters.forEach { $0.resume() }
        completionWaiters.removeAll()
    }

    func snapshot(maxResults: Int) -> ScanSnapshot {
        let matching = peripherals.values
            .filter(filter.matches)
            .sorted { ($0.rssi ?? .min, $1.id.uuid.uuidString) > ($1.rssi ?? .min, $0.id.uuid.uuidString) }
        return ScanSnapshot(
            id: id,
            filter: filter,
            isActive: isActive,
            startedAt: startedAt,
            endedAt: endedAt,
            peripherals: Array(matching.prefix(max(0, maxResults))),
            matchedCount: matching.count,
            seenCount: peripherals.count,
            ignoredCount: ignored)
    }
}
