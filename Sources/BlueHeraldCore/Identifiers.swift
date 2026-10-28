public import Foundation

/// A Bluetooth attribute UUID, held as its full 128-bit value.
///
/// SIG-assigned 16- and 32-bit UUIDs are shorthand for values on the Bluetooth Base UUID
/// `0000xxxx-0000-1000-8000-00805F9B34FB`, so `"2a19"`, `"0x2A19"` and
/// `"00002A19-0000-1000-8000-00805F9B34FB"` all parse to the same value and compare equal.
public struct BLEUUID: Hashable, Comparable, Sendable {
    public let rawValue: UInt128

    /// The low 96 bits shared by every UUID on the Bluetooth Base UUID.
    static let baseSuffix: UInt128 = 0x0000_1000_8000_0080_5F9B_34FB
    static let suffixMask: UInt128 = (1 << 96) - 1

    public init(rawValue: UInt128) {
        self.rawValue = rawValue
    }

    /// A SIG-assigned 16-bit UUID such as `0x180F` (Battery Service).
    public init(_ shortValue: UInt16) {
        self.init(shortValue: UInt32(shortValue))
    }

    /// A 16- or 32-bit UUID on the Bluetooth Base UUID.
    public init(shortValue: UInt32) {
        rawValue = UInt128(shortValue) << 96 | Self.baseSuffix
    }

    public init(_ uuid: UUID) {
        let b = uuid.uuid
        self.init(bigEndianBytes: [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15])!
    }

    /// Parses the 2-, 4- or 16-byte big-endian form that `CBUUID.data` and ATT PDUs use.
    public init?(bigEndianBytes bytes: some Collection<UInt8>) {
        guard [2, 4, 16].contains(bytes.count) else { return nil }
        let value = bytes.reduce(UInt128.zero) { $0 << 8 | UInt128($1) }
        if bytes.count == 16 {
            self.init(rawValue: value)
        } else {
            self.init(shortValue: UInt32(truncatingIfNeeded: value))
        }
    }

    /// Accepts `2A19`, `0x2a19`, `0000FEED`, the dashed 36-character form, or 32 bare hex digits.
    /// Surrounding whitespace is ignored; anything else returns `nil`.
    public init?(_ text: some StringProtocol) {
        var utf8 = Substring(text).utf8.drop { $0 == UInt8(ascii: " ") }
        while utf8.last == UInt8(ascii: " ") { utf8 = utf8.dropLast() }
        if utf8.starts(with: "0x".utf8) || utf8.starts(with: "0X".utf8) { utf8 = utf8.dropFirst(2) }

        let isDashed = utf8.count == 36
        var value = UInt128.zero
        var digits = 0
        for (offset, byte) in utf8.enumerated() {
            if byte == UInt8(ascii: "-") {
                guard isDashed, [8, 13, 18, 23].contains(offset) else { return nil }
                continue
            }
            guard digits < 32, let nibble = Hex.nibble(byte) else { return nil }
            value = value << 4 | UInt128(nibble)
            digits += 1
        }

        switch (digits, isDashed) {
        case (4, false), (8, false): self.init(shortValue: UInt32(truncatingIfNeeded: value))
        case (32, _): self.init(rawValue: value)
        default: return nil
        }
    }

    /// The 16- or 32-bit short form, when the UUID sits on the Bluetooth Base UUID.
    public var shortValue: UInt32? {
        guard rawValue & Self.suffixMask == Self.baseSuffix else { return nil }
        return UInt32(truncatingIfNeeded: rawValue >> 96)
    }

    public var uuid: UUID {
        let byte = { (index: Int) in UInt8(truncatingIfNeeded: rawValue >> (8 * (15 - index))) }
        return UUID(
            uuid: (
                byte(0), byte(1), byte(2), byte(3), byte(4), byte(5), byte(6), byte(7),
                byte(8), byte(9), byte(10), byte(11), byte(12), byte(13), byte(14), byte(15)
            ))
    }

    public static func < (lhs: BLEUUID, rhs: BLEUUID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension BLEUUID: CustomStringConvertible {
    /// `2A19` for 16-bit and `0000FEED`-style for 32-bit SIG UUIDs, otherwise the uppercase
    /// 8-4-4-4-12 form. This is the same spelling `CBUUID.uuidString` produces.
    public var description: String {
        if let short = shortValue {
            return Hex.uppercase(short, digits: short <= 0xFFFF ? 4 : 8)
        }
        let hex = Hex.uppercase(rawValue, digits: 32)
        var dashed = ""
        dashed.reserveCapacity(36)
        for (offset, character) in hex.enumerated() {
            if [8, 12, 16, 20].contains(offset) { dashed.append("-") }
            dashed.append(character)
        }
        return dashed
    }
}

/// The identifier the platform assigns to a peripheral.
///
/// CoreBluetooth never exposes MAC addresses; it hands out a UUID that is stable for a given
/// peripheral on this host only.
public struct PeripheralID: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    public init?(_ text: some StringProtocol) {
        guard let uuid = UUID(uuidString: String(text).trimmingCharacters(in: .whitespaces)) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString }
}
