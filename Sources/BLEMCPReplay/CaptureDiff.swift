public import BLEMCPCore
public import Foundation

/// Compares what crossed the air in two captures, for regression checks: record a session, change
/// the code, record it again (against the device or a replay of the first), and diff the two.
///
/// Only writes (`tx`), notifications (`rx`) and characteristic reads are compared, by
/// characteristic and bytes. Timing, markers and other `info` rows are ignored, since they differ
/// between any two runs.
public struct CaptureDiff: Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case tx, rx, read
    }

    public struct Entry: Hashable, Sendable, CustomStringConvertible {
        public let kind: Kind
        public let characteristic: BLEUUID
        public let value: Data

        public init(kind: Kind, characteristic: BLEUUID, value: Data) {
            self.kind = kind
            self.characteristic = characteristic
            self.value = value
        }

        public var description: String {
            "\(kind.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) \(characteristic.description.lowercased()) \(Hex.encode(value))"
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
        let left = Self.entries(of: left, kinds: kinds)
        let right = Self.entries(of: right, kinds: kinds)
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

    private static func entries(of recording: CaptureRecording, kinds: Set<Kind>) -> [Located] {
        recording.rows.compactMap { row in
            let entry: Entry? =
                switch row.meaning {
                case .write(let characteristic, let value, _): Entry(kind: .tx, characteristic: characteristic, value: value)
                case .notification(let characteristic, let value): Entry(kind: .rx, characteristic: characteristic, value: value)
                case .read(let characteristic, let value): Entry(kind: .read, characteristic: characteristic, value: value)
                default: nil
                }
            guard let entry, kinds.contains(entry.kind) else { return nil }
            return Located(entry: entry, line: row.line)
        }
    }
}
