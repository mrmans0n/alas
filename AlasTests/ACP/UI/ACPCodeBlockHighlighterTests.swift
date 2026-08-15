import AppKit
import SwiftUI
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
        #expect(ACPCodeLanguage.highlighterExtension(for: "sql") == "sql")
    }

    @Test("maps fence labels for the 2026-08 grammar additions")
    func mapsNewGrammarFenceLabels() {
        #expect(ACPCodeLanguage.highlighterExtension(for: "cs") == "cs")
        #expect(ACPCodeLanguage.highlighterExtension(for: "csharp") == "cs")
        #expect(ACPCodeLanguage.highlighterExtension(for: "c#") == "cs")
        #expect(ACPCodeLanguage.highlighterExtension(for: "scala") == "scala")
        #expect(ACPCodeLanguage.highlighterExtension(for: "r") == "r")
        #expect(ACPCodeLanguage.highlighterExtension(for: "dart") == "dart")
        #expect(ACPCodeLanguage.highlighterExtension(for: "ex") == "ex")
        #expect(ACPCodeLanguage.highlighterExtension(for: "exs") == "ex")
        #expect(ACPCodeLanguage.highlighterExtension(for: "elixir") == "ex")
        #expect(ACPCodeLanguage.highlighterExtension(for: "erl") == "erl")
        #expect(ACPCodeLanguage.highlighterExtension(for: "erlang") == "erl")
        #expect(ACPCodeLanguage.highlighterExtension(for: "hs") == "hs")
        #expect(ACPCodeLanguage.highlighterExtension(for: "haskell") == "hs")
        #expect(ACPCodeLanguage.highlighterExtension(for: "clj") == "clj")
        #expect(ACPCodeLanguage.highlighterExtension(for: "clojure") == "clj")
        #expect(ACPCodeLanguage.highlighterExtension(for: "jl") == "jl")
        #expect(ACPCodeLanguage.highlighterExtension(for: "julia") == "jl")
        #expect(ACPCodeLanguage.highlighterExtension(for: "zig") == "zig")
        #expect(ACPCodeLanguage.highlighterExtension(for: "ps1") == "ps1")
        #expect(ACPCodeLanguage.highlighterExtension(for: "powershell") == "ps1")
        #expect(ACPCodeLanguage.highlighterExtension(for: "groovy") == "groovy")
        #expect(ACPCodeLanguage.highlighterExtension(for: "gradle") == "groovy")
        #expect(ACPCodeLanguage.highlighterExtension(for: "objc") == "m")
        #expect(ACPCodeLanguage.highlighterExtension(for: "objective-c") == "m")
        #expect(ACPCodeLanguage.highlighterExtension(for: "graphql") == "graphql")
        #expect(ACPCodeLanguage.highlighterExtension(for: "gql") == "graphql")
        #expect(ACPCodeLanguage.highlighterExtension(for: "proto") == "proto")
        #expect(ACPCodeLanguage.highlighterExtension(for: "protobuf") == "proto")
        #expect(ACPCodeLanguage.highlighterExtension(for: "svelte") == "svelte")
        #expect(ACPCodeLanguage.highlighterExtension(for: "ini") == "ini")
        #expect(ACPCodeLanguage.highlighterExtension(for: "make") == "mk")
        #expect(ACPCodeLanguage.highlighterExtension(for: "makefile") == "mk")
        #expect(ACPCodeLanguage.highlighterExtension(for: "cmake") == "cmake")
    }

    @Test("labels with no grammar remain plain")
    func labelsWithNoGrammarRemainPlain() {
        // No tree-sitter-perl grammar exists at all (see the pack's
        // Cargo.toml for why the only published version is unusable).
        #expect(ACPCodeLanguage.highlighterExtension(for: "pl") == nil)
        #expect(ACPCodeLanguage.highlighterExtension(for: "perl") == nil)
    }

    @Test("path resolution maps only supported editor highlighter paths")
    func pathResolutionMapsSupportedPaths() {
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "Sources/App.swift") == "swift")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "script.py") == "py")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "package.json") == "json")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "Dockerfile") == "dockerfile")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "page.htm") == "htm")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "styles.scss") == "scss")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "changes.patch") == "patch")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "query.sql") == "sql")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "README") == nil)
    }

    @Test("path resolution routes filename-based grammars through LanguageRegistry")
    func pathResolutionRoutesFilenameBasedGrammars() {
        // Regression coverage: this previously went through a bare
        // `pathExtension` in some call sites, which resolves `Makefile` to
        // "" and `CMakeLists.txt` to "txt" — losing the grammar entirely.
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "Makefile") == "mk")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "GNUmakefile") == "mk")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "CMakeLists.txt") == "cmake")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "Containerfile") == "dockerfile")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: ".editorconfig") == "ini")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "Jenkinsfile") == "groovy")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "Program.cs") == "cs")
        #expect(ACPCodeLanguage.highlighterExtension(forPath: "main.zig") == "zig")
    }

    @Test("tool output syntax prefers diff shape over paths")
    func toolOutputSyntaxPrefersDiffShape() {
        let content = """
        @@ -1,2 +1,2 @@
        -old
        +new
        """
        #expect(ACPToolOutputSyntax.highlighterExtension(content: content, locations: ["Sources/App.swift"]) == "diff")
    }

    @Test("tool output syntax uses whole-output fenced labels")
    func toolOutputSyntaxUsesWholeOutputFencedLabels() {
        let content = """
        ```sql
        SELECT id FROM users
        ```
        """
        #expect(ACPToolOutputSyntax.highlighterExtension(content: content, locations: []) == "sql")
    }

    @Test("tool output syntax prefers fenced labels over diff shape")
    func toolOutputSyntaxPrefersFencedLabelsOverDiffShape() {
        let content = """
        ```swift
        @@ -1 +1 @@
        -old
        +new
        ```
        """
        #expect(ACPToolOutputSyntax.highlighterExtension(content: content, locations: []) == "swift")
    }

    @Test("tool output syntax detects ACP-flattened diffs")
    func toolOutputSyntaxDetectsACPFlattenedDiffs() {
        let content = """
        --- a.swift
        -let old = 1
        +let new = 2
        """
        #expect(ACPToolOutputSyntax.highlighterExtension(content: content, locations: []) == "diff")
    }

    @Test("tool output syntax detects ACP-flattened diffs with indented code")
    func toolOutputSyntaxDetectsACPFlattenedDiffsWithIndentedCode() {
        let content = """
        --- Sources/App.swift
        -    let old = 1
        +    let new = 2
        """
        #expect(ACPToolOutputSyntax.highlighterExtension(content: content, locations: []) == "diff")
    }

    @Test("tool output syntax rejects section headings that resemble hunk markers")
    func toolOutputSyntaxRejectsSectionHeadingHunkMarkers() {
        #expect(ACPToolOutputSyntax.highlighterExtension(
            content: "@@ Section @@",
            locations: ["Sources/App.swift"]
        ) == "swift")
    }

    @Test("tool output syntax rejects markdown-like flattened diff markers")
    func toolOutputSyntaxRejectsMarkdownLikeFlattenedDiffMarkers() {
        let content = """
        --- Notes
        - item one
        + item two
        """
        #expect(ACPToolOutputSyntax.highlighterExtension(content: content, locations: []) == nil)
    }

    @Test("tool output syntax uses exactly one supported location path")
    func toolOutputSyntaxUsesSingleSupportedPath() {
        #expect(ACPToolOutputSyntax.highlighterExtension(
            content: "let value = 1",
            locations: ["Sources/App.swift"]
        ) == "swift")
    }

    @Test("tool output syntax remains plain for ambiguous or unsupported paths")
    func toolOutputSyntaxRejectsAmbiguousOutput() {
        #expect(ACPToolOutputSyntax.highlighterExtension(
            content: "let value = 1",
            locations: []
        ) == nil)
        #expect(ACPToolOutputSyntax.highlighterExtension(
            content: "let value = 1",
            locations: ["Sources/App.swift", "Sources/Other.swift"]
        ) == nil)
        // `.ini` gained a grammar alongside this test's other additions, so a
        // plain `.txt` is the still-genuinely-unsupported case here now.
        #expect(ACPToolOutputSyntax.highlighterExtension(
            content: "theme = cool-slate",
            locations: ["notes.txt"]
        ) == nil)
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

    @Test("SQL labels apply non-default ACP syntax colors")
    func sqlLabelsApplySyntaxColors() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let editorTheme = EditorTheme(theme: theme)
        let attributed = ACPCodeBlockHighlighter.attributedString(
            code: "SELECT id FROM users WHERE active = true;",
            language: "sql",
            theme: theme
        )

        #expect(attributed.string == "SELECT id FROM users WHERE active = true;")
        #expect(try foregroundColor(for: "SELECT", in: attributed) != editorTheme.defaultFG)
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

    @Test("highlight cache key changes with language and theme inputs")
    func highlightedTextCacheKeyTracksInputs() throws {
        let dark = try Theme.loadBundled(id: "cool-slate")
        let light = try Theme.loadBundled(id: "light")
        var accentTheme = dark
        accentTheme.accentOverrideHex = "#123456"
        var tokenOverrideTheme = dark
        tokenOverrideTheme.resolvedColorOverrides = [
            "fg": Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1),
        ]
        var changedTokens = dark.tokens
        changedTokens["fg"] = "\(changedTokens["fg"] ?? "") changed"
        let rawTokenTheme = Theme(id: dark.id, name: dark.name, tokens: changedTokens)

        let a = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "swift",
            theme: dark,
            fontSize: 12
        )
        let precomputedThemeKey = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "swift",
            themeKey: ACPSyntaxHighlightCacheKey.themeKey(dark),
            fontSize: 12
        )
        let b = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "diff",
            theme: dark,
            fontSize: 12
        )
        let c = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "swift",
            theme: light,
            fontSize: 12
        )
        let differentText = ACPSyntaxHighlightCacheKey(
            text: "let value = 2",
            resolvedExtension: "swift",
            theme: dark,
            fontSize: 12
        )
        let differentFontSize = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "swift",
            theme: dark,
            fontSize: 13
        )
        let differentAccent = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "swift",
            theme: accentTheme,
            fontSize: 12
        )
        let differentRawToken = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "swift",
            theme: rawTokenTheme,
            fontSize: 12
        )
        let differentResolvedColorOverride = ACPSyntaxHighlightCacheKey(
            text: "let value = 1",
            resolvedExtension: "swift",
            theme: tokenOverrideTheme,
            fontSize: 12
        )

        #expect(a == a)
        #expect(a == precomputedThemeKey)
        #expect(a != b)
        #expect(a != c)
        #expect(a != differentText)
        #expect(a != differentFontSize)
        #expect(a != differentAccent)
        #expect(a != differentRawToken)
        #expect(a != differentResolvedColorOverride)
    }

    @Test("tool output diff choice applies diff syntax colors")
    func toolOutputDiffChoiceAppliesColors() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let editorTheme = EditorTheme(theme: theme)
        let content = """
        @@ -1 +1 @@
        -old
        +new
        """
        let ext = ACPToolOutputSyntax.highlighterExtension(content: content, locations: ["Sources/App.swift"])
        let attributed = ACPCodeBlockHighlighter.attributedString(
            code: content,
            language: ext,
            theme: theme,
            fontSize: 11.5
        )

        #expect(ext == "diff")
        #expect(try foregroundColor(for: "@@", in: attributed) != editorTheme.defaultFG)
    }

    @Test("tool output single path choice applies file syntax colors")
    func toolOutputSinglePathChoiceAppliesColors() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let editorTheme = EditorTheme(theme: theme)
        let content = "func greet() {}"
        let ext = ACPToolOutputSyntax.highlighterExtension(content: content, locations: ["Sources/App.swift"])
        let attributed = ACPCodeBlockHighlighter.attributedString(
            code: content,
            language: ext,
            theme: theme,
            fontSize: 11.5
        )

        #expect(ext == "swift")
        #expect(try foregroundColor(for: "func", in: attributed) != editorTheme.defaultFG)
    }

    @Test("tool output unsupported path remains default-colored")
    func toolOutputUnsupportedPathRemainsPlain() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let editorTheme = EditorTheme(theme: theme)
        let content = "theme = cool-slate"
        let ext = ACPToolOutputSyntax.highlighterExtension(content: content, locations: ["notes.txt"])
        let attributed = ACPCodeBlockHighlighter.attributedString(
            code: content,
            language: ext,
            theme: theme,
            fontSize: 11.5
        )

        #expect(ext == nil)
        #expect(allForegroundColors(in: attributed, equal: editorTheme.defaultFG))
    }
}
