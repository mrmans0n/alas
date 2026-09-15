import Foundation
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
        #expect(icon.imagePath == nil)
        #expect(icon.transparentBackground == false)
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

    @Test func sanitizedColorCanUseCallerFallback() {
        #expect(ProjectIcon.sanitizedColor(nil, fallback: "#112233") == "#112233")
        #expect(ProjectIcon.sanitizedColor("nope", fallback: "#112233") == "#112233")
        #expect(ProjectIcon.sanitizedColor("nope", fallback: "also-bad") == ProjectIcon.defaultColor)
    }

    @Test func sanitizedEmojiUsesFirstValidEmojiOnly() {
        #expect(ProjectIcon.sanitizedEmoji("abc 🚀") == "🚀")
        #expect(ProjectIcon.sanitizedEmoji("abc") == nil)
        #expect(ProjectIcon(mode: .emoji, color: "#112233", emoji: "abc").emoji == nil)
    }

    @Test func transparentBackgroundSurvivesRoundTrip() throws {
        for transparent in [true, false] {
            let icon = ProjectIcon(
                mode: .symbol,
                color: "#112233",
                symbolName: "folder",
                transparentBackground: transparent
            )
            let data = try JSONEncoder().encode(icon)

            #expect(try JSONDecoder().decode(ProjectIcon.self, from: data) == icon)
        }
    }

    @Test func opaqueIconOmitsTransparentBackgroundKey() throws {
        let data = try JSONEncoder().encode(ProjectIcon.default())
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["transparentBackground"] == nil)
    }

    @Test func legacyIconDecodesAsOpaque() throws {
        let json = ##"{"mode":"letter","color":"#112233"}"##
        let icon = try JSONDecoder().decode(ProjectIcon.self, from: Data(json.utf8))

        #expect(icon.transparentBackground == false)
    }

    @Test func withColorPreservesTransparentBackground() {
        let icon = ProjectIcon(mode: .letter, color: "#112233", transparentBackground: true)

        #expect(icon.withColor("#445566").transparentBackground == true)
        #expect(icon.withColor("#445566").color == "#445566")
    }
}
