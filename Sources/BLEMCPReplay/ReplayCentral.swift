public import BLEMCPCore
public import Foundation

/// A `BLECentral` that plays a recorded capture instead of using a radio, so an agent, a device
/// library or a test can run against a real device's behaviour with no device in reach.
///
/// The devices in the capture advertise and accept connections, and discovery returns their
/// recorded (or inferred) attribute tables. The rest follows the timeline of recorded requests:
///
/// - A **write** is matched to the next unused recorded write of the same bytes to the same
///   characteristic (in the same service, when the capture recorded services), and the notifications recorded after it are sent again with their recorded
///   delays (divided by `Options.speed`). A frame repeated after the recording ran out of copies
///   gets the replies of its latest earlier copy. A write the capture never made is accepted with
///   no reply and listed as a divergence in `report()`; with `Options.isStrict` it fails instead.
/// - A **subscription** is matched the same way, so a device that starts streaming when notified
///   streams again.
/// - A **read** returns the latest value recorded for that characteristic up to the session's
///   position in the timeline, so a read after a replayed write sees what the device answered then.
///
/// Recorded link losses are played as `disconnected` events. Nothing here suspends, so the
/// cancellation contract holds trivially.
public actor ReplayCentral: BLECentral {
    public struct Options: Hashable, Sendable {
        /// 1 plays replies at recorded pace, 2 twice as fast; 0 sends them without delay.
        public let speed: Double
        /// Fail writes the capture does not have next, instead of accepting them silently.
        public let isStrict: Bool

        public init(speed: Double = 1, isStrict: Bool = false) {
            self.speed = max(0, speed)
            self.isStrict = isStrict
        }
    }

    public nonisolated let events: AsyncStream<CentralEvent>
    public nonisolated let script: ReplayScript
    private let eventSink: AsyncStream<CentralEvent>.Continuation
    private let options: Options
    private let source: String?
    private let devices: [PeripheralID: ReplayScript.Device]

    private var connected: Set<PeripheralID> = []
    private var notifying: Set<CharacteristicAddress> = []
    private var scanners: [Int: AsyncStream<Advertisement>.Continuation] = [:]
    private var lastScanner = 0

    /// Requests matched so far; a matched request is not matched again while unused ones remain.
    private var used: Set<Int> = []
    /// One past the latest matched request: where the session is in the timeline.
    private var position = 0
    private var usedReads: Set<Int> = []
    private var lastReadValues: [ReadKey: Data] = [:]
    private var deliveries: [UInt64: (peripheral: PeripheralID, task: Task<Void, Never>)] = [:]
    private var lastDelivery: UInt64 = 0
    private var divergences: [BackendReport.Divergence] = []

    private static let divergenceCapacity = 64
    private static let defaultRSSI = -60
    private static let maximumWriteLength = 512

    private struct ReadKey: Hashable {
        let peripheral: PeripheralID
        let service: BLEUUID
        let characteristic: BLEUUID
        let descriptor: BLEUUID?

        init(_ address: CharacteristicAddress, descriptor: BLEUUID? = nil) {
            peripheral = address.peripheral
            service = address.service
            characteristic = address.characteristic
            self.descriptor = descriptor
        }

        func matches(_ read: ReplayScript.RecordedRead) -> Bool {
            read.peripheral == peripheral && read.characteristic == characteristic && read.descriptor == descriptor
                && (read.service == nil || read.service == service)
        }
    }

    public init(_ recording: CaptureRecording, options: Options = Options()) {
        let script = ReplayScript(recording)
        self.script = script
        self.options = options
        self.source = recording.source
        self.devices = Dictionary(script.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        (events, eventSink) = AsyncStream.makeStream(of: CentralEvent.self)
    }

    // MARK: BLECentral

    public func state() -> CentralState {
        .poweredOn
    }

    public func waitUntilPoweredOn() {}

    /// Every device advertises once when a scan starts, with everything its capture recorded.
    public func scan() -> AsyncStream<Advertisement> {
        lastScanner += 1
        let token = lastScanner
        let (stream, continuation) = AsyncStream.makeStream(of: Advertisement.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeScanner(token) }
        }
        scanners[token] = continuation
        for device in script.devices {
            continuation.yield(
                Advertisement(
                    peripheral: device.id, name: device.advertisedName, rssi: device.rssi ?? Self.defaultRSSI,
                    isConnectable: device.isConnectable, serviceUUIDs: device.advertisedServices,
                    manufacturerData: device.manufacturerData, serviceData: device.serviceData,
                    txPowerLevel: device.txPowerLevel))
        }
        return stream
    }

    private func removeScanner(_ token: Int) {
        scanners[token] = nil
    }

    public func connect(_ id: PeripheralID) throws(BLEError) -> ConnectedPeripheral {
        guard let device = devices[id] else { throw .unknownPeripheral(id) }
        connected.insert(id)
        return ConnectedPeripheral(id: id, name: device.name)
    }

    public func disconnect(_ id: PeripheralID) {
        guard connected.remove(id) != nil else { return }
        dropState(of: id)
    }

    public func discoverServices(of id: PeripheralID) throws(BLEError) -> [GATTService] {
        try requireConnected(id)
        return devices[id]?.services ?? []
    }

    public func read(_ characteristic: CharacteristicAddress) throws(BLEError) -> Data {
        try requireConnected(characteristic.peripheral)
        return recordedRead(ReadKey(characteristic))
    }

    public func write(_ value: Data, to characteristic: CharacteristicAddress, mode: WriteMode) throws(BLEError) {
        try requireConnected(characteristic.peripheral)
        let request = ReplayScript.Request.write(characteristic.characteristic, value)
        let peripheral = characteristic.peripheral
        if options.isStrict {
            let next = script.triggers.indices[min(position, script.triggers.count)...].first { index in
                !used.contains(index) && script.triggers[index].peripheral == peripheral && script.triggers[index].request.isWrite
            }
            guard let next, script.triggers[next].request == request, script.triggers[next].isIn(characteristic.service) else {
                let expected = next.map { "the next recorded write is \(describe(script.triggers[$0].request)) (line \(script.triggers[$0].line))" }
                    ?? "the capture has no writes left"
                let message = "Strict replay: \(describe(request)) is not what the capture does next; \(expected)."
                diverge(message)
                throw .backendFailure(message)
            }
            play(next)
            return
        }
        guard let index = match(request, at: characteristic) else {
            diverge("No recorded \(describe(request)); the write was accepted without a reply.")
            return
        }
        play(index)
    }

    public func read(_ descriptor: DescriptorAddress) throws(BLEError) -> Data {
        let characteristic = descriptor.characteristic
        try requireConnected(characteristic.peripheral)
        if descriptor.descriptor == GATTDescriptor.characteristicUserDescription,
            let text = devices[characteristic.peripheral]?.services
                .first(where: { $0.uuid == characteristic.service })?.characteristics
                .first(where: { $0.uuid == characteristic.characteristic })?.userDescription
        {
            return Data(text.utf8)
        }
        return recordedRead(ReadKey(characteristic, descriptor: descriptor.descriptor))
    }

    /// Accepted and forgotten: descriptor writes have no recorded answer to play.
    public func write(_ value: Data, to descriptor: DescriptorAddress) throws(BLEError) {
        try requireConnected(descriptor.characteristic.peripheral)
    }

    public func setNotifications(_ enabled: Bool, for characteristic: CharacteristicAddress) throws(BLEError) {
        try requireConnected(characteristic.peripheral)
        guard enabled else {
            notifying.remove(characteristic)
            return
        }
        notifying.insert(characteristic)
        if let index = match(.subscribe(characteristic.characteristic), at: characteristic) {
            play(index)
        }
    }

    public func readRSSI(of id: PeripheralID) throws(BLEError) -> Int {
        try requireConnected(id)
        return devices[id]?.rssi ?? Self.defaultRSSI
    }

    public func maximumWriteLength(for id: PeripheralID, mode: WriteMode) throws(BLEError) -> Int {
        try requireConnected(id)
        return Self.maximumWriteLength
    }

    /// `async` like the requirement: in async code Swift prefers an async overload, so a synchronous
    /// one would lose to the protocol extension's `nil` default.
    public func report() async -> BackendReport? {
        BackendReport(
            kind: "replay", source: source, matchedRequests: used.count, recordedRequests: script.triggers.count,
            divergences: divergences)
    }

    // MARK: Timeline

    /// The next unused recorded copy of `request` from the session's position on, or else the
    /// latest copy before it, so repeated frames keep getting answers.
    private func match(_ request: ReplayScript.Request, at address: CharacteristicAddress) -> Int? {
        let triggers = script.triggers
        let (peripheral, service) = (address.peripheral, address.service)
        for index in triggers.indices[min(position, triggers.count)...]
        where !used.contains(index) && triggers[index].peripheral == peripheral && triggers[index].request == request
            && triggers[index].isIn(service)
        {
            return index
        }
        for index in triggers.indices[..<min(position, triggers.count)].reversed()
        where triggers[index].peripheral == peripheral && triggers[index].request == request && triggers[index].isIn(service) {
            return index
        }
        return nil
    }

    /// Marks the request used, moves the position past it and sends its replies.
    private func play(_ index: Int) {
        used.insert(index)
        position = max(position, index + 1)
        let trigger = script.triggers[index]
        guard !trigger.replies.isEmpty else { return }

        lastDelivery += 1
        let token = lastDelivery
        let speed = options.speed
        let start = ContinuousClock.now
        let task = Task { [weak self] in
            for step in trigger.replies {
                if speed > 0, step.delay > 0 {
                    try? await Task.sleep(until: start + .seconds(step.delay / speed), clock: .continuous)
                }
                guard !Task.isCancelled else { return }
                await self?.deliver(step.reply, to: trigger.peripheral)
            }
            await self?.finishDelivery(token)
        }
        deliveries[token] = (trigger.peripheral, task)
    }

    private func deliver(_ reply: ReplayScript.Reply, to peripheral: PeripheralID) {
        guard connected.contains(peripheral) else { return }
        switch reply {
        case .notification(let characteristic, let value, let service):
            // Notifications go where the session subscribed, so they are never sent unasked.
            guard
                let address = notifying.first(where: {
                    $0.peripheral == peripheral && $0.characteristic == characteristic && (service == nil || $0.service == service)
                })
            else { return }
            eventSink.yield(.valueUpdated(address, value, receivedAt: .now))
        case .linkLoss(let reason):
            connected.remove(peripheral)
            dropState(of: peripheral)
            eventSink.yield(.disconnected(peripheral, reason: reason))
        }
    }

    private func finishDelivery(_ token: UInt64) {
        deliveries[token] = nil
    }

    private func dropState(of peripheral: PeripheralID) {
        notifying = notifying.filter { $0.peripheral != peripheral }
        for (token, delivery) in deliveries where delivery.peripheral == peripheral {
            delivery.task.cancel()
            deliveries[token] = nil
        }
    }

    /// The latest value recorded for `key` up to the session's position: reads recorded before a
    /// request that has not been replayed yet are not reached.
    private func recordedRead(_ key: ReadKey) -> Data {
        let reads = script.reads
        let matching = reads.indices.filter { key.matches(reads[$0]) }
        let reached = matching.filter { (reads[$0].afterTrigger ?? -1) < position }
        if let latest = reached.last(where: { !usedReads.contains($0) }) {
            usedReads.formUnion(reached.filter { $0 <= latest })
            lastReadValues[key] = reads[latest].value
            return reads[latest].value
        }
        if let value = lastReadValues[key] ?? matching.first.map({ reads[$0].value }) {
            lastReadValues[key] = value
            return value
        }
        let target = key.descriptor.map { "descriptor \($0) of \(key.characteristic)" } ?? "\(key.characteristic)"
        diverge("No recorded read of \(target); returned an empty value.")
        return Data()
    }

    private func requireConnected(_ id: PeripheralID) throws(BLEError) {
        guard connected.contains(id) else { throw .notConnected(id) }
    }

    private func diverge(_ message: String) {
        divergences.append(BackendReport.Divergence(at: .now, message: message))
        if divergences.count > Self.divergenceCapacity {
            divergences.removeFirst(divergences.count - Self.divergenceCapacity)
        }
    }

    private func describe(_ request: ReplayScript.Request) -> String {
        switch request {
        case .write(let characteristic, let value): "write of \(Hex.encode(value)) to \(characteristic)"
        case .subscribe(let characteristic): "subscription to \(characteristic)"
        }
    }
}

extension ReplayScript.Request {
    fileprivate var isWrite: Bool {
        if case .write = self { true } else { false }
    }
}

extension ReplayScript.Trigger {
    /// Whether the request was made in `service`; a capture without services matches any.
    fileprivate func isIn(_ service: BLEUUID) -> Bool {
        self.service == nil || self.service == service
    }
}
