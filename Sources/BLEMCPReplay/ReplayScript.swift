public import BLEMCPCore
public import Foundation

/// A capture turned into what a replay needs: the devices to advertise and serve, and a timeline
/// of recorded requests, each with what the device sent after it.
///
/// A request is a write or a subscription. Its replies are what the same device sent after it, up
/// to that device's next request: notifications, and a link loss if one happened, with their
/// delays. Reads are kept apart and answered by timeline position, see `ReplayCentral`.
///
/// Rows name their peripheral and service. Older captures, and swift-dragoman's fixtures, do not:
/// their rows belong to the device last mentioned, on any service. A file a server appended to
/// holds several runs; a request never takes replies from the next run.
///
/// Older captures also have no `gatt` or `advertisement` rows. For a device without them the
/// attribute table is inferred from the rows: written characteristics become writable, notifying
/// ones notify, read ones are readable, in their recorded services or else in one service with the
/// UUID `inferredService`.
public struct ReplayScript: Sendable {
    public struct Device: Hashable, Sendable {
        public let id: PeripheralID
        /// The name it gave once connected (its GAP name).
        public let name: String?
        /// The name scans saw. It can differ from `name`: an iPhone running a LightBlue virtual
        /// device advertises the virtual device's name and connects as "iPhone".
        public let advertisedName: String?
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
        /// The service is `nil` when the capture did not record it.
        case notification(BLEUUID, Data, service: BLEUUID? = nil)
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
        /// The service of the request's characteristic, `nil` when the capture did not record it.
        public let service: BLEUUID?
        public let line: Int
        public let replies: [Step]
    }

    public struct RecordedRead: Hashable, Sendable {
        public let peripheral: PeripheralID
        public let service: BLEUUID?
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
        devices = builder.devices()
        triggers = builder.drafts.map {
            Trigger(peripheral: $0.peripheral, request: $0.request, service: $0.service, line: $0.line, replies: $0.replies)
        }
        reads = builder.reads
    }

    private struct Builder {
        /// Devices in order of first mention, with what the rows said about them.
        var order: [PeripheralID] = []
        var advertisements: [PeripheralID: CaptureRow] = [:]
        var names: [PeripheralID: String] = [:]
        var tables: [PeripheralID: [GATTService]] = [:]
        var usage: [PeripheralID: [Attribute: Usage]] = [:]
        var usageOrder: [PeripheralID: [Attribute]] = [:]
        /// The device rows without a peripheral belong to.
        var current: PeripheralID?

        /// Every request in recorded order; replies are added while it is open.
        var drafts: [Draft] = []
        /// Each device's latest request, while what the device sends still answers it.
        var open: [PeripheralID: Int] = [:]
        var reads: [RecordedRead] = []

        struct Draft {
            let peripheral: PeripheralID
            let request: Request
            let service: BLEUUID?
            let line: Int
            let time: Double
            var replies: [Step] = []
        }

        struct Attribute: Hashable {
            let service: BLEUUID?
            let characteristic: BLEUUID
        }

        struct Usage {
            var properties: CharacteristicProperties = []
            var descriptors: [BLEUUID] = []
        }

        mutating func mention(_ id: PeripheralID) {
            if !order.contains(id) { order.append(id) }
            current = id
        }

        /// The row's peripheral, or for older captures the device last mentioned.
        mutating func device(of row: CaptureRow) -> PeripheralID {
            if let id = row.peripheral {
                mention(id)
                return id
            }
            if let current { return current }
            mention(ReplayScript.inferredPeripheral)
            return ReplayScript.inferredPeripheral
        }

        mutating func use(
            _ characteristic: BLEUUID, in service: BLEUUID?, on id: PeripheralID, _ properties: CharacteristicProperties,
            descriptor: BLEUUID? = nil
        ) {
            let attribute = Attribute(service: service, characteristic: characteristic)
            if usage[id]?[attribute] == nil { usageOrder[id, default: []].append(attribute) }
            usage[id, default: [:]][attribute, default: Usage()].properties.formUnion(properties)
            if let descriptor, usage[id]?[attribute]?.descriptors.contains(descriptor) == false {
                usage[id]?[attribute]?.descriptors.append(descriptor)
            }
        }

