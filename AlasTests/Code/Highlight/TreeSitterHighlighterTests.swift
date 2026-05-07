import Foundation
import Testing
@testable import Alas

@Suite("TreeSitterHighlighter")
struct TreeSitterHighlighterTests {
    @Test("Swift `func foo()` is captured as keyword + function")
    func swiftFunction() throws {
        let src = "func foo() {}"
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "swift")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.function))
    }

    @Test("fallback highlighter preserves non-Swift spans")
    func fallbackHighlighterForKnownExtensions() throws {
        let rust = TreeSitterHighlighter.highlight(source: #"fn main() { println!("hi") }"#, fileExtension: "rs")
        let json = TreeSitterHighlighter.highlight(source: #"{"ok": true, "n": 1}"#, fileExtension: "json")
        #expect(rust.contains(where: { $0.capture == .keyword }))
        #expect(rust.contains(where: { $0.capture == .string }))
        #expect(json.contains(where: { $0.capture == .string }))
        #expect(json.contains(where: { $0.capture == .number }))
    }

    @Test("unknown extension returns no spans")
    func unknownExtension() throws {
        let spans = TreeSitterHighlighter.highlight(source: "print()", fileExtension: "abc")
        #expect(spans.isEmpty)
    }

    @Test("string literal captured")
    func stringLiteral() throws {
        let src = #"let x = "hi""#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "swift")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.string))
    }

    @Test("session accepts incremental edits")
    func sessionIncrementalEdit() async throws {
        let session = TreeSitterHighlighter.Session()
        _ = await session.highlight(source: "func foo() {}", fileExtension: "swift", edits: [])
        let spans = await session.highlight(
            source: "func foobar() {}",
            fileExtension: "swift",
            edits: [EditorTextEdit(location: 8, oldLength: 0, replacementText: "bar")]
        )
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.function))
    }
}
