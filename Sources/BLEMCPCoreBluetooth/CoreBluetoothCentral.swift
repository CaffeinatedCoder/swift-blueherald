#if canImport(CoreBluetooth)
public import BLEMCPCore
@preconcurrency import CoreBluetooth
import Dispatch
public import Foundation

/// `BLECentral` on CoreBluetooth.
///
/// The actor's executor *is* the serial queue CoreBluetooth delivers its delegate callbacks on.
/// Callbacks therefore enter the actor synchronously through `assumeIsolated` (no hop, no lock),
/// every `CBPeripheral` call happens on the queue CoreBluetooth expects, and the non-`Sendable`
/// CoreBluetooth objects never leave the actor; only value types do.
public actor CoreBluetoothCentral: BLECentral {
    private let queue: DispatchSerialQueue
    private let bridge: DelegateBridge
    private var centralManager: CBCentralManager?

    public nonisolated let events: AsyncStream<CentralEvent>
    private let eventSink: AsyncStream<CentralEvent>.Continuation

    private var pending = PendingOperations()
    private var knownPeripherals: [PeripheralID: KnownPeripheral] = [:]
    private var linkedPeripherals: Set<PeripheralID> = []
    private var scanConsumers: [UInt64: AsyncStream<Advertisement>.Continuation] = [:]
    private var lastScanToken: UInt64 = 0

    /// CoreBluetooth keeps `CBPeripheral` objects alive only while someone holds them; a
    /// connection to an unretained peripheral is cancelled. Bounded so busy radio
    /// environments cannot grow it without limit.
    private static let knownPeripheralCapacity = 1024

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init() {
        let (events, eventSink) = AsyncStream.makeStream(of: CentralEvent.self, bufferingPolicy: .bufferingNewest(65_536))
        let bridge = DelegateBridge()
        self.queue = DispatchSerialQueue(label: "ble-mcp.corebluetooth", qos: .userInitiated)
        self.bridge = bridge
        self.events = events
        self.eventSink = eventSink
        // Set before the manager exists, so no callback can observe a missing owner.
        bridge.owner = self
    }

    /// Created on first use: instantiating it is what triggers the macOS Bluetooth permission
    /// prompt, which should not appear before a tool actually needs the radio.
    private var manager: CBCentralManager {
        if let centralManager { return centralManager }
        let manager = CBCentralManager(
            delegate: bridge, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        centralManager = manager
        return manager
    }

    // MARK: - BLECentral

    public func state() -> CentralState {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            return .unauthorized
        }
        return CentralState(manager.state)
    }

    public func waitUntilPoweredOn() async throws(BLEError) {
        switch manager.state {
        case .poweredOn:
            return
        case .unknown, .resetting:
            _ = try await perform(.poweredOn, on: nil) {}
        case let state:
            throw .bluetoothUnavailable(CentralState(state))
        }
    }

    public func scan() async throws(BLEError) -> AsyncStream<Advertisement> {
        guard manager.state == .poweredOn else { throw .bluetoothUnavailable(CentralState(manager.state)) }
        lastScanToken += 1
        let token = lastScanToken
        let (stream, continuation) = AsyncStream.makeStream(of: Advertisement.self, bufferingPolicy: .bufferingNewest(4096))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeScanConsumer(token) }
        }
        scanConsumers[token] = continuation
        if !manager.isScanning {
            // One radio scan serves every consumer. Duplicates stay on so RSSI keeps updating;
            // filtering happens in the session against merged advertisement data.
            manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        return stream
    }

    public func connect(_ id: PeripheralID) async throws(BLEError) -> ConnectedPeripheral {
        guard manager.state == .poweredOn else { throw .bluetoothUnavailable(CentralState(manager.state)) }
        guard let peripheral = peripheral(for: id) else { throw .unknownPeripheral(id) }
        peripheral.delegate = bridge
        if peripheral.state != .connected {
            let manager = manager
            _ = try await perform(.connect(id), on: id) {
                manager.connect(peripheral, options: nil)
            }
        }
        linkedPeripherals.insert(id)
        return ConnectedPeripheral(id: id, name: peripheral.name)
    }

    public func disconnect(_ id: PeripheralID) async {
        linkedPeripherals.remove(id)
        pending.failAll(for: id, with: .disconnected(id, reason: "disconnected on request"))
        guard let peripheral = knownPeripherals[id]?.peripheral, peripheral.state != .disconnected else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    public func discoverServices(of id: PeripheralID) async throws(BLEError) -> [GATTService] {
        let peripheral = try linkedPeripheral(id)
        _ = try await perform(.services(id), on: id) { peripheral.discoverServices(nil) }
        for service in peripheral.services ?? [] {
            _ = try await perform(.characteristics(ObjectIdentifier(service)), on: id) {
                peripheral.discoverCharacteristics(nil, for: service)
            }
            for characteristic in service.characteristics ?? [] {
                _ = try await perform(.descriptors(ObjectIdentifier(characteristic)), on: id) {
                    peripheral.discoverDescriptors(for: characteristic)
                }
            }
        }
        return (peripheral.services ?? []).map(GATTService.init)
    }

    public func read(_ address: CharacteristicAddress) async throws(BLEError) -> Data {
        let (peripheral, characteristic) = try locate(address)
        let outcome = try await perform(.read(ObjectIdentifier(characteristic)), on: address.peripheral) {
            peripheral.readValue(for: characteristic)
        }
        guard case .data(let value) = outcome else { return Data() }
        return value
    }

    public func write(_ value: Data, to address: CharacteristicAddress, mode: WriteMode) async throws(BLEError) {
        let (peripheral, characteristic) = try locate(address)
        switch mode {
        case .withResponse:
            _ = try await perform(.write(ObjectIdentifier(characteristic)), on: address.peripheral) {
                peripheral.writeValue(value, for: characteristic, type: .withResponse)
            }
        case .withoutResponse:
            // Flow control: CoreBluetooth silently drops unacknowledged writes once its queue is
            // full, so wait for `peripheralIsReady(toSendWriteWithoutResponse:)` first.
            while !peripheral.canSendWriteWithoutResponse {
                _ = try await perform(.writeWithoutResponseReady(address.peripheral), on: address.peripheral) {}
            }
            peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
        }
    }

    public func read(_ address: DescriptorAddress) async throws(BLEError) -> Data {
        let (peripheral, descriptor) = try locate(address)
        let outcome = try await perform(
            .readDescriptor(ObjectIdentifier(descriptor)), on: address.characteristic.peripheral
        ) {
            peripheral.readValue(for: descriptor)
        }
        guard case .data(let value) = outcome else { return Data() }
        return value
    }

    public func write(_ value: Data, to address: DescriptorAddress) async throws(BLEError) {
        let (peripheral, descriptor) = try locate(address)
        _ = try await perform(.writeDescriptor(ObjectIdentifier(descriptor)), on: address.characteristic.peripheral) {
            peripheral.writeValue(value, for: descriptor)
        }
    }

    public func setNotifications(_ enabled: Bool, for address: CharacteristicAddress) async throws(BLEError) {
        let (peripheral, characteristic) = try locate(address)
        guard characteristic.isNotifying != enabled else { return }
        _ = try await perform(.notify(ObjectIdentifier(characteristic)), on: address.peripheral) {
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    public func readRSSI(of id: PeripheralID) async throws(BLEError) -> Int {
        let peripheral = try linkedPeripheral(id)
        let outcome = try await perform(.rssi(id), on: id) { peripheral.readRSSI() }
        guard case .rssi(let value) = outcome else { throw .backendFailure("RSSI read returned no value") }
        return value
    }

    public func maximumWriteLength(for id: PeripheralID, mode: WriteMode) throws(BLEError) -> Int {
        let peripheral = try linkedPeripheral(id)
        return peripheral.maximumWriteValueLength(for: mode == .withResponse ? .withResponse : .withoutResponse)
    }

    // MARK: - Request plumbing

    /// Registers a continuation for `key`, issues the request, and suspends until a delegate
    /// callback, a disconnect or task cancellation resolves it, whichever comes first.
    ///
    /// The isolation is passed explicitly on purpose. Given this actor-isolated operation, the
    /// `nonisolated(nonsending)` overload of `withTaskCancellationHandler` compiles under -O
    /// (Swift 6.4) without the hop back to the actor after the continuation resumes: the caller
    /// then carries on on the global executor, which aborted the first discovery in release builds
    /// (swiftlang/swift#92915, fix pending in swiftlang/swift#93356). The isolation overload is not
    /// deprecated, so this can stay once the fix ships.
    private func perform(
        _ key: OperationKey,
        on peripheral: PeripheralID?,
        _ request: () -> Void
    ) async throws(BLEError) -> Outcome {
        let token = pending.makeToken()
        let result = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: OperationContinuation) in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: .failure(.cancelled))
                        return
                    }
                    pending.enqueue(key, token: token, peripheral: peripheral, continuation: continuation)
                    request()
                }
            },
            onCancel: { Task { await self.cancel(key, token: token) } },
            isolation: self)
        return try result.get()
    }

    private func cancel(_ key: OperationKey, token: UInt64) {
        guard pending.resume(key, token: token, with: .failure(.cancelled)) else { return }
        if case .connect(let id) = key, let peripheral = knownPeripherals[id]?.peripheral {
            // An abandoned connection attempt would otherwise stay pending in the controller forever.
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    private func removeScanConsumer(_ token: UInt64) {
        guard scanConsumers.removeValue(forKey: token) != nil else { return }
        if scanConsumers.isEmpty, manager.isScanning {
            manager.stopScan()
        }
    }

    private func peripheral(for id: PeripheralID) -> CBPeripheral? {
        if let known = knownPeripherals[id] { return known.peripheral }
        guard let retrieved = manager.retrievePeripherals(withIdentifiers: [id.uuid]).first else { return nil }
        remember(retrieved)
        return retrieved
    }

    private func linkedPeripheral(_ id: PeripheralID) throws(BLEError) -> CBPeripheral {
        guard linkedPeripherals.contains(id), let peripheral = knownPeripherals[id]?.peripheral,
            peripheral.state == .connected
        else { throw .notConnected(id) }
        return peripheral
    }

    private func locate(_ address: CharacteristicAddress) throws(BLEError) -> (CBPeripheral, CBCharacteristic) {
        let peripheral = try linkedPeripheral(address.peripheral)
        let services = peripheral.services ?? []
        guard let service = services.first(where: { BLEUUID($0.uuid) == address.service }) else {
            throw .serviceNotFound(address.service, available: services.map { BLEUUID($0.uuid) })
        }
        let characteristics = service.characteristics ?? []
        guard let characteristic = characteristics.first(where: { BLEUUID($0.uuid) == address.characteristic }) else {
            throw .characteristicNotFound(
                address.characteristic, service: address.service, available: characteristics.map { BLEUUID($0.uuid) })
        }
        return (peripheral, characteristic)
    }

    private func locate(_ address: DescriptorAddress) throws(BLEError) -> (CBPeripheral, CBDescriptor) {
        let (peripheral, characteristic) = try locate(address.characteristic)
        let descriptors = characteristic.descriptors ?? []
        guard let descriptor = descriptors.first(where: { BLEUUID($0.uuid) == address.descriptor }) else {
            throw .descriptorNotFound(
                address.descriptor, characteristic: address.characteristic.characteristic,
                available: descriptors.map { BLEUUID($0.uuid) })
        }
        return (peripheral, descriptor)
    }

    private func remember(_ peripheral: CBPeripheral) {
        let id = PeripheralID(peripheral.identifier)
        if knownPeripherals[id] == nil, knownPeripherals.count >= Self.knownPeripheralCapacity {
            evictIdlePeripherals()
        }
        knownPeripherals[id] = KnownPeripheral(peripheral: peripheral, lastSeen: .now)
    }

    private func evictIdlePeripherals() {
        let idle = knownPeripherals.values
            .filter { $0.peripheral.state == .disconnected && !linkedPeripherals.contains($0.id) }
            .sorted { $0.lastSeen < $1.lastSeen }
        for peripheral in idle.prefix(Self.knownPeripheralCapacity / 4) {
            knownPeripherals[peripheral.id] = nil
        }
    }

    private func address(of characteristic: CBCharacteristic, on peripheral: CBPeripheral) -> CharacteristicAddress? {
        guard let service = characteristic.service else { return nil }
        return CharacteristicAddress(
            peripheral: PeripheralID(peripheral.identifier),
            service: BLEUUID(service.uuid),
            characteristic: BLEUUID(characteristic.uuid))
    }

    private static func result(_ error: (any Error)?, _ operation: String, success: Outcome = .done) -> Result<Outcome, BLEError> {
        error.map { .failure(BLEError($0, during: operation)) } ?? .success(success)
    }

    // MARK: - Delegate callbacks (entered synchronously on the actor's queue)

    func handleStateUpdate() {
        let state = manager.state
        eventSink.yield(.stateChanged(CentralState(state)))
        switch state {
        case .poweredOn:
            pending.resumeAll(.poweredOn, with: .success(.done))
        case .unknown, .resetting:
            break
        default:
            pending.resumeAll(.poweredOn, with: .failure(.bluetoothUnavailable(CentralState(state))))
        }
        guard state != .poweredOn else { return }

        // CoreBluetooth invalidates every peripheral object and link when the adapter goes away.
        let error = BLEError.bluetoothUnavailable(CentralState(state))
        pending.failAllPeripheralOperations(with: error)
        linkedPeripherals.removeAll()
        knownPeripherals.removeAll()
        scanConsumers.values.forEach { $0.finish() }
        scanConsumers.removeAll()
    }

    func handleDiscovery(of peripheral: CBPeripheral, _ advertisement: Advertisement) {
        remember(peripheral)
        for consumer in scanConsumers.values {
            consumer.yield(advertisement)
        }
    }

    func handleConnect(_ peripheral: CBPeripheral) {
        pending.resumeAll(.connect(PeripheralID(peripheral.identifier)), with: .success(.done))
    }

    func handleFailedConnect(_ peripheral: CBPeripheral, error: (any Error)?) {
        let id = PeripheralID(peripheral.identifier)
        let reason = error?.localizedDescription ?? "the peripheral did not accept the connection"
        pending.resumeAll(.connect(id), with: .failure(.connectionFailed(id, reason: reason)))
    }

    func handleDisconnect(_ peripheral: CBPeripheral, error: (any Error)?) {
        let id = PeripheralID(peripheral.identifier)
        let reason = error?.localizedDescription
        pending.failAll(for: id, with: .disconnected(id, reason: reason))
        if linkedPeripherals.remove(id) != nil {
            eventSink.yield(.disconnected(id, reason: reason))
        }
    }

    func handleServicesDiscovered(on peripheral: CBPeripheral, error: (any Error)?) {
        pending.resumeAll(
            .services(PeripheralID(peripheral.identifier)), with: Self.result(error, "Service discovery"))
    }

    func handleCharacteristicsDiscovered(for service: CBService, error: (any Error)?) {
        pending.resumeAll(
            .characteristics(ObjectIdentifier(service)), with: Self.result(error, "Characteristic discovery"))
    }

    func handleDescriptorsDiscovered(for characteristic: CBCharacteristic, error: (any Error)?) {
        pending.resumeAll(
            .descriptors(ObjectIdentifier(characteristic)), with: Self.result(error, "Descriptor discovery"))
    }

    func handleValueUpdate(of characteristic: CBCharacteristic, on peripheral: CBPeripheral, error: (any Error)?) {
        let value = characteristic.value ?? Data()
        // CoreBluetooth reports read responses and notifications through the same callback. A
        // pending read claims it; anything else on a notifying characteristic is a notification.
        if pending.resumeFirst(
            .read(ObjectIdentifier(characteristic)), with: Self.result(error, "Read", success: .data(value)))
        {
            return
        }
        guard error == nil, characteristic.isNotifying, let address = address(of: characteristic, on: peripheral)
        else { return }
        eventSink.yield(.valueUpdated(address, value, receivedAt: .now))
    }

    func handleWrite(to characteristic: CBCharacteristic, error: (any Error)?) {
        pending.resumeFirst(.write(ObjectIdentifier(characteristic)), with: Self.result(error, "Write"))
    }

    func handleNotificationStateUpdate(of characteristic: CBCharacteristic, error: (any Error)?) {
        pending.resumeFirst(.notify(ObjectIdentifier(characteristic)), with: Self.result(error, "Changing notification state"))
    }

    func handleDescriptorValueUpdate(of descriptor: CBDescriptor, error: (any Error)?) {
        pending.resumeFirst(
            .readDescriptor(ObjectIdentifier(descriptor)),
            with: Self.result(error, "Descriptor read", success: .data(descriptor.wireValue)))
    }

    func handleDescriptorWrite(to descriptor: CBDescriptor, error: (any Error)?) {
        pending.resumeFirst(.writeDescriptor(ObjectIdentifier(descriptor)), with: Self.result(error, "Descriptor write"))
    }

    func handleRSSI(_ rssi: Int, of peripheral: CBPeripheral, error: (any Error)?) {
        pending.resumeFirst(
            .rssi(PeripheralID(peripheral.identifier)), with: Self.result(error, "RSSI read", success: .rssi(rssi)))
    }

    func handleReadyToWriteWithoutResponse(_ peripheral: CBPeripheral) {
        pending.resumeAll(.writeWithoutResponseReady(PeripheralID(peripheral.identifier)), with: .success(.done))
    }
}

private struct KnownPeripheral {
    let peripheral: CBPeripheral
    let lastSeen: ContinuousClock.Instant

    var id: PeripheralID { PeripheralID(peripheral.identifier) }
}
#endif
