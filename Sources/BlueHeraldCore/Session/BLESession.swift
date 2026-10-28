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

    // The bookkeeping and its invariants live in value types; the actor keeps the suspension
    // points and what has to be checked again after each of them.
    private var scans = ScanRegistry()
    private var connections = ConnectionTable()
    private var subscriptions = SubscriptionTable()
    private var waiters = WaiterQueue<CheckedContinuation<Void, Never>>()
    /// Resumed with `true` once the reply subscription is theirs, `false` on shutdown.
    private var transactions = TransactionQueue<CheckedContinuation<Bool, Never>>()

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
        eventPump = Task(name: "blueherald.session.events") { [weak self] in
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
        scans.closeAll()
        let peripherals = connections.ids
        for id in peripherals {
            closeSubscriptions(of: id, reason: "server shutting down")
            if connections[id]?.state == .connected {
                capture(.disconnected(id, reason: "server shutting down"))
            }
        }
        connections.removeAll()
        waiters.takeAll().forEach { $0.resume() }
        transactions.takeAll().forEach { $0.resume(returning: false) }
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
            activeScans: scans.activeIDs,
            connections: await connectionSnapshots(),
            subscriptions: subscriptions.snapshots,
            linkLosses: connections.newestLinkLossesFirst,
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
        try scans.ensureCapacity(limit: configuration.limits.maxScans)
        try await ensurePoweredOn()
        let stream = try await central.scan()
        // Re-check after suspending: the session may have shut down, or another call taken the
        // last slot. Dropping the unused stream terminates it, which releases the backend scan.
        guard !isShutDown else { throw .cancelled }
        try scans.ensureCapacity(limit: configuration.limits.maxScans)

        let id = scans.nextID()
        var scan = ActiveScan(id: id, filter: filter, stopAfter: stopAfter)
        scan.consumer = Task(name: "blueherald.\(id).advertisements") { [weak self] in
            for await advertisement in stream {
                guard let self else { return }
                await self.record(advertisement, in: id)
            }
        }
        if let duration {
            scan.timer = Task(name: "blueherald.\(id).timer") { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await self?.finishScan(id)
            }
        }
        scans.insert(scan)
        return id
    }

    public func scanResults(_ id: ScanID, maxResults: Int = .max) throws(BLEError) -> ScanSnapshot {
        try scans.snapshot(id, maxResults: maxResults)
    }

    /// Stops the scan if it is running and returns its final results. The scan is then forgotten.
    @discardableResult
    public func stopScan(_ id: ScanID, maxResults: Int = .max) throws(BLEError) -> ScanSnapshot {
        try scans.stop(id, maxResults: maxResults)
    }

    private func record(_ advertisement: Advertisement, in id: ScanID) {
        scans.record(advertisement, in: id, limit: configuration.limits.maxPeripheralsPerScan)
    }

    private func finishScan(_ id: ScanID) {
        scans.finish(id)
    }

    private func waitForScanEnd(_ id: ScanID) async {
        // Isolation passed explicitly, as in `waitForNotification`.
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    guard !Task.isCancelled, scans.resumeWhenFinished(id, continuation) else {
                        continuation.resume()
                        return
                    }
                }
            },
            onCancel: { Task { await self.finishScan(id) } },
            isolation: self)
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

        let limit = configuration.limits.maxConnections
        try connections.ensureCapacity(limit: limit)
        try await ensurePoweredOn()
        guard connections[id] == nil else { throw .alreadyConnecting(id) }
        try connections.ensureCapacity(limit: limit)
        let attempt = connections.begin(id, name: scans.seen[id]?.name)

        let central = central
        let peripheral: ConnectedPeripheral
        do {
            peripheral = try await withDeadline(configuration.timeouts.connect, operation: "Connecting to \(id)") {
                try await central.connect(id)
            }
        } catch {
            connections.abandon(id, attempt: attempt)
            throw error
        }

        guard connections.isOwned(id, by: attempt) else {
            // Disconnected or shut down while the link came up. A newer attempt that owns the
            // entry now gets this same link, so only an untracked one is closed.
            if connections[id] == nil {
                await central.disconnect(id)
            }
            guard !isShutDown else { throw .cancelled }
            throw .disconnected(id, reason: "the connection was closed while it was being established")
        }
        connections.markConnected(id, name: peripheral.name ?? scans.seen[id]?.name)
        if let advertised = scans.seen[id] {
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
        guard connections.remove(id) != nil else { return false }
        closeSubscriptions(of: id, reason: "disconnected on request")
        capture(.disconnected(id, reason: "disconnected on request"))
        await central.disconnect(id)
        return true
    }

    public func connectionSnapshots() async -> [ConnectionSnapshot] {
        var snapshots: [ConnectionSnapshot] = []
        for id in connections.ids {
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
        return connection.snapshot(subscriptions: subscriptions.ids(of: id), maximumWriteLength: lengths)
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
        let connection = try connections.requireConnected(id)
        var services: [GATTService]
        var isNew = false
        if !refresh, let cached = connection.services {
            services = cached
        } else {
            services = try await discoverAttributeTable(of: id)
            isNew = true
        }
        if userDescriptions, connections[id]?.hasUserDescriptions == false {
            services = await UserDescriptions.read(
                of: id, into: services, from: central, perRead: min(configuration.timeouts.operation, .seconds(2)))
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

    public func read(_ selector: CharacteristicSelector) async throws(BLEError) -> CharacteristicValue {
        let target = try await resolve(selector)
        try target.require(.read, named: "read")
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
        try await send(try await prepareWrite(value, to: selector, mode: requestedMode))
    }

    /// Everything a write checks before it goes out, some of which suspends.
    private func prepareWrite(
        _ value: Data,
        to selector: CharacteristicSelector,
        mode requestedMode: WriteMode?
    ) async throws(BLEError) -> PreparedWrite {
        // Policy first: a refused frame never causes discovery, let alone reaches the radio.
        try configuration.writePolicy.checkWrite(value, to: selector.characteristic)
        let target = try await resolve(selector)
        let mode = try target.writeMode(requested: requestedMode)
        let maximum = try await central.maximumWriteLength(for: target.address.peripheral, mode: mode)
        guard value.count <= maximum else { throw .payloadTooLarge(size: value.count, maximum: maximum) }
        return PreparedWrite(value: value, address: target.address, mode: mode)
    }

    private func send(_ write: PreparedWrite) async throws(BLEError) -> WriteReceipt {
        let central = central
        let (value, address, mode) = (write.value, write.address, write.mode)
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
        _ = try connections.requireConnected(id)
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

    // MARK: - Request and reply

    /// Writes `value` and waits up to `timeout` for the device's answer: the first notification
    /// on `replySelector` after the write that starts with `prefix`.
    ///
    /// The reply characteristic is subscribed to before the write, so even an immediate answer is
    /// caught, and the subscription stays open so the next exchange is just as safe. The reply is
    /// taken out of the buffer; anything else that arrived stays readable with `notifications`.
    /// Exchanges that wait on the same reply characteristic run one after the other, so neither
    /// can take the other's answer. Not having an answer is not an error: the write happened,
    /// and the result says so.
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
        let id = try await claimReplies(on: replySelector)
        defer { releaseReplies(on: id) }
        let write = try await prepareWrite(value, to: selector, mode: mode)
        // Opened only now, with nothing left to wait for before the write goes out: whatever
        // arrived while the write was being prepared is not its answer.
        let window = subscriptions.replyWindow()
        let receipt = try await send(write)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var reply = subscriptions.takeFirst(on: id, in: window, prefix: prefix)
        // A cancelled wait returns at once, so cancellation must end the loop.
        while reply == nil, subscriptions[id]?.isOpen == true, clock.now < deadline, !Task.isCancelled {
            await waitForNotification(on: id, timeout: deadline - clock.now)
            reply = subscriptions.takeFirst(on: id, in: window, prefix: prefix)
        }
        if reply == nil, Task.isCancelled {
            throw .cancelled
        }
        if reply == nil, subscriptions[id]?.isOpen != true {
            // The link went while waiting; say so rather than reporting a silent device.
            _ = try connections.requireConnected(replySelector.peripheral)
        }
        guard let subscription = subscriptions[id] else { throw .subscriptionNotFound(id) }
        return Transaction(
            write: receipt,
            reply: reply,
            latency: reply.map { .milliseconds(Int(($0.receivedAt.timeIntervalSince(window.sentAt) * 1000).rounded())) },
            unmatched: subscriptions.unmatched(on: id, in: window, prefix: prefix),
            subscription: subscription.snapshot,
            timeout: timeout)
    }

    /// Subscribes to `selector` and waits until no other transaction waits on that subscription.
    /// Returns it open and claimed; the caller releases it.
    private func claimReplies(on selector: CharacteristicSelector) async throws(BLEError) -> SubscriptionID {
        while true {
            let id = try await subscribe(selector).id
            let token = transactions.nextToken()
            // Isolation passed explicitly, as in `waitForNotification`.
            let claimed = await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        guard !Task.isCancelled else {
                            continuation.resume(returning: false)
                            return
                        }
                        if transactions.enter(id, token: token, waker: continuation) {
                            continuation.resume(returning: true)
                        }
                    }
                },
                onCancel: { Task { await self.withdrawClaim(token) } },
                isolation: self)
            guard claimed else { throw .cancelled }
            // Cancelled just as it was handed over: pass it on.
            guard !Task.isCancelled else {
                releaseReplies(on: id)
                throw .cancelled
            }
            // Waiting for the turn can take a whole exchange; the subscription may be gone by now.
            if subscriptions[id]?.isOpen == true { return id }
            releaseReplies(on: id)
        }
    }

    private func releaseReplies(on id: SubscriptionID) {
        transactions.leave(id)?.resume(returning: true)
    }

    private func withdrawClaim(_ token: UInt64) {
        transactions.withdraw(token)?.resume(returning: false)
    }

    // MARK: - Subscriptions

    /// Enables notifications (or indications) and starts buffering them. Subscribing to a
    /// characteristic that already has an open subscription returns that subscription, once
    /// notifications are on: a call that arrives while another is still enabling them waits for
    /// it, and tries again itself if that one fails.
    public func subscribe(_ selector: CharacteristicSelector) async throws(BLEError) -> SubscriptionSnapshot {
        while true {
            let target = try await resolve(selector)
            guard let existing = subscriptions.open(at: target.address) else {
                return try await enableSubscription(target)
            }
            guard existing.state == .pending else { return existing.snapshot }
            // Woken when the other call activates or discards it; its own deadline bounds the wait.
            await waitForNotification(on: existing.id, timeout: configuration.timeouts.operation)
            guard !Task.isCancelled else { throw .cancelled }
        }
    }

    private func enableSubscription(_ target: ResolvedCharacteristic) async throws(BLEError) -> SubscriptionSnapshot {
        let address = target.address
        let mode = try target.notificationMode()
        try subscriptions.ensureCapacity(limit: configuration.limits.maxSubscriptions)
        let id = subscriptions.add(
            on: address, userDescription: target.characteristic.userDescription, mode: mode,
            capacity: configuration.limits.notificationBufferCapacity)

        let central = central
        do {
            try await withDeadline(configuration.timeouts.operation, operation: "Enabling notifications on \(address.characteristic)") {
                try await central.setNotifications(true, for: address)
            }
        } catch {
            discardSubscription(id)
            throw error
        }

        guard subscriptions.activate(id) else {
            // The peripheral disconnected while notifications were being enabled.
            discardSubscription(id)
            throw .disconnected(address.peripheral, reason: "the peripheral disconnected while subscribing")
        }
        waiters.takeJoiners(of: id).forEach { $0.resume() }
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
        guard wait > .zero, subscriptions.bufferedCount(in: id) == 0 else { return drain(id, maxCount: maxCount, waited: nil) }
        guard subscriptions.canReceive(in: id) else { return drain(id, maxCount: maxCount, waited: nil, skipped: true) }
        let clock = ContinuousClock()
        let start = clock.now
        await waitForNotification(on: id, timeout: wait)
        return drain(id, maxCount: maxCount, waited: clock.now - start)
    }

    /// - Parameters:
    ///   - waited: How long the call waited before draining, if it did.
    ///   - skipped: A wait was asked for but nothing could arrive.
    private func drain(_ id: SubscriptionID?, maxCount: Int, waited: Duration?, skipped: Bool = false) -> NotificationBatch {
        let drained = subscriptions.drain(id, maxCount: maxCount)
        let wait: NotificationBatch.WaitOutcome =
            if skipped {
                .skipped
            } else if let waited, drained.notifications.isEmpty {
                .nothingArrived(after: waited)
            } else {
                .none
            }
        return NotificationBatch(
            notifications: drained.notifications, remaining: drained.remaining, dropped: drained.dropped,
            subscriptions: drained.subscriptions, wait: wait)
    }

    private func waitForNotification(on id: SubscriptionID?, timeout: Duration) async {
        let token = waiters.nextToken()
        let timer = Task(name: "blueherald.notification-wait.timer") { [weak self] in
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
                    waiters.add(continuation, token: token, waitingFor: id)
                }
            },
            onCancel: { Task { await self.resumeWaiter(token) } },
            isolation: self)
    }

    private func resumeWaiter(_ token: UInt64) {
        waiters.remove(token)?.resume()
    }

    private func resumeWaiters(for id: SubscriptionID) {
        waiters.take(for: id).forEach { $0.resume() }
    }

    private func discardSubscription(_ id: SubscriptionID) {
        guard subscriptions.discard(id) != nil else { return }
        resumeWaiters(for: id)
    }

    private func closeSubscriptions(of peripheral: PeripheralID, reason: String) {
        for id in subscriptions.close(of: peripheral, reason: reason) {
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
            for id in connections.ids {
                connectionLost(id, reason: "Bluetooth became \(state.rawValue)")
            }
            scans.finishAll()

        case .disconnected(let id, let reason):
            connectionLost(id, reason: reason)

        case .valueUpdated(let address, let value, let receivedAt):
            guard let id = subscriptions.record(value, from: address, receivedAt: receivedAt) else { return }
            capture(.notification(address, value), at: receivedAt)
            resumeWaiters(for: id)
        }
    }

    private func connectionLost(_ id: PeripheralID, reason: String?) {
        guard let connection = connections.lose(id, reason: reason) else { return }
        closeSubscriptions(of: id, reason: "peripheral disconnected" + (reason.map { ": \($0)" } ?? ""))
        if connection.state == .connected {
            capture(.disconnected(id, reason: reason))
            eventSink.yield(.peripheralDisconnected(id, name: connection.name, reason: reason))
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

/// A write that has passed every check and only has to go out.
private struct PreparedWrite: Sendable {
    let value: Data
    let address: CharacteristicAddress
    let mode: WriteMode
}
