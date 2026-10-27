import BLEMCPCore
import Foundation
import MCP

/// How a `value` argument is spelled.
enum PayloadEncoding: String, ArgumentValue {
    case hex
    case base64
    case utf8

    static var schema: [String: Value] {
        ["type": "string", "enum": [.string(Self.hex.rawValue), .string(Self.base64.rawValue), .string(Self.utf8.rawValue)]]
    }
    static var expectation: String { "\"hex\", \"base64\" or \"utf8\"" }

    init?(argument value: Value) {
        guard case .string(let text) = value else { return nil }
        self.init(rawValue: text.lowercased())
    }

    var jsonValue: Value { .string(rawValue) }
}

/// Arguments several tools share, declared once so their names and descriptions stay uniform.
enum CommonArguments {
    static let peripheral = Argument.required(
        "peripheral_id", as: PeripheralID.self,
        "Peripheral id (a UUID) from ble_scan or ble_connections.")

    static let characteristic = Argument.required(
        "characteristic_uuid", as: BLEUUID.self,
        "Characteristic UUID, short (\"2A19\") or full (\"6E400002-B5A3-F393-E0A9-E50E24DCCA9E\").")

    static let service = Argument.optional(
        "service_uuid", as: BLEUUID.self,
        "Service UUID. Only needed when the characteristic UUID exists in more than one service.")

    static let descriptor = Argument.required(
        "descriptor_uuid", as: BLEUUID.self,
        "Descriptor UUID, e.g. \"2901\" (Characteristic User Description).")

    static let value = Argument.required(
        "value", as: String.self,
        "The bytes to write, spelled in `encoding`. Hex accepts separators and 0x prefixes: \"01 ff\", \"0x01,0xFF\".")

    static let encoding = Argument.optional(
        "encoding", as: PayloadEncoding.self, "How `value` is spelled.", default: .hex)

    static let characteristicTarget: [any ArgumentDeclaration] = [peripheral, characteristic, service]

    static func selector(_ arguments: ToolArguments) throws(ToolError) -> CharacteristicSelector {
        CharacteristicSelector(
            peripheral: try arguments[peripheral],
            service: try arguments[service],
            characteristic: try arguments[characteristic])
    }

    static func payload(_ arguments: ToolArguments) throws(ToolError) -> Data {
        let text = try arguments[value]
        let decoded: Data? =
            switch try arguments[encoding] {
            case .hex: Hex.decode(text)
            case .base64: Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .utf8: Data(text.utf8)
            }
        guard let decoded else {
            throw .invalidArguments("Argument 'value' is not valid \(try arguments[encoding].rawValue).")
        }
        return decoded
    }
}
