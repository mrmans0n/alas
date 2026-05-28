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

    @Test("TypeScript captures types; TSX captures JSX attributes")
    func typescriptBasics() throws {
        let ts = TreeSitterHighlighter.highlight(
            source: "interface User { name: string } const u: User = { name: \"a\" };",
            fileExtension: "ts"
        )
        let tsx = TreeSitterHighlighter.highlight(
            source: #"const G = (p: {n: string}) => <Button primary onClick={() => p.n}>Hi</Button>;"#,
            fileExtension: "tsx"
        )
        #expect(ts.contains(where: { $0.capture == .keyword }))
        // `User` parses as `type_identifier @type` — a TS-only capture the
        // regex fallback would never emit, so this proves the tree-sitter
        // query path is wired.
        #expect(ts.contains(where: { $0.capture == .type }))
        // `primary` / `onClick` are `jsx_attribute (property_identifier) @attribute`
        // from the JSX overlay — emitted only when the JSX query is loaded.
        #expect(tsx.contains(where: { $0.capture == .attribute }))
    }

    @Test("JavaScript captures functions; JSX captures attributes via overlay")
    func javascriptBasics() throws {
        let js = TreeSitterHighlighter.highlight(
            source: #"const greet = (name) => `hello, ${name}`;"#,
            fileExtension: "js"
        )
        let jsx = TreeSitterHighlighter.highlight(
            source: #"const G = ({name}) => <Button primary onClick={() => name}>Hi</Button>;"#,
            fileExtension: "jsx"
        )
        #expect(js.contains(where: { $0.capture == .keyword }))
        #expect(js.contains(where: { $0.capture == .string }))
        // `primary` / `onClick` are JSX attribute names — `@attribute` capture
        // from the JSX overlay. The regex fallback never emits `.attribute`,
        // so this proves the JSX overlay was merged into the .jsx query.
        #expect(jsx.contains(where: { $0.capture == .attribute }))
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
        #expect(captures.contains(.function))
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

    @Test("JSON strings, numbers, and literal constants are captured")
    func jsonBasics() throws {
        let spans = TreeSitterHighlighter.highlight(source: #"{"ok": true, "n": 1, "name": "alas", "x": null}"#, fileExtension: "json")
        #expect(!spans.isEmpty)
        #expect(spans.contains(where: { $0.capture == .string }))
        #expect(spans.contains(where: { $0.capture == .number }))
        // `true`/`false`/`null` come through as `@constant.builtin` → .constant.
        // EditorTheme routes .constant to the keyword color so they render.
        #expect(spans.contains(where: { $0.capture == .constant }))
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

    @Test("C++ classes, templates, and strings are captured")
    func cppBasics() throws {
        let src = """
        #include <string>
        template<typename T>
        class Box { public: T value; };
        int main() { Box<std::string> b{"hi"}; return 0; }
        """
        let cpp = TreeSitterHighlighter.highlight(source: src, fileExtension: "cpp")
        let hpp = TreeSitterHighlighter.highlight(source: src, fileExtension: "hpp")
        #expect(cpp.contains(where: { $0.capture == .keyword }))
        #expect(cpp.contains(where: { $0.capture == .string }))
        #expect(cpp.contains(where: { $0.capture == .number }))
        #expect(!hpp.isEmpty)
    }

    @Test("C `int main(void)` is captured as keyword + function")
    func cBasics() throws {
        let src = """
        #include <stdio.h>
        int main(void) { printf("hi\\n"); return 0; }
        """
        let c = TreeSitterHighlighter.highlight(source: src, fileExtension: "c")
        let h = TreeSitterHighlighter.highlight(source: src, fileExtension: "h")
        #expect(c.contains(where: { $0.capture == .keyword }))
        #expect(c.contains(where: { $0.capture == .string }))
        #expect(c.contains(where: { $0.capture == .number }))
        #expect(!h.isEmpty)
    }

    @Test("Kotlin `fun main()` and `val` are captured")
    func kotlinBasics() throws {
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

    @Test("diff fallback colors added, removed, and hunk lines")
    func diffFallbackBasics() throws {
        let src = """
        @@ -1,2 +1,2 @@
        -old line
        +new line
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "diff")
        #expect(spans.contains(where: { $0.capture == .keyword }))
        #expect(spans.contains(where: { $0.capture == .string }))
        #expect(spans.contains(where: { $0.capture == .comment }))
    }

    @Test("diff fallback classifies headers and changed marker runs exactly")
    func diffFallbackExactMarkerClassification() throws {
        let src = """
        diff --git a/file.md b/file.md
        index 1111111..2222222 100644
        --- a/file.md
        +++ b/file.md
        @@ -1,2 +1,2 @@
        ---- heading
        ++++ heading
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "diff")

        #expect(capture(for: "--- a/file.md", in: src, spans: spans) == .keyword)
        #expect(capture(for: "+++ b/file.md", in: src, spans: spans) == .keyword)
        #expect(capture(for: "---- heading", in: src, spans: spans) == .comment)
        #expect(capture(for: "++++ heading", in: src, spans: spans) == .string)
    }

    @Test("markup, CSS, and SQL fallback emit useful spans")
    func chatFallbackBasics() throws {
        let html = TreeSitterHighlighter.highlight(source: #"<button class="primary">Save</button>"#, fileExtension: "html")
        let css = TreeSitterHighlighter.highlight(source: #".primary { display: flex; color: #fff; }"#, fileExtension: "css")
        let sql = TreeSitterHighlighter.highlight(source: #"SELECT id FROM users WHERE active = true;"#, fileExtension: "sql")

        #expect(html.contains(where: { $0.capture == .keyword }))
        #expect(html.contains(where: { $0.capture == .attribute }))
        #expect(html.contains(where: { $0.capture == .string }))
        #expect(css.contains(where: { $0.capture == .keyword }))
        #expect(sql.contains(where: { $0.capture == .keyword }))
    }

    @Test("markup fallback captures spaced and boolean attributes exactly")
    func markupFallbackExactAttributes() throws {
        let src = #"<button class = "primary" disabled>Save</button>"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "html")

        #expect(capture(for: "class", in: src, spans: spans) == .attribute)
        #expect(capture(for: "disabled", in: src, spans: spans) == .attribute)
        #expect(capture(for: #""primary""#, in: src, spans: spans) == .string)
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

    private func capture(for substring: String, in source: String, spans: [HighlightSpan]) -> HighlightCapture? {
        guard let range = source.range(of: substring) else { return nil }
        let nsRange = NSRange(range, in: source)
        return spans.first(where: { $0.range == nsRange })?.capture
    }
}
