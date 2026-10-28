/// The phantom tag that gives each kind of session identifier its own type and prefix.
public protocol IdentifierKind {
    static var prefix: String { get }
}

/// A short, human-typable identifier such as `scan-3` or `sub-12`, typed by what it identifies
/// so a scan ID can never be passed where a subscription ID is expected.
public struct SessionIdentifier<Kind: IdentifierKind>: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init?(_ text: some StringProtocol) {
        let parts = text.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0] == Kind.prefix, let value = Int(parts[1]), value > 0 else { return nil }
        rawValue = value
    }

    public var description: String { "\(Kind.prefix)-\(rawValue)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ScanKind: IdentifierKind {
    public static var prefix: String { "scan" }
}

public enum SubscriptionKind: IdentifierKind {
    public static var prefix: String { "sub" }
}

public typealias ScanID = SessionIdentifier<ScanKind>
public typealias SubscriptionID = SessionIdentifier<SubscriptionKind>
