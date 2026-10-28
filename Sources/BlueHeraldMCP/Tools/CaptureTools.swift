import BlueHeraldCore
import MCP

enum CaptureTools {
    static let mark: ToolDefinition = {
        let note = Argument.required("note", as: String.self, "What happens next, e.g. \"select AC V\".")
        let fields = Argument.optional(
            "fields", as: MarkerFields.self,
            """
            Extra string, number or boolean fields for the row, e.g. {"select": "G", "expect_mode": 1}. \
            A fixture can be split at the rows that carry a given field.
            """)
        return ToolDefinition(
            name: "ble_capture_mark",
            title: "Mark the capture",
            description: """
                Adds an info row to the capture file, to label what the next writes and notifications \
                are about. Keys t, dir, uuid, hex and note are reserved.
                """,
            arguments: [note, fields],
            effect: .stateful,
            requiresCapture: true
        ) { arguments, session in
            let markerFields = try arguments[fields]?.values ?? [:]
            let reserved = markerFields.keys.filter(CaptureLine.reservedKeys.contains).sorted()
            guard reserved.isEmpty else {
                throw ToolError.invalidArguments(
                    "Field\(reserved.count == 1 ? "" : "s") \(reserved.map { "'\($0)'" }.joined(separator: ", ")) "
                        + "\(reserved.count == 1 ? "is" : "are") reserved by the capture format; pick another name.")
            }
            await session.mark(try arguments[note], fields: markerFields)
            return MarkReport(capturePath: session.captureDestination ?? "", marked: true)
        }
    }()
}

/// A flat object of scalars, the only kind of extra field a capture row carries.
struct MarkerFields: ArgumentValue {
    let values: [String: CaptureValue]

    static var schema: [String: Value] {
        ["type": "object", "additionalProperties": ["type": ["string", "number", "boolean"]]]
    }
    static var expectation: String { "an object of string, number or boolean values" }

    init?(argument value: Value) {
        guard case .object(let object) = value else { return nil }
        var values: [String: CaptureValue] = [:]
        for (key, item) in object {
            switch item {
            case .string(let text): values[key] = .string(text)
            case .int(let int): values[key] = .integer(int)
            case .double(let double) where double.isFinite: values[key] = .number(double)
            case .bool(let bool): values[key] = .bool(bool)
            case .null: continue
            default: return nil
            }
        }
        self.values = values
    }

    var jsonValue: Value {
        .object(
            values.mapValues {
                switch $0 {
                case .string(let text): .string(text)
                case .integer(let int): .int(int)
                case .number(let double): .double(double)
                case .bool(let bool): .bool(bool)
                }
            })
    }
}

struct MarkReport: Encodable {
    let capturePath: String
    let marked: Bool
}
