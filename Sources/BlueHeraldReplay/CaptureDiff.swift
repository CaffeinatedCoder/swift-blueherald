public import BlueHeraldCore
public import Foundation

/// Compares what crossed the air in two captures, for regression checks: record a session, change
/// the code, record it again (against the device or a replay of the first), and diff the two.
///
/// Only writes (`tx`), notifications (`rx`) and characteristic reads are compared, by
/// characteristic and bytes, and by service when both captures recorded services. Timing,
/// peripheral ids (CoreBluetooth assigns them per Mac), markers and other `info` rows are ignored,
/// since they differ between any two runs.
public struct CaptureDiff: Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case tx, rx, read
    }

    public struct Entry: Hashable, Sendable, CustomStringConvertible {
        public let kind: Kind
        /// `nil` unless both captures recorded services.
        public let service: BLEUUID?
        public let characteristic: BLEUUID
        public let value: Data

        public init(kind: Kind, service: BLEUUID? = nil, characteristic: BLEUUID, value: Data) {
            self.kind = kind
            self.service = service
            self.characteristic = characteristic
            self.value = value
        }

        /// `rx   ff02 abcd`, or `rx   fff0/ff02 abcd` with the service.
        public var description: String {
            let path = (service.map { "\($0.description.lowercased())/" } ?? "") + characteristic.description.lowercased()
            return "\(kind.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) \(path) \(Hex.encode(value))"
        }
    }

    public struct Located: Hashable, Sendable {
        public let entry: Entry
        /// 1-based line in its capture.
        public let line: Int

        public init(entry: Entry, line: Int) {
            self.entry = entry
            self.line = line
        }
    }

    public enum Change: Hashable, Sendable {
        /// Only in the left capture.
        case removed(Located)
        /// Only in the right capture.
        case inserted(Located)
    }

    public let left: [Located]
    public let right: [Located]
    /// In capture order, as an edit script from left to right.
    public let changes: [Change]

    public init(_ left: CaptureRecording, _ right: CaptureRecording, kinds: Set<Kind> = Set(Kind.allCases)) {
        // A capture from before services were recorded can still be compared with a newer one.
        let withServices = Self.recordsServices(left) && Self.recordsServices(right)
        let left = Self.entries(of: left, kinds: kinds, withServices: withServices)
        let right = Self.entries(of: right, kinds: kinds, withServices: withServices)
        self.left = left
        self.right = right

        let difference = right.map(\.entry).difference(from: left.map(\.entry))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var changes: [Change] = []
        var (i, j) = (0, 0)
        while i < left.count || j < right.count {
            if i < left.count, removed.contains(i) {
                changes.append(.removed(left[i]))
                i += 1
            } else if j < right.count, inserted.contains(j) {
                changes.append(.inserted(right[j]))
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        self.changes = changes
    }

    public var isIdentical: Bool { changes.isEmpty }

    /// A report for people: the counts on each side, then up to `limit` changes with their lines.
    public func summary(leftName: String, rightName: String, limit: Int = 20) -> String {
        func counts(_ entries: [Located]) -> String {
            let byKind = Dictionary(grouping: entries, by: \.entry.kind)
            return Kind.allCases.map { "\(byKind[$0]?.count ?? 0) \($0.rawValue)" }.joined(separator: ", ")
        }
        var lines = [
            "- \(leftName): \(counts(left))",
            "+ \(rightName): \(counts(right))",
        ]
        guard !isIdentical else {
            lines.append("Identical: \(left.count) entries in the same order.")
            return lines.joined(separator: "\n")
        }
        let removals = changes.count { if case .removed = $0 { true } else { false } }
        lines.append("\(removals) only on the left, \(changes.count - removals) only on the right:")
        for change in changes.prefix(limit) {
            switch change {
            case .removed(let located): lines.append("- line \(located.line): \(located.entry)")
            case .inserted(let located): lines.append("+ line \(located.line): \(located.entry)")
            }
        }
        if changes.count > limit {
            lines.append("… and \(changes.count - limit) more.")
        }
        return lines.joined(separator: "\n")
    }

    private static func entries(of recording: CaptureRecording, kinds: Set<Kind>, withServices: Bool) -> [Located] {
        recording.rows.compactMap { row in
            let compared: (Kind, BLEUUID, Data)? =
                switch row.meaning {
                case .write(let characteristic, let value, _): (.tx, characteristic, value)
                case .notification(let characteristic, let value): (.rx, characteristic, value)
                case .read(let characteristic, let value): (.read, characteristic, value)
                default: nil
                }
            guard let (kind, characteristic, value) = compared, kinds.contains(kind) else { return nil }
            let entry = Entry(kind: kind, service: withServices ? row.service : nil, characteristic: characteristic, value: value)
            return Located(entry: entry, line: row.line)
        }
    }

    private static func recordsServices(_ recording: CaptureRecording) -> Bool {
        recording.rows.contains { row in
            switch row.meaning {
            case .write, .notification, .read: row.service != nil
            default: false
            }
        }
    }
}
