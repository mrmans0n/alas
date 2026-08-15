import Foundation
import Testing
@testable import Alas

/// Guards the extension → grammar mapping. The pack's own Rust suite proves
/// every grammar resolves and every query compiles; what it cannot see is
/// whether Alas ever *reaches* a grammar, which is what this file covers.
@Suite("LanguageRegistry")
struct LanguageRegistryTests {
    /// Deliberately spelled out rather than derived from
    /// `languageIDsByExtension`: a test that reads the same table it checks
    /// would keep passing if an entry were dropped.
    private static let expectedExtensions: [String: String] = [
        // Pre-existing, so a regression in the new filename handling shows up.
        "swift": "swift", "py": "python", "rs": "rust", "go": "go",
        "ts": "typescript", "tsx": "tsx", "js": "javascript",
        "java": "java", "kt": "kotlin", "rb": "ruby", "php": "php",
        "c": "c", "cpp": "cpp", "html": "html", "css": "css",
        "json": "json", "yaml": "yaml", "toml": "toml", "md": "markdown",
        "tf": "hcl", "lua": "lua", "sh": "bash",
        // Added alongside the new grammars.
        "cs": "csharp", "csx": "csharp",
        "scala": "scala", "sc": "scala", "sbt": "scala",
        "r": "r",
        "dart": "dart",
        "ex": "elixir", "exs": "elixir",
        "erl": "erlang", "hrl": "erlang",
        "hs": "haskell", "lhs": "haskell",
        "clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure",
        "jl": "julia",
        "zig": "zig",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "groovy": "groovy", "gradle": "groovy", "gvy": "groovy",
        "m": "objc", "mm": "objc",
        "sql": "sql",
        "graphql": "graphql", "gql": "graphql",
        "proto": "proto",
        "scss": "scss",
        "svelte": "svelte",
        "xml": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "svg": "xml",
        "plist": "xml", "storyboard": "xml", "xib": "xml",
        "csproj": "xml", "resx": "xml",
        "ini": "ini", "cfg": "ini", "properties": "ini",
        "mk": "make",
        "cmake": "cmake",
        "mts": "typescript", "cts": "typescript"
    ]

