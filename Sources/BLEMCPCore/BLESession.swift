public import Foundation

/// The stateful heart of the server: scans, connections, subscriptions and their notification
/// buffers, on top of any `BLECentral`.
///
/// All state lives in this actor and leaves it only as immutable snapshots. Because actors are
/// re-entrant, every method that suspends re-validates what it checked before the suspension
/// (capacity, connection state) instead of trusting it, and claims slots before awaiting so
/// concurrent calls cannot overshoot a limit.
public actor BLESession {
    public nonisolated let configuration: SessionConfiguration
    /// When this session, and so this server process, started. Connections do not outlive it.
    public nonisolated let startedAt = Date.now
    /// Disconnections and adapter changes, for forwarding to the client. Single consumer.
    public nonisolated let events: AsyncStream<SessionEvent>

    private let central: any BLECentral
    private let captureSink: (any CaptureSink)?
    private let eventSink: AsyncStream<SessionEvent>.Continuation
    private var eventPump: Task<Void, Never>?
    private var isShutDown = false
    private var adapterState = CentralState.unknown

    private var scans: [ScanID: ActiveScan] = [:]
    private var connections: [PeripheralID: Connection] = [:]
    private var subscriptions: [SubscriptionID: Subscription] = [:]
    private var subscriptionsByAddress: [CharacteristicAddress: SubscriptionID] = [:]
    private var waiters: [NotificationWaiter] = []
    /// Everything scans have seen of each peripheral, merged: names for connections, and the
    /// advertisement a capture records when the session connects.
    private var seen: [PeripheralID: DiscoveredPeripheral] = [:]
    private var linkLosses: [PeripheralID: LinkLoss] = [:]

    private var lastScanID = 0
    private var lastSubscriptionID = 0
    private var lastSequence: UInt64 = 0
    private var lastWaiterToken: UInt64 = 0
    private var lastConnectAttempt: UInt64 = 0

    private static let seenCapacity = 4096
    private static let linkLossCapacity = 64
    private static let finishedScanCapacity = 8

    /// - Parameter capture: Receives every write, notification, read and link change, in order.
    public init(
        central: some BLECentral,
        configuration: SessionConfiguration = SessionConfiguration(),
        capture: (any CaptureSink)? = nil
    ) {
        self.central = central
        self.configuration = configuration
        self.captureSink = capture
        let (events, eventSink) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.events = events
        self.eventSink = eventSink
    }

    /// Starts consuming backend events. Idempotent.
    public func start() {
        guard eventPump == nil, !isShutDown else { return }
        let backendEvents = central.events
        eventPump = Task { [weak self] in
            for await event in backendEvents {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    /// Stops every scan, closes every subscription and disconnects every peripheral.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for id in scans.keys {
            scans[id]?.finish()
        }
        scans.removeAll()
        let peripherals = Array(connections.keys)
        for id in peripherals {
            closeSubscriptions(of: id, reason: "server shutting down")
            if connections[id]?.state == .connected {
                capture(.disconnected(id, reason: "server shutting down"))
            }
        }
        connections.removeAll()
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
        eventPump?.cancel()
        eventPump = nil
        eventSink.finish()

        let central = central
        await withTaskGroup(of: Void.self) { group in
            for id in peripherals {
                group.addTask { await central.disconnect(id) }
            }
        }
    }

    // MARK: - Status

    public func status() async -> SessionStatus {
        var state = await central.state()
        if state.isSettling || state == .awaitingPermission {
            // CoreBluetooth reports the adapter state a moment after its manager is created, on
            // first use. The first start of a new build can take seconds while macOS checks the
            // binary (2 s was measured to be too short), so wait as long as any operation would.
            // A permission prompt needs a person, so that wait is short.
            let timeouts = configuration.timeouts
            let limit = state == .awaitingPermission ? min(timeouts.permissionPrompt, timeouts.poweredOn) : timeouts.poweredOn
            let central = central
            _ = try? await withDeadline(limit, operation: "Waiting for the adapter state") {
                try await central.waitUntilPoweredOn()
            }
            state = await central.state()
        }
        return SessionStatus(
            startedAt: startedAt,
            captureDestination: captureDestination,
            adapterState: state,
            configuration: configuration,
            activeScans: scans.values.filter(\.isActive).map(\.id).sorted(),
            connections: await connectionSnapshots(),
            subscriptions: subscriptions.values.map(\.snapshot).sorted { $0.id < $1.id },
            linkLosses: linkLosses.values.sorted { $0.at > $1.at },
            backend: await central.report())
    }

    // MARK: - Scanning

    /// Scans for `duration`, or until `stopAfter` peripherals have matched, and returns what it found.
    public func scan(
        filter: ScanFilter = .all,
        duration: Duration,
        stopAfter: Int? = nil,
        maxResults: Int = .max
    ) async throws(BLEError) -> ScanSnapshot {
        let id = try await startScan(filter: filter, duration: duration, stopAfter: stopAfter)
        await waitForScanEnd(id)
        return try stopScan(id, maxResults: maxResults)
    }

    /// Starts a background scan. It runs until `duration` elapses, `stopAfter` peripherals match,
    /// or `stopScan` is called; its results stay readable until `stopScan`.
    public func startScan(
        filter: ScanFilter = .all,
        duration: Duration? = nil,
        stopAfter: Int? = nil
    ) async throws(BLEError) -> ScanID {
        try ensureScanCapacity()
        try await ensurePoweredOn()
        let stream = try await central.scan()
        // Re-check after suspending: the session may have shut down, or another call taken the
        // last slot. Dropping the unused stream terminates it, which releases the backend scan.
        guard !isShutDown else { throw .cancelled }
        try ensureScanCapacity()

        lastScanID += 1
        let id = ScanID(rawValue: lastScanID)
        var scan = ActiveScan(id: id, filter: filter, stopAfter: stopAfter)
        scan.consumer = Task { [weak self] in
            for await advertisement in stream {
                guard let self else { return }
                await self.record(advertisement, in: id)
            }
        }
        if let duration {
            scan.timer = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await self?.finishScan(id)
            }
        }
        scans[id] = scan
        pruneFinishedScans()
        return id
    }

    public func scanResults(_ id: ScanID, maxResults: Int = .max) throws(BLEError) -> ScanSnapshot {
        guard let scan = scans[id] else { throw .scanNotFound(id) }
        return scan.snapshot(maxResults: maxResults)
    }

    /// Stops the scan if it is running and returns its final results. The scan is then forgotten.
    @discardableResult
    public func stopScan(_ id: ScanID, maxResults: Int = .max) throws(BLEError) -> ScanSnapshot {
        guard var scan = scans.removeValue(forKey: id) else { throw .scanNotFound(id) }
        scan.finish()
        return scan.snapshot(maxResults: maxResults)
    }

    private func record(_ advertisement: Advertisement, in id: ScanID) {
        let peripheral = advertisement.peripheral
        if seen[peripheral] != nil {
            seen[peripheral]?.merge(advertisement)
        } else if seen.count < Self.seenCapacity {
            seen[peripheral] = DiscoveredPeripheral(advertisement)
        }
        guard let reachedTarget = scans[id]?.record(advertisement, limit: configuration.limits.maxPeripheralsPerScan)
        else { return }
        if reachedTarget {
            finishScan(id)
        }
    }

    private func finishScan(_ id: ScanID) {
        scans[id]?.finish()
    }

    private func waitForScanEnd(_ id: ScanID) async {
        // Isolation passed explicitly, as in `waitForNotification`.
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    guard scans[id]?.isActive == true, !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    scans[id]?.completionWaiters.append(continuation)
                }
            },
            onCancel: { Task { await self.finishScan(id) } },
            isolation: self)
    }

    private func ensureScanCapacity() throws(BLEError) {
        let limit = configuration.limits.maxScans
        guard scans.values.count(where: \.isActive) < limit else { throw .scanLimitReached(limit: limit) }
    }

    private func pruneFinishedScans() {
        let finished = scans.values.filter { !$0.isActive }.sorted { $0.id < $1.id }
        for scan in finished.dropLast(Self.finishedScanCapacity) {
            scans[scan.id] = nil
        }
    }

    // MARK: - Connections

    /// - Parameters:
    ///   - discover: Also discover the attribute table.
    ///   - userDescriptions: With `discover`, also read each characteristic's 0x2901 name.
    public func connect(
        _ id: PeripheralID,
        discover: Bool = true,
        userDescriptions: Bool = true
    ) async throws(BLEError) -> ConnectionSnapshot {
        if let existing = connections[id] {
            guard existing.state == .connected else { throw .alreadyConnecting(id) }
            if discover, existing.services == nil || (userDescriptions && !existing.hasUserDescriptions) {
                _ = try? await discoverServices(of: id, userDescriptions: userDescriptions)
            }
            return try await connectionSnapshot(id)
        }

        try ensureConnectionCapacity()
        try await ensurePoweredOn()
        guard connections[id] == nil else { throw .alreadyConnecting(id) }
        try ensureConnectionCapacity()
        lastConnectAttempt += 1
        let attempt = lastConnectAttempt
        connections[id] = Connection(id: id, name: seen[id]?.name, attempt: attempt)

        let central = central
        let peripheral: ConnectedPeripheral
        do {
            peripheral = try await withDeadline(configuration.timeouts.connect, operation: "Connecting to \(id)") {
                try await central.connect(id)
            }
        } catch {
            // After a disconnect, the entry may belong to a newer attempt by now.
            if connections[id]?.attempt == attempt { connections[id] = nil }
            throw error
        }

        guard connections[id]?.attempt == attempt else {
            // Disconnected or shut down while the link came up. A newer attempt that owns the
            // entry now gets this same link, so only an untracked one is closed.
            if connections[id] == nil {
                await central.disconnect(id)
            }
            guard !isShutDown else { throw .cancelled }
            throw .disconnected(id, reason: "the connection was closed while it was being established")
        }
        connections[id]?.markConnected(name: peripheral.name ?? seen[id]?.name)
        linkLosses[id] = nil
        if let advertised = seen[id] {
            capture(.advertisement(advertised))
        }
        capture(.connected(id, name: connections[id]?.name))
        if discover {
            _ = try? await discoverServices(of: id, userDescriptions: userDescriptions)
        }
        return try await connectionSnapshot(id)
    }

    /// Disconnects `id` and closes its subscriptions. A peripheral that is not connected is
    /// already where this leaves it, so that is not an error. Returns whether there was a link.
    @discardableResult
    public func disconnect(_ id: PeripheralID) async -> Bool {
        guard connections.removeValue(forKey: id) != nil else { return false }
        closeSubscriptions(of: id, reason: "disconnected on request")
        capture(.disconnected(id, reason: "disconnected on request"))
        await central.disconnect(id)
        return true
    }

    public func connectionSnapshots() async -> [ConnectionSnapshot] {
        var snapshots: [ConnectionSnapshot] = []
        for id in connections.keys.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            if let snapshot = try? await connectionSnapshot(id) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    public func connectionSnapshot(_ id: PeripheralID) async throws(BLEError) -> ConnectionSnapshot {
        guard connections[id] != nil else { throw .notConnected(id) }
        var lengths: WriteLengths?
        if connections[id]?.state == .connected {
            let central = central
            if let withResponse = try? await central.maximumWriteLength(for: id, mode: .withResponse),
                let withoutResponse = try? await central.maximumWriteLength(for: id, mode: .withoutResponse)
            {
                lengths = WriteLengths(withResponse: withResponse, withoutResponse: withoutResponse)
            }
        }
        guard let connection = connections[id] else { throw .notConnected(id) }
        return ConnectionSnapshot(
            id: id,
            name: connection.name,
            state: connection.state,
            connectedAt: connection.connectedAt,
            services: connection.services,
            discoveryError: connection.discoveryError,
            subscriptions: subscriptions.values.filter { $0.address.peripheral == id }.map(\.id).sorted(),
            maximumWriteLength: lengths)
    }

    private func ensureConnectionCapacity() throws(BLEError) {
        let limit = configuration.limits.maxConnections
        guard connections.count < limit else { throw .connectionLimitReached(limit: limit) }
    }

    private func requireConnected(_ id: PeripheralID) throws(BLEError) -> Connection {
        guard let connection = connections[id], connection.state == .connected else {
            // Saying why beats a bare "not connected": the agent may never have seen the drop.
            if connections[id] == nil, let loss = linkLosses[id] {
                throw .linkLost(id, reason: loss.reason, at: loss.at)
            }
            throw .notConnected(id)
        }
        return connection
    }

    // MARK: - GATT

    /// The peripheral's attribute table, discovered on first use and cached for the connection.
    ///
    /// With `userDescriptions`, each characteristic's 0x2901 descriptor is read too, so vendor
    /// characteristics arrive with the device's own names. That part is best effort: a read that
    /// fails or is slow leaves that name out instead of failing discovery.
    public func discoverServices(
        of id: PeripheralID,
        refresh: Bool = false,
        userDescriptions: Bool = true
    ) async throws(BLEError) -> [GATTService] {
        let connection = try requireConnected(id)
        var services: [GATTService]
        var isNew = false
        if !refresh, let cached = connection.services {
            services = cached
        } else {
            services = try await discoverAttributeTable(of: id)
            isNew = true
        }
        if userDescriptions, connections[id]?.hasUserDescriptions == false {
            services = await readingUserDescriptions(of: id, into: services)
            guard connections[id]?.state == .connected else { throw .disconnected(id, reason: nil) }
            connections[id]?.services = services
            connections[id]?.hasUserDescriptions = true
            isNew = true
        }
        if isNew {
            capture(.discovered(id, services))
        }
        return services
    }

    private func discoverAttributeTable(of id: PeripheralID) async throws(BLEError) -> [GATTService] {
        let central = central
        do throws(BLEError) {
            let services = try await withDeadline(
                configuration.timeouts.discovery, operation: "Discovering services of \(id)"
            ) {
                try await central.discoverServices(of: id)
            }
            guard connections[id]?.state == .connected else { throw .disconnected(id, reason: nil) }
            connections[id]?.services = services
            connections[id]?.hasUserDescriptions = false
            connections[id]?.discoveryError = nil
            return services
        } catch {
            connections[id]?.discoveryError = error
            throw error
        }
    }

    /// Returns `services` with the 0x2901 names filled in. Each read gets at most two seconds and
    /// all of them together ten, so a device that stalls cannot hold discovery hostage.
    private func readingUserDescriptions(of id: PeripheralID, into services: [GATTService]) async -> [GATTService] {
        let central = central
        let perRead = min(configuration.timeouts.operation, .seconds(2))
        let budgetEnds = ContinuousClock.now + .seconds(10)
        var described: [GATTService] = []
        described.reserveCapacity(services.count)
        for service in services {
            var characteristics: [GATTCharacteristic] = []
            characteristics.reserveCapacity(service.characteristics.count)
            for characteristic in service.characteristics {
                guard characteristic.hasUserDescription, ContinuousClock.now < budgetEnds else {
                    characteristics.append(characteristic)
                    continue
                }
                let address = DescriptorAddress(
                    characteristic: CharacteristicAddress(peripheral: id, service: service.uuid, characteristic: characteristic.uuid),
                    descriptor: GATTDescriptor.characteristicUserDescription)
                let value = try? await withDeadline(perRead, operation: "Reading the user description of \(characteristic.uuid)") {
                    try await central.read(address)
                }
                characteristics.append(characteristic.with(userDescription: value.flatMap(Self.userDescriptionText)))
            }
            described.append(GATTService(uuid: service.uuid, isPrimary: service.isPrimary, characteristics: characteristics))
        }
        return described
    }

    /// 0x2901 holds UTF-8 text; devices often pad it with NULs or spaces.
    private static func userDescriptionText(_ value: Data) -> String? {
        DeviceText.clean(String(validating: value.reversed().drop { $0 == 0 }.reversed(), as: UTF8.self))
    }

    public func read(_ selector: CharacteristicSelector) async throws(BLEError) -> CharacteristicValue {
        let target = try await resolve(selector)
        try require(.read, named: "read", on: target)
        let central = central
        let address = target.address
        let value = try await withDeadline(configuration.timeouts.operation, operation: "Reading \(address.characteristic)") {
            try await central.read(address)
        }
        capture(.read(address, value))
        return CharacteristicValue(
            address: address, userDescription: target.characteristic.userDescription, properties: target.characteristic.properties,
            value: value, readAt: .now)
    }

    /// Writes `value`. Without an explicit mode, characteristics that acknowledge writes get an
    /// acknowledged write; the rest get a write without response.
    public func write(
        _ value: Data,
        to selector: CharacteristicSelector,
        mode requestedMode: WriteMode? = nil
    ) async throws(BLEError) -> WriteReceipt {
        // Policy first: a refused frame never causes discovery, let alone reaches the radio.
        try configuration.writePolicy.checkWrite(value, to: selector.characteristic)
        let target = try await resolve(selector)

        let mode = requestedMode ?? (target.characteristic.properties.contains(.write) ? .withResponse : .withoutResponse)
        switch mode {
        case .withResponse: try require(.write, named: "write", on: target)
        case .withoutResponse: try require(.writeWithoutResponse, named: "write_without_response", on: target)
        }

        let central = central
        let address = target.address
        let maximum = try await central.maximumWriteLength(for: address.peripheral, mode: mode)
        guard value.count <= maximum else { throw .payloadTooLarge(size: value.count, maximum: maximum) }
        capture(.write(address, value, mode))
        do {
            try await withDeadline(configuration.timeouts.operation, operation: "Writing \(address.characteristic)") {
                try await central.write(value, to: address, mode: mode)
            }
        } catch {
            capture(.writeFailed(address, descriptor: nil, error))
            throw error
        }
        return WriteReceipt(address: address, descriptor: nil, byteCount: value.count, mode: mode)
    }

    public func readDescriptor(
        _ descriptor: BLEUUID,
        of selector: CharacteristicSelector
    ) async throws(BLEError) -> DescriptorValue {
        let target = try await resolve(selector)
        let address = try GATTResolver.resolve(descriptor: descriptor, of: target)
        let central = central
        let value = try await withDeadline(configuration.timeouts.operation, operation: "Reading descriptor \(descriptor)") {
            try await central.read(address)
        }
        capture(.descriptorRead(address, value))
        return DescriptorValue(address: address, value: value, readAt: .now)
    }

    public func writeDescriptor(
        _ value: Data,
        to descriptor: BLEUUID,
        of selector: CharacteristicSelector
    ) async throws(BLEError) -> WriteReceipt {
        try configuration.writePolicy.checkDescriptorWrite(on: selector.characteristic)
        guard descriptor != GATTDescriptor.clientCharacteristicConfiguration else {
            throw .reservedDescriptor(descriptor)
        }
        let target = try await resolve(selector)
        let address = try GATTResolver.resolve(descriptor: descriptor, of: target)
        let central = central
        capture(.descriptorWrite(address, value))
        do {
            try await withDeadline(configuration.timeouts.operation, operation: "Writing descriptor \(descriptor)") {
                try await central.write(value, to: address)
            }
        } catch {
            capture(.writeFailed(target.address, descriptor: descriptor, error))
            throw error
        }
        return WriteReceipt(address: target.address, descriptor: descriptor, byteCount: value.count, mode: nil)
    }

    public func readRSSI(of id: PeripheralID) async throws(BLEError) -> Int {
        _ = try requireConnected(id)
        let central = central
        return try await withDeadline(configuration.timeouts.operation, operation: "Reading RSSI of \(id)") {
            try await central.readRSSI(of: id)
        }
    }

    private func resolve(_ selector: CharacteristicSelector) async throws(BLEError) -> ResolvedCharacteristic {
        // Names are not needed to address a characteristic; skipping them keeps a first read fast.
        let services = try await discoverServices(of: selector.peripheral, userDescriptions: false)
        return try GATTResolver.resolve(selector, in: services)
    }

    private func require(
        _ property: CharacteristicProperties,
        named name: String,
        on target: ResolvedCharacteristic
    ) throws(BLEError) {
        let properties = target.characteristic.properties
        guard properties.contains(property) else {
            throw .propertyNotSupported(
                characteristic: target.address.characteristic, required: name, available: properties.names)
        }
    }

    // MARK: - Request and reply

    /// Writes `value` and waits up to `timeout` for the device's answer: the first notification
    /// on `replySelector` after the write that starts with `prefix`.
    ///
    /// The reply characteristic is subscribed to before the write, so even an immediate answer is
    /// caught, and the subscription stays open so the next exchange is just as safe. The reply is
    /// taken out of the buffer; anything else that arrived stays readable with `notifications`.
    /// Not having an answer is not an error: the write happened, and the result says so.
    public func transact(
        _ value: Data,
        to selector: CharacteristicSelector,
        mode: WriteMode? = nil,
        replyOn replySelector: CharacteristicSelector,
        prefix: Data = Data(),
        timeout: Duration
    ) async throws(BLEError) -> Transaction {
        // Policy first, as in `write`: a refused frame must not even cause a subscription.
        try configuration.writePolicy.checkWrite(value, to: selector.characteristic)
        let id = try await subscribe(replySelector).id
        let mark = lastSequence
        let sentAt = Date.now
        let receipt = try await write(value, to: selector, mode: mode)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var reply = takeReply(on: id, after: mark, prefix: prefix)
        // A cancelled wait returns at once, so cancellation must end the loop.
        while reply == nil, subscriptions[id]?.isOpen == true, clock.now < deadline, !Task.isCancelled {
            await waitForNotification(on: id, timeout: deadline - clock.now)
            reply = takeReply(on: id, after: mark, prefix: prefix)
        }
        if reply == nil, Task.isCancelled {
            throw .cancelled
        }
        if reply == nil, subscriptions[id]?.isOpen != true {
            // The link went while waiting; say so rather than reporting a silent device.
            _ = try requireConnected(replySelector.peripheral)
        }
        guard let subscription = subscriptions[id] else { throw .subscriptionNotFound(id) }
        return Transaction(
            write: receipt,
            reply: reply,
            latency: reply.map { .milliseconds(Int(($0.receivedAt.timeIntervalSince(sentAt) * 1000).rounded())) },
            unmatched: subscription.buffer.elements.count { $0.sequence > mark && !$0.value.starts(with: prefix) },
            subscription: subscription.snapshot,
            timeout: timeout)
    }

    private func takeReply(on id: SubscriptionID, after mark: UInt64, prefix: Data) -> ValueNotification? {
        subscriptions[id]?.buffer.removeFirst { $0.sequence > mark && $0.value.starts(with: prefix) }
    }

    // MARK: - Subscriptions

    /// Enables notifications (or indications) and starts buffering them. Subscribing to a
    /// characteristic that already has an open subscription returns that subscription, once
    /// notifications are on: a call that arrives while another is still enabling them waits for
    /// it, and tries again itself if that one fails.
    public func subscribe(_ selector: CharacteristicSelector) async throws(BLEError) -> SubscriptionSnapshot {
        while true {
            let target = try await resolve(selector)
            guard let existing = subscriptionsByAddress[target.address], let subscription = subscriptions[existing] else {
                return try await enableSubscription(target)
            }
            guard subscription.state == .pending else { return subscription.snapshot }
            // Woken when the other call activates or discards it; its own deadline bounds the wait.
            await waitForNotification(on: existing, timeout: configuration.timeouts.operation)
            guard !Task.isCancelled else { throw .cancelled }
        }
    }

    private func enableSubscription(_ target: ResolvedCharacteristic) async throws(BLEError) -> SubscriptionSnapshot {
        let address = target.address

        let properties = target.characteristic.properties
        let mode: NotificationMode
        if properties.contains(.notify) {
            mode = .notify
        } else if properties.contains(.indicate) {
            mode = .indicate
        } else {
            throw .propertyNotSupported(
                characteristic: address.characteristic, required: "notify or indicate", available: properties.names)
        }
        let limit = configuration.limits.maxSubscriptions
        guard subscriptions.values.count(where: \.isOpen) < limit else {
            throw .subscriptionLimitReached(limit: limit)
        }

        lastSubscriptionID += 1
        let id = SubscriptionID(rawValue: lastSubscriptionID)
        subscriptions[id] = Subscription(
            id: id, address: address, userDescription: target.characteristic.userDescription, mode: mode,
            capacity: configuration.limits.notificationBufferCapacity)
        subscriptionsByAddress[address] = id

        let central = central
        do {
            try await withDeadline(configuration.timeouts.operation, operation: "Enabling notifications on \(address.characteristic)") {
                try await central.setNotifications(true, for: address)
            }
        } catch {
            discardSubscription(id)
            throw error
        }

        guard subscriptions[id]?.state == .pending else {
            // The peripheral disconnected while notifications were being enabled.
            discardSubscription(id)
            throw .disconnected(address.peripheral, reason: "the peripheral disconnected while subscribing")
        }
        subscriptions[id]?.state = .active
        resumeJoiners(of: id)
        capture(.notificationsEnabled(address, mode))
        guard let subscription = subscriptions[id] else { throw .subscriptionNotFound(id) }
        return subscription.snapshot
    }

    /// Disables notifications and discards the subscription, including anything still buffered.
    @discardableResult
    public func unsubscribe(_ id: SubscriptionID) async throws(BLEError) -> SubscriptionSnapshot {
        guard var subscription = subscriptions[id] else { throw .subscriptionNotFound(id) }
        let wasOpen = subscription.isOpen
        discardSubscription(id)
        subscription.state = .closed(reason: "unsubscribed")

        let address = subscription.address
        if wasOpen {
            capture(.notificationsDisabled(address))
        }
        if wasOpen, connections[address.peripheral]?.state == .connected {
            let central = central
            // Best effort: the subscription is gone either way, and stray notifications that
            // still arrive have nowhere to go.
            try? await withDeadline(configuration.timeouts.operation, operation: "Disabling notifications") {
                try await central.setNotifications(false, for: address)
            }
        }
        return subscription.snapshot
    }

    /// Returns up to `maxCount` buffered notifications in arrival order, from one subscription or
    /// from all of them. When nothing is buffered, waits up to `wait` for the next one.
    public func notifications(
        from id: SubscriptionID? = nil,
        maxCount: Int,
        waitUpTo wait: Duration = .zero
    ) async throws(BLEError) -> NotificationBatch {
        if let id, subscriptions[id] == nil { throw .subscriptionNotFound(id) }
        let selected = { (subscription: Subscription) in id == nil || subscription.id == id }
        let buffered = subscriptions.values.filter(selected).reduce(0) { $0 + $1.buffer.count }
        let canReceive = subscriptions.values.contains { selected($0) && $0.isOpen }
        guard wait > .zero, buffered == 0 else { return drain(id, maxCount: maxCount, waited: nil) }
        guard canReceive else { return drain(id, maxCount: maxCount, waited: nil, skipped: true) }
        let clock = ContinuousClock()
        let start = clock.now
        await waitForNotification(on: id, timeout: wait)
        return drain(id, maxCount: maxCount, waited: clock.now - start)
    }

    /// - Parameters:
    ///   - waited: How long the call waited before draining, if it did.
    ///   - skipped: A wait was asked for but nothing could arrive.
    private func drain(_ id: SubscriptionID?, maxCount: Int, waited: Duration?, skipped: Bool = false) -> NotificationBatch {
        let ids = id.map { [$0] } ?? subscriptions.keys.sorted()
        var collected: [ValueNotification] = []
        collected.reserveCapacity(min(maxCount, 256))

        // k-way merge on the session-wide sequence number; k is bounded by maxSubscriptions.
        while collected.count < maxCount {
            var next: SubscriptionID?
            var lowest = UInt64.max
            for candidate in ids {
                if let head = subscriptions[candidate]?.buffer.first, head.sequence < lowest {
                    next = candidate
                    lowest = head.sequence
                }
            }
            guard let next, let notification = subscriptions[next]?.buffer.popFirst() else { break }
            collected.append(notification)
        }

        var dropped = 0
        var remaining = 0
        var snapshots: [SubscriptionSnapshot] = []
        for candidate in ids {
            guard let subscription = subscriptions[candidate] else { continue }
            dropped += subscription.droppedSinceLastRead
            remaining += subscription.buffer.count
            subscriptions[candidate]?.droppedSinceLastRead = 0
            snapshots.append(subscription.snapshot)
            if !subscription.isOpen, subscription.buffer.isEmpty {
                // Closed and fully read: nothing left to report.
                subscriptions[candidate] = nil
            }
        }
        let wait: NotificationBatch.WaitOutcome =
            if skipped {
                .skipped
            } else if let waited, collected.isEmpty {
                .nothingArrived(after: waited)
            } else {
                .none
            }
        return NotificationBatch(
            notifications: collected, remaining: remaining, dropped: dropped, subscriptions: snapshots, wait: wait)
    }

    private func waitForNotification(on id: SubscriptionID?, timeout: Duration) async {
        lastWaiterToken += 1
        let token = lastWaiterToken
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resumeWaiter(token)
        }
        defer { timer.cancel() }

        // Isolation passed explicitly: given an actor-isolated operation, the
        // `nonisolated(nonsending)` overload can compile under -O without the hop back to this
        // actor once the continuation resumes, and `drain` would then run off the actor
        // (swiftlang/swift#92915). Inlining hides that here today; this keeps it from depending on it.
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    guard !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    waiters.append(NotificationWaiter(token: token, subscription: id, continuation: continuation))
                }
            },
            onCancel: { Task { await self.resumeWaiter(token) } },
            isolation: self)
    }

    private func resumeWaiter(_ token: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    private func resumeWaiters(for id: SubscriptionID) {
        guard !waiters.isEmpty else { return }
        let ready = waiters.filter { $0.isWaiting(for: id) }
        waiters.removeAll { $0.isWaiting(for: id) }
        ready.forEach { $0.continuation.resume() }
    }

    /// Wakes the calls waiting for `id` to become active. Waits on any subscription are left alone,
    /// since nothing arrived.
    private func resumeJoiners(of id: SubscriptionID) {
        let ready = waiters.filter { $0.subscription == id }
        waiters.removeAll { $0.subscription == id }
        ready.forEach { $0.continuation.resume() }
    }

    private func discardSubscription(_ id: SubscriptionID) {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        if subscriptionsByAddress[subscription.address] == id {
            subscriptionsByAddress[subscription.address] = nil
        }
        resumeWaiters(for: id)
    }

    private func closeSubscriptions(of peripheral: PeripheralID, reason: String) {
        for (id, subscription) in subscriptions where subscription.address.peripheral == peripheral && subscription.isOpen {
            subscriptions[id]?.state = .closed(reason: reason)
            subscriptionsByAddress[subscription.address] = nil
            resumeWaiters(for: id)
        }
    }

    // MARK: - Capture

    /// Where the capture goes, or `nil` when the session records nothing.
    public nonisolated var captureDestination: String? { captureSink?.destination }

    /// Labels the capture at this point, for example before the next step of an experiment.
    /// Does nothing when the session records nothing.
    public func mark(_ note: String, fields: [String: CaptureValue] = [:]) {
        capture(.marker(note: note, fields: fields))
    }

    private func capture(_ kind: CaptureEvent.Kind, at time: Date = .now) {
        captureSink?.record(CaptureEvent(time: time, kind: kind))
    }

    // MARK: - Backend events

    private func handle(_ event: CentralEvent) {
        switch event {
        case .stateChanged(let state):
            guard state != adapterState else { return }
            adapterState = state
            eventSink.yield(.adapterStateChanged(state))
            guard state != .poweredOn else { return }
            // Links and scans do not survive the adapter going away.
            for id in Array(connections.keys) {
                connectionLost(id, reason: "Bluetooth became \(state.rawValue)")
            }
            for id in scans.keys {
                scans[id]?.finish()
            }

        case .disconnected(let id, let reason):
            connectionLost(id, reason: reason)

        case .valueUpdated(let address, let value, let receivedAt):
            guard let id = subscriptionsByAddress[address] else { return }
            capture(.notification(address, value), at: receivedAt)
            lastSequence += 1
            subscriptions[id]?.record(
                ValueNotification(
                    subscription: id, sequence: lastSequence, address: address, value: value, receivedAt: receivedAt))
            resumeWaiters(for: id)
        }
    }

    private func connectionLost(_ id: PeripheralID, reason: String?) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        closeSubscriptions(of: id, reason: "peripheral disconnected" + (reason.map { ": \($0)" } ?? ""))
        if connection.state == .connected {
            recordLinkLoss(LinkLoss(peripheral: id, name: connection.name, reason: reason, at: .now))
            capture(.disconnected(id, reason: reason))
            eventSink.yield(.peripheralDisconnected(id, name: connection.name, reason: reason))
        }
    }

    private func recordLinkLoss(_ loss: LinkLoss) {
        linkLosses[loss.peripheral] = loss
        if linkLosses.count > Self.linkLossCapacity, let oldest = linkLosses.values.min(by: { $0.at < $1.at }) {
            linkLosses[oldest.peripheral] = nil
        }
    }

    private func ensurePoweredOn() async throws(BLEError) {
        guard !isShutDown else { throw .cancelled }
        let central = central
        do {
            try await withDeadline(configuration.timeouts.poweredOn, operation: "Waiting for Bluetooth to power on") {
                try await central.waitUntilPoweredOn()
            }
        } catch .timedOut {
            throw .bluetoothUnavailable(await central.state())
        }
        // The session may have shut down while the adapter came up.
        guard !isShutDown else { throw .cancelled }
    }
}

