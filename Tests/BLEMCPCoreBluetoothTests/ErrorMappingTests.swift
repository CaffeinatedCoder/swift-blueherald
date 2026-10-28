import BLEMCPCore
import BLEMCPCoreBluetooth
import CoreBluetooth
import Foundation
import Testing

@Suite("CoreBluetooth error mapping")
struct ErrorMappingTests {
    func error(_ domain: String, _ code: Int, _ text: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    @Test(
        "ATT security errors mean the access needs pairing",
        arguments: [CBATTError.insufficientAuthentication, .insufficientEncryption, .insufficientEncryptionKeySize])
    func pairingRequired(_ code: CBATTError.Code) {
        let mapped = BLEError(error(CBATTErrorDomain, code.rawValue, "Encryption is insufficient."), during: "Read")
        #expect(mapped == .pairingRequired(operation: "Read", reason: "Encryption is insufficient."))
        #expect(mapped.code == "pairing_required")
        #expect(mapped.hint?.contains("pairing dialog") == true)
    }

    @Test(
        "lost keys and an encryption timeout mean pairing failed", arguments: [CBError.peerRemovedPairingInformation, .encryptionTimedOut])
    func pairingFailed(_ code: CBError.Code) {
        let failure = error(CBErrorDomain, code.rawValue, "Peer removed pairing information")
        #expect(BLEError(failure, during: "Read") == .pairingFailed(reason: "Peer removed pairing information"))
        #expect(BLEError(pairingFailure: failure)?.code == "pairing_failed")
    }

    @Test("other ATT errors keep their number")
    func otherErrors() {
        let mapped = BLEError(error(CBATTErrorDomain, CBATTError.readNotPermitted.rawValue, "Reading is not permitted."), during: "Read")
        #expect(mapped == .attributeError(operation: "Read", code: 2, message: "Reading is not permitted."))
        #expect(BLEError(pairingFailure: error(CBErrorDomain, CBError.connectionTimeout.rawValue, "timeout")) == nil)
        #expect(BLEError(pairingFailure: nil) == nil)
    }
}
