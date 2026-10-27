public import BLEMCPCore
import Foundation
public import MCP

// Tool arguments are declared once, as `ToolArgument` values. The same value produces the
// JSON-schema property advertised in `tools/list` and parses the argument in `tools/call`, so
// schema and parsing cannot drift apart.
//
// Parsing is deliberately lenient about encoding and strict about meaning: MCP clients send
// `5000`, `5000.0` or `"5000"` for the same integer, so all three are accepted, but `5000.5`
// or an out-of-range value is rejected with a message that names the argument.

/// A type that can be read from a JSON tool argument.
public protocol ArgumentValue: Sendable {
    /// The JSON schema of the value itself, without description or default.
    static var schema: [String: Value] { get }
    /// What the agent sees when parsing fails, e.g. "an integer".
    static var expectation: String { get }
    /// Returns `nil` when `value` does not encode a valid instance.
    init?(argument value: Value)
    /// The value as JSON, used for schema defaults.
    var jsonValue: Value { get }
}

extension Int: ArgumentValue {
    public static var schema: [String: Value] { ["type": "integer"] }
    public static var expectation: String { "an integer" }

    public init?(argument value: Value) {
        switch value {
        case .int(let int): self = int
        // `Int(exactly:)` rather than `Int(_:)`, which traps on NaN, infinity and out-of-range values.
        case .double(let double): guard let int = Int(exactly: double) else { return nil }; self = int
        case .string(let text): guard let int = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }; self = int
        default: return nil
        }
    }

    public var jsonValue: Value { .int(self) }
}

extension Bool: ArgumentValue {
    public static var schema: [String: Value] { ["type": "boolean"] }
    public static var expectation: String { "a boolean" }

    public init?(argument value: Value) {
        switch value {
        case .bool(let bool): self = bool
        case .int(0): self = false
        case .int(1): self = true
        case .string(let text):
            switch text.lowercased() {
            case "true", "yes", "1": self = true
            case "false", "no", "0": self = false
            default: return nil
            }
        default: return nil
        }
    }

    public var jsonValue: Value { .bool(self) }
}

extension String: ArgumentValue {
    public static var schema: [String: Value] { ["type": "string"] }
    public static var expectation: String { "a string" }

    public init?(argument value: Value) {
        guard case .string(let text) = value else { return nil }
        self = text
    }

    public var jsonValue: Value { .string(self) }
}

extension BLEUUID: ArgumentValue {
    public static var schema: [String: Value] { ["type": "string"] }
    public static var expectation: String {
        "a Bluetooth UUID such as \"180F\", \"0x2A19\" or \"6E400001-B5A3-F393-E0A9-E50E24DCCA9E\""
    }

    public init?(argument value: Value) {
        guard case .string(let text) = value else { return nil }
        self.init(text)
    }

    public var jsonValue: Value { .string(description) }
}

extension PeripheralID: ArgumentValue {
    public static var schema: [String: Value] { ["type": "string", "format": "uuid"] }
    public static var expectation: String { "a peripheral UUID as returned by ble_scan" }

    public init?(argument value: Value) {
        guard case .string(let text) = value else { return nil }
        self.init(text)
    }

    public var jsonValue: Value { .string(description) }
}

extension SessionIdentifier: ArgumentValue {
    public static var schema: [String: Value] { ["type": "string"] }
    public static var expectation: String { "an id such as \"\(Kind.prefix)-1\"" }

    public init?(argument value: Value) {
        // "sub-3" is canonical; a bare 3 or "3" is accepted too.
        let parsed: Self? =
            switch value {
            case .string(let text): Self(text) ?? Int(text).flatMap { $0 > 0 ? Self(rawValue: $0) : nil }
            case .int(let int) where int > 0: Self(rawValue: int)
            default: nil
            }
        guard let parsed else { return nil }
        self = parsed
    }

    public var jsonValue: Value { .string(description) }
}

extension WriteMode: ArgumentValue {
    public static var schema: [String: Value] {
        ["type": "string", "enum": [.string(Self.withResponse.rawValue), .string(Self.withoutResponse.rawValue)]]
    }
    public static var expectation: String { "\"with_response\" or \"without_response\"" }

    public init?(argument value: Value) {
        guard case .string(let text) = value else { return nil }
        self.init(rawValue: text)
    }

    public var jsonValue: Value { .string(rawValue) }
}

extension Array: ArgumentValue where Element: ArgumentValue {
    public static var schema: [String: Value] { ["type": "array", "items": .object(Element.schema)] }
    public static var expectation: String { "an array of \(Element.expectation)" }

    /// Also accepts a single element, or a comma-separated string, for an array.
    public init?(argument value: Value) {
        let items: [Value] =
            switch value {
            case .array(let items): items
            case .string(let text) where text.contains(","):
                text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }
            default: [value]
            }
        var elements: [Element] = []
        elements.reserveCapacity(items.count)
        for item in items {
            guard let element = Element(argument: item) else { return nil }
            elements.append(element)
        }
        self = elements
    }

    public var jsonValue: Value { .array(map(\.jsonValue)) }
}

/// The schema-facing half of a `ToolArgument`, independent of its output type.
public protocol ArgumentDeclaration: Sendable {
    var name: String { get }
    var isRequired: Bool { get }
    var propertySchema: Value { get }
}

