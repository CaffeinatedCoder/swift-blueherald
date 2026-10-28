public import BLEMCPCore
public import Foundation

/// A capture turned into what a replay needs: the devices to advertise and serve, and a timeline
/// of recorded requests, each with what the device sent after it.
///
/// A request is a write or a subscription. Its replies are the notifications (and a link loss, if
/// one happened) recorded after it and before the next request, with their delays. Reads are kept
/// apart and answered by timeline position, see `ReplayCentral`.
///
/// Older captures, and swift-dragoman's fixtures, have no `gatt` or `advertisement` rows. For a
/// device without them the attribute table is inferred from the rows: written characteristics
/// become writable, notifying ones notify, read ones are readable, all in one service with the
/// UUID `inferredService`.
public struct ReplayScript: Sendable {
    public struct Device: Hashable, Sendable {
        public let id: PeripheralID
        public let name: String?
        public let rssi: Int?
        public let isConnectable: Bool?
        public let txPowerLevel: Int?
        public let advertisedServices: [BLEUUID]
        public let manufacturerData: Data?
        public let serviceData: [BLEUUID: Data]
        public let services: [GATTService]
        /// Whether `services` came from the rows rather than a recorded `gatt` row.
        public let isInferred: Bool
    }

    public enum Request: Hashable, Sendable {
        case write(BLEUUID, Data)
        case subscribe(BLEUUID)
    }

    public enum Reply: Hashable, Sendable {
        case notification(BLEUUID, Data)
        case linkLoss(reason: String?)
    }

    public struct Step: Hashable, Sendable {
        public let reply: Reply
        /// Seconds after the request.
        public let delay: Double
    }

    public struct Trigger: Hashable, Sendable {
        public let peripheral: PeripheralID
        public let request: Request
        public let line: Int
        public let replies: [Step]
    }

    public struct RecordedRead: Hashable, Sendable {
        public let peripheral: PeripheralID
        public let characteristic: BLEUUID
        public let descriptor: BLEUUID?
        public let value: Data
        /// Index of the last request recorded before the read, if any.
        public let afterTrigger: Int?
    }

    /// The service an inferred attribute table puts every characteristic in (ASCII "REPLAY").
    public static let inferredService = BLEUUID("52455050-4C41-5900-0000-000000000000")!
    /// The peripheral a capture that names none is played as.
    public static let inferredPeripheral = PeripheralID(UUID(uuidString: "52455050-4C41-5900-0000-000000000001")!)

    public let devices: [Device]
    public let triggers: [Trigger]
    public let reads: [RecordedRead]

    /// Disconnects the session asked for; any other reason is a link loss worth replaying.
    private static let requestedDisconnects: Set<String> = ["disconnected on request", "server shutting down"]

    public init(_ recording: CaptureRecording) {
        var builder = Builder()
        for row in recording.rows {
            builder.add(row)
        }
        builder.finishTrigger()
        devices = builder.devices()
        triggers = builder.triggers
        reads = builder.reads
    }

    private struct Builder {
        /// Devices in order of first mention, with what the rows said about them.
        var order: [PeripheralID] = []
        var advertisements: [PeripheralID: CaptureRow] = [:]
        var names: [PeripheralID: String] = [:]
        var tables: [PeripheralID: [GATTService]] = [:]
        var usage: [PeripheralID: [BLEUUID: Usage]] = [:]
        var usageOrder: [PeripheralID: [BLEUUID]] = [:]
        var current: PeripheralID?

        var triggers: [Trigger] = []
        var reads: [RecordedRead] = []
        var open: (peripheral: PeripheralID, request: Request, line: Int, time: Double, replies: [Step])?

        struct Usage {
            var properties: CharacteristicProperties = []
            var descriptors: [BLEUUID] = []
        }

        mutating func mention(_ id: PeripheralID) {
            if !order.contains(id) { order.append(id) }
            current = id
        }

        var peripheral: PeripheralID {
            mutating get {
                if let current { return current }
                mention(ReplayScript.inferredPeripheral)
                return ReplayScript.inferredPeripheral
            }
        }

        mutating func use(_ characteristic: BLEUUID, _ properties: CharacteristicProperties, descriptor: BLEUUID? = nil) {
            let id = peripheral
            if usage[id]?[characteristic] == nil { usageOrder[id, default: []].append(characteristic) }
            usage[id, default: [:]][characteristic, default: Usage()].properties.formUnion(properties)
            if let descriptor, usage[id]?[characteristic]?.descriptors.contains(descriptor) == false {
                usage[id]?[characteristic]?.descriptors.append(descriptor)
            }
        }

