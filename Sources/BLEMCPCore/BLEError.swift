public import Foundation

/// Every failure the session can report. Each case maps to a stable snake_case `code`, a
/// `message` and, where there is an obvious next step, a `hint` an agent can act on.
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
        case .disconnected: "disconnected"
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
        case .backendFailure(let message):
            "Bluetooth backend failure: \(message)"
        }
    }

    public var hint: String? {
        switch self {
        case .bluetoothUnavailable(.unauthorized):
            "Grant Bluetooth access to the app that launched this server in System Settings > Privacy & Security > Bluetooth, then restart it."
        case .bluetoothUnavailable(.poweredOff):
            "Turn Bluetooth on."
        case .bluetoothUnavailable(.unknown), .bluetoothUnavailable(.resetting):
            "The adapter has not reported ready yet. On first launch macOS may be showing a Bluetooth permission prompt; accept it and retry."
        case .bluetoothUnavailable(.unsupported):
            "This Mac has no Bluetooth LE controller."
        case .unknownPeripheral:
            "Run ble_scan first; peripheral ids are only resolvable after the host has seen the device."
        case .notConnected:
            "Call ble_connect first. Connections do not survive a server restart; ble_status shows when this server started."
        case .disconnected:
            "Call ble_connect again."
        case .connectionLimitReached:
            "Disconnect an idle peripheral with ble_disconnect, or raise BLE_MCP_MAX_CONNECTIONS."
        case .serviceNotFound, .characteristicNotFound, .descriptorNotFound:
            "Call ble_discover to list the attribute table."
        case .ambiguousCharacteristic:
            "Pass service_uuid to choose one."
        case .writesDisabled:
            "Restart the server with BLE_MCP_ALLOW_WRITES=1 to enable writes."
        case .writeNotAllowed:
            "Add the characteristic UUID to BLE_MCP_WRITE_ALLOWLIST, or its exact frames to BLE_MCP_WRITE_VALUE_ALLOWLIST."
        case .writeDenied:
            "Remove the characteristic from BLE_MCP_WRITE_DENYLIST if writing it is really intended."
        case .writeValueNotAllowed:
            "Only frames listed in BLE_MCP_WRITE_VALUE_ALLOWLIST can be written to this characteristic."
        case .reservedDescriptor:
            "Use ble_subscribe and ble_unsubscribe to change notification state."
        case .subscriptionLimitReached:
            "Remove a subscription with ble_unsubscribe, or raise BLE_MCP_MAX_SUBSCRIPTIONS."
        case .scanLimitReached:
            "Stop a running scan with ble_scan_stop."
        case .timedOut:
            "The peripheral may be out of range or busy; check it is advertising and retry."
        default:
            nil
        }
    }

    private func list(_ uuids: [BLEUUID]) -> String {
        uuids.isEmpty ? "none" : uuids.map(\.description).joined(separator: ", ")
    }
}
