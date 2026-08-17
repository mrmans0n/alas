import Testing
@testable import Alas

@Suite("Warning character")
struct WarningCharacterTests {
    @Test func parsesCodePointAndLiteralScalar() {
        #expect(WarningCharacter.parse("u+200b", note: " Zero-width space ") ==
            WarningCharacter(scalarValue: 0x200B, note: "Zero-width space"))
        #expect(WarningCharacter.parse("\u{00A0}", note: "NBSP")?.scalarValue == 0x00A0)
        #expect(WarningCharacter.parse("💩", note: "")?.code == "U+1F4A9")
    }

    @Test func rejectsInvalidInput() {
        #expect(WarningCharacter.parse("", note: "") == nil)
        #expect(WarningCharacter.parse("ab", note: "") == nil)
        #expect(WarningCharacter.parse("U+D800", note: "") == nil)
        #expect(WarningCharacter.parse("U+110000", note: "") == nil)
    }

    @Test func sanitizesEntries() {
        let entries = [
            WarningCharacter(scalarValue: 0x200B, note: "First"),
            WarningCharacter(scalarValue: 0x110000, note: "Invalid"),
            WarningCharacter(scalarValue: 0x200B, note: "Second"),
        ]
        #expect(WarningCharacter.sanitized(entries) == [
            WarningCharacter(scalarValue: 0x200B, note: "First")
        ])
    }

    @Test func defaultsCoverAmbiguousAndBidiCharacters() {
        #expect(WarningCharacter.defaults.contains { $0.scalarValue == 0x2013 && $0.note == "En dash" })
        #expect(WarningCharacter.defaults.contains { $0.scalarValue == 0x202E })
        #expect(WarningCharacter.defaults.contains { $0.scalarValue == 0x2069 })
        #expect(WarningCharacter.defaults.map(\.scalarValue).count == Set(WarningCharacter.defaults.map(\.scalarValue)).count)
    }
}
