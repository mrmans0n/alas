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
        let zsh = TreeSitterHighlighter.highlight(source: src, fileExtension: "zsh")
        #expect(!sh.isEmpty)
        #expect(!bash.isEmpty)
        #expect(!zsh.isEmpty)
        #expect(sh.contains(where: { $0.capture == .keyword }))
        #expect(sh.contains(where: { $0.capture == .comment }))
        #expect(zsh.contains(where: { $0.capture == .keyword }))
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

    @Test("Ruby class and method are captured")
    func rubyBasics() throws {
        let src = """
        class Greeter
          def greet(name)
            "hello, #{name}"
          end
        end
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "rb")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.function))
        #expect(captures.contains(.string))
    }

    @Test("Lua function and local are captured")
    func luaBasics() throws {
        let src = """
        local function greet(name)
          return "hello, " .. name
        end
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "lua")
        let captures = Set(spans.map { $0.capture })
        #expect(captures.contains(.keyword))
        #expect(captures.contains(.function))
        #expect(captures.contains(.string))
    }

    @Test("Lua control flow, booleans, and method syntax are captured")
    func luaControlFlowAndMethods() throws {
        let src = """
        function greeter:greet()
          if true then
            return self:name()
          end
        end
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "lua")

        #expect(capture(for: "if", in: src, spans: spans) == .keyword)
        #expect(capture(for: "true", in: src, spans: spans) == .constant)
        #expect(capture(for: "name", in: src, spans: spans) == .function)
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

    @Test("diff fallback classifies post-hunk file marker lines as changed content")
    func diffFallbackPostHunkMarkerLines() throws {
        let src = """
        --- a/file.md
        +++ b/file.md
        @@ -1,2 +1,2 @@
        --- heading
        +++ heading
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "diff")

        #expect(capture(for: "--- a/file.md", in: src, spans: spans) == .keyword)
        #expect(capture(for: "+++ b/file.md", in: src, spans: spans) == .keyword)
        #expect(capture(for: "--- heading", in: src, spans: spans) == .comment)
        #expect(capture(for: "+++ heading", in: src, spans: spans) == .string)
    }

    @Test("diff fallback resets header state for each file block")
    func diffFallbackResetsHeaderStateForEachFileBlock() throws {
        let src = """
        diff --git a/first.md b/first.md
        index 1111111..2222222 100644
        --- a/first.md
        +++ b/first.md
        @@ -1 +1 @@
        +first line
        diff --git a/second.md b/second.md
        index 3333333..4444444 100644
        --- a/second.md
        +++ b/second.md
        @@ -1 +1 @@
        +++ heading
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "diff")

        #expect(capture(for: "--- a/second.md", in: src, spans: spans) == .keyword)
        #expect(capture(for: "+++ b/second.md", in: src, spans: spans) == .keyword)
        #expect(capture(for: "+++ heading", in: src, spans: spans) == .string)
    }

    @Test("diff fallback recognizes adjacent non-Git file headers after hunks")
    func diffFallbackRecognizesAdjacentNonGitFileHeadersAfterHunks() throws {
        let src = """
        --- first.txt
        +++ first.txt
        @@ -1 +1 @@
        -old
        +new
        --- second.txt
        +++ second.txt
        @@ -1 +1 @@
        +++ heading
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "patch")

        #expect(capture(for: "--- second.txt", in: src, spans: spans) == .keyword)
        #expect(capture(for: "+++ second.txt", in: src, spans: spans) == .keyword)
        #expect(capture(for: "+++ heading", in: src, spans: spans) == .string)
    }

    @Test("diff fallback colors common metadata lines")
    func diffFallbackCommonMetadataLines() throws {
        let src = """
        diff -u a b
        new file mode 100644
        old mode 100644
        new mode 100755
        rename from old.txt
        rename to new.txt
        \\ No newline at end of file
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "patch")

        #expect(capture(for: "diff -u a b", in: src, spans: spans) == .keyword)
        #expect(capture(for: "new file mode 100644", in: src, spans: spans) == .keyword)
        #expect(capture(for: "old mode 100644", in: src, spans: spans) == .keyword)
        #expect(capture(for: "new mode 100755", in: src, spans: spans) == .keyword)
        #expect(capture(for: "rename from old.txt", in: src, spans: spans) == .keyword)
        #expect(capture(for: "rename to new.txt", in: src, spans: spans) == .keyword)
        #expect(capture(for: #"\ No newline at end of file"#, in: src, spans: spans) == .keyword)
    }

    @Test("markup, CSS, and SQL fallback emit useful spans")
    func chatFallbackBasics() throws {
        let html = TreeSitterHighlighter.highlight(source: #"<button class="primary">Save</button>"#, fileExtension: "xml")
        let css = TreeSitterHighlighter.highlight(source: #".primary { display: flex; color: #fff; }"#, fileExtension: "scss")
        let sql = TreeSitterHighlighter.highlight(source: #"SELECT id FROM users WHERE active = true;"#, fileExtension: "sql")

        #expect(html.contains(where: { $0.capture == .keyword }))
        #expect(html.contains(where: { $0.capture == .attribute }))
        #expect(html.contains(where: { $0.capture == .string }))
        #expect(css.contains(where: { $0.capture == .keyword }))
        #expect(sql.contains(where: { $0.capture == .keyword }))
    }

    @Test("HTML uses tree-sitter grammar and query")
    func htmlTreeSitterBasics() throws {
        #expect(LanguageRegistry.language(forFileExtension: "html") != nil)
        #expect(LanguageRegistry.language(forFileExtension: "htm") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "html") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "htm") != nil)

        let spans = TreeSitterHighlighter.highlight(
            source: #"<button disabled class="primary">Save</button>"#,
            fileExtension: "html"
        )
        #expect(spans.contains(where: { $0.capture == .keyword }))
        #expect(spans.contains(where: { $0.capture == .attribute }))
        #expect(spans.contains(where: { $0.capture == .string }))
    }

    @Test("PHP tagless snippets use the PHP-only grammar")
    func phpTaglessSnippets() throws {
        let src = #"function hello($name) { return "hi"; }"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "php")

        #expect(capture(for: "function", in: src, spans: spans) == .keyword)
        #expect(capture(for: "hello", in: src, spans: spans) == .function)
        #expect(capture(for: #""hi""#, in: src, spans: spans) == .string)
    }

    @Test("PHP tagless snippets ignore tag-like text inside strings")
    func phpTaglessSnippetsIgnoreTagLikeStrings() throws {
        let src = #"echo "<?xml version=\"1.0\"";"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "php")

        #expect(capture(for: "echo", in: src, spans: spans) == .keyword)
        #expect(spans.contains(where: { $0.capture == .string }))
    }

    @Test("PHP-only query removes compact tag captures")
    func phpOnlyQueryRemovesCompactTagCaptures() throws {
        let compact = #"[ (php_tag) (php_end_tag) ] @tag\n(function_definition name: (name) @function)"#
        let filtered = LanguageRegistry.phpOnlyQueryText(from: compact)

        #expect(!filtered.contains("php_tag"))
        #expect(!filtered.contains("php_end_tag"))
        #expect(filtered.contains("function_definition"))
    }

    @Test("CSS uses tree-sitter grammar and query")
    func cssTreeSitterBasics() throws {
        #expect(LanguageRegistry.language(forFileExtension: "css") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "css") != nil)

        let spans = TreeSitterHighlighter.highlight(
            source: #".primary { display: flex; color: #fff; }"#,
            fileExtension: "css"
        )
        #expect(spans.contains(where: { $0.capture == .property }))
        #expect(spans.contains(where: { $0.capture == .string }))
    }

    @Test("PHP uses tree-sitter grammar and query")
    func phpTreeSitterBasics() throws {
        #expect(LanguageRegistry.language(forFileExtension: "php") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "php") != nil)

        let spans = TreeSitterHighlighter.highlight(
            source: #"<?php function hello($name) { return "hi"; }"#,
            fileExtension: "php"
        )
        #expect(spans.contains(where: { $0.capture == .keyword }))
        #expect(spans.contains(where: { $0.capture == .function }))
        #expect(spans.contains(where: { $0.capture == .string }))
    }

    @Test("Markdown uses tree-sitter grammar and query")
    func markdownTreeSitterBasics() throws {
        #expect(LanguageRegistry.language(forFileExtension: "md") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "md") != nil)

        let spans = TreeSitterHighlighter.highlight(
            source: "# Title\n\n```swift\nlet value = 1\n```",
            fileExtension: "md"
        )
        #expect(spans.contains(where: { $0.capture == .punctuation }))
        #expect(spans.contains(where: { $0.capture == .string }))
    }

    @Test("Markdown inline syntax is captured")
    func markdownInlineSyntax() throws {
        let src = #"A **bold** word and `code` with [link](https://example.com)"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "md")

        #expect(capture(for: "`", in: src, spans: spans) == .punctuation)
        #expect(capture(for: "`code`", in: src, spans: spans) == .string)
        #expect(capture(for: "https://example.com", in: src, spans: spans) == .string)
    }

    @Test("HCL uses tree-sitter grammar and query")
    func hclTreeSitterBasics() throws {
        #expect(LanguageRegistry.language(forFileExtension: "tf") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "tf") != nil)

        let spans = TreeSitterHighlighter.highlight(
            source: #"resource "aws_s3_bucket" "logs" { bucket = "alas-logs" }"#,
            fileExtension: "tf"
        )
        #expect(spans.contains(where: { $0.capture == .type }))
        #expect(spans.contains(where: { $0.capture == .property }))
        #expect(spans.contains(where: { $0.capture == .string }))
    }

    @Test("Dockerfile uses tree-sitter grammar and query")
    func dockerfileTreeSitterBasics() throws {
        #expect(LanguageRegistry.language(forFileExtension: "dockerfile") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "dockerfile") != nil)
        #expect(LanguageRegistry.highlighterExtension(forPath: "Dockerfile") == "dockerfile")
        #expect(LanguageRegistry.highlighterExtension(forPath: "dockerfile") == "dockerfile")

        let spans = TreeSitterHighlighter.highlight(
            source: """
            FROM swift:latest
            ENV APP_HOME="/app"
            """,
            fileExtension: "dockerfile"
        )
        #expect(spans.contains(where: { $0.capture == .keyword }))
        #expect(spans.contains(where: { $0.capture == .operator }))
        #expect(spans.contains(where: { $0.capture == .string }))
    }

    @Test("CSS fallback does not treat hashes as line comments")
    func cssFallbackDoesNotTreatHashesAsLineComments() throws {
        let src = #".primary { color: #fff; background: red; } #app { display: grid; }"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "scss")
        let swallowedRange = NSRange(src.range(of: "#fff; background")!, in: src)

        #expect(capture(for: "background", in: src, spans: spans) == .keyword)
        #expect(capture(for: "display", in: src, spans: spans) == .keyword)
        #expect(!spans.contains(where: { $0.capture == .comment && NSIntersectionRange($0.range, swallowedRange).length == swallowedRange.length }))
    }

    @Test("markup fallback captures spaced and boolean attributes exactly")
    func markupFallbackExactAttributes() throws {
        let src = #"<button class = "primary" disabled>Save</button>"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "xml")

        #expect(capture(for: "class", in: src, spans: spans) == .attribute)
        #expect(capture(for: "disabled", in: src, spans: spans) == .attribute)
        #expect(capture(for: #""primary""#, in: src, spans: spans) == .string)
    }

    @Test("markup fallback does not classify assigned text outside tags as attributes")
    func markupFallbackDoesNotClassifyAssignedTextOutsideTagsAsAttributes() throws {
        let src = #"x = 1 <button class="primary">Save</button>"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "xml")

        #expect(capture(for: "x", in: src, spans: spans) != .attribute)
        #expect(capture(for: "class", in: src, spans: spans) == .attribute)
        #expect(capture(for: #""primary""#, in: src, spans: spans) == .string)
    }

    @Test("markup fallback does not recover boolean attributes inside comments or strings")
    func markupFallbackSkipsBooleanAttributesInsideCommentsAndStrings() throws {
        let src = #"<!-- <button disabled> --> <input disabled value="<tag disabled>">"#
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "xml")

        #expect(capture(for: "disabled", occurrence: 0, in: src, spans: spans) != .attribute)
        #expect(capture(for: "disabled", occurrence: 1, in: src, spans: spans) == .attribute)
        #expect(capture(for: "disabled", occurrence: 2, in: src, spans: spans) != .attribute)
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

    /// Every extension the registry claims to support must resolve to both a
    /// grammar and a compiled query. A typo in the extension-to-grammar-id
    /// mapping, or a grammar that drops out of the linked pack, otherwise
    /// surfaces only as that language silently rendering as plain text.
    @Test("every supported extension resolves to a grammar and a query")
    func everySupportedExtensionResolves() throws {
        let extensions = [
            "swift", "yaml", "yml", "json", "toml", "py", "rb", "lua", "rs", "go",
            "sh", "bash", "zsh", "js", "mjs", "cjs", "jsx", "ts", "tsx", "java",
            "kt", "kts", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx",
            "html", "htm", "css", "php", "php-only", "md", "markdown",
            "markdown-inline", "hcl", "tf", "tfvars", "dockerfile"
        ]

        for ext in extensions {
            #expect(LanguageRegistry.language(forFileExtension: ext) != nil, "no grammar for .\(ext)")
            #expect(LanguageRegistry.highlightQuery(forExtension: ext) != nil, "no query for .\(ext)")
        }
    }

    @Test("unknown extensions resolve to no grammar")
    func unknownExtensionsResolveToNothing() throws {
        #expect(LanguageRegistry.language(forFileExtension: "nosuchlang") == nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "nosuchlang") == nil)
        #expect(LanguageRegistry.language(forFileExtension: "") == nil)
    }

    private func capture(for substring: String, in source: String, spans: [HighlightSpan]) -> HighlightCapture? {
        guard let range = source.range(of: substring) else { return nil }
        let nsRange = NSRange(range, in: source)
        return spans.first(where: { $0.range == nsRange })?.capture
    }

    private func capture(
        for substring: String,
        occurrence: Int,
        in source: String,
        spans: [HighlightSpan]
    ) -> HighlightCapture? {
        guard let range = range(of: substring, occurrence: occurrence, in: source) else { return nil }
        let nsRange = NSRange(range, in: source)
        return spans.first(where: { $0.range == nsRange })?.capture
    }

    private func range(of substring: String, occurrence: Int, in source: String) -> Range<String.Index>? {
        var searchRange = source.startIndex..<source.endIndex
        for index in 0...occurrence {
            guard let range = source.range(of: substring, range: searchRange) else { return nil }
            if index == occurrence { return range }
            searchRange = range.upperBound..<source.endIndex
        }
        return nil
    }
}
