public import BlueHeraldCore
public import Foundation

/// A scripted `BLECentral` for tests. It honours the same cancellation contract as the real
/// backend, so session timeouts can be tested by making an operation hang.
public actor FakeCentral: BLECentral {
    public struct Device: Sendable {
        public let id: PeripheralID
        public var name: String?
        public var rssi: Int
        public var advertisedServices: [BLEUUID]
        public var manufacturerData: Data?
        public var services: [GATTService]
        /// Characteristic values by characteristic UUID.
        public var values: [BLEUUID: Data]
        /// Descriptor values by descriptor UUID.
        public var descriptorValues: [BLEUUID: Data]
        /// 0x2901 values by characteristic UUID.
        public var userDescriptions: [BLEUUID: String]

        public init(
            id: PeripheralID = PeripheralID(UUID()),
            name: String? = nil,
            rssi: Int = -60,
            advertisedServices: [BLEUUID] = [],
            manufacturerData: Data? = nil,
            services: [GATTService] = [],
            values: [BLEUUID: Data] = [:],
            descriptorValues: [BLEUUID: Data] = [:],
            userDescriptions: [BLEUUID: String] = [:]
        ) {
            self.id = id
            self.name = name
            self.rssi = rssi
            self.advertisedServices = advertisedServices
            self.manufacturerData = manufacturerData
            self.services = services
            self.values = values
            self.descriptorValues = descriptorValues
            self.userDescriptions = userDescriptions
        }
    }

    public enum Behavior: Sendable {
        case succeed
        case fail(BLEError)
        /// Never completes on its own; only cancellation ends it.
        case hang
    }

    /// Answers a write with notifications, the way request/reply devices do.
    public typealias Responder = @Sendable (CharacteristicAddress, Data) -> [(CharacteristicAddress, Data)]

    public struct Write: Hashable, Sendable {
        public let address: CharacteristicAddress
        public let descriptor: BLEUUID?
        public let value: Data
        public let mode: WriteMode?
    }

    public nonisolated let events: AsyncStream<CentralEvent>
    private let eventSink: AsyncStream<CentralEvent>.Continuation

    private var adapterState: CentralState
    private var devices: [PeripheralID: Device]
    private var connected: Set<PeripheralID> = []
    public private(set) var notifying: Set<CharacteristicAddress> = []
    private var scanners: [Int: AsyncStream<Advertisement>.Continuation] = [:]
    private var lastScanner = 0

    public private(set) var writes: [Write] = []
    public private(set) var disconnectRequests: [PeripheralID] = []
    public private(set) var connectAttempts = 0
    public private(set) var descriptorReads = 0
    private var connectBehavior = Behavior.succeed
    private var readBehavior = Behavior.succeed
    private var writeBehavior = Behavior.succeed
    private var descriptorReadBehavior = Behavior.succeed
    private var notificationBehavior = Behavior.succeed
    private var notificationDelay = Duration.zero
    private var maximumWriteLengths: (withResponse: Int, withoutResponse: Int) = (512, 20)
    private var responder: Responder?
    private var responseDelay = Duration.zero
    /// Held checkpoints, and whether a request held there survives the loss of its link.
    private var held: [Checkpoint: Bool] = [:]
    /// How many calls are stopped at each checkpoint right now.
    public private(set) var waiting: [Checkpoint: Int] = [:]
    /// Counts each peripheral's link losses, so a held request can tell that its link went.
    private var linkGenerations: [PeripheralID: Int] = [:]

    /// A request a test can stop, to act while the session waits for it.
    public enum Checkpoint: Hashable, Sendable {
        case maximumWriteLength
        case write
        case discoverServices
        case descriptorRead
    }

    public init(state: CentralState = .poweredOn, devices: [Device] = []) {
        let (events, eventSink) = AsyncStream.makeStream(of: CentralEvent.self)
        self.events = events
        self.eventSink = eventSink
        self.adapterState = state
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    }

    // MARK: Test controls

    public var activeScanCount: Int { scanners.count }

    public func setConnectBehavior(_ behavior: Behavior) {
        connectBehavior = behavior
    }

    public func setReadBehavior(_ behavior: Behavior) {
        readBehavior = behavior
    }

    public func setWriteBehavior(_ behavior: Behavior) {
        writeBehavior = behavior
    }

    public func setDescriptorReadBehavior(_ behavior: Behavior) {
        descriptorReadBehavior = behavior
    }

    /// How changing the notification state behaves, after `delay`: a peripheral that takes a while
    /// to acknowledge the CCCD write, or rejects it.
    public func setNotificationBehavior(_ behavior: Behavior, delay: Duration = .zero) {
        notificationBehavior = behavior
        notificationDelay = delay
    }

    /// Every characteristic write runs `responder`; what it returns is notified after `delay`.
    /// With no delay the replies go out before the write returns, like a device that answers
    /// faster than its acknowledgement arrives.
    public func setResponder(delay: Duration = .zero, _ responder: Responder?) {
        self.responder = responder
        responseDelay = delay
    }

    /// Stops every call of `checkpoint` from now on until `release`. Cancellation still ends it.
    ///
    /// A held request whose link drops meanwhile fails with `disconnected` once released, the way
    /// CoreBluetoothCentral fails pending requests. With `survivingLinkLoss` it answers late
    /// instead, as a backend without that guarantee might, even after a new link is up.
    public func hold(_ checkpoint: Checkpoint, survivingLinkLoss: Bool = false) {
        held[checkpoint] = survivingLinkLoss
    }

    public func release(_ checkpoint: Checkpoint) {
        held[checkpoint] = nil
    }

    /// Changes the attribute table the device reports from now on, like a firmware update would.
    public func setServices(_ services: [GATTService], of id: PeripheralID) {
        devices[id]?.services = services
    }

    public func setMaximumWriteLengths(withResponse: Int, withoutResponse: Int) {
        maximumWriteLengths = (withResponse, withoutResponse)
    }

    /// Sends one round of advertisements to every running scan. Every new scan also receives a
    /// round as soon as it starts.
    public func advertise() {
        for scanner in scanners.values {
            advertiseDevices(to: scanner)
        }
    }

    /// One advertisement per device, in two halves the way real controllers report them:
    /// services and manufacturer data first, the name in a separate scan response.
    private func advertiseDevices(to scanner: AsyncStream<Advertisement>.Continuation) {
        for device in devices.values.sorted(by: { $0.id.uuid.uuidString < $1.id.uuid.uuidString }) {
            scanner.yield(
                Advertisement(
                    peripheral: device.id, rssi: device.rssi, isConnectable: true,
                    serviceUUIDs: device.advertisedServices, manufacturerData: device.manufacturerData))
            scanner.yield(Advertisement(peripheral: device.id, name: device.name, rssi: device.rssi))
        }
    }

    public func notify(_ value: Data, from address: CharacteristicAddress, at date: Date = .now) {
        guard notifying.contains(address) else { return }
        eventSink.yield(.valueUpdated(address, value, receivedAt: date))
    }

    public func dropLink(to id: PeripheralID, reason: String? = "connection timeout") {
        guard connected.remove(id) != nil else { return }
        linkGenerations[id, default: 0] += 1
        notifying = notifying.filter { $0.peripheral != id }
        eventSink.yield(.disconnected(id, reason: reason))
    }

    public func changeState(to state: CentralState) {
        adapterState = state
        if state != .poweredOn {
            for id in connected {
                linkGenerations[id, default: 0] += 1
            }
            connected.removeAll()
            notifying.removeAll()
        }
        eventSink.yield(.stateChanged(state))
    }

    // MARK: BLECentral

    public func state() -> CentralState {
        adapterState
    }

    public func waitUntilPoweredOn() async throws(BLEError) {
        // Polls, so that `changeState(to:)` releases waiters the way CoreBluetooth's state callback does.
        while adapterState.isSettling || adapterState == .awaitingPermission {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                throw .cancelled
            }
        }
        guard adapterState == .poweredOn else { throw .bluetoothUnavailable(adapterState) }
    }

    public func scan() throws(BLEError) -> AsyncStream<Advertisement> {
        guard adapterState == .poweredOn else { throw .bluetoothUnavailable(adapterState) }
        lastScanner += 1
        let token = lastScanner
        let (stream, continuation) = AsyncStream.makeStream(of: Advertisement.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeScanner(token) }
        }
        scanners[token] = continuation
        advertiseDevices(to: continuation)
        return stream
    }

    public func connect(_ id: PeripheralID) async throws(BLEError) -> ConnectedPeripheral {
        connectAttempts += 1
        try await behave(connectBehavior)
        guard let device = devices[id] else { throw .unknownPeripheral(id) }
        connected.insert(id)
        return ConnectedPeripheral(id: id, name: device.name)
    }

    public func disconnect(_ id: PeripheralID) {
        disconnectRequests.append(id)
        if connected.remove(id) != nil {
            linkGenerations[id, default: 0] += 1
        }
        notifying = notifying.filter { $0.peripheral != id }
    }

    public func discoverServices(of id: PeripheralID) async throws(BLEError) -> [GATTService] {
        // The table as it was when asked, even if the answer arrives late.
        let services = try device(id).services
        try await pass(.discoverServices, for: id)
        return services
    }

    public func read(_ address: CharacteristicAddress) async throws(BLEError) -> Data {
        try await behave(readBehavior)
        return try device(address.peripheral).values[address.characteristic] ?? Data()
    }

    public func write(_ value: Data, to address: CharacteristicAddress, mode: WriteMode) async throws(BLEError) {
        try await pass(.write, for: address.peripheral)
        try await behave(writeBehavior)
        _ = try device(address.peripheral)
        devices[address.peripheral]?.values[address.characteristic] = value
        writes.append(Write(address: address, descriptor: nil, value: value, mode: mode))
        let replies = responder?(address, value) ?? []
        if responseDelay == .zero {
            for (replyAddress, reply) in replies {
                notify(reply, from: replyAddress)
            }
        } else {
            // One task for all of them: a task per reply would let them overtake each other.
            let delay = responseDelay
            Task {
                try? await Task.sleep(for: delay)
                for (replyAddress, reply) in replies {
                    notify(reply, from: replyAddress)
                }
            }
        }
    }

    public func read(_ address: DescriptorAddress) async throws(BLEError) -> Data {
        descriptorReads += 1
        try await pass(.descriptorRead, for: address.characteristic.peripheral)
        try await behave(descriptorReadBehavior)
        let device = try device(address.characteristic.peripheral)
        if address.descriptor == GATTDescriptor.characteristicUserDescription,
            let text = device.userDescriptions[address.characteristic.characteristic]
        {
            return Data(text.utf8)
        }
        return device.descriptorValues[address.descriptor] ?? Data()
    }

    public func write(_ value: Data, to address: DescriptorAddress) throws(BLEError) {
        _ = try device(address.characteristic.peripheral)
        writes.append(Write(address: address.characteristic, descriptor: address.descriptor, value: value, mode: nil))
    }

    public func setNotifications(_ enabled: Bool, for address: CharacteristicAddress) async throws(BLEError) {
        _ = try device(address.peripheral)
        // Decided when the request is made, like a peripheral's answer.
        let behavior = notificationBehavior
        if notificationDelay > .zero {
            try? await Task.sleep(for: notificationDelay)
        }
        try await behave(behavior)
        if enabled {
            notifying.insert(address)
        } else {
            notifying.remove(address)
        }
    }

    public func readRSSI(of id: PeripheralID) throws(BLEError) -> Int {
        try device(id).rssi
    }

    public func maximumWriteLength(for id: PeripheralID, mode: WriteMode) async throws(BLEError) -> Int {
        try await pass(.maximumWriteLength, for: id)
        _ = try device(id)
        return mode == .withResponse ? maximumWriteLengths.withResponse : maximumWriteLengths.withoutResponse
    }

    // MARK: Helpers

    private func device(_ id: PeripheralID) throws(BLEError) -> Device {
        guard connected.contains(id), let device = devices[id] else { throw .notConnected(id) }
        return device
    }

    private func behave(_ behavior: Behavior) async throws(BLEError) {
        switch behavior {
        case .succeed: return
        case .fail(let error): throw error
        case .hang: try await hang()
        }
    }

    private func pass(_ checkpoint: Checkpoint, for peripheral: PeripheralID) async throws(BLEError) {
        guard let survivesLinkLoss = held[checkpoint] else { return }
        let generation = linkGenerations[peripheral, default: 0]
        waiting[checkpoint, default: 0] += 1
        defer { waiting[checkpoint, default: 1] -= 1 }
        // Polls, like `waitUntilPoweredOn`; a held request ends on cancellation like a hanging one.
        while held[checkpoint] != nil {
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                throw .cancelled
            }
        }
        if !survivesLinkLoss, linkGenerations[peripheral, default: 0] != generation {
            throw .disconnected(peripheral, reason: "the link was lost while the request was pending")
        }
    }

    private func hang() async throws(BLEError) {
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            throw .cancelled
        }
        throw .cancelled
    }

    private func removeScanner(_ token: Int) {
        scanners[token] = nil
    }
}
