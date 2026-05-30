import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("ACP code block highlighter")
struct ACPCodeBlockHighlighterTests {
    private func foregroundColor(
        for needle: String,
        in attributed: NSAttributedString
    ) throws -> NSColor {
        let range = (attributed.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound)
        let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        return try #require(color)
    }

    private func allForegroundColors(
        in attributed: NSAttributedString,
        equal expected: NSColor
    ) -> Bool {
        guard attributed.length > 0 else { return true }
        var matches = true
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            guard let color = value as? NSColor, color == expected else {
                matches = false
                stop.pointee = true
                return
            }
        }
        return matches
    }

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

    @Test("maps additional ACP fence labels to highlighter extensions")
    func mapsAdditionalFenceLabels() {
        #expect(ACPCodeLanguage.highlighterExtension(for: "diff") == "diff")
        #expect(ACPCodeLanguage.highlighterExtension(for: "patch") == "patch")
        #expect(ACPCodeLanguage.highlighterExtension(for: "html") == "html")
        #expect(ACPCodeLanguage.highlighterExtension(for: "xml") == "xml")
        #expect(ACPCodeLanguage.highlighterExtension(for: "css") == "css")
        #expect(ACPCodeLanguage.highlighterExtension(for: "scss") == "scss")
        #expect(ACPCodeLanguage.highlighterExtension(for: "sass") == "sass")
        #expect(ACPCodeLanguage.highlighterExtension(for: "ruby") == "rb")
        #expect(ACPCodeLanguage.highlighterExtension(for: "rb") == "rb")
        #expect(ACPCodeLanguage.highlighterExtension(for: "lua") == "lua")
        #expect(ACPCodeLanguage.highlighterExtension(for: "php") == "php")
        #expect(ACPCodeLanguage.highlighterExtension(for: "hcl") == "hcl")
        #expect(ACPCodeLanguage.highlighterExtension(for: "terraform") == "tf")
        #expect(ACPCodeLanguage.highlighterExtension(for: "tfvars") == "tfvars")
        #expect(ACPCodeLanguage.highlighterExtension(for: "dockerfile") == "dockerfile")
    }

    @Test("future-known unsupported ACP fence labels remain plain")
    func futureKnownUnsupportedFenceLabelsRemainPlain() {
        #expect(ACPCodeLanguage.highlighterExtension(for: "sql") == nil)
        #expect(ACPCodeLanguage.highlighterExtension(for: "perl") == nil)
        #expect(ACPCodeLanguage.highlighterExtension(for: "elixir") == nil)
        #expect(ACPCodeLanguage.highlighterExtension(for: "ini") == nil)
    }

    @Test("supported labels apply non-default ACP syntax colors")
    func supportedLabelsApplySyntaxColors() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let editorTheme = EditorTheme(theme: theme)

        let diff = ACPCodeBlockHighlighter.attributedString(
            code: "@@ -1 +1 @@\n-old\n+new",
            language: "diff",
            theme: theme
        )
        let html = ACPCodeBlockHighlighter.attributedString(
            code: #"<button disabled class="primary">Save</button>"#,
            language: "html",
            theme: theme
        )
        let css = ACPCodeBlockHighlighter.attributedString(
            code: #".primary { display: flex; color: #fff; }"#,
            language: "css",
            theme: theme
        )

        #expect(try foregroundColor(for: "@@", in: diff) != editorTheme.defaultFG)
        #expect(try foregroundColor(for: "button", in: html) != editorTheme.defaultFG)
        #expect(try foregroundColor(for: "primary", in: html) != editorTheme.defaultFG)
        #expect(try foregroundColor(for: "fff", in: css) != editorTheme.defaultFG)
    }

    @Test("future-known unsupported ACP labels keep attributed output plain")
    func futureKnownUnsupportedAttributedOutputRemainsPlain() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let editorTheme = EditorTheme(theme: theme)
        let attributed = ACPCodeBlockHighlighter.attributedString(
            code: "SELECT id FROM users WHERE active = true;",
            language: "sql",
            theme: theme
        )

        #expect(attributed.string == "SELECT id FROM users WHERE active = true;")
        #expect(allForegroundColors(in: attributed, equal: editorTheme.defaultFG))
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
