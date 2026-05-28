import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("ACP code block highlighter")
struct ACPCodeBlockHighlighterTests {
    @Test("maps common ACP fence labels to highlighter extensions")
    func mapsFenceLabels() {
        #expect(ACPCodeLanguage.highlighterExtension(for: "swift") == "swift")
        #expect(ACPCodeLanguage.highlighterExtension(for: "python") == "py")
        #expect(ACPCodeLanguage.highlighterExtension(for: "typescript") == "ts")
        #expect(ACPCodeLanguage.highlighterExtension(for: "javascript") == "js")
        #expect(ACPCodeLanguage.highlighterExtension(for: "md") == "md")
        #expect(ACPCodeLanguage.highlighterExtension(for: "markdown") == "md")
        #expect(ACPCodeLanguage.highlighterExtension(for: "shell") == "sh")
        #expect(ACPCodeLanguage.highlighterExtension(for: "zsh") == "sh")
        #expect(ACPCodeLanguage.highlighterExtension(for: "c++") == "cpp")
        #expect(ACPCodeLanguage.highlighterExtension(for: "{.swift}") == "swift")
        #expect(ACPCodeLanguage.highlighterExtension(for: "swift title=Example.swift") == "swift")
    }

    @Test("unknown and empty fence labels remain plain")
    func unknownFenceLabels() {
        #expect(ACPCodeLanguage.highlighterExtension(for: nil) == nil)
        #expect(ACPCodeLanguage.highlighterExtension(for: "") == nil)
        #expect(ACPCodeLanguage.highlighterExtension(for: "not-a-language") == nil)
    }

    @Test("Swift code applies syntax color while preserving monospaced font")
    func swiftCodeAppliesSyntaxColor() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let attributed = ACPCodeBlockHighlighter.attributedString(
            code: "func greet() {}",
            language: "swift",
            theme: theme
        )
        let ns = attributed.string as NSString
        let funcRange = ns.range(of: "func")
        let font = attributed.attribute(.font, at: funcRange.location, effectiveRange: nil) as? NSFont
        let color = attributed.attribute(.foregroundColor, at: funcRange.location, effectiveRange: nil) as? NSColor

        #expect(font?.isFixedPitch == true)
        #expect(color != EditorTheme(theme: theme).defaultFG)
    }

    @Test("unknown code remains default-colored monospaced text")
    func unknownCodeRemainsPlain() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let attributed = ACPCodeBlockHighlighter.attributedString(
            code: "plain text",
            language: "not-a-language",
            theme: theme
        )
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(font?.isFixedPitch == true)
        #expect(color == EditorTheme(theme: theme).defaultFG)
    }

    @Test("highlighted output bridges to Swift AttributedString")
    func highlightedOutputBridgesToSwiftAttributedString() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let nsAttributed = ACPCodeBlockHighlighter.attributedString(
            code: "let value = 1",
            language: "swift",
            theme: theme
        )
        let swiftAttributed = AttributedString(nsAttributed)

        #expect(String(swiftAttributed.characters) == "let value = 1")
    }
}