/// One declared tool argument: its schema property and how to parse it into `Output`.
public struct ToolArgument<Output: Sendable>: ArgumentDeclaration {
    public let name: String
    public let isRequired: Bool
    public let propertySchema: Value
    private let parse: @Sendable (Value?) throws(ToolError) -> Output

    init(
        name: String,
        isRequired: Bool,
        schema: [String: Value],
        parse: @escaping @Sendable (Value?) throws(ToolError) -> Output
    ) {
        self.name = name
        self.isRequired = isRequired
        self.propertySchema = .object(schema)
        self.parse = parse
    }

    func value(from argument: Value?) throws(ToolError) -> Output {
        try parse(argument)
    }
}

/// Factories for `ToolArgument`.
public enum Argument {
    public static func required<T: ArgumentValue>(
        _ name: String,
        as type: T.Type = T.self,
        _ description: String
    ) -> ToolArgument<T> {
        ToolArgument(name: name, isRequired: true, schema: schema(T.self, description)) { (value: Value?) throws(ToolError) -> T in
            guard let value else { throw .invalidArguments("Missing required argument '\(name)'.") }
            return try parsed(value, as: T.self, name: name)
        }
    }

    public static func optional<T: ArgumentValue>(
        _ name: String,
        as type: T.Type = T.self,
        _ description: String
    ) -> ToolArgument<T?> {
        ToolArgument(name: name, isRequired: false, schema: schema(T.self, description)) { (value: Value?) throws(ToolError) -> T? in
            try value.map { (value: Value) throws(ToolError) -> T in try parsed(value, as: T.self, name: name) }
        }
    }

    public static func optional<T: ArgumentValue>(
        _ name: String,
        as type: T.Type = T.self,
        _ description: String,
        default defaultValue: T
    ) -> ToolArgument<T> {
        var schema = schema(T.self, description)
        schema["default"] = defaultValue.jsonValue
        return ToolArgument(name: name, isRequired: false, schema: schema) { (value: Value?) throws(ToolError) -> T in
            guard let value else { return defaultValue }
            return try parsed(value, as: T.self, name: name)
        }
    }

    /// An optional integer constrained to `range`, advertised as `minimum`/`maximum`.
    public static func integer(
        _ name: String,
        _ description: String,
        in range: ClosedRange<Int>
    ) -> ToolArgument<Int?> {
        ToolArgument(name: name, isRequired: false, schema: integerSchema(description, range, default: nil)) {
            (value: Value?) throws(ToolError) -> Int? in
            try value.map { (value: Value) throws(ToolError) -> Int in try bounded(value, range, name: name) }
        }
    }

    /// An integer constrained to `range` that falls back to `defaultValue` when absent.
    public static func integer(
        _ name: String,
        _ description: String,
        in range: ClosedRange<Int>,
        default defaultValue: Int
    ) -> ToolArgument<Int> {
        precondition(range.contains(defaultValue), "default for '\(name)' lies outside its range")
        return ToolArgument(name: name, isRequired: false, schema: integerSchema(description, range, default: defaultValue)) {
            (value: Value?) throws(ToolError) -> Int in
            guard let value else { return defaultValue }
            return try bounded(value, range, name: name)
        }
    }

    private static func integerSchema(_ description: String, _ range: ClosedRange<Int>, default defaultValue: Int?) -> [String: Value] {
        var schema = schema(Int.self, description)
        schema["minimum"] = .int(range.lowerBound)
        schema["maximum"] = .int(range.upperBound)
        if let defaultValue {
            schema["default"] = .int(defaultValue)
        }
        return schema
    }

    private static func bounded(_ value: Value, _ range: ClosedRange<Int>, name: String) throws(ToolError) -> Int {
        let int = try parsed(value, as: Int.self, name: name)
        guard range.contains(int) else {
            throw .invalidArguments("Argument '\(name)' must be between \(range.lowerBound) and \(range.upperBound), got \(int).")
        }
        return int
    }

    private static func schema<T: ArgumentValue>(_ type: T.Type, _ description: String) -> [String: Value] {
        var schema = T.schema
        schema["description"] = .string(description)
        return schema
    }

    private static func parsed<T: ArgumentValue>(_ value: Value, as type: T.Type, name: String) throws(ToolError) -> T {
        guard let parsed = T(argument: value) else {
            throw .invalidArguments("Argument '\(name)' must be \(T.expectation), got \(value).")
        }
        return parsed
    }
}

/// The arguments of one `tools/call`, validated against the tool's declared argument names.
public struct ToolArguments: Sendable {
    private let values: [String: Value]

    init(_ values: [String: Value]?, declared: [any ArgumentDeclaration]) throws(ToolError) {
        // JSON null means "not given"; agents often send it for optional arguments.
        let given = (values ?? [:]).filter { !$0.value.isNull }
        let names = Set(declared.map(\.name))
        let unknown = given.keys.filter { !names.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let valid = declared.isEmpty ? "This tool takes no arguments." : "Valid arguments: \(declared.map(\.name).joined(separator: ", "))."
            throw .invalidArguments("Unknown argument\(unknown.count == 1 ? "" : "s") \(unknown.map { "'\($0)'" }.joined(separator: ", ")). \(valid)")
        }
        self.values = given
    }

    public subscript<Output>(_ argument: ToolArgument<Output>) -> Output {
        get throws(ToolError) {
            try argument.value(from: values[argument.name])
        }
    }
}
