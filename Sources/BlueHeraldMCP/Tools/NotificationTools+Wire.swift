import BlueHeraldCore
import Foundation

struct SubscriptionReport: Encodable {
    let subscriptionId: String
    let peripheralId: String
    let serviceUuid: String
    let characteristicUuid: String
    let characteristicName: String?
    let characteristicDescription: String?
    let mode: String
    let state: String
    let closedReason: String?
    let received: Int
    let dropped: Int
    let buffered: Int
    let createdAt: Date

    init(_ snapshot: SubscriptionSnapshot) {
        subscriptionId = snapshot.id.description
        peripheralId = snapshot.address.peripheral.description
        serviceUuid = snapshot.address.service.description
        characteristicUuid = snapshot.address.characteristic.description
        characteristicName = AssignedNumbers.name(for: snapshot.address.characteristic)
        characteristicDescription = snapshot.userDescription
        mode = snapshot.mode.rawValue
        switch snapshot.state {
        case .pending:
            state = "pending"
            closedReason = nil
        case .active:
            state = "active"
            closedReason = nil
        case .closed(let reason):
            state = "closed"
            closedReason = reason
        }
        received = snapshot.receivedCount
        dropped = snapshot.droppedCount
        buffered = snapshot.bufferedCount
        createdAt = snapshot.createdAt
    }
}

struct NotificationEntry: Encodable {
    let subscriptionId: String
    let seq: UInt64
    let receivedAt: Date
    let value: Bytes

    init(_ notification: ValueNotification) {
        subscriptionId = notification.subscription.description
        seq = notification.sequence
        receivedAt = notification.receivedAt
        value = Bytes(notification.value)
    }
}

struct NotificationsReport: Encodable {
    let notifications: [NotificationEntry]
    let remaining: Int
    let dropped: Int
    let subscriptions: [SubscriptionReport]
    let note: String?

    init(_ batch: NotificationBatch) {
        notifications = batch.notifications.map(NotificationEntry.init)
        remaining = batch.remaining
        dropped = batch.dropped
        subscriptions = batch.subscriptions.map(SubscriptionReport.init)
        note =
            switch batch.wait {
            case .none:
                nil
            case .skipped:
                "Returned without waiting: no open subscription can deliver notifications. Call ble_subscribe first."
            case .nothingArrived(let waited)
            where batch.subscriptions.allSatisfy({ if case .closed = $0.state { true } else { false } }):
                "Waited \(Int((waited / .milliseconds(1)).rounded())) ms; the subscription closed meanwhile (see closed_reason)."
            case .nothingArrived(let waited):
                "Waited \(Int((waited / .milliseconds(1)).rounded())) ms and nothing arrived."
            }
    }
}
