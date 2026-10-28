import BlueHeraldCore
import Foundation

// The JSON contract agents see. Kept separate from the core model so the wire format stays
// stable while the domain evolves. Property names are camelCase here and snake_case on the wire;
// optional properties are omitted when nil. Each tool group keeps its results next to it, in
// Tools/*+Wire.swift; the pieces several groups share live here.

struct UUIDReference: Encodable {
    let uuid: String
    let name: String?

    init(_ uuid: BLEUUID) {
        self.uuid = uuid.description
        self.name = AssignedNumbers.name(for: uuid)
    }
}

struct Bytes: Encodable {
    let hex: String
    /// Present only when the bytes read as printable UTF-8 text of at least two characters,
    /// ignoring trailing NUL padding. Shorter values are nearly always numbers: a battery level
    /// of 89 would read "Y", and a little-endian 36 padded with a NUL would read "$".
    /// Cut to `textLimit` characters; `hex` always holds the whole value.
    let utf8: String?
    /// Set when `utf8` was cut.
    let utf8Truncated: Bool?
    let length: Int

    static let textLimit = 128

    init(_ data: Data) {
        hex = Hex.encode(data)
        length = data.count
        let text = Self.printableText(data)
        if let text, text.count > Self.textLimit {
            utf8 = String(text.prefix(Self.textLimit))
            utf8Truncated = true
        } else {
            utf8 = text
            utf8Truncated = nil
        }
    }

    private static func printableText(_ data: Data) -> String? {
        let trimmed = data.reversed().drop { $0 == 0 }.reversed()
        guard !trimmed.isEmpty, let text = String(validating: trimmed, as: UTF8.self) else { return nil }
        let isPrintable = text.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.generalCategory.isControl || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }
        let looksLikeText = text.count >= 2 && text.contains { !$0.isWhitespace }
        return isPrintable && looksLikeText ? text : nil
    }
}

extension Unicode.GeneralCategory {
    fileprivate var isControl: Bool {
        switch self {
        case .control, .format, .unassigned, .privateUse, .surrogate: true
        default: false
        }
    }
}

struct ErrorSummary: Encodable {
    let code: String
    let message: String

    init(_ error: BLEError) {
        code = error.code
        message = error.message
    }
}
