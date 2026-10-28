public import BlueHeraldCore

// The next step for each failure names tools and environment variables, so it lives with them
// rather than in the core, which only knows the stable `code`.
extension BLEError {
    public var hint: String? {
        switch self {
        case .bluetoothUnavailable(.unauthorized):
            "Grant Bluetooth access to the app that launched this server in System Settings > Privacy & Security > Bluetooth, then restart it."
        case .bluetoothUnavailable(.poweredOff):
            "Turn Bluetooth on."
        case .bluetoothUnavailable(.awaitingPermission):
            "macOS is asking whether blueherald may use Bluetooth. Someone at this Mac has to accept the prompt; then retry."
        case .bluetoothUnavailable(.unknown), .bluetoothUnavailable(.resetting):
            "The adapter has not reported its state yet. The first Bluetooth use after blueherald was rebuilt or updated can take several seconds while macOS checks the new binary; retry shortly."
        case .bluetoothUnavailable(.unsupported):
            "This Mac has no Bluetooth LE controller."
        case .unknownPeripheral:
            "Run ble_scan first; peripheral ids are only resolvable after the host has seen the device."
        case .notConnected:
            "Call ble_connect first. Connections do not survive a server restart; ble_status shows when this server started."
        case .disconnected, .linkLost:
            "Call ble_connect again."
        case .connectionLimitReached:
            "Disconnect an idle peripheral with ble_disconnect, or raise BLUEHERALD_MAX_CONNECTIONS."
        case .serviceNotFound, .characteristicNotFound, .descriptorNotFound:
            "Call ble_discover to list the attribute table."
        case .ambiguousCharacteristic:
            "Pass service_uuid to choose one."
        case .writesDisabled:
            "Restart the server with BLUEHERALD_ALLOW_WRITES=1 to enable writes."
        case .writeNotAllowed:
            "Add the characteristic UUID to BLUEHERALD_WRITE_ALLOWLIST, or its exact frames to BLUEHERALD_WRITE_VALUE_ALLOWLIST."
        case .writeDenied:
            "Remove the characteristic from BLUEHERALD_WRITE_DENYLIST if writing it is really intended."
        case .writeValueNotAllowed:
            "Only frames listed in BLUEHERALD_WRITE_VALUE_ALLOWLIST can be written to this characteristic."
        case .reservedDescriptor:
            "Use ble_subscribe and ble_unsubscribe to change notification state."
        case .subscriptionLimitReached:
            "Remove a subscription with ble_unsubscribe, or raise BLUEHERALD_MAX_SUBSCRIPTIONS."
        case .scanLimitReached:
            "Stop a running scan with ble_scan_stop."
        case .timedOut:
            "The peripheral may be out of range or busy; check it is advertising and retry."
        case .pairingRequired:
            "This access starts pairing. macOS shows a pairing dialog that a person has to confirm (some devices also need a PIN); retry once it is confirmed. If no dialog appears, pair the device in System Settings > Bluetooth."
        case .pairingFailed:
            "If the device was reset or paired with another host, remove it in System Settings > Bluetooth, then connect and retry so the Mac pairs again. A pairing dialog nobody confirmed also ends here."
        default:
            nil
        }
    }
}
