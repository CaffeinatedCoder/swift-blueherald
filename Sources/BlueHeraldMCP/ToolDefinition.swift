public import BlueHeraldCore
import Foundation
public import MCP

/// A failure reported to the agent as a tool result with `isError: true`, so it can correct
/// itself. Unknown tools are protocol errors instead and never reach this type.
public enum ToolError: Error, Sendable {
    case invalidArguments(String)
    case ble(BLEError)
    case internalFailure(String)

    init(normalising error: any Error) {
        switch error {
        case let error as ToolError: self = error
        case let error as BLEError: self = .ble(error)
        case is CancellationError: self = .ble(.cancelled)
        default: self = .internalFailure(String(describing: error))
        }
    }

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .ble(let error): error.code
        case .internalFailure: "internal_error"
        }
    }

    var message: String {
        switch self {
        case .invalidArguments(let message), .internalFailure(let message): message
        case .ble(let error): error.message
        }
    }

    var hint: String? {
        guard case .ble(let error) = self else { return nil }
        return error.hint
    }
}

/// Whether a tool can change the state of a peripheral. Write tools are hidden from
/// `tools/list` and refused unless the write policy enables them.
public enum ToolEffect: Sendable {
    case readOnly
    /// Changes server state (connections, scans, subscriptions) but writes nothing to a device.
    case stateful
    case writesToDevice
}

/// A tool: its MCP descriptor plus a type-erased handler. Immutable and `Sendable`, so a catalog
/// of them can be shared freely. Device libraries contribute their own tools by creating more of
/// these and passing them to `BlueHeraldServer`.
public struct ToolDefinition: Sendable {
    public let tool: Tool
    public let effect: ToolEffect
    /// Only offered when the session records a capture.
    public let requiresCapture: Bool
    private let arguments: [any ArgumentDeclaration]
    private let handler: @Sendable (ToolArguments, BLESession) async throws -> any Encodable & Sendable

    public init<Output: Encodable & Sendable>(
        name: String,
        title: String,
        description: String,
        arguments: [any ArgumentDeclaration] = [],
        effect: ToolEffect,
        idempotent: Bool = false,
        requiresCapture: Bool = false,
        run: @escaping @Sendable (ToolArguments, BLESession) async throws -> Output
    ) {
        let properties = Dictionary(uniqueKeysWithValues: arguments.map { ($0.name, $0.propertySchema) })
        let required = arguments.filter(\.isRequired).map { Value.string($0.name) }
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = .array(required)
        }
        self.tool = Tool(
            name: name,
            title: title,
            description: description,
            inputSchema: .object(schema),
            annotations: Tool.Annotations(
                title: title,
                readOnlyHint: effect == .readOnly,
                destructiveHint: effect == .writesToDevice,
                idempotentHint: idempotent,
                openWorldHint: true))
        self.effect = effect
        self.requiresCapture = requiresCapture
        self.arguments = arguments
        self.handler = { arguments, session in try await run(arguments, session) }
    }

    public var name: String { tool.name }

    /// Runs the tool. Never throws: every failure becomes an error result.
    func call(_ rawArguments: [String: Value]?, session: BLESession) async -> CallTool.Result {
        do {
            let arguments = try ToolArguments(rawArguments, declared: self.arguments)
            return try ToolResult.success(await handler(arguments, session))
        } catch {
            return ToolResult.failure(ToolError(normalising: error))
        }
    }
}

/// Encodes tool outputs. The JSON goes out twice, as the spec recommends: as `structuredContent`
/// for clients that read it, and as compact text content for those that do not.
enum ToolResult {
    static func success(_ output: some Encodable) throws -> CallTool.Result {
        let data = try encoder.encode(output)
        // Typed as an optional so the non-generic initializer is chosen over the one that
        // re-encodes a Codable value.
        let structured: Value? = try JSONDecoder().decode(Value.self, from: data)
        return CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: structured,
            isError: false)
    }

    static func failure(_ error: ToolError) -> CallTool.Result {
        let body = ErrorBody(error: .init(code: error.code, message: error.message, hint: error.hint))
        guard let data = try? encoder.encode(body) else {
            return CallTool.Result(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        }
        let structured: Value? = try? JSONDecoder().decode(Value.self, from: data)
        return CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: structured,
            isError: true)
    }

    private struct ErrorBody: Encodable {
        struct Detail: Encodable {
            let code: String
            let message: String
            let hint: String?
        }
        let error: Detail
    }

    /// Configured once and never mutated afterwards, so sharing it across calls is safe.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }()
}

/// The immutable set of tools one server exposes, after applying the write policy and leaving
/// out capture tools when nothing is being captured.
public struct ToolCatalog: Sendable {
    public let definitions: [ToolDefinition]
    private let index: [String: ToolDefinition]

    public init(_ definitions: [ToolDefinition], writePolicy: WritePolicy, capturing: Bool = false) {
        let visible = definitions.filter {
            ($0.effect != .writesToDevice || writePolicy.isEnabled) && (!$0.requiresCapture || capturing)
        }
        self.definitions = visible
        self.index = Dictionary(visible.map { ($0.name, $0) }) { first, _ in first }
    }

    public var tools: [Tool] { definitions.map(\.tool) }

    public func definition(named name: String) -> ToolDefinition? {
        index[name]
    }
}