// MARK: - Internal state

private struct ActiveScan {
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

private struct Connection {
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
}

private struct Subscription {
    let id: SubscriptionID
    let address: CharacteristicAddress
    let userDescription: String?
    let mode: NotificationMode
    let createdAt = Date.now
    var state = SubscriptionState.pending
    var buffer: RingBuffer<ValueNotification>
    var receivedCount = 0
    var droppedCount = 0
    var droppedSinceLastRead = 0

    init(id: SubscriptionID, address: CharacteristicAddress, userDescription: String?, mode: NotificationMode, capacity: Int) {
        self.id = id
        self.address = address
        self.userDescription = userDescription
        self.mode = mode
        buffer = RingBuffer(capacity: capacity)
    }

    var isOpen: Bool {
        if case .closed = state { false } else { true }
    }

    mutating func record(_ notification: ValueNotification) {
        receivedCount += 1
        if buffer.append(notification) != nil {
            droppedCount += 1
            droppedSinceLastRead += 1
        }
    }

    var snapshot: SubscriptionSnapshot {
        SubscriptionSnapshot(
            id: id,
            address: address,
            userDescription: userDescription,
            mode: mode,
            state: state,
            createdAt: createdAt,
            receivedCount: receivedCount,
            droppedCount: droppedCount,
            bufferedCount: buffer.count)
    }
}

private struct NotificationWaiter {
    let token: UInt64
    /// `nil` waits for any subscription.
    let subscription: SubscriptionID?
    let continuation: CheckedContinuation<Void, Never>

    func isWaiting(for id: SubscriptionID) -> Bool {
        subscription == nil || subscription == id
    }
}
