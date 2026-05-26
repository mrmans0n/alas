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

    @Test("fallback highlighter recognizes Kotlin")
    func fallbackHighlighterRecognizesKotlin() throws {
        let kt = TreeSitterHighlighter.highlight(source: "fun main() { println(\"hi\") }", fileExtension: "kt")
        let kts = TreeSitterHighlighter.highlight(source: "val x = 1", fileExtension: "kts")
        #expect(kt.contains(where: { $0.capture == .keyword }))
        #expect(kt.contains(where: { $0.capture == .string }))
        #expect(kts.contains(where: { $0.capture == .keyword }))
    }

    @Test("YAML keys, strings, and numbers are captured")
    func yamlBasics() throws {
        let src = """
        name: alas
        port: 8080
        tags:
          - "swift"
          - "macos"
        """
        let yaml = TreeSitterHighlighter.highlight(source: src, fileExtension: "yaml")
        let yml = TreeSitterHighlighter.highlight(source: src, fileExtension: "yml")
        #expect(!yaml.isEmpty)
        #expect(!yml.isEmpty)
        #expect(yaml.contains(where: { $0.capture == .string }))
        #expect(yaml.contains(where: { $0.capture == .number }))
        #expect(yaml.contains(where: { $0.capture == .property }))
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

    @Test("session reparses changed source when edit ranges are unavailable")
    func sessionReparsesChangedSourceWithoutEdits() async throws {
        let session = TreeSitterHighlighter.Session()
        _ = await session.highlight(source: "func foo() {}", fileExtension: "swift", edits: [])
        let spans = await session.highlight(source: #"let value = "hello""#, fileExtension: "swift", edits: [])
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.string))
    }
}