        mutating func add(_ row: CaptureRow) {
            switch row.meaning {
            case .runStarted:
                // A new run: its clock starts again, and its devices are mentioned afresh.
                open.removeAll()
                current = nil
            case .advertisement(let id):
                mention(id)
                advertisements[id] = row
            case .connected(_, let name):
                let id = device(of: row)
                if let name { names[id] = name }
            case .device(let id):
                mention(id)
            case .gatt(_, let services):
                tables[device(of: row)] = services
            case .write(let characteristic, let value, let mode):
                let id = device(of: row)
                let properties: CharacteristicProperties =
                    switch mode {
                    case .withResponse: .write
                    case .withoutResponse: .writeWithoutResponse
                    case nil: [.write, .writeWithoutResponse]
                    }
                use(characteristic, in: row.service, on: id, properties)
                startRequest(.write(characteristic, value), on: id, row: row)
            case .notificationsEnabled(let characteristic, let mode):
                let id = device(of: row)
                use(
                    characteristic, in: row.service, on: id, mode == .notify ? .notify : .indicate,
                    descriptor: GATTDescriptor.clientCharacteristicConfiguration)
                startRequest(.subscribe(characteristic), on: id, row: row)
            case .notification(let characteristic, let value):
                let id = device(of: row)
                // Values of an indicating characteristic arrive as rx rows too.
                let attribute = Attribute(service: row.service, characteristic: characteristic)
                let isSubscribable = usage[id]?[attribute]?.properties.isDisjoint(with: [.notify, .indicate]) == false
                use(
                    characteristic, in: row.service, on: id, isSubscribable ? [] : .notify,
                    descriptor: GATTDescriptor.clientCharacteristicConfiguration)
                // Notifications with no request before them (a capture started mid-stream) are
                // played once the agent subscribes.
                if open[id] == nil { startRequest(.subscribe(characteristic), on: id, row: row) }
                reply(.notification(characteristic, value, service: row.service), on: id, at: row.time)
            case .read(let characteristic, let value):
                let id = device(of: row)
                use(characteristic, in: row.service, on: id, .read)
                reads.append(
                    RecordedRead(
                        peripheral: id, service: row.service, characteristic: characteristic, descriptor: nil, value: value,
                        afterTrigger: lastRequest))
            case .descriptorRead(let characteristic, let descriptor, let value):
                let id = device(of: row)
                use(characteristic, in: row.service, on: id, [], descriptor: descriptor)
                reads.append(
                    RecordedRead(
                        peripheral: id, service: row.service, characteristic: characteristic, descriptor: descriptor,
                        value: value, afterTrigger: lastRequest))
            case .disconnected(_, let reason):
                let id = device(of: row)
                if let reason, !ReplayScript.requestedDisconnects.contains(reason) {
                    reply(.linkLoss(reason: reason), on: id, at: row.time)
                }
                open[id] = nil
            case .notificationsDisabled, .other:
                break
            }
        }

        /// The last request recorded so far.
        var lastRequest: Int? {
            drafts.isEmpty ? nil : drafts.count - 1
        }

        mutating func startRequest(_ request: Request, on id: PeripheralID, row: CaptureRow) {
            open[id] = drafts.count
            drafts.append(Draft(peripheral: id, request: request, service: row.service, line: row.line, time: row.time))
        }

        mutating func reply(_ reply: Reply, on id: PeripheralID, at time: Double) {
            guard let index = open[id] else { return }
            drafts[index].replies.append(Step(reply: reply, delay: max(0, time - drafts[index].time)))
        }

        func devices() -> [Device] {
            order.map { id in
                let advertisement = advertisements[id]
                let table = tables[id]
                return Device(
                    id: id,
                    name: names[id] ?? advertisement?.name,
                    advertisedName: advertisement?.name ?? names[id],
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

        /// One service per recorded service UUID, in order of first use; characteristics recorded
        /// without one go to `inferredService`.
        func inferredTable(of id: PeripheralID) -> [GATTService] {
            var services: [BLEUUID] = []
            var characteristics: [BLEUUID: [GATTCharacteristic]] = [:]
            for attribute in usageOrder[id] ?? [] {
                guard let usage = usage[id]?[attribute] else { continue }
                let service = attribute.service ?? ReplayScript.inferredService
                if characteristics[service] == nil { services.append(service) }
                characteristics[service, default: []].append(
                    GATTCharacteristic(
                        uuid: attribute.characteristic, properties: usage.properties,
                        descriptors: usage.descriptors.map(GATTDescriptor.init)))
            }
            return services.map { GATTService(uuid: $0, characteristics: characteristics[$0] ?? []) }
        }
    }
}
