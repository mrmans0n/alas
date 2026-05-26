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

    @Test("Java class and method are captured")
    func javaBasics() throws {
        let src = """
        public class Greeter {
          public String greet(String name) { return "hello, " + name; }
        }
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "java")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.string))
    }

    @Test("TypeScript and TSX get keyword + type + string captures")
    func typescriptBasics() throws {
        let ts = TreeSitterHighlighter.highlight(
            source: "interface User { name: string } const u: User = { name: \"a\" };",
            fileExtension: "ts"
        )
        let tsx = TreeSitterHighlighter.highlight(
            source: "type Props = { name: string }; const G = (p: Props) => <h1>{p.name}</h1>;",
            fileExtension: "tsx"
        )
        #expect(ts.contains(where: { $0.capture == .keyword }))
        #expect(ts.contains(where: { $0.capture == .string }))
        #expect(!tsx.isEmpty)
        #expect(tsx.contains(where: { $0.capture == .keyword }))
    }

    @Test("JavaScript and JSX get keyword + string + function captures")
    func javascriptBasics() throws {
        let js = TreeSitterHighlighter.highlight(
            source: #"const greet = (name) => `hello, ${name}`;"#,
            fileExtension: "js"
        )
        let jsx = TreeSitterHighlighter.highlight(
            source: #"const Greeting = ({name}) => <h1>Hi, {name}</h1>;"#,
            fileExtension: "jsx"
        )
        #expect(js.contains(where: { $0.capture == .keyword }))
        #expect(js.contains(where: { $0.capture == .string }))
        #expect(!jsx.isEmpty)
        #expect(jsx.contains(where: { $0.capture == .keyword }))
    }

    @Test("Bash variable expansion and keywords are captured")
    func bashBasics() throws {
        let src = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ -z "$NAME" ]]; then echo "anon"; fi
        """
        let sh = TreeSitterHighlighter.highlight(source: src, fileExtension: "sh")
        let bash = TreeSitterHighlighter.highlight(source: src, fileExtension: "bash")
        #expect(!sh.isEmpty)
        #expect(!bash.isEmpty)
        #expect(sh.contains(where: { $0.capture == .keyword }))
        #expect(sh.contains(where: { $0.capture == .comment }))
    }

    @Test("Go `func main()` is captured as keyword + function")
    func goFunction() throws {
        let src = """
        package main
        import "fmt"
        func main() { fmt.Println("hi") }
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "go")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.string))
    }

    @Test("Rust `fn main()` is captured as keyword + function")
    func rustFunction() throws {
        let spans = TreeSitterHighlighter.highlight(source: #"fn main() { println!("hi") }"#, fileExtension: "rs")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.function))
        #expect(captures.contains(.string))
    }

    @Test("JSON strings and numbers are captured")
    func jsonBasics() throws {
        let spans = TreeSitterHighlighter.highlight(source: #"{"ok": true, "n": 1, "name": "alas"}"#, fileExtension: "json")
        #expect(!spans.isEmpty)
        #expect(spans.contains(where: { $0.capture == .string }))
        #expect(spans.contains(where: { $0.capture == .number }))
    }

    @Test("Python `def foo()` is captured as keyword + function")
    func pythonFunction() throws {
        let src = """
        def greet(name):
            return f"hello, {name}"
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "py")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.function))
        #expect(captures.contains(.string))
    }

    @Test("TOML keys, strings, and numbers are captured")
    func tomlBasics() throws {
        let src = """
        name = "alas"
        port = 8080
        [server]
        host = "localhost"
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "toml")
        #expect(!spans.isEmpty)
        #expect(spans.contains(where: { $0.capture == .string }))
        #expect(spans.contains(where: { $0.capture == .number }))
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