    @Test("Every mapped extension resolves to a grammar and a compiling query")
    func everyMappedExtensionResolves() throws {
        for ext in Self.expectedExtensions.keys.sorted() {
            #expect(
                LanguageRegistry.language(forFileExtension: ext) != nil,
                "\(ext) resolved to no grammar"
            )
            // A nil query here means the text would silently render as plain
            // text even though the grammar loaded.
            #expect(
                LanguageRegistry.highlightQuery(forExtension: ext) != nil,
                "\(ext) resolved to no highlight query"
            )
        }
    }

    @Test("Extensions are matched case-insensitively")
    func extensionsAreCaseInsensitive() throws {
        // `.R` is the conventional spelling for R sources, so this is the
        // common path rather than an edge case.
        #expect(LanguageRegistry.language(forFileExtension: "R") != nil)
        #expect(LanguageRegistry.highlightQuery(forExtension: "SQL") != nil)
    }

    @Test("Extensionless and misleading filenames resolve by filename")
    func filenamesResolve() throws {
        let cases: [String: String] = [
            "/repo/Dockerfile": "dockerfile",
            "/repo/Containerfile": "dockerfile",
            "/repo/Makefile": "mk",
            "/repo/GNUmakefile": "mk",
            // `.txt` would otherwise win and resolve to nothing.
            "/repo/CMakeLists.txt": "cmake",
            "/repo/.editorconfig": "ini",
            "/repo/Jenkinsfile": "groovy"
        ]
        for (path, expected) in cases {
            let resolved = LanguageRegistry.highlighterExtension(forPath: path)
            #expect(resolved == expected, "\(path) resolved to \(resolved)")
            #expect(
                LanguageRegistry.language(forFileExtension: resolved) != nil,
                "\(path) resolved to no grammar"
            )
        }
    }

    @Test("build.sbt resolves to the Scala grammar")
    func sbtFilesResolveToScala() throws {
        // `.sbt` is a real (if unusual) extension, not a filename special
        // case, but sbt projects' conventional `build.sbt` is exactly the
        // path this needs to resolve for in practice.
        let resolved = LanguageRegistry.highlighterExtension(forPath: "/repo/build.sbt")
        #expect(resolved == "sbt")
        #expect(LanguageRegistry.language(forFileExtension: resolved) != nil)
    }

    @Test(".csx C# scripts resolve to the C# grammar")
    func csxFilesResolveToCSharp() throws {
        let resolved = LanguageRegistry.highlighterExtension(forPath: "/repo/build.csx")
        #expect(resolved == "csx")
        #expect(LanguageRegistry.language(forFileExtension: resolved) != nil)
    }

    @Test(".lhs literate Haskell resolves to the Haskell grammar")
    func lhsFilesResolveToHaskell() throws {
        let resolved = LanguageRegistry.highlighterExtension(forPath: "/repo/Main.lhs")
        #expect(resolved == "lhs")
        #expect(LanguageRegistry.language(forFileExtension: resolved) != nil)
    }

    @Test("A plain .txt file still resolves to nothing")
    func unknownExtensionsStayUnmapped() throws {
        // The filename table must not accidentally swallow every `.txt`.
        #expect(LanguageRegistry.highlighterExtension(forPath: "/repo/notes.txt") == "txt")
        #expect(LanguageRegistry.language(forFileExtension: "txt") == nil)
    }

    @Test("SCSS merges the CSS query, not just its own")
    func scssInheritsCSSPatterns() throws {
        let src = """
        $primary: #333;
        .card { color: $primary; font-weight: bold; }
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "scss")
        let captures = Set(spans.map { $0.capture })
        // `property` comes from `(property_name) @property`, which exists only
        // in the CSS query — the SCSS query names no `property_name` at all.
        // Without the merge a stylesheet would highlight almost nothing.
        #expect(captures.contains(.property), "SCSS did not inherit CSS patterns: \(captures)")
    }

    @Test("Objective-C merges the C query, not just its own")
    func objcInheritsCPatterns() throws {
        let src = """
        // greeter
        #import <Foundation/Foundation.h>
        @interface Greeter : NSObject
        - (NSString *)greet:(NSString *)name;
        @end
        """
        let spans = TreeSitterHighlighter.highlight(source: src, fileExtension: "m")
        let captures = Set(spans.map { $0.capture })
        // The Objective-C query declares `; inherits: c` and names no comment
        // pattern itself, so a captured comment can only have come from C's.
        #expect(captures.contains(.comment), "Obj-C did not inherit C patterns: \(captures)")
    }

    @Test("Newly added grammars highlight real source")
    func newGrammarsHighlightRealSource() throws {
        // One representative source per new grammar. Asserting on `.keyword`
        // (or the nearest structural capture) proves the query actually fired,
        // which compiling it cannot: the regex fallback never emits these for
        // extensions it does not know.
        let cases: [(ext: String, source: String, expected: HighlightCapture)] = [
            ("cs", "public class Greeter { public string Greet() => \"hi\"; }", .keyword),
            ("scala", "object Main { def greet(name: String): String = name }", .keyword),
            ("r", "greet <- function(name) { paste(\"hi\", name) }", .function),
            ("dart", "class Greeter { String greet(String name) => name; }", .keyword),
            ("ex", "defmodule Greeter do\n  def greet(name), do: name\nend", .function),
            ("erl", "-module(greeter).\ngreet(Name) -> Name.", .function),
            ("hs", "greet :: String -> String\ngreet name = name", .function),
            // tree-sitter-clojure-orchard's query is deliberately minimal —
            // literals, comments, and quasiquote operators only, no
            // function/keyword captures — so `"hi "` (a `str_lit`) is the
            // capture this grammar can actually produce.
            ("clj", "(defn greet [name] (str \"hi \" name))", .string),
            ("jl", "function greet(name)\n    return name\nend", .keyword),
            ("zig", "pub fn greet(name: []const u8) []const u8 { return name; }", .keyword),
            ("ps1", "function Get-Greeting { param($Name) return $Name }", .keyword),
            ("gradle", "apply plugin: 'java'\ndependencies { implementation 'a:b:1.0' }", .string),
            ("sql", "SELECT name FROM users WHERE id = 1;", .keyword),
            ("graphql", "query GetUser { user(id: 1) { name } }", .keyword),
            ("proto", "syntax = \"proto3\";\nmessage User { string name = 1; }", .keyword),
            ("svelte", "<script>let name = 'x';</script>\n<h1>{name}</h1>", .keyword),
            // XML tag names capture as `@tag`, which folds into `.keyword`.
            ("xml", "<?xml version=\"1.0\"?>\n<root><child id=\"a\">t</child></root>", .keyword),
            ("ini", "[server]\nhost = localhost\nport = 8080", .property),
            // `all` matches the query's well-known-target regex
            // (`@constant.macro`); Make's query has no `@function` capture
            // for recipe commands at all.
            ("mk", "all: build\n\tgcc -o out main.c", .constant),
            ("cmake", "project(Alas)\nadd_executable(alas main.c)", .function)
        ]

        for testCase in cases {
            let spans = TreeSitterHighlighter.highlight(
                source: testCase.source,
                fileExtension: testCase.ext
            )
            let captures = Set(spans.map { $0.capture })
            #expect(
                captures.contains(testCase.expected),
                "\(testCase.ext): expected \(testCase.expected), got \(captures.sorted { $0.rawValue < $1.rawValue })"
            )
        }
    }
}
