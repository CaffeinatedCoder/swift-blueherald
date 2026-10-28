import BlueHeraldCore
import Foundation
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

    static let write = ToolDefinition(
        name: "ble_write",
        title: "Write a characteristic",
        description: """
            Writes bytes to a characteristic. This changes the state of real hardware. Only available \
            when the server runs with BLUEHERALD_ALLOW_WRITES, and subject to its allowlists and denylist \
            (ble_status lists them).
            """,
        arguments: CommonArguments.characteristicTarget + [
            CommonArguments.value, CommonArguments.encoding, CommonArguments.writeMode,
        ],
        effect: .writesToDevice
    ) { arguments, session in
        let receipt = try await session.write(
            try CommonArguments.payload(arguments),
            to: try CommonArguments.selector(arguments),
            mode: try arguments[CommonArguments.writeMode])
        return WriteReport(receipt)
    }

    static let transact: ToolDefinition = {
        let reply = Argument.required(
            "reply_uuid", as: BLEUUID.self, "The notify or indicate characteristic the device answers on, e.g. \"FF02\".")
        let replyService = Argument.optional(
            "reply_service_uuid", as: BLEUUID.self,
            "Service of reply_uuid. Only needed when that UUID exists in more than one service.")
        let prefix = Argument.optional(
            "reply_prefix", as: String.self,
            "Hex the reply must start with, e.g. \"abcd04\". Notifications that do not match stay buffered.")
        let timeout = Argument.integer(
            "timeout_ms", "How long to wait for the reply after the write.", in: 50...60_000, default: 2_000)
        return ToolDefinition(
            name: "ble_transact",
            title: "Write and wait for the reply",
            description: """
                Writes a frame and waits for the device's answer: the first notification on reply_uuid \
                after the write, optionally only one starting with reply_prefix. One call instead of \
                subscribe, write and wait, and no race with a fast reply: reply_uuid is subscribed to \
                before the write, and that subscription stays open for the next exchange. Exchanges \
                that wait on the same reply_uuid run one after the other. Returns the \
                reply with its latency, or a note when none came; other notifications stay readable \
                with ble_notifications. Changes real hardware and follows the same write policy as ble_write.
                """,
            arguments: CommonArguments.characteristicTarget + [
                CommonArguments.value, CommonArguments.encoding, CommonArguments.writeMode,
                reply, replyService, prefix, timeout,
            ],
            effect: .writesToDevice
        ) { arguments, session in
            let replyPrefix =
                try arguments[prefix].map { (text: String) throws(ToolError) -> Data in
                    guard let bytes = Hex.decode(text) else {
                        throw .invalidArguments("Argument 'reply_prefix' must be hex, got \"\(text)\".")
                    }
                    return bytes
                } ?? Data()
            let target = try CommonArguments.selector(arguments)
            let transaction = try await session.transact(
                try CommonArguments.payload(arguments),
                to: target,
                mode: try arguments[CommonArguments.writeMode],
                replyOn: CharacteristicSelector(
                    peripheral: target.peripheral, service: try arguments[replyService], characteristic: try arguments[reply]),
                prefix: replyPrefix,
                timeout: .milliseconds(try arguments[timeout]))
            return TransactReport(transaction, prefix: replyPrefix)
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
