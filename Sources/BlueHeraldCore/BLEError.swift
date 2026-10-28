public import Foundation

/// Every failure the session can report. Each case maps to a stable snake_case `code` and a
/// `message`. The next step an agent can take (a tool to call, a variable to set) is the server's
/// business: BlueHeraldMCP adds it as `hint`.
public enum BLEError: Error, Hashable, Sendable {
    case bluetoothUnavailable(CentralState)
    case timedOut(operation: String, after: Duration)
    case cancelled
    case unknownPeripheral(PeripheralID)
    case notConnected(PeripheralID)
    case alreadyConnecting(PeripheralID)
    case connectionLimitReached(limit: Int)
    case connectionFailed(PeripheralID, reason: String)
    case disconnected(PeripheralID, reason: String?)
    /// An established link that the peripheral or the adapter dropped between calls.
    case linkLost(PeripheralID, reason: String?, at: Date)
    case serviceNotFound(BLEUUID, available: [BLEUUID])
    case characteristicNotFound(BLEUUID, service: BLEUUID?, available: [BLEUUID])
    case ambiguousCharacteristic(BLEUUID, services: [BLEUUID])
    case descriptorNotFound(BLEUUID, characteristic: BLEUUID, available: [BLEUUID])
    case propertyNotSupported(characteristic: BLEUUID, required: String, available: [String])
    case writesDisabled
    case writeNotAllowed(BLEUUID)
    case writeDenied(BLEUUID)
    case writeValueNotAllowed(BLEUUID, value: Data, allowed: [Data])
    case reservedDescriptor(BLEUUID)
    case payloadTooLarge(size: Int, maximum: Int)
    case subscriptionNotFound(SubscriptionID)
    case subscriptionLimitReached(limit: Int)
    case scanNotFound(ScanID)
    case scanLimitReached(limit: Int)
    case attributeError(operation: String, code: Int, message: String)
    /// The attribute needs an encrypted, paired link; the access starts pairing.
    case pairingRequired(operation: String, reason: String)
    /// Pairing was refused, timed out, or the peripheral no longer has this Mac's keys.
    case pairingFailed(reason: String)
    case backendFailure(String)
}

extension BLEError {
    public var code: String {
        switch self {
        case .bluetoothUnavailable: "bluetooth_unavailable"
        case .timedOut: "timeout"
        case .cancelled: "cancelled"
        case .unknownPeripheral: "unknown_peripheral"
        case .notConnected: "not_connected"
        case .alreadyConnecting: "already_connecting"
        case .connectionLimitReached: "connection_limit_reached"
        case .connectionFailed: "connection_failed"
        case .disconnected, .linkLost: "disconnected"
        case .serviceNotFound: "service_not_found"
        case .characteristicNotFound: "characteristic_not_found"
        case .ambiguousCharacteristic: "ambiguous_characteristic"
        case .descriptorNotFound: "descriptor_not_found"
        case .propertyNotSupported: "property_not_supported"
        case .writesDisabled: "writes_disabled"
        case .writeNotAllowed: "write_not_allowed"
        case .writeDenied: "write_denied"
        case .writeValueNotAllowed: "write_value_not_allowed"
        case .reservedDescriptor: "reserved_descriptor"
        case .payloadTooLarge: "payload_too_large"
        case .subscriptionNotFound: "subscription_not_found"
        case .subscriptionLimitReached: "subscription_limit_reached"
        case .scanNotFound: "scan_not_found"
        case .scanLimitReached: "scan_limit_reached"
        case .attributeError: "attribute_error"
        case .pairingRequired: "pairing_required"
        case .pairingFailed: "pairing_failed"
        case .backendFailure: "backend_failure"
        }
    }

    public var message: String {
        switch self {
        case .bluetoothUnavailable(let state):
            "Bluetooth is not available (adapter state: \(state.rawValue))."
        case .timedOut(let operation, let after):
            "\(operation) did not complete within \(Int(after / .milliseconds(1))) ms."
        case .cancelled:
            "The operation was cancelled."
        case .unknownPeripheral(let id):
            "No peripheral with id \(id) is known to the Bluetooth stack."
        case .notConnected(let id):
            "Peripheral \(id) is not connected."
        case .alreadyConnecting(let id):
            "A connection to \(id) is already in progress."
        case .connectionLimitReached(let limit):
            "The maximum of \(limit) simultaneous connections is reached."
        case .connectionFailed(let id, let reason):
            "Connecting to \(id) failed: \(reason)"
        case .disconnected(let id, let reason):
            "Peripheral \(id) disconnected\(reason.map { ": \($0)" } ?? ".")"
        case .linkLost(let id, let reason, let at):
            "Peripheral \(id) lost its link at \(at.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))\(reason.map { ": \($0)" } ?? ".")"
        case .serviceNotFound(let uuid, let available):
            "Service \(uuid) not found. Available services: \(list(available))."
        case .characteristicNotFound(let uuid, let service, let available):
            "Characteristic \(uuid) not found\(service.map { " in service \($0)" } ?? ""). Available: \(list(available))."
        case .ambiguousCharacteristic(let uuid, let services):
            "Characteristic \(uuid) exists in several services: \(list(services))."
        case .descriptorNotFound(let uuid, let characteristic, let available):
            "Descriptor \(uuid) not found on characteristic \(characteristic). Available: \(list(available))."
        case .propertyNotSupported(let characteristic, let required, let available):
            "Characteristic \(characteristic) does not support \(required) (properties: \(available.isEmpty ? "none" : available.joined(separator: ", ")))."
        case .writesDisabled:
            "Writes are disabled on this server."
        case .writeNotAllowed(let uuid):
            "Characteristic \(uuid) is not on the write allowlist."
        case .writeDenied(let uuid):
            "Characteristic \(uuid) is on the write denylist and is never written."
        case .writeValueNotAllowed(let uuid, let value, let allowed):
            "The value \(Hex.encode(value)) is not allowed for characteristic \(uuid). Allowed frames: \(allowed.map { Hex.encode($0) }.joined(separator: ", "))."
        case .reservedDescriptor(let uuid):
            "Descriptor \(uuid) is managed by the Bluetooth stack and cannot be written directly."
        case .payloadTooLarge(let size, let maximum):
            "The value is \(size) bytes but at most \(maximum) can be written in one operation."
        case .subscriptionNotFound(let id):
            "No subscription with id \(id)."
        case .subscriptionLimitReached(let limit):
            "The maximum of \(limit) active subscriptions is reached."
        case .scanNotFound(let id):
            "No scan with id \(id)."
        case .scanLimitReached(let limit):
            "The maximum of \(limit) concurrent scans is reached."
        case .attributeError(let operation, let code, let message):
            "\(operation) failed with ATT/stack error \(code): \(message)"
        case .pairingRequired(let operation, let reason):
            "\(operation) needs a paired, encrypted link: \(reason)"
        case .pairingFailed(let reason):
            "Pairing failed: \(reason)"
        case .backendFailure(let message):
            "Bluetooth backend failure: \(message)"
        }
    }

    private func list(_ uuids: [BLEUUID]) -> String {
        uuids.isEmpty ? "none" : uuids.map(\.description).joined(separator: ", ")
    }
}
