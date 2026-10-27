public import Foundation

/// Allocation-light hex encoding for attribute values.
public enum Hex {
    private static let lowercaseDigits: InlineArray<16, UInt8> = [
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
    ]

    /// Lowercase hex with no separators: `[0x01, 0xAB]` becomes `"01ab"`.
    public static func encode(_ bytes: some Collection<UInt8>) -> String {
        let count = bytes.count
        guard count > 0 else { return "" }
        return String(unsafeUninitializedCapacity: count * 2) { buffer in
            var index = 0
            for byte in bytes {
                buffer[index] = lowercaseDigits[Int(byte >> 4)]
                buffer[index + 1] = lowercaseDigits[Int(byte & 0x0F)]
                index += 2
            }
            return index
        }
    }

    /// Decodes hex the way people and agents write it: case-insensitive, with an optional `0x`
    /// at the start of each token and whitespace, `:`, `-`, `_` or `,` between bytes.
    /// Returns `nil` for any other character or an odd number of digits.
    public static func decode(_ text: some StringProtocol) -> Data? {
        let utf8 = Array(text.utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count / 2)
        var high: UInt8?
        var atTokenStart = true
        var index = 0

        while index < utf8.count {
            let byte = utf8[index]
            if isSeparator(byte) {
                atTokenStart = true
                index += 1
                continue
            }
            if atTokenStart, byte == UInt8(ascii: "0"), index + 1 < utf8.count,
                utf8[index + 1] | 0x20 == UInt8(ascii: "x")
            {
                atTokenStart = false
                index += 2
                continue
            }
            atTokenStart = false
            guard let nibble = nibble(byte) else { return nil }
            if let pending = high {
                bytes.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
            index += 1
        }
        return high == nil ? Data(bytes) : nil
    }

    static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): ascii &- UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): ascii &- UInt8(ascii: "a") &+ 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): ascii &- UInt8(ascii: "A") &+ 10
        default: nil
        }
    }

    static func uppercase(_ value: some BinaryInteger, digits: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
            UInt8(ascii: ":"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: ","):
            true
        default:
            false
        }
    }
}
