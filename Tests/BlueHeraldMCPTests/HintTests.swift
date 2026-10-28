import BlueHeraldCore
import BlueHeraldMCP
import Testing

@Suite("Error hints")
struct HintTests {
    @Test("a pending permission prompt asks for a person, an unknown state does not")
    func permission() {
        #expect(BLEError.bluetoothUnavailable(.awaitingPermission).hint?.contains("accept the prompt") == true)
        #expect(BLEError.bluetoothUnavailable(.unknown).hint?.contains("permission") == false)
    }

    @Test("a pairing failure points at the pairing dialog")
    func pairing() {
        #expect(BLEError.pairingRequired(operation: "Read", reason: "Encryption is insufficient.").hint?.contains("pairing dialog") == true)
    }
}