        mutating func add(_ row: CaptureRow) {
            switch row.meaning {
            case .advertisement(let id):
                mention(id)
                advertisements[id] = row
            case .connected(let id, let name):
                if let id { mention(id) }
                if let name { names[peripheral] = name }
            case .device(let id):
                mention(id)
            case .gatt(let id, let services):
                if let id { mention(id) }
                tables[peripheral] = services
            case .write(let characteristic, let value, let mode):
                let properties: CharacteristicProperties =
                    switch mode {
                    case .withResponse: .write
                    case .withoutResponse: .writeWithoutResponse
                    case nil: [.write, .writeWithoutResponse]
                    }
                use(characteristic, properties)
                startTrigger(.write(characteristic, value), row: row)
            case .notificationsEnabled(let characteristic, let mode):
                use(characteristic, mode == .notify ? .notify : .indicate, descriptor: GATTDescriptor.clientCharacteristicConfiguration)
                startTrigger(.subscribe(characteristic), row: row)
            case .notification(let characteristic, let value):
                // Values of an indicating characteristic arrive as rx rows too.
                let isSubscribable = usage[peripheral]?[characteristic]?.properties.isDisjoint(with: [.notify, .indicate]) == false
                use(characteristic, isSubscribable ? [] : .notify, descriptor: GATTDescriptor.clientCharacteristicConfiguration)
                // Notifications with no request before them (a capture started mid-stream) are
                // played once the agent subscribes.
                if open == nil { startTrigger(.subscribe(characteristic), row: row) }
                let start = open?.time ?? row.time
                open?.replies.append(Step(reply: .notification(characteristic, value), delay: row.time - start))
            case .read(let characteristic, let value):
                use(characteristic, .read)
                reads.append(RecordedRead(peripheral: peripheral, characteristic: characteristic, descriptor: nil, value: value, afterTrigger: lastTrigger))
            case .descriptorRead(let characteristic, let descriptor, let value):
                use(characteristic, [], descriptor: descriptor)
                reads.append(RecordedRead(peripheral: peripheral, characteristic: characteristic, descriptor: descriptor, value: value, afterTrigger: lastTrigger))
            case .disconnected(_, let reason):
                if let reason, !ReplayScript.requestedDisconnects.contains(reason), let start = open?.time {
                    open?.replies.append(Step(reply: .linkLoss(reason: reason), delay: row.time - start))
                }
                finishTrigger()
            case .notificationsDisabled, .other:
                break
            }
        }

        /// Index the next trigger gets, minus one: the last trigger started so far.
        var lastTrigger: Int? {
            let count = triggers.count + (open == nil ? 0 : 1)
            return count == 0 ? nil : count - 1
        }

        mutating func startTrigger(_ request: Request, row: CaptureRow) {
            finishTrigger()
            open = (peripheral, request, row.line, row.time, [])
        }

        mutating func finishTrigger() {
            guard let open else { return }
            triggers.append(Trigger(peripheral: open.peripheral, request: open.request, line: open.line, replies: open.replies))
            self.open = nil
        }

        func devices() -> [Device] {
            order.map { id in
                let advertisement = advertisements[id]
                let table = tables[id]
                return Device(
                    id: id,
                    name: names[id] ?? advertisement?.name,
                    rssi: advertisement?.rssi,
                    isConnectable: advertisement?.isConnectable ?? true,
                    txPowerLevel: advertisement?.txPowerLevel,
                    advertisedServices: advertisement?.advertisedServices ?? [],
                    manufacturerData: advertisement?.manufacturerData,
                    serviceData: advertisement?.serviceData ?? [:],
                    services: table ?? inferredTable(of: id),
                    isInferred: table == nil)
            }
        }

        func inferredTable(of id: PeripheralID) -> [GATTService] {
            let characteristics = (usageOrder[id] ?? []).compactMap { uuid in
                usage[id]?[uuid].map { usage in
                    GATTCharacteristic(uuid: uuid, properties: usage.properties, descriptors: usage.descriptors.map(GATTDescriptor.init))
                }
            }
            return characteristics.isEmpty ? [] : [GATTService(uuid: ReplayScript.inferredService, characteristics: characteristics)]
        }
    }
}
