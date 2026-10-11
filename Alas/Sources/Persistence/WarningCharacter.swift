import Foundation

struct WarningCharacter: Codable, Equatable, Identifiable, Sendable {
    let scalarValue: UInt32
    var note: String

    var id: UInt32 { scalarValue }
    var scalar: Unicode.Scalar? { Unicode.Scalar(scalarValue) }
    var code: String { String(format: "U+%04X", scalarValue) }

    static func parse(_ input: String, note: String) -> WarningCharacter? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: UInt32?
        if trimmed.lowercased().hasPrefix("u+") {
            let digits = trimmed.dropFirst(2)
            value = (4...6).contains(digits.count) && digits.allSatisfy(\.isHexDigit)
                ? UInt32(digits, radix: 16)
                : nil
        } else if input.unicodeScalars.count == 1 {
            value = input.unicodeScalars.first?.value
        } else if trimmed.unicodeScalars.count == 1 {
            value = trimmed.unicodeScalars.first?.value
        } else {
            value = nil
        }
        guard let value, Unicode.Scalar(value) != nil else { return nil }
        return .init(scalarValue: value, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func sanitized(_ entries: [WarningCharacter]) -> [WarningCharacter] {
        var seen = Set<UInt32>()
        return entries.filter { $0.scalar != nil && seen.insert($0.scalarValue).inserted }
    }

    static let defaults: [WarningCharacter] = [
        .init(scalarValue: 0x0003, note: "End of text"), .init(scalarValue: 0x00A0, note: "Non-breaking space"),
        .init(scalarValue: 0x00AD, note: "Soft hyphen"), .init(scalarValue: 0x034F, note: "Combining grapheme joiner"),
        .init(scalarValue: 0x037E, note: "Greek question mark"), .init(scalarValue: 0x061C, note: "Arabic letter mark"),
        .init(scalarValue: 0x180E, note: "Mongolian vowel separator"), .init(scalarValue: 0x200B, note: "Zero-width space"),
        .init(scalarValue: 0x200C, note: "Zero-width non-joiner"), .init(scalarValue: 0x200D, note: "Zero-width joiner"),
        .init(scalarValue: 0x200E, note: "Left-to-right mark"), .init(scalarValue: 0x200F, note: "Right-to-left mark"),
        .init(scalarValue: 0x2013, note: "En dash"), .init(scalarValue: 0x2018, note: "Left single quote"),
        .init(scalarValue: 0x2019, note: "Right single quote"), .init(scalarValue: 0x201C, note: "Left double quote"),
        .init(scalarValue: 0x201D, note: "Right double quote"), .init(scalarValue: 0x2029, note: "Paragraph separator"),
        .init(scalarValue: 0x202A, note: "Left-to-right embedding"), .init(scalarValue: 0x202B, note: "Right-to-left embedding"),
        .init(scalarValue: 0x202C, note: "Pop directional formatting"), .init(scalarValue: 0x202D, note: "Left-to-right override"),
        .init(scalarValue: 0x202E, note: "Right-to-left override"), .init(scalarValue: 0x202F, note: "Narrow non-breaking space"),
        .init(scalarValue: 0x2060, note: "Word joiner"), .init(scalarValue: 0x2061, note: "Function application"),
        .init(scalarValue: 0x2062, note: "Invisible times"), .init(scalarValue: 0x2063, note: "Invisible separator"),
        .init(scalarValue: 0x2064, note: "Invisible plus"), .init(scalarValue: 0x2066, note: "Left-to-right isolate"),
        .init(scalarValue: 0x2067, note: "Right-to-left isolate"), .init(scalarValue: 0x2068, note: "First strong isolate"),
        .init(scalarValue: 0x2069, note: "Pop directional isolate"), .init(scalarValue: 0xFEFF, note: "Zero-width no-break space / byte-order mark"),
    ]
}
