import Testing
@testable import Alas

struct SimpleHighlighterTests {
    @Test func highlightsSwiftKeyword() {
        let tokens = SimpleHighlighter.tokenize("func foo() {}", language: "swift")
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "func" }))
    }

    @Test func highlightsString() {
        let tokens = SimpleHighlighter.tokenize("let x = \"hi\"", language: "swift")
        #expect(tokens.contains(where: { $0.kind == .string }))
    }

    @Test func detectsLanguageByExtension() {
        #expect(SimpleHighlighter.language(forFile: "foo.rs") == "rust")
        #expect(SimpleHighlighter.language(forFile: "foo.swift") == "swift")
        #expect(SimpleHighlighter.language(forFile: "data.json") == "json")
        #expect(SimpleHighlighter.language(forFile: "readme.md") == "markdown")
        #expect(SimpleHighlighter.language(forFile: "weird.xyz") == "plain")
    }
}
