import BLEMCPCore
import Foundation
import Testing

@Suite("Write policy")
struct WritePolicyTests {
    let dataIn = BLEUUID(0xFF01)
    let baudRate = BLEUUID(0xFF03)
    let other = BLEUUID(0xFFE1)
    let poll = Data([0xAB, 0xCD, 0x03, 0x5E, 0x01, 0xD9])
    let clearLog = Data([0xAB, 0xCD, 0x03, 0x63, 0x01, 0xDE])

    @Test("read-only refuses everything")
    func readOnly() {
        #expect(throws: BLEError.writesDisabled) { try WritePolicy.readOnly.checkWrite(poll, to: dataIn) }
        #expect(throws: BLEError.writesDisabled) { try WritePolicy.readOnly.checkDescriptorWrite(on: dataIn) }
    }

    @Test("with no lists, every characteristic is writable")
    func unrestricted() throws {
        let policy = WritePolicy(isEnabled: true)
        try policy.checkWrite(clearLog, to: dataIn)
        try policy.checkDescriptorWrite(on: other)
    }

    @Test("the denylist wins over every allowlist")
    func denylistWins() {
        let policy = WritePolicy(
            isEnabled: true, allowlist: [baudRate], denylist: [baudRate], allowedValues: [baudRate: [poll]])
        #expect(throws: BLEError.writeDenied(baudRate)) { try policy.checkWrite(poll, to: baudRate) }
        #expect(throws: BLEError.writeDenied(baudRate)) { try policy.checkDescriptorWrite(on: baudRate) }
    }

    @Test("a denylist alone leaves the rest writable")
    func denylistAlone() throws {
        let policy = WritePolicy(isEnabled: true, denylist: [baudRate])
        try policy.checkWrite(clearLog, to: dataIn)
        #expect(throws: BLEError.writeDenied(baudRate)) { try policy.checkWrite(poll, to: baudRate) }
    }

    @Test("frames are matched exactly and listed in the error")
    func exactFrames() throws {
        let policy = WritePolicy(isEnabled: true, allowedValues: [dataIn: [poll]])
        try policy.checkWrite(poll, to: dataIn)
        #expect(throws: BLEError.writeValueNotAllowed(dataIn, value: clearLog, allowed: [poll])) {
            try policy.checkWrite(clearLog, to: dataIn)
        }
        #expect(throws: BLEError.writeValueNotAllowed(dataIn, value: poll.dropLast(), allowed: [poll])) {
            try policy.checkWrite(poll.dropLast(), to: dataIn)
        }
    }

    @Test("a frame restriction is stricter than a characteristic allowlist entry")
    func framesBeatCharacteristicAllowlist() {
        let policy = WritePolicy(isEnabled: true, allowlist: [dataIn], allowedValues: [dataIn: [poll]])
        #expect(throws: BLEError.writeValueNotAllowed(dataIn, value: clearLog, allowed: [poll])) {
            try policy.checkWrite(clearLog, to: dataIn)
        }
    }

    @Test("any allowlist locks unlisted characteristics and their descriptors")
    func allowlistsLock() throws {
        let policy = WritePolicy(isEnabled: true, allowlist: [other], allowedValues: [dataIn: [poll]])
        try policy.checkWrite(clearLog, to: other)
        try policy.checkDescriptorWrite(on: other)
        #expect(throws: BLEError.writeNotAllowed(baudRate)) { try policy.checkWrite(poll, to: baudRate) }
        #expect(throws: BLEError.writeNotAllowed(baudRate)) { try policy.checkDescriptorWrite(on: baudRate) }
        // Only the listed frames were permitted on dataIn, not its descriptors.
        #expect(throws: BLEError.writeNotAllowed(dataIn)) { try policy.checkDescriptorWrite(on: dataIn) }
    }

    @Test("the error names the refused and the allowed frames")
    func message() {
        let error = BLEError.writeValueNotAllowed(dataIn, value: clearLog, allowed: [poll])
        #expect(error.code == "write_value_not_allowed")
        #expect(error.message == "The value abcd036301de is not allowed for characteristic FF01. Allowed frames: abcd035e01d9.")
    }
}
