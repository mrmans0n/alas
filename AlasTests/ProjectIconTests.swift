import Testing
@testable import Alas

struct ProjectIconTests {
    @Test func defaultIconUsesLetterModeAndColor() {
        let icon = ProjectIcon.default(color: "#123456")

        #expect(icon.mode == .letter)
        #expect(icon.color == "#123456")
        #expect(icon.label == nil)
        #expect(icon.symbolName == nil)
        #expect(icon.emoji == nil)
        #expect(icon.imageAssetName == nil)
    }

    @Test func fallbackLabelUsesLastPathComponentInitial() {
        #expect(ProjectIcon.fallbackLabel(projectName: "mrmans0n/alas") == "A")
        #expect(ProjectIcon.fallbackLabel(projectName: "  ") == "?")
    }

    @Test func sanitizedLabelClampsToTwoCharacters() {
        #expect(ProjectIcon.sanitizedLabel("abc") == "AB")
        #expect(ProjectIcon.sanitizedLabel("z") == "Z")
        #expect(ProjectIcon.sanitizedLabel("  ") == nil)
    }

    @Test func sanitizedColorRequiresSixDigitHex() {
        #expect(ProjectIcon.sanitizedColor("#aabbcc") == "#aabbcc")
        #expect(ProjectIcon.sanitizedColor("AABBCC") == "#AABBCC")
        #expect(ProjectIcon.sanitizedColor("bad") == ProjectIcon.defaultColor)
        #expect(ProjectIcon.sanitizedColor("#12345g") == ProjectIcon.defaultColor)
    }
}
