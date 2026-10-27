import BLEMCPCore
import MCP

enum AttributeTools {
    static let read = ToolDefinition(
        name: "ble_read",
        title: "Read a characteristic",
        description: """
            Reads a characteristic value. Returns it as hex, plus as text when the bytes are printable \
            UTF-8. Services are discovered automatically on first use.
            """,
        arguments: CommonArguments.characteristicTarget,
        effect: .readOnly,
        idempotent: true
    ) { arguments, session in
        ValueReport(try await session.read(try CommonArguments.selector(arguments)))
    }

    static let write: ToolDefinition = {
        let mode = Argument.optional(
            "mode", as: WriteMode.self,
            "with_response waits for the peripheral's acknowledgement; without_response is faster but unconfirmed. Defaults to with_response when the characteristic supports it.")
        return ToolDefinition(
            name: "ble_write",
            title: "Write a characteristic",
            description: """
                Writes bytes to a characteristic. This changes the state of real hardware. Only available \
                when the server runs with BLE_MCP_ALLOW_WRITES, and limited to BLE_MCP_WRITE_ALLOWLIST \
                when that is set.
                """,
            arguments: CommonArguments.characteristicTarget + [CommonArguments.value, CommonArguments.encoding, mode],
            effect: .writesToDevice
        ) { arguments, session in
            let receipt = try await session.write(
                try CommonArguments.payload(arguments),
                to: try CommonArguments.selector(arguments),
                mode: try arguments[mode])
            return WriteReport(receipt)
        }
    }()

    static let readDescriptor = ToolDefinition(
        name: "ble_read_descriptor",
        title: "Read a descriptor",
        description: "Reads a descriptor of a characteristic, e.g. 2901 (User Description) or 2904 (Presentation Format).",
        arguments: CommonArguments.characteristicTarget + [CommonArguments.descriptor],
        effect: .readOnly,
        idempotent: true
    ) { arguments, session in
        let reading = try await session.readDescriptor(
            try arguments[CommonArguments.descriptor], of: try CommonArguments.selector(arguments))
        return ValueReport(reading)
    }

    static let writeDescriptor = ToolDefinition(
        name: "ble_write_descriptor",
        title: "Write a descriptor",
        description: """
            Writes bytes to a descriptor. The Client Characteristic Configuration descriptor (2902) is \
            managed through ble_subscribe instead. Subject to the same write policy as ble_write, \
            checked against the owning characteristic's UUID.
            """,
        arguments: CommonArguments.characteristicTarget + [
            CommonArguments.descriptor, CommonArguments.value, CommonArguments.encoding,
        ],
        effect: .writesToDevice
    ) { arguments, session in
        let receipt = try await session.writeDescriptor(
            try CommonArguments.payload(arguments),
            to: try arguments[CommonArguments.descriptor],
            of: try CommonArguments.selector(arguments))
        return WriteReport(receipt)
    }
}
