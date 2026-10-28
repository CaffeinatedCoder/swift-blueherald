/// Cleans text that a peripheral supplies about itself (advertised names, GAP names, 0x2901
/// descriptions).
///
/// That text is untrusted input: a device can name itself anything, including text meant to
/// steer whoever reads it. The core types keep it as the device sent it; whatever shows it to a
/// person or an agent cleans it on the way out. Cleaning cannot tell intent, but it bounds what a
/// name can carry. Line breaks and other control characters become spaces, invisible formatting
/// characters (bidirectional overrides, zero-width joiners) are dropped, runs of whitespace
/// collapse to one space, and the result is cut to `limit` characters.
public enum DeviceText {
    /// Enough for any real device name or characteristic label.
    public static let limit = 64

    /// The cleaned text, or `nil` when nothing printable is left.
    public static func clean(_ text: String?, limit: Int = Self.limit) -> String? {
        guard let cleaned = visible(text) else { return nil }
        return cleaned.count > limit ? cleaned.prefix(limit - 1) + "…" : cleaned
    }

    /// The cleaned text at full length, for matching rather than showing.
    public static func visible(_ text: String?) -> String? {
        guard let text else { return nil }
        var cleaned = ""
        cleaned.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format, .privateUse, .unassigned, .surrogate:
                continue
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                pendingSpace = !cleaned.isEmpty
            default:
                if scalar.properties.isWhitespace {
                    pendingSpace = !cleaned.isEmpty
                    continue
                }
                if pendingSpace {
                    cleaned.unicodeScalars.append(" ")
                    pendingSpace = false
                }
                cleaned.unicodeScalars.append(scalar)
            }
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
