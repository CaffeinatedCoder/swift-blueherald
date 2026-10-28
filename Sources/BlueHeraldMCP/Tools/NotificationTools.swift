import BlueHeraldCore
import MCP

enum NotificationTools {
    private static let subscriptionID = Argument.required(
        "subscription_id", as: SubscriptionID.self, "Subscription id returned by ble_subscribe.")

    static let subscribe = ToolDefinition(
        name: "ble_subscribe",
        title: "Subscribe to notifications",
        description: """
            Enables notifications (or indications) on a characteristic and buffers every value it \
            sends. Read them with ble_notifications. Subscribing twice returns the existing subscription.
            """,
        arguments: CommonArguments.characteristicTarget,
        effect: .stateful,
        idempotent: true
    ) { arguments, session in
        SubscriptionReport(try await session.subscribe(try CommonArguments.selector(arguments)))
    }

    static let unsubscribe = ToolDefinition(
        name: "ble_unsubscribe",
        title: "Unsubscribe",
        description: "Disables notifications and discards the subscription, including values not yet read.",
        arguments: [subscriptionID],
        effect: .stateful
    ) { arguments, session in
        SubscriptionReport(try await session.unsubscribe(try arguments[subscriptionID]))
    }

    static let read: ToolDefinition = {
        let subscription = Argument.optional(
            "subscription_id", as: SubscriptionID.self, "Read one subscription. Omit to read all, merged in arrival order.")
        let maxCount = Argument.integer(
            "max_count", "Maximum notifications to return.", in: 1...1000, default: 100)
        let wait = Argument.integer(
            "wait_ms", "When nothing is buffered, wait up to this long for the next notification.", in: 0...60_000,
            default: 0)
        return ToolDefinition(
            name: "ble_notifications",
            title: "Read notifications",
            description: """
                Returns buffered notifications, oldest first, and removes them from the buffer. Each has \
                a session-wide sequence number and a receive timestamp. `dropped` counts values the \
                buffer overwrote since the last read; read more often or with a larger max_count if it \
                is not zero. Use wait_ms to block until data arrives instead of polling. When it \
                comes back empty, `note` says whether it waited or there was nothing to wait on.
                """,
            arguments: [subscription, maxCount, wait],
            effect: .stateful
        ) { arguments, session in
            let batch = try await session.notifications(
                from: try arguments[subscription],
                maxCount: try arguments[maxCount],
                waitUpTo: .milliseconds(try arguments[wait]))
            return NotificationsReport(batch)
        }
    }()
}
