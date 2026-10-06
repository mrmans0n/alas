# Symbol mentions, phase 1: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users find project symbols through the composer's `@` picker, insert them as style A badges, and send the agent a reference (optionally with the declaration's code), with a snapshot stored on the sent message.

**Architecture:** Tree-sitter tag queries in `ThirdParty/treesitter-pack` feed a Swift `SymbolExtractor`. A `WorktreeSymbolIndex` actor indexes local worktrees lazily from `FileIndex`'s file list. Symbol mentions travel the existing mention pipeline as `alas-symbol://` links. At send time `ACPSymbolReference` re-finds each symbol, stores an `ACPSymbolSnapshot` on the recorded attachment, and replaces the link on the wire with reference text and optional code.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, SwiftTreeSitter 0.25.0, Rust (`tree-sitter` crates), Swift Testing.

**Spec:** `docs/plans/2026-10-06-composer-symbol-mentions-design.md` (phase 1 of 3). Phases 2 (composer preview) and 3 (transcript preview) get their own plans after this lands.

## Global Constraints

- Tag query ids: `<language>.tags`, served by `alas_ts_query`. Languages: Swift, TypeScript, TSX, JavaScript, Python, Go, Rust, Java, Kotlin.
- Kotlin tags query is written by Alas in `ThirdParty/treesitter-pack/queries/kotlin/tags.scm`.
- Index is in memory, built lazily on first symbol query, never at app launch. Files over 1 MB or failing to parse are skipped.
- Remote worktrees: no project-wide index. `File.swift#query` drill-down works everywhere.
- Ranking: `FuzzyMatch`-based; ties: types before members, non-test before test, shorter path first, stable order.
- Test path: a component is `Tests`, `test`, `tests`, `__tests__`, or `spec`, or the file name (without extension) ends in `Test`, `Tests`, `Spec`, `_test`, or `.test`.
- Link scheme `alas-symbol://`. Agents never see it.
- Excerpt cap: 400 lines or 32 KB, whichever comes first, with a closing marker stating how much was cut.
- `resource` block when the agent advertises `embeddedContext`; otherwise a fenced code block in the text.
- Wire reference text (1-based lines): `Referenced symbol: SessionManager.restore(), method in Sources/SessionManager.swift, lines 121–159.`
- Not found at send: last known location, marked `not found when sent`.
- `ACPMessage.Attachment.symbol` is optional and excluded from `==`/`hash(into:)`.
- Picker scopes: All, Files, Symbols, Sessions; ⌘1–⌘4 select a scope; ⇥ keeps its current meaning; ⏎ inserts; ⌥⏎ inserts with "Include code" on.
- Badge style A: kind icon, container dimmed, name in code font; filled variant with `{ } N lines` when code is included.
- Phase 1 transcript: sent symbols render as `FileChip` labeled with the qualified name; clicking opens the editor at the symbol.
- Tests use Swift Testing (`import Testing`), follow `AGENTS.md` testing policy, and run focused with `-only-testing`.
- After adding Swift files, run `xcodegen` and commit `Alas.xcodeproj/project.pbxproj` with the sources.
- Conventional Commits; no agent attribution anywhere.

## Review Focus

1. A pasted or hand-edited `alas-symbol://` link whose `path` contains `..` or is absolute must be rejected, and a tracked symlink that resolves outside the worktree must never be read, by the index or by include-code expansion. Pinned in Tasks 3 and 5.
2. Source containing non-ASCII characters (emoji, accented identifiers) before a declaration must still give correct line ranges and names. Pinned in Task 2.
3. A declaration whose body contains a Markdown fence (```` ``` ````) must not break the fenced code block sent to the agent. Pinned in Task 6.
4. Overloads with the same name and container (Swift `init`, Java overloads) must resolve to the one nearest the stored line, not the first. Pinned in Task 6.
5. A single declaration line longer than 32 KB (minified code) must still be cut to the byte cap. Pinned in Task 6.

## Deviations from the spec, called out

- **Missing-symbol warning on the composer badge** moves to phase 2. Detecting it needs live re-resolution while the draft sits in the composer, which belongs with the preview's loading. Phase 1 still sends `not found when sent` correctly.
- **Index refresh triggers:** besides `WorktreeWatcher` change events (only the surfaced worktree runs a watcher), the index also refreshes each time the picker opens. Refresh is stat-based, so this costs a stat per indexed file.

## File structure

| File | Responsibility |
|---|---|
| `ThirdParty/treesitter-pack/src/lib.rs` | Register nine `.tags` query ids; tests. |
| `ThirdParty/treesitter-pack/queries/kotlin/tags.scm` | Alas-written Kotlin tags query. |
| `ThirdParty/treesitter-pack/include/treesitter_pack.h` | Comment wording only ("query", not "highlight query"). |
| `Alas/Sources/Code/Highlight/LanguageRegistry.swift` | `tagsQuery(forPath:)`, `supportsSymbols(forPath:)`. |
| `Alas/Sources/Code/Symbols/SymbolEntry.swift` (new) | `SymbolKind`, `SymbolEntry`. |
| `Alas/Sources/Code/Symbols/SymbolExtractor.swift` (new) | Parse one file into `[SymbolEntry]`. |
| `Alas/Sources/Code/Symbols/SymbolSource.swift` (new) | Read a worktree file, local or remote, capped at 1 MB. |
| `Alas/Sources/Code/Symbols/WorktreeSymbolIndex.swift` (new) | Per-worktree in-memory index with incremental refresh. |
| `Alas/Sources/App/AppState.swift` | Own `symbolIndex`; refresh on worktree change. |
| `Alas/Sources/ACP/UI/ACPMentionSymbols.swift` (new) | Pure picker logic: scopes, query parsing, ranking, highlight preservation. |
| `Alas/Sources/ACP/UI/ACPMentionPicker.swift` | Symbol rows, scope chips, headers, footer, ⌥⏎. |
| `Alas/Sources/ACP/UI/ACPComposer.swift` | Panel size, symbol provider plumbing, `insertSymbolMention`. |
| `Alas/Sources/ACP/UI/ACPComposerShell.swift`, `ACPTabView.swift` | Pass `ACPSymbolMentionSource` down. |
| `Alas/Sources/ACP/UI/ACPSymbolChipCell.swift` (new) | Style A badge cell. |
| `Alas/Sources/ACP/UI/ACPMentionChipAttachment.swift` | Choose the symbol cell for symbol URIs; symbol hover text. |
| `Alas/Sources/ACP/Session/ACPSymbolReference.swift` (new) | URI format, snapshot type, resolution, wire replacement. |
| `Alas/Sources/ACP/Session/ACPMessage.swift` | `Attachment.symbol`. |
| `Alas/Sources/ACP/Session/ACPSessionRunner.swift` | Resolve before recording in both send paths; expand on the wire. |
| `Alas/Sources/ACP/UI/ACPFileChip.swift` | Optional click action. |
| `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift`, `ACPSubagentRowView.swift` | Symbol chips with click-to-open. |
| `AlasTests/Code/Symbols/SymbolExtractorTests.swift` (new) | Per-language extraction. |
| `AlasTests/Code/Symbols/WorktreeSymbolIndexTests.swift` (new) | Incremental refresh. |
| `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift` (new) | URI, resolution, wire format, caps. |
| Existing suites extended | `LanguageRegistryTests`, `ACPMentionPickerTests`, `ACPImageBlocksTests`, `ACPMessageTests`. |

Test command template (used throughout):

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/<Suite> test
```

Check the `Test run with N tests in M suites` line every time: a misspelled suite runs nothing and still reports success.

---

### Task 1: Tag queries in the grammar pack

**Files:**
- Create: `ThirdParty/treesitter-pack/queries/kotlin/tags.scm`
- Modify: `ThirdParty/treesitter-pack/src/lib.rs` (constants near line 80, `QUERIES` at 170–222, tests module)
- Modify: `ThirdParty/treesitter-pack/include/treesitter_pack.h` (comment above `alas_ts_query`)

**Interfaces:**
- Produces: query ids `swift.tags`, `typescript.tags`, `tsx.tags`, `javascript.tags`, `python.tags`, `go.tags`, `rust.tags`, `java.tags`, `kotlin.tags`. Captures: `@name` and `@definition.<kind>`; some upstream queries also emit `@reference.*`, which consumers ignore.

- [ ] **Step 1: Write the failing tests** (append inside `mod tests` in `src/lib.rs`)

```rust
    /// Tags ids and the grammar each compiles against. TypeScript and TSX
    /// inherit JavaScript's tags the way their highlight queries do, so the
    /// Swift side merges `javascript.tags` in front of theirs.
    const TAG_QUERIES: &[(&str, &str, &[&str])] = &[
        ("swift.tags", "swift", &["swift.tags"]),
        ("javascript.tags", "javascript", &["javascript.tags"]),
        ("typescript.tags", "typescript", &["javascript.tags", "typescript.tags"]),
        ("tsx.tags", "tsx", &["javascript.tags", "tsx.tags"]),
        ("python.tags", "python", &["python.tags"]),
        ("go.tags", "go", &["go.tags"]),
        ("rust.tags", "rust", &["rust.tags"]),
        ("java.tags", "java", &["java.tags"]),
        ("kotlin.tags", "kotlin", &["kotlin.tags"]),
    ];

    #[test]
    fn every_tags_query_compiles_against_its_grammar() {
        for (id, language_id, parts) in TAG_QUERIES {
            assert!(query(id).is_some(), "{id} is not registered");
            let combined = parts
                .iter()
                .map(|part| query(part).unwrap_or_else(|| panic!("{part} has no query")))
                .collect::<Vec<_>>()
                .join("\n");
            let (_, entry) = LANGUAGES
                .iter()
                .find(|(name, _)| name == language_id)
                .unwrap_or_else(|| panic!("{language_id} is not a registered language"));
            let compiled = tree_sitter::Query::new(&language_handle(*entry), &combined)
                .unwrap_or_else(|error| panic!("{id} does not compile: {error:?}"));
            assert!(
                compiled.capture_names().iter().any(|name| *name == "name"),
                "{id} never captures @name"
            );
            assert!(
                compiled.capture_names().iter().any(|name| name.starts_with("definition.")),
                "{id} captures no @definition.*"
            );
        }
    }

    #[test]
    fn kotlin_tags_capture_top_level_and_member_declarations_only() {
        use tree_sitter::StreamingIterator;
        let source = r#"
            interface Greeter { fun greet(): String }
            class Hello(private val name: String) : Greeter {
                val prefix = "Hello, "
                override fun greet(): String {
                    val local = prefix + name
                    return local
                }
            }
            object Registry { fun all(): List<Greeter> = emptyList() }
            val topLevel = 1
        "#;
        let language: tree_sitter::Language = tree_sitter_kotlin_ng::LANGUAGE.into();
        let mut parser = tree_sitter::Parser::new();
        parser.set_language(&language).unwrap();
        let tree = parser.parse(source, None).unwrap();
        let query = tree_sitter::Query::new(&language, KOTLIN_TAGS).unwrap();
        let names = query.capture_names();
        let mut cursor = tree_sitter::QueryCursor::new();
        let mut found: Vec<(String, String)> = Vec::new();
        let mut matches = cursor.matches(&query, tree.root_node(), source.as_bytes());
        while let Some(m) = matches.next() {
            let name = m.captures.iter().find(|c| names[c.index as usize] == "name");
            let kind = m.captures.iter().find(|c| names[c.index as usize].starts_with("definition."));
            if let (Some(name), Some(kind)) = (name, kind) {
                found.push((
                    name.node.utf8_text(source.as_bytes()).unwrap().to_string(),
                    names[kind.index as usize].to_string(),
                ));
            }
        }
        found.sort();
        let mut expected: Vec<(String, String)> = [
            ("Greeter", "definition.interface"),
            ("greet", "definition.function"),
            ("Hello", "definition.class"),
            ("prefix", "definition.property"),
            ("greet", "definition.function"),
            ("Registry", "definition.class"),
            ("all", "definition.function"),
            ("topLevel", "definition.property"),
        ]
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect();
        expected.sort();
        assert_eq!(found, expected, "`local` and constructor params must not be tagged");
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ThirdParty/treesitter-pack && cargo test tags`
Expected: compile error `cannot find value KOTLIN_TAGS`.

- [ ] **Step 3: Write the Kotlin tags query**

`ThirdParty/treesitter-pack/queries/kotlin/tags.scm`:

```scheme
; Alas-maintained: tree-sitter-kotlin-ng ships no tags query.
; Only top-level and class-body properties are tagged, never locals.

(class_declaration
  "interface"
  name: (identifier) @name) @definition.interface

(class_declaration
  "class"
  name: (identifier) @name) @definition.class

(object_declaration
  name: (identifier) @name) @definition.class

(function_declaration
  name: (identifier) @name) @definition.function

(source_file
  (property_declaration
    (variable_declaration
      (identifier) @name)) @definition.property)

(class_body
  (property_declaration
    (variable_declaration
      (identifier) @name)) @definition.property)
```

If `"class"` as an anonymous child does not compile, check `node-types.json` in the pinned kotlin-ng checkout and use the exact anonymous token spelling it lists. Local functions nested in function bodies are tagged; that is acceptable.

- [ ] **Step 4: Register the queries** in `src/lib.rs`

After `const GROOVY_HIGHLIGHTS ...` add:

```rust
/// tree-sitter-kotlin-ng ships no tags query; this one is maintained by Alas.
const KOTLIN_TAGS: &str = include_str!("../queries/kotlin/tags.scm");
```

Change the doc comment above `QUERIES` to:

```rust
/// Highlight queries keyed by language id, plus symbol tags queries keyed by
/// `<language>.tags`. `javascript_jsx` is the JSX overlay upstream ships beside
/// the base JavaScript query; Alas merges it in for `.jsx`/`.tsx`. TypeScript
/// and TSX share one upstream highlight file and one upstream tags file.
```

Append to the end of the `QUERIES` array (before `];`):

```rust
    ("swift.tags", tree_sitter_swift::TAGS_QUERY),
    ("javascript.tags", tree_sitter_javascript::TAGS_QUERY),
    ("typescript.tags", tree_sitter_typescript::TAGS_QUERY),
    ("tsx.tags", tree_sitter_typescript::TAGS_QUERY),
    ("python.tags", tree_sitter_python::TAGS_QUERY),
    ("go.tags", tree_sitter_go::TAGS_QUERY),
    ("rust.tags", tree_sitter_rust::TAGS_QUERY),
    ("java.tags", tree_sitter_java::TAGS_QUERY),
    ("kotlin.tags", KOTLIN_TAGS),
```

In `alas_ts_query`'s doc comment and in `include/treesitter_pack.h`, replace "Returns the highlight query for `id`" with "Returns the query for `id` (a highlight query, or a `<language>.tags` symbol query)".

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ThirdParty/treesitter-pack && cargo test`
Expected: all tests PASS, including `every_query_is_non_empty` (which now also covers the tags ids).

- [ ] **Step 6: Commit**

```bash
git add ThirdParty/treesitter-pack
git commit -m "feat(treesitter): add symbol tags queries"
```

---

### Task 2: Symbol extraction in Swift

**Files:**
- Modify: `Alas/Sources/Code/Highlight/LanguageRegistry.swift` (new statics near the caches at 15–19; new functions after `highlightQuery(forExtension:)`)
- Create: `Alas/Sources/Code/Symbols/SymbolEntry.swift`
- Create: `Alas/Sources/Code/Symbols/SymbolExtractor.swift`
- Test: `AlasTests/Code/Highlight/LanguageRegistryTests.swift`, `AlasTests/Code/Symbols/SymbolExtractorTests.swift`

**Interfaces:**
- Consumes: Task 1 query ids.
- Produces:
  - `LanguageRegistry.tagsQuery(forPath: String) -> (languageID: String, language: Language, query: Query)?`
  - `LanguageRegistry.supportsSymbols(forPath: String) -> Bool`
  - `enum SymbolKind: String, Codable, Sendable, CaseIterable` with `isType`, `isCallable`, `label`, `badgeLetter`
  - `struct SymbolEntry: Sendable, Hashable { name, kind, container, languageID, relativePath, nameRange: NSRange, lineRange: ClosedRange<Int>; qualifiedName; displayName }`
  - `SymbolExtractor.symbols(in source: String, relativePath: String) -> [SymbolEntry]`

- [ ] **Step 1: Write the failing tests**

Add to `LanguageRegistryTests` (inside the suite):

```swift
    @Test("Every symbol language resolves a compiling tags query", arguments: [
        "a.swift", "a.ts", "a.tsx", "a.js", "a.py", "a.go", "a.rs", "a.java", "a.kt",
    ])
    func tagsQueryResolves(path: String) {
        #expect(LanguageRegistry.tagsQuery(forPath: path) != nil)
        #expect(LanguageRegistry.supportsSymbols(forPath: path))
    }

    @Test("Languages without a tags query report no symbol support")
    func noTagsQuery() {
        #expect(LanguageRegistry.tagsQuery(forPath: "a.json") == nil)
        #expect(!LanguageRegistry.supportsSymbols(forPath: "README.md"))
    }
```

Create `AlasTests/Code/Symbols/SymbolExtractorTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("SymbolExtractor")
struct SymbolExtractorTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        let path: String
        let source: String
        /// (name, kind, container, first line, last line), 0-based lines.
        let symbols: [(String, SymbolKind, String?, Int, Int)]
        var testDescription: String { path }
    }

    static let cases: [Expected] = [
        Expected(path: "Sources/Session.swift", source: """
        // 🚀 émoji before declarations shifts UTF-16 offsets
        struct Session {
            let id: String
            func restore() {
                print(id)
            }
        }
        extension Session {
            func close() {}
        }
        protocol Restorable { func restore() }
        """, symbols: [
            ("Session", .struct, nil, 1, 6),
            ("id", .property, "Session", 2, 2),
            ("restore", .method, "Session", 3, 5),
            ("close", .method, "Session", 8, 8),
            ("Restorable", .interface, nil, 10, 10),
        ]),
        Expected(path: "src/app.ts", source: """
        export interface Store { load(): void }
        export class TabStore {
          restore(from: string) {
            return from
          }
        }
        export function generatePrompt() {}
        """, symbols: [
            ("Store", .interface, nil, 0, 0),
            ("TabStore", .class, nil, 1, 5),
            ("restore", .method, "TabStore", 2, 4),
            ("generatePrompt", .function, nil, 6, 6),
        ]),
        Expected(path: "src/app.js", source: """
        class Greeter {
          greet() { return 1 }
        }
        function main() {}
        """, symbols: [
            ("Greeter", .class, nil, 0, 2),
            ("greet", .method, "Greeter", 1, 1),
            ("main", .function, nil, 3, 3),
        ]),
        Expected(path: "pkg/tool.py", source: """
        class Converter:
            def storage_to_text(self, value):
                return value

        def main():
            pass
        """, symbols: [
            ("Converter", .class, nil, 0, 2),
            ("storage_to_text", .method, "Converter", 1, 2),
            ("main", .function, nil, 4, 5),
        ]),
        Expected(path: "server.go", source: """
        package main

        type Server struct{}

        func (s *Server) Start() {}

        func (c Client) Start() {}

        func main() {}
        """, symbols: [
            ("Server", .type, nil, 2, 2),
            ("Start", .method, "Server", 4, 4),
            ("Start", .method, "Client", 6, 6),
            ("main", .function, nil, 8, 8),
        ]),
        Expected(path: "src/lib.rs", source: """
        pub struct Index;
        impl Index {
            pub fn refresh(&self) {}
        }
        pub fn build() {}
        """, symbols: [
            ("Index", .class, nil, 0, 0),
            ("refresh", .method, "Index", 2, 2),
            ("build", .function, nil, 4, 4),
        ]),
        Expected(path: "src/Main.java", source: """
        public class Main {
            void run() {}
        }
        interface Runner { void run(); }
        """, symbols: [
            ("Main", .class, nil, 0, 2),
            ("run", .method, "Main", 1, 1),
            ("Runner", .interface, nil, 3, 3),
        ]),
        Expected(path: "rules/Check.kt", source: """
        class ModifierReusedCheck {
            val id = "x"
            fun visit() {
                val local = 1
            }
        }
        """, symbols: [
            ("ModifierReusedCheck", .class, nil, 0, 5),
            ("id", .property, "ModifierReusedCheck", 1, 1),
            ("visit", .method, "ModifierReusedCheck", 2, 4),
        ]),
    ]

    @Test("extracts declarations with kind, container, and line range", arguments: cases)
    func extracts(_ expected: Expected) {
        let symbols = SymbolExtractor.symbols(in: expected.source, relativePath: expected.path)
        let actual = symbols.map { "\($0.name)|\($0.kind)|\($0.container ?? "-")|\($0.lineRange.lowerBound)-\($0.lineRange.upperBound)" }
        for (name, kind, container, start, end) in expected.symbols {
            let line = "\(name)|\(kind)|\(container ?? "-")|\(start)-\(end)"
            #expect(actual.contains(line), "missing \(line) in \(actual)")
        }
        #expect(!symbols.contains { $0.name == "local" }, "locals must not be indexed")
        for symbol in symbols {
            #expect((expected.source as NSString).substring(with: symbol.nameRange) == symbol.name)
            #expect(symbol.relativePath == expected.path)
        }
    }

    @Test("unknown languages and unparsable input yield no symbols")
    func unsupported() {
        #expect(SymbolExtractor.symbols(in: "{ \"a\": 1 }", relativePath: "a.json").isEmpty)
        #expect(SymbolExtractor.symbols(in: "", relativePath: "a.swift").isEmpty)
    }
}
```

The expectations describe the required behavior. If an upstream tags query labels a case differently (for example Rust `impl` methods as `function`), fix it in the extractor's refinement, not by loosening the expectation, unless the upstream query cannot see the declaration at all; then remove that row and say why in the commit message.

- [ ] **Step 2: Run tests to verify they fail**

Run the test command with `-only-testing AlasTests/SymbolExtractorTests -only-testing AlasTests/LanguageRegistryTests`.
Expected: build failure, `cannot find 'SymbolExtractor' in scope`.

- [ ] **Step 3: Implement**

`Alas/Sources/Code/Symbols/SymbolEntry.swift`:

```swift
import Foundation

enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case `class`, `struct`, `enum`, interface, module, type
    case function, method, property, constant, macro

    /// Upstream tags capture `@definition.<tag>`.
    init?(tag: String) {
        switch tag {
        case "class": self = .class
        case "struct": self = .struct
        case "enum": self = .enum
        case "interface": self = .interface
        case "module": self = .module
        case "type": self = .type
        case "function": self = .function
        case "method": self = .method
        case "property", "field": self = .property
        case "constant": self = .constant
        case "macro": self = .macro
        default: return nil
        }
    }

    var isType: Bool {
        switch self {
        case .class, .struct, .enum, .interface, .module, .type: true
        case .function, .method, .property, .constant, .macro: false
        }
    }

    var isCallable: Bool { self == .function || self == .method || self == .macro }

    /// Word used in the text sent to the agent.
    var label: String {
        switch self {
        case .interface: "interface"
        default: rawValue
        }
    }

    var badgeLetter: String {
        switch self {
        case .class: "C"
        case .struct: "S"
        case .enum: "E"
        case .interface: "I"
        case .module: "N"
        case .type: "T"
        case .function: "F"
        case .method: "M"
        case .property: "P"
        case .constant: "K"
        case .macro: "X"
        }
    }
}

struct SymbolEntry: Sendable, Hashable {
    let name: String
    let kind: SymbolKind
    /// Enclosing type, e.g. "SessionManager". Nil at top level.
    let container: String?
    let languageID: String
    let relativePath: String
    /// UTF-16 range of the name in the file.
    let nameRange: NSRange
    /// 0-based, inclusive, full declaration.
    let lineRange: ClosedRange<Int>

    var qualifiedName: String { container.map { "\($0).\(name)" } ?? name }
    /// What the badge and the agent text show: `SessionManager.restore()`.
    var displayName: String { kind.isCallable ? qualifiedName + "()" : qualifiedName }
}
```

In `LanguageRegistry.swift`, next to the existing caches:

```swift
    /// Tags query ids per grammar id. TypeScript and TSX inherit JavaScript's
    /// tags the same way their highlight queries do.
    private static let tagsQueryIDsByLanguageID: [String: [String]] = [
        "swift": ["swift.tags"],
        "javascript": ["javascript.tags"],
        "typescript": ["javascript.tags", "typescript.tags"],
        "tsx": ["javascript.tags", "tsx.tags"],
        "python": ["python.tags"],
        "go": ["go.tags"],
        "rust": ["rust.tags"],
        "java": ["java.tags"],
        "kotlin": ["kotlin.tags"],
    ]
    nonisolated(unsafe) private static var tagsQueryCache: [String: Query] = [:]
    nonisolated(unsafe) private static var tagsQueryMissCache: Set<String> = []
```

After `highlightQuery(forExtension:)`:

```swift
    static func supportsSymbols(forPath path: String) -> Bool {
        let ext = highlighterExtension(forPath: path)
        guard let id = languageIDsByExtension[ext] else { return false }
        return tagsQueryIDsByLanguageID[id] != nil
    }

    /// Grammar plus compiled tags query for `path`, or nil when the language
    /// has no tags query. Cached per grammar id.
    static func tagsQuery(forPath path: String) -> (languageID: String, language: Language, query: Query)? {
        let ext = highlighterExtension(forPath: path)
        guard let id = languageIDsByExtension[ext],
              let parts = tagsQueryIDsByLanguageID[id],
              let language = language(forFileExtension: ext) else { return nil }
        cacheLock.lock()
        if let cached = tagsQueryCache[id] {
            cacheLock.unlock()
            return (id, language, cached)
        }
        if tagsQueryMissCache.contains(id) {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        let combined = parts.compactMap(queryText(id:)).joined(separator: "\n")
        let query = combined.isEmpty ? nil : try? Query(language: language, data: Data(combined.utf8))

        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let query else {
            tagsQueryMissCache.insert(id)
            return nil
        }
        tagsQueryCache[id] = query
        return (id, language, query)
    }
```

`Alas/Sources/Code/Symbols/SymbolExtractor.swift`:

```swift
import Foundation
import SwiftTreeSitter

/// Turns one source file into its declarations using the language's tags
/// query. Pure and synchronous; callers choose the thread.
enum SymbolExtractor {
    /// Node types that end a declaration when walking up from a name.
    private static let declarationSuffixes = ["_declaration", "_definition", "_item", "_spec", "_signature", "_declarator"]
    /// Wrappers between a name and its real declaration (Kotlin
    /// `variable_declaration` inside `property_declaration`, JS declarators).
    private static let passThroughTypes: Set<String> = ["variable_declaration", "multi_variable_declaration", "variable_declarator"]
    /// Ancestors whose name becomes a member's container.
    private static let containerTypes: Set<String> = [
        "class_declaration", "protocol_declaration", "class_definition", "interface_declaration",
        "enum_declaration", "object_declaration", "record_declaration", "abstract_class_declaration",
        "struct_item", "enum_item", "trait_item", "impl_item", "mod_item", "internal_module", "module", "class",
    ]

    static func symbols(in source: String, relativePath: String) -> [SymbolEntry] {
        guard !source.isEmpty,
              let tags = LanguageRegistry.tagsQuery(forPath: relativePath) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(tags.language)) != nil,
              let tree = parser.parse(source),
              let root = tree.rootNode else { return [] }
        let text = source as NSString
        var seen = Set<NSRange>()
        var result: [SymbolEntry] = []
        let matches = tags.query.execute(node: root, in: tree).resolve(with: .init(string: source))
        for match in matches {
            guard let nameCapture = match.captures.first(where: { $0.nameComponents == ["name"] }),
                  let definition = match.captures.first(where: { $0.nameComponents.first == "definition" }),
                  definition.nameComponents.count >= 2,
                  var kind = SymbolKind(tag: definition.nameComponents[1]) else { continue }
            let nameNode = nameCapture.node
            guard nameNode.range.length > 0, seen.insert(nameNode.range).inserted else { continue }
            let declaration = declarationNode(from: nameNode, limit: definition.node)
            if declaration.nodeType == "class_declaration", tags.languageID == "swift" {
                switch declaration.child(byFieldName: "declaration_kind").map({ text.substring(with: $0.range) }) {
                case "struct": kind = .struct
                case "enum": kind = .enum
                case "extension": continue
                default: break
                }
            }
            let container = containerName(of: declaration, text: text)
            if kind == .function, container != nil { kind = .method }
            result.append(SymbolEntry(
                name: text.substring(with: nameNode.range),
                kind: kind,
                container: container,
                languageID: tags.languageID,
                relativePath: relativePath,
                nameRange: nameNode.range,
                lineRange: lineRange(of: declaration)
            ))
        }
        return result.sorted { $0.nameRange.location < $1.nameRange.location }
    }

    private static func isDeclaration(_ node: Node) -> Bool {
        guard let type = node.nodeType, !passThroughTypes.contains(type) else { return false }
        return declarationSuffixes.contains { type.hasSuffix($0) }
    }

    /// Nearest declaration above the name, never past the captured
    /// definition node. Swift tags capture a method's whole class as the
    /// definition, so the walk must stop at the first declaration instead.
    private static func declarationNode(from name: Node, limit: Node) -> Node {
        var current = name.parent
        while let node = current {
            if isDeclaration(node) || node.range == limit.range { return node }
            current = node.parent
        }
        return limit
    }

    private static func containerName(of declaration: Node, text: NSString) -> String? {
        // Go methods name their type in the receiver, `func (s *Server) Start()`.
        if declaration.nodeType == "method_declaration",
           let receiver = declaration.child(byFieldName: "receiver"),
           let type = firstDescendant(of: receiver, type: "type_identifier") {
            return text.substring(with: type.range)
        }
        var current = declaration.parent
        while let node = current {
            if let type = node.nodeType, containerTypes.contains(type),
               let nameNode = node.child(byFieldName: "name") ?? node.child(byFieldName: "type") {
                return text.substring(with: nameNode.range)
            }
            current = node.parent
        }
        return nil
    }

    private static func firstDescendant(of node: Node, type: String) -> Node? {
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if child.nodeType == type { return child }
            if let found = firstDescendant(of: child, type: type) { return found }
        }
        return nil
    }

    private static func lineRange(of node: Node) -> ClosedRange<Int> {
        let start = Int(node.pointRange.lowerBound.row)
        var end = Int(node.pointRange.upperBound.row)
        if node.pointRange.upperBound.column == 0, end > start { end -= 1 }
        return start...end
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command with `-only-testing AlasTests/SymbolExtractorTests -only-testing AlasTests/LanguageRegistryTests`.
Expected: PASS. Iterate on `declarationSuffixes`, `passThroughTypes`, `containerTypes`, or the Kotlin query until every row matches; do not delete rows that the upstream query can see.

- [ ] **Step 5: Regenerate the project and commit**

```bash
xcodegen
git add Alas/Sources/Code/Symbols Alas/Sources/Code/Highlight/LanguageRegistry.swift \
  AlasTests/Code/Symbols/SymbolExtractorTests.swift AlasTests/Code/Highlight/LanguageRegistryTests.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "feat(symbols): extract declarations with tree-sitter tags"
```

---

### Task 3: Worktree symbol index

**Files:**
- Create: `Alas/Sources/Code/Symbols/SymbolSource.swift`
- Create: `Alas/Sources/Code/Symbols/WorktreeSymbolIndex.swift`
- Modify: `Alas/Sources/App/AppState.swift` (`fileIndex` declaration at ~1371; `rightPaneStore.worktreeDidChange` at ~1607)
- Test: `AlasTests/Code/Symbols/WorktreeSymbolIndexTests.swift`

**Interfaces:**
- Consumes: `SymbolExtractor.symbols(in:relativePath:)`, `LanguageRegistry.supportsSymbols(forPath:)`.
- Produces:
  - `SymbolSource.read(root: URL, relativePath: String) async -> String?` and `SymbolSource.containedLocalURL(root: URL, relativePath: String) -> URL?`
  - `actor WorktreeSymbolIndex` with `func updates(root: URL, files: [String]?) -> AsyncStream<WorktreeSymbolIndex.Snapshot>` (`nil` files: enumeration failed, replay the cache unchanged) and `func isLoaded(root: URL) -> Bool`
  - `struct WorktreeSymbolIndex.Snapshot: Sendable, Equatable { symbols: [SymbolEntry]; indexedFiles: Int; totalFiles: Int; isComplete: Bool }`
  - `AppState.symbolIndex: WorktreeSymbolIndex`

- [ ] **Step 1: Write the failing test**

`AlasTests/Code/Symbols/WorktreeSymbolIndexTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("WorktreeSymbolIndex")
struct WorktreeSymbolIndexTests {
    private func lastSnapshot(_ stream: AsyncStream<WorktreeSymbolIndex.Snapshot>) async -> WorktreeSymbolIndex.Snapshot? {
        var last: WorktreeSymbolIndex.Snapshot?
        for await snapshot in stream { last = snapshot }
        return last
    }

    @Test("a refresh picks up changed, added, and deleted files and skips unsupported ones")
    func incrementalRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try write("A.swift", "struct Alpha {}")
        try write("B.swift", "struct Beta {}")
        try write("notes.md", "# Gamma")
        let index = WorktreeSymbolIndex()

        let first = try #require(await lastSnapshot(index.updates(root: root, files: ["A.swift", "B.swift", "notes.md"])))
        #expect(first.isComplete)
        #expect(first.totalFiles == 2)
        #expect(Set(first.symbols.map(\.name)) == ["Alpha", "Beta"])
        #expect(await index.isLoaded(root: root))

        // Force a different size so the stamp changes even within one mtime tick.
        try write("A.swift", "struct AlphaRenamed {}")
        try write("C.swift", "struct Gamma {}")
        try FileManager.default.removeItem(at: root.appendingPathComponent("B.swift"))
        let second = try #require(await lastSnapshot(index.updates(root: root, files: ["A.swift", "C.swift"])))
        #expect(Set(second.symbols.map(\.name)) == ["AlphaRenamed", "Gamma"])

        // A failed `git ls-files` must not wipe what is already indexed.
        let failed = try #require(await lastSnapshot(index.updates(root: root, files: nil)))
        #expect(failed.isComplete)
        #expect(Set(failed.symbols.map(\.name)) == ["AlphaRenamed", "Gamma"])
    }

    @Test("a file that could not be read is retried once readable, even with an unchanged stamp")
    func retriesUnreadableFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Locked.swift")
        try "struct Locked {}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let index = WorktreeSymbolIndex()

        let locked = try #require(await lastSnapshot(index.updates(root: root, files: ["Locked.swift"])))
        #expect(locked.symbols.isEmpty)

        // chmod changes neither size nor modification date.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let readable = try #require(await lastSnapshot(index.updates(root: root, files: ["Locked.swift"])))
        #expect(readable.symbols.map(\.name) == ["Locked"])
    }

    @Test("a read that fails after opening is a failure, not an empty file")
    func failedReadIsNil() throws {
        // A directory opens for reading but every read throws EISDIR.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SymbolSource.readBounded(directory) == nil)
    }

    @Test("files over the size cap are skipped")
    func skipsLargeFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let big = "struct Big {}\n" + String(repeating: "// pad\n", count: WorktreeSymbolIndex.maxFileBytes / 7 + 1)
        try big.write(to: root.appendingPathComponent("Big.swift"), atomically: true, encoding: .utf8)

        let snapshot = try #require(await lastSnapshot(WorktreeSymbolIndex().updates(root: root, files: ["Big.swift"])))
        #expect(snapshot.symbols.isEmpty)
        #expect(snapshot.isComplete)
    }

    @Test("symlinks that resolve outside the worktree are neither indexed nor read")
    func ignoresEscapingSymlinks() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("worktree", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "struct Secret {}".write(to: outside.appendingPathComponent("Secret.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape.swift"),
                                                   withDestinationURL: outside.appendingPathComponent("Secret.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)

        let snapshot = try #require(await lastSnapshot(WorktreeSymbolIndex().updates(
            root: root, files: ["Escape.swift", "linked/Secret.swift"])))
        #expect(snapshot.symbols.isEmpty)
        #expect(await SymbolSource.read(root: root, relativePath: "Escape.swift") == nil)
        #expect(await SymbolSource.read(root: root, relativePath: "linked/Secret.swift") == nil)

        // Git metadata is never read, by path or through an in-tree symlink.
        let hooks = root.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "struct Hook {}".write(to: hooks.appendingPathComponent("hook.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Hook.swift"),
                                                   withDestinationURL: hooks.appendingPathComponent("hook.swift"))
        #expect(await SymbolSource.read(root: root, relativePath: ".git/hooks/hook.swift") == nil)
        #expect(await SymbolSource.read(root: root, relativePath: "Hook.swift") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run with `-only-testing AlasTests/WorktreeSymbolIndexTests`.
Expected: build failure, `cannot find 'WorktreeSymbolIndex' in scope`.

- [ ] **Step 3: Implement**

`Alas/Sources/Code/Symbols/SymbolSource.swift`:

```swift
import Foundation

/// Reads one worktree file for symbol extraction, locally or over SSH.
enum SymbolSource {
    static let maxBytes = 1_000_000

    static func read(root: URL, relativePath: String) async -> String? {
        guard isSafeRelativePath(relativePath) else { return nil }
        if let host = RemoteHostRegistry.shared.host(forPath: root.path) {
            // Resolves every component on the host, so an intermediate
            // symlink cannot escape the worktree either.
            guard case .ok(let byteSize, let data) = try? await RemotePathContainment.containedResolvedRead(
                host: host, path: root.appendingPathComponent(relativePath).path,
                worktreeRoot: root.path, maxBytes: maxBytes),
                  byteSize <= maxBytes, data.count == byteSize else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return await Task.detached(priority: .userInitiated) {
            guard let url = containedLocalURL(root: root, relativePath: relativePath) else { return nil }
            return readBounded(url)
        }.value
    }

    /// Reads at most `maxBytes + 1` bytes, so a file that grew past the cap
    /// after any earlier size check is rejected instead of read whole.
    static func readBounded(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // A throwing read is a failure (nil), never an empty file: an empty
        // result would be indexed with the current stamp and never retried.
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { return nil }
        guard data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The file's physical URL when it resolves, symlinks included, to a
    /// location strictly inside the physical worktree root and outside
    /// `.git` (matching `RemotePathContainment` on the remote side).
    static func containedLocalURL(root: URL, relativePath: String) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let resolved = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        let components = resolved.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents,
              !components.dropFirst(rootComponents.count).contains(where: { $0.lowercased() == ".git" })
        else { return nil }
        return resolved
    }

    /// Worktree-relative, no `..`, not absolute, never inside `.git`.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0.lowercased() == ".git" }
    }
}
```

`Alas/Sources/Code/Symbols/WorktreeSymbolIndex.swift`:

```swift
import Foundation
import os

/// In-memory declarations per local worktree. Built lazily the first time a
/// picker asks, then refreshed incrementally: only files whose size or
/// modification date changed are parsed again.
actor WorktreeSymbolIndex {
    struct Snapshot: Sendable, Equatable {
        let symbols: [SymbolEntry]
        let indexedFiles: Int
        let totalFiles: Int
        var isComplete: Bool { indexedFiles >= totalFiles }
    }

    static let maxFileBytes = SymbolSource.maxBytes
    /// Publish progress after this many files.
    static let snapshotInterval = 200

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private struct Record {
        let stamp: Stamp
        let symbols: [SymbolEntry]
    }

    private var records: [String: [String: Record]] = [:]
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "symbols.index")

    func isLoaded(root: URL) -> Bool { records[Self.key(root)] != nil }

    /// Streams progress while refreshing `root` against `files` (worktree
    /// relative, from `FileIndex`). Ends after a complete snapshot.
    /// Cancelling the consumer stops parsing; finished files are kept.
    /// `files: nil` means enumeration failed: replay the cache, change nothing.
    func updates(root: URL, files: [String]?) -> AsyncStream<Snapshot> {
        guard let files else {
            let cached = records[Self.key(root)] ?? [:]
            let snapshot = Self.snapshot(cached, indexed: cached.count, total: cached.count)
            return AsyncStream { continuation in
                continuation.yield(snapshot)
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let task = Task { await self.refresh(root: root, files: files, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func refresh(root: URL, files: [String], continuation: AsyncStream<Snapshot>.Continuation) async {
        let key = Self.key(root)
        let candidates = files.filter { LanguageRegistry.supportsSymbols(forPath: $0) }
        let listed = Set(candidates)
        var current = (records[key] ?? [:]).filter { listed.contains($0.key) }
        // Always publish first, so even a small or fully cached worktree
        // shows "Indexing symbols…" until the stat pass finishes.
        continuation.yield(Self.snapshot(current, indexed: 0, total: candidates.count))
        let started = Date()
        var processed = 0
        var parsed = 0
        for path in candidates {
            if Task.isCancelled { break }
            if let url = SymbolSource.containedLocalURL(root: root, relativePath: path),
               let stamp = Self.stamp(of: url) {
                if current[path]?.stamp != stamp {
                    if stamp.size > Self.maxFileBytes {
                        current[path] = Record(stamp: stamp, symbols: [])
                    } else if let source = SymbolSource.readBounded(url) {
                        current[path] = Record(stamp: stamp, symbols: SymbolExtractor.symbols(in: source, relativePath: path))
                        parsed += 1
                    }
                    // A failed read commits nothing: the previous record (and
                    // its old stamp) stays, so the next refresh retries.
                }
            } else {
                current[path] = nil
            }
            processed += 1
            if processed % Self.snapshotInterval == 0 {
                records[key] = current
                continuation.yield(Self.snapshot(current, indexed: processed, total: candidates.count))
            }
        }
        records[key] = current
        if !Task.isCancelled {
            continuation.yield(Self.snapshot(current, indexed: processed, total: candidates.count))
        }
        logger.debug("refreshed \(key, privacy: .private): \(candidates.count) files, \(parsed) parsed in \(Date().timeIntervalSince(started), format: .fixed(precision: 3))s")
        continuation.finish()
    }

    private static func key(_ root: URL) -> String { root.standardizedFileURL.path }

    private static func stamp(of url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let modified = values.contentModificationDate,
              let size = values.fileSize else { return nil }
        return Stamp(modified: modified, size: size)
    }

    private static func snapshot(_ records: [String: Record], indexed: Int, total: Int) -> Snapshot {
        let symbols = records.keys.sorted().flatMap { records[$0]?.symbols ?? [] }
        return Snapshot(symbols: symbols, indexedFiles: indexed, totalFiles: total)
    }
}
```

`AppState.swift`, beside `let fileIndex = FileIndex()`:

```swift
    @ObservationIgnored
    let symbolIndex = WorktreeSymbolIndex()
```

Replace the `rightPaneStore.worktreeDidChange` assignment (~1607) with:

```swift
        rightPaneStore.worktreeDidChange = { [weak self] worktreeID in
            self?.rescanWorktreeStatus(worktreeId: worktreeID)
            self?.refreshSymbolIndexIfLoaded(worktreeId: worktreeID)
        }
```

And add (near `openFile`):

```swift
    /// Keeps an already-built symbol index current. Never builds one: the
    /// index is created lazily by the `@` picker.
    func refreshSymbolIndexIfLoaded(worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId), !worktree.path.isRemoteAlasPath else { return }
        let root = worktree.path
        Task { [fileIndex, symbolIndex] in
            guard await symbolIndex.isLoaded(root: root) else { return }
            await fileIndex.invalidate(forWorktreePath: root)
            // `try?` without a fallback: a failed enumeration leaves the index alone.
            let files = (try? await fileIndex.entries(forWorktreePath: root))?.map(\.relativePath)
            for await _ in await symbolIndex.updates(root: root, files: files) {}
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run with `-only-testing AlasTests/WorktreeSymbolIndexTests`.
Expected: PASS (2 tests).

- [ ] **Step 5: Regenerate the project and commit**

```bash
xcodegen
git add Alas/Sources/Code/Symbols Alas/Sources/App/AppState.swift \
  AlasTests/Code/Symbols/WorktreeSymbolIndexTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(symbols): add incremental worktree symbol index"
```

---

### Task 4: Picker decision logic

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPMentionSymbols.swift`
- Modify: `Alas/Sources/ACP/UI/ACPMentionPicker.swift:22-25` (`MentionPickerItem`)
- Test: `AlasTests/ACP/UI/ACPMentionPickerTests.swift`

**Interfaces:**
- Consumes: `SymbolEntry`, `FuzzyMatch.score(query:target:)`.
- Produces:
  - `MentionPickerItem.symbol(SymbolEntry)`
  - `enum MentionScope: Int, CaseIterable { case all, files, symbols, sessions }` with `title`, `shortcut: Character`
  - `enum MentionSymbolQuery: Equatable { case project(String); case file(file: String, symbol: String); static func parse(_:) }`
  - `MentionSymbolRanking.rank(_:query:limit:) -> [SymbolEntry]`, `MentionSymbolRanking.isTestPath(_:) -> Bool`
  - `MentionPickerNavigation.index(preserving:fallback:in:) -> Int`

- [ ] **Step 1: Write the failing tests** (add inside `ACPMentionPickerTests`)

```swift
    private func symbol(_ name: String, _ kind: SymbolKind, container: String? = nil, path: String = "Sources/A.swift") -> SymbolEntry {
        SymbolEntry(name: name, kind: kind, container: container, languageID: "swift",
                    relativePath: path, nameRange: NSRange(location: 0, length: name.utf16.count), lineRange: 0...0)
    }

    @Test("symbols rank exact names first, then types over members, real code over tests, shorter paths")
    func ranksSymbols() {
        let symbols = [
            symbol("testRestore", .method, container: "SessionManagerTests", path: "Tests/SessionManagerTests.swift"),
            symbol("restore", .method, container: "TabStore", path: "Sources/Tabs/TabStore.swift"),
            symbol("restore", .method, container: "SessionManager", path: "Sources/SessionManager.swift"),
            symbol("RestorePolicy", .struct, path: "Sources/Session/RestorePolicy.swift"),
            symbol("restore", .method, container: "Fixture", path: "Tests/Fixtures/Fixture.swift"),
        ]
        let ranked = MentionSymbolRanking.rank(symbols, query: "restore", limit: 10).map(\.qualifiedName)
        #expect(ranked == [
            // Equal exact matches: the shorter path wins (27 vs 28 characters).
            "TabStore.restore", "SessionManager.restore", "Fixture.restore",
            "RestorePolicy", "SessionManagerTests.testRestore",
        ])
        #expect(MentionSymbolRanking.rank(symbols, query: "tabst rest", limit: 1).map(\.qualifiedName) == ["TabStore.restore"])
        #expect(MentionSymbolRanking.rank(symbols, query: "zzz", limit: 10).isEmpty)
    }

    @Test("on an equal match, a type beats a member even when the type lives in tests")
    func typeBeatsMember() {
        let symbols = [symbol("Store", .property, container: "App"), symbol("Store", .class, path: "Tests/StoreTests.swift")]
        #expect(MentionSymbolRanking.rank(symbols, query: "Store", limit: 2).map(\.kind) == [.class, .property])
    }

    @Test("test paths follow the spec's directory and file-name rules", arguments: [
        ("Tests/A.swift", true), ("src/__tests__/a.ts", true), ("spec/a_spec.rb", true),
        ("Sources/FooTests.swift", true), ("pkg/server_test.go", true), ("src/a.test.ts", true),
        ("Sources/Testing.swift", false), ("Sources/Contest.swift", false), ("src/latest/a.ts", false),
    ])
    func testPaths(path: String, isTest: Bool) {
        #expect(MentionSymbolRanking.isTestPath(path) == isTest)
    }

    @Test("a # splits a file filter from a symbol filter", arguments: [
        ("restore", MentionSymbolQuery.project("restore")),
        ("TabStore.swift#res", .file(file: "TabStore.swift", symbol: "res")),
        ("TabStore.swift#", .file(file: "TabStore.swift", symbol: "")),
        ("#res", .project("#res")),
        ("a#b#c", .file(file: "a#b", symbol: "c")),
    ])
    func parsesSymbolQuery(query: String, expected: MentionSymbolQuery) {
        #expect(MentionSymbolQuery.parse(query) == expected)
    }

    @Test("new results keep the highlighted item when it is still listed")
    func preservesHighlightedItem() {
        let a = MentionPickerItem.file(URL(fileURLWithPath: "/tmp/a"))
        let b = MentionPickerItem.file(URL(fileURLWithPath: "/tmp/b"))
        let s = MentionPickerItem.symbol(symbol("restore", .method))
        #expect(MentionPickerNavigation.index(preserving: b, fallback: 1, in: [s, a, b]) == 2)
        #expect(MentionPickerNavigation.index(preserving: b, fallback: 1, in: [s, a]) == 1)
        #expect(MentionPickerNavigation.index(preserving: nil, fallback: 5, in: [a]) == 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing AlasTests/ACPMentionPickerTests`.
Expected: build failure, `cannot find 'MentionSymbolRanking' in scope`.

- [ ] **Step 3: Implement**

In `ACPMentionPicker.swift` replace the enum at 22–25:

```swift
enum MentionPickerItem: Hashable {
    case session(ACPSessionMentionCandidate)
    case symbol(SymbolEntry)
    case file(URL)
}
```

Add to `MentionPickerNavigation` (same file):

```swift
    /// After results change under an unchanged query, keep the user's
    /// highlighted item if it is still listed; otherwise keep the position.
    static func index(preserving item: MentionPickerItem?, fallback: Int, in items: [MentionPickerItem]) -> Int {
        if let item, let index = items.firstIndex(of: item) { return index }
        return move(from: fallback, by: 0, count: items.count)
    }
```

`Alas/Sources/ACP/UI/ACPMentionSymbols.swift`:

```swift
import Foundation

enum MentionScope: Int, CaseIterable, Identifiable {
    case all, files, symbols, sessions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .files: "Files"
        case .symbols: "Symbols"
        case .sessions: "Sessions"
        }
    }

    /// ⌘1–⌘4.
    var shortcut: Character { Character(String(rawValue + 1)) }
}

enum MentionSymbolQuery: Equatable {
    case project(String)
    /// `File.swift#name`: symbols of the best-matching file only.
    case file(file: String, symbol: String)

    static func parse(_ query: String) -> MentionSymbolQuery {
        guard let hash = query.lastIndex(of: "#") else { return .project(query) }
        let file = query[..<hash].trimmingCharacters(in: .whitespaces)
        guard !file.isEmpty else { return .project(query) }
        return .file(file: file, symbol: String(query[query.index(after: hash)...]).trimmingCharacters(in: .whitespaces))
    }
}

enum MentionSymbolRanking {
    /// Symbols shown in the All scope; the Symbols scope shows up to the
    /// picker's full limit.
    static let allScopeLimit = 8

    private static let testDirectories: Set<String> = ["Tests", "test", "tests", "__tests__", "spec"]
    private static let testSuffixes = ["Test", "Tests", "Spec", "_test", ".test"]

    static func isTestPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.dropLast().contains(where: testDirectories.contains) { return true }
        guard let file = components.last else { return false }
        let stem = (file as NSString).deletingPathExtension
        return testSuffixes.contains { stem.hasSuffix($0) }
    }

    static func rank(_ symbols: [SymbolEntry], query: String, limit: Int) -> [SymbolEntry] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return Array(symbols.prefix(limit)) }
        let normalized = query.lowercased()
        struct Scored {
            let entry: SymbolEntry
            let namePriority: Int
            let score: Double
            let isTest: Bool
            let order: Int
        }
        var scored: [Scored] = []
        for (order, entry) in symbols.enumerated() {
            var total = 0.0
            var matched = true
            for token in tokens {
                let nameScore = FuzzyMatch.score(query: token, target: entry.name)?.score.advanced(by: 8)
                let qualifiedScore = FuzzyMatch.score(query: token, target: entry.qualifiedName)?.score
                guard let best = [nameScore, qualifiedScore].compactMap(\.self).max() else {
                    matched = false
                    break
                }
                total += best
            }
            guard matched else { continue }
            let name = entry.name.lowercased()
            let priority = name == normalized ? 3 : name.hasPrefix(normalized) ? 2 : name.contains(normalized) ? 1 : 0
            scored.append(Scored(entry: entry, namePriority: priority, score: total,
                                 isTest: isTestPath(entry.relativePath), order: order))
        }
        scored.sort {
            if $0.namePriority != $1.namePriority { return $0.namePriority > $1.namePriority }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.kind.isType != $1.entry.kind.isType { return $0.entry.kind.isType }
            if $0.isTest != $1.isTest { return !$0.isTest }
            if $0.entry.relativePath.count != $1.entry.relativePath.count {
                return $0.entry.relativePath.count < $1.entry.relativePath.count
            }
            return $0.order < $1.order
        }
        return scored.prefix(limit).map(\.entry)
    }
}
```

Order follows the spec: name priority and fuzzy score first, then types before members, non-test before test, shorter path, original order. In the first test the three exact `restore` methods tie on score, so the test-path one sorts last among them.

- [ ] **Step 4: Run tests to verify they pass**

Run with `-only-testing AlasTests/ACPMentionPickerTests`.
Expected: PASS. Existing picker tests must still pass. The new `.symbol` case makes two switches non-exhaustive: add `case .symbol: break` to `handleKey`'s `switch ranked[highlight]` and `case .symbol: EmptyView()` to `list`'s `switch item`. Task 7 replaces both.

- [ ] **Step 5: Regenerate the project and commit**

```bash
xcodegen
git add Alas/Sources/ACP/UI/ACPMentionSymbols.swift Alas/Sources/ACP/UI/ACPMentionPicker.swift \
  AlasTests/ACP/UI/ACPMentionPickerTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): rank symbol mentions and parse file drill-down queries"
```

---

### Task 5: Symbol link format and attachment snapshot

**Files:**
- Create: `Alas/Sources/ACP/Session/ACPSymbolReference.swift` (URI part; Task 6 adds resolution)
- Modify: `Alas/Sources/ACP/Session/ACPMessage.swift:114-168` (`Attachment`)
- Test: `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift`, `AlasTests/ACP/Session/ACPMessageTests.swift`

**Interfaces:**
- Consumes: `SymbolEntry`, `SymbolKind`, `SymbolSource.isSafeRelativePath(_:)`.
- Produces:
  - `ACPSymbolReference.scheme`, `ACPSymbolReference.Target` (`path`, `name`, `kind`, `container`, `lineRange`, `includeCode`, `qualifiedName`, `displayName`, `init(entry:includeCode:)`)
  - `ACPSymbolReference.uri(for:) -> String`, `ACPSymbolReference.target(fromURI:) -> Target?`
  - `struct ACPSymbolSnapshot: Codable, Equatable, Hashable, Sendable { lineRange, contentHash, excerpt, truncated, found }`
  - `ACPMessage.Attachment.symbol: ACPSymbolSnapshot?` and `init(uri:name:mimeType:textOffset:symbol:)`

- [ ] **Step 1: Write the failing tests**

`AlasTests/ACP/Session/ACPSymbolReferenceTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("ACP symbol reference")
struct ACPSymbolReferenceTests {
    static let target = ACPSymbolReference.Target(
        path: "Sources/Session Manager/Ünïcode.swift", name: "restore", kind: .method,
        container: "SessionManager", lineRange: 119...157, includeCode: true
    )

    @Test("a target survives the URI round trip, including spaces and non-ASCII paths")
    func uriRoundTrip() {
        let uri = ACPSymbolReference.uri(for: Self.target)
        #expect(uri.hasPrefix("alas-symbol://"))
        #expect(ACPSymbolReference.target(fromURI: uri) == Self.target)
        #expect(Self.target.displayName == "SessionManager.restore()")
    }

    @Test("links that escape the worktree or are malformed are rejected", arguments: [
        "alas-symbol://symbol?path=../secret.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=/etc/passwd&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=a/../../b.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=.git/hooks/a.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=sub/.GIT/a.swift&name=a&kind=method&start=0&end=0",
        "alas-symbol://symbol?path=a.swift&name=a&kind=nonsense&start=0&end=0",
        "alas-symbol://symbol?path=a.swift&name=a&kind=method&start=5&end=2",
        "alas-symbol://symbol?path=a.swift&name=a&kind=method&start=0&end=9223372036854775807",
        "alas-session://abc",
        "file:///tmp/a.swift",
    ])
    func rejectsUnsafeLinks(uri: String) {
        #expect(ACPSymbolReference.target(fromURI: uri) == nil)
    }
}
```

Add to `ACPMessageTests`:

```swift
    @Test("symbol snapshots round-trip, legacy rows decode without one, and equality ignores them")
    func symbolSnapshotPersistence() throws {
        let snapshot = ACPSymbolSnapshot(lineRange: 3...9, contentHash: "abc", excerpt: "func a() {}", truncated: false, found: true)
        let attachment = ACPMessage.Attachment(uri: "alas-symbol://symbol?x", name: "A.a()", symbol: snapshot)
        let message = ACPMessage.user(id: UUID(), text: "hi", attachments: [attachment])
        let back = try ACPMessageCodec.decode(kind: message.kind, payload: ACPMessageCodec.encode(message))
        guard case .user(_, _, _, let attachments, _, _) = back else {
            Issue.record("expected user message")
            return
        }
        #expect(attachments.first?.symbol == snapshot)

        let legacy = try JSONDecoder().decode(ACPMessage.Attachment.self, from: Data(#"{"uri":"file:///a","name":"a"}"#.utf8))
        #expect(legacy.symbol == nil)

        let echoed = ACPMessage.Attachment(uri: attachment.uri, name: attachment.name)
        #expect(echoed == attachment)
        #expect(echoed.hashValue == attachment.hashValue)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPMessageTests`.
Expected: build failure, `cannot find 'ACPSymbolReference' in scope`.

- [ ] **Step 3: Implement**

`Alas/Sources/ACP/Session/ACPSymbolReference.swift`:

```swift
import CryptoKit
import Foundation

/// A code symbol the user attached to a prompt from the `@` picker.
///
/// Like `ACPSessionReference`, it rides the mention pipeline as a resource
/// link (`alas-symbol://symbol?path=…`), so chips, drafts, the queue, and the
/// recorded message treat it like a file mention. Just before sending, the
/// symbol is found again in its file and the link is replaced on the wire by
/// a reference line and, when requested, the declaration's code. Agents never
/// see the `alas-symbol` scheme.
enum ACPSymbolReference {
    static let scheme = "alas-symbol"
    /// Upper bound for parsed line numbers, so `+ 1` and range counting
    /// can never overflow on a crafted link.
    static let maxLineNumber = 10_000_000

    struct Target: Equatable, Hashable, Sendable {
        let path: String
        let name: String
        let kind: SymbolKind
        let container: String?
        /// 0-based, inclusive, at insertion time.
        let lineRange: ClosedRange<Int>
        var includeCode: Bool

        init(path: String, name: String, kind: SymbolKind, container: String?,
             lineRange: ClosedRange<Int>, includeCode: Bool) {
            self.path = path
            self.name = name
            self.kind = kind
            self.container = container
            self.lineRange = lineRange
            self.includeCode = includeCode
        }

        init(entry: SymbolEntry, includeCode: Bool) {
            self.init(path: entry.relativePath, name: entry.name, kind: entry.kind,
                      container: entry.container, lineRange: entry.lineRange, includeCode: includeCode)
        }

        var qualifiedName: String { container.map { "\($0).\(name)" } ?? name }
        var displayName: String { kind.isCallable ? qualifiedName + "()" : qualifiedName }
    }

    static func uri(for target: Target) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "symbol"
        var items = [
            URLQueryItem(name: "path", value: target.path),
            URLQueryItem(name: "name", value: target.name),
            URLQueryItem(name: "kind", value: target.kind.rawValue),
            URLQueryItem(name: "start", value: String(target.lineRange.lowerBound)),
            URLQueryItem(name: "end", value: String(target.lineRange.upperBound)),
        ]
        if let container = target.container { items.append(URLQueryItem(name: "container", value: container)) }
        if target.includeCode { items.append(URLQueryItem(name: "code", value: "1")) }
        components.queryItems = items
        return components.string ?? "\(scheme)://symbol"
    }

    static func target(fromURI uri: String) -> Target? {
        // URI schemes are case-insensitive; Foundation keeps the original case.
        guard let components = URLComponents(string: uri), components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == "symbol" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        guard let path = values["path"], SymbolSource.isSafeRelativePath(path),
              let name = values["name"], !name.isEmpty,
              let kind = values["kind"].flatMap(SymbolKind.init(rawValue:)),
              let start = values["start"].flatMap(Int.init),
              let end = values["end"].flatMap(Int.init),
              start >= 0, end >= start, end <= maxLineNumber else { return nil }
        return Target(path: path, name: name, kind: kind, container: values["container"],
                      lineRange: start...end, includeCode: values["code"] == "1")
    }
}

/// What a sent symbol mention looked like at send time. Stored on the
/// recorded attachment so the transcript can show it later.
struct ACPSymbolSnapshot: Codable, Equatable, Hashable, Sendable {
    /// 0-based, inclusive, as sent.
    let lineRange: ClosedRange<Int>
    /// SHA-256 (hex) of the declaration text as sent; empty when not found.
    let contentHash: String
    /// The code sent to the agent, only when "Include code" was on.
    let excerpt: String?
    let truncated: Bool
    let found: Bool
}
```

`ACPMessage.swift`, inside `Attachment` after `textOffset`:

```swift
        /// Symbol mentions only: what was sent (see `ACPSymbolReference`).
        /// Absent in legacy rows. Excluded from `==`/`hash(into:)` like
        /// `textOffset`, so an agent-echoed copy still reconciles.
        let symbol: ACPSymbolSnapshot?

        init(uri: String, name: String?, mimeType: String? = nil, textOffset: Int? = nil,
             symbol: ACPSymbolSnapshot? = nil) {
            self.uri = uri
            self.name = name
            self.mimeType = mimeType
            self.textOffset = textOffset
            self.symbol = symbol
        }
```

Replace the existing `init(uri:name:mimeType:textOffset:)` with the one above. Leave `==` and `hash(into:)` unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run with `-only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPMessageTests`.
Expected: PASS.

- [ ] **Step 5: Regenerate the project and commit**

```bash
xcodegen
git add Alas/Sources/ACP/Session/ACPSymbolReference.swift Alas/Sources/ACP/Session/ACPMessage.swift \
  AlasTests/ACP/Session/ACPSymbolReferenceTests.swift AlasTests/ACP/Session/ACPMessageTests.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): add symbol mention links and sent-symbol snapshots"
```

---

### Task 6: Send-time resolution and wire expansion

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSymbolReference.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionRunner.swift` (steer path ~3644–3674; `sendNow` ~4098–4223)
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift` (new method beside `attachCheckpoint` at ~761)
- Test: `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift`, `AlasTests/ACP/Session/ACPImageBlocksTests.swift`, `AlasTests/ACP/Session/ACPSessionTests.swift`

**Interfaces:**
- Consumes: Task 5 types, `SymbolSource.read`, `SymbolExtractor.symbols`, `LanguageRegistry.codeFenceLanguage(forPath:)`.
- Produces:
  - `ACPSymbolReference.maxExcerptLines = 400`, `maxExcerptBytes = 32 * 1024`
  - `struct ACPSymbolReference.Resolution: Equatable, Sendable { target; found; lineRange; declaration: String? }`
  - `ACPSymbolReference.resolve(blocks:worktreeRoot:) async -> [String: Resolution]` (keyed by URI)
  - `ACPSymbolReference.resolve(_:source:) -> Resolution` (pure)
  - `ACPSymbolReference.excerpt(_:) -> Excerpt` (`text`, `shownLines`, `totalLines`, `truncated`)
  - `ACPSymbolReference.referenceText(for:) -> String`
  - `ACPSymbolReference.replacingReferences(in:resolutions:embeddedContext:worktreeRoot:) -> [ACPContentBlock]`
  - `ACPSymbolReference.attachingSnapshots(to:resolutions:) -> [ACPMessage.Attachment]`
  - `ACPSession.replaceSymbolSnapshots(inUserMessage: UUID, resolutions:) -> Int?` (index of the changed message)

- [ ] **Step 1: Write the failing tests** (add to `ACPSymbolReferenceTests`)

```swift
    private static let swiftSource = """
    struct SessionManager {
        init() {}
        init(id: String) {}
        func restore() {
            print("``` not a fence")
        }
    }
    """

    private func target(_ name: String, _ kind: SymbolKind, lines: ClosedRange<Int>, code: Bool = false) -> ACPSymbolReference.Target {
        .init(path: "Sources/SessionManager.swift", name: name, kind: kind,
              container: "SessionManager", lineRange: lines, includeCode: code)
    }

    @Test("resolution follows a moved declaration and picks the overload nearest the stored line")
    func resolvesMovedAndOverloaded() {
        let moved = "// header\n// header\n" + Self.swiftSource
        let restore = ACPSymbolReference.resolve(target("restore", .method, lines: 3...5), source: moved)
        #expect(restore.found)
        #expect(restore.lineRange == 5...7)
        #expect(restore.declaration?.hasPrefix("    func restore()") == true)

        let secondInit = ACPSymbolReference.resolve(target("init", .method, lines: 2...2), source: Self.swiftSource)
        #expect(secondInit.lineRange == 2...2)
        #expect(secondInit.declaration == "    init(id: String) {}")

        let gone = ACPSymbolReference.resolve(target("close", .method, lines: 9...9), source: Self.swiftSource)
        #expect(!gone.found)
        #expect(gone.lineRange == 9...9)
        #expect(ACPSymbolReference.resolve(target("restore", .method, lines: 3...5), source: nil).found == false)
    }

    @Test("excerpts stay within 400 lines and 32 KB, marker included, and say how much was cut", arguments: [
        (String(repeating: "x\n", count: 500), 400, 500, "… cut: showing 400 of 500 lines"),
        (String(repeating: String(repeating: "y", count: 1_000) + "\n", count: 50), 32, 50, "… cut: showing 32 of 50 lines"),
        (String(repeating: "z", count: 40_000), 1, 1, "… cut: showing 1 of 1 lines, first line shortened"),
        (String(repeating: "€", count: 12_000), 1, 1, "… cut: showing 1 of 1 lines, first line shortened"),
    ])
    func capsExcerpt(declaration: String, shown: Int, total: Int, marker: String) {
        let excerpt = ACPSymbolReference.excerpt(declaration)
        #expect(excerpt.truncated)
        #expect(excerpt.shownLines == shown)
        #expect(excerpt.totalLines == total)
        #expect(excerpt.text.utf8.count <= ACPSymbolReference.maxExcerptBytes)
        #expect(excerpt.text.hasSuffix(marker))
        #expect(!excerpt.text.contains("\u{FFFD}"), "cuts land on scalar boundaries, never mid-character")
        #expect(!ACPSymbolReference.excerpt("short\n").truncated)
    }

    @Test("the wire gets reference text, plus code as a resource or a fence that survives backticks")
    func replacesLinksOnTheWire() {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let withCode = target("restore", .method, lines: 3...5, code: true)
        let withoutCode = target("restore", .method, lines: 3...5)
        let gone = target("close", .method, lines: 9...9, code: true)
        let resolutions = [
            ACPSymbolReference.uri(for: withCode): ACPSymbolReference.resolve(withCode, source: Self.swiftSource),
            ACPSymbolReference.uri(for: withoutCode): ACPSymbolReference.resolve(withoutCode, source: Self.swiftSource),
            ACPSymbolReference.uri(for: gone): ACPSymbolReference.resolve(gone, source: Self.swiftSource),
        ]
        let blocks: [ACPContentBlock] = [
            .text("Why does @SessionManager.restore() fail? "),
            .resourceLink(uri: ACPSymbolReference.uri(for: withCode), name: "SessionManager.restore()"),
            .resourceLink(uri: ACPSymbolReference.uri(for: withoutCode), name: "SessionManager.restore()"),
            .resourceLink(uri: ACPSymbolReference.uri(for: gone), name: "SessionManager.close()"),
            .resourceLink(uri: "file:///tmp/wt/a.swift", name: "a.swift"),
            .resourceLink(uri: "ALAS-SYMBOL://symbol?path=../escape.swift&name=x&kind=function&start=0&end=0", name: "x()"),
        ]
        let reference = "Referenced symbol: SessionManager.restore(), method in Sources/SessionManager.swift, lines 4–6."

        let embedded = ACPSymbolReference.replacingReferences(in: blocks, resolutions: resolutions, embeddedContext: true, worktreeRoot: root)
        #expect(embedded[0] == blocks[0])
        #expect(embedded[1] == .text(reference))
        guard case .resource(let uri, _, let code) = embedded[2] else {
            Issue.record("expected resource, got \(embedded[2])")
            return
        }
        #expect(uri == "file:///tmp/wt/Sources/SessionManager.swift#L4-L6")
        #expect(code.hasPrefix("    func restore()"))
        #expect(embedded[3] == .text(reference))
        #expect(embedded[4] == .text("Referenced symbol: SessionManager.close(), method in Sources/SessionManager.swift, lines 10–10 (last known location; not found when sent)."))
        #expect(embedded[5] == blocks[4])
        #expect(embedded[6] == .text("Referenced symbol: x() (unreadable link; not sent)."))
        #expect(!embedded.contains { block in
            if case .resourceLink(let uri, _) = block { return uri.lowercased().hasPrefix("alas-symbol:") }
            return false
        }, "agents never see the alas-symbol scheme")

        let fenced = ACPSymbolReference.replacingReferences(in: blocks, resolutions: resolutions, embeddedContext: false, worktreeRoot: root)
        guard case .text(let text) = fenced[1] else {
            Issue.record("expected text, got \(fenced[1])")
            return
        }
        #expect(text.hasPrefix(reference + "\n\n````swift\n"))
        #expect(text.hasSuffix("\n````"))
        #expect(fenced.count == blocks.count)
    }

    @Test("recorded attachments carry the snapshot of what was sent")
    func attachesSnapshots() {
        let withCode = target("restore", .method, lines: 3...5, code: true)
        let uri = ACPSymbolReference.uri(for: withCode)
        let resolution = ACPSymbolReference.resolve(withCode, source: Self.swiftSource)
        let attachments = ACPSymbolReference.attachingSnapshots(
            to: [.init(uri: uri, name: "SessionManager.restore()"), .init(uri: "file:///a", name: "a")],
            resolutions: [uri: resolution]
        )
        let snapshot = attachments[0].symbol
        #expect(snapshot?.found == true)
        #expect(snapshot?.lineRange == 3...5)
        #expect(snapshot?.excerpt == resolution.declaration)
        #expect(snapshot?.contentHash.count == 64)
        #expect(attachments[1].symbol == nil)
    }
```

Add to `ACPSessionTests` (next to `checkpointCaptureAttachesToRecordedPrompt`):

```swift
    @Test("a retried send re-stamps the recorded symbol snapshot with what it actually sent")
    func retryRestampsSymbolSnapshot() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let target = ACPSymbolReference.Target(path: "A.swift", name: "run", kind: .function,
                                               container: nil, lineRange: 0...0, includeCode: true)
        let uri = ACPSymbolReference.uri(for: target)
        let first = ACPSymbolReference.resolve(target, source: "func run() {}")
        let id = session.recordUserPrompt(
            text: "@run() ",
            attachments: ACPSymbolReference.attachingSnapshots(to: [.init(uri: uri, name: "run()")], resolutions: [uri: first]))

        let retried = ACPSymbolReference.resolve(target, source: "// moved\nfunc run() { work() }")
        #expect(session.replaceSymbolSnapshots(inUserMessage: id, resolutions: [uri: retried]) == 0)
        guard case .user(_, _, _, let attachments, _, _) = session.transcript.messages[0] else {
            Issue.record("expected user message")
            return
        }
        #expect(attachments.first?.symbol?.lineRange == 1...1)
        #expect(attachments.first?.symbol?.excerpt == "func run() { work() }")
        #expect(session.replaceSymbolSnapshots(inUserMessage: id, resolutions: [uri: retried]) == nil, "unchanged: nothing to persist")
    }
```

Add to `ACPImageBlocksTests`:

```swift
    @Test("hydrate never expands symbol links into file contents")
    func hydrateLeavesSymbolLinks() async {
        let link = ACPContentBlock.resourceLink(
            uri: ACPSymbolReference.uri(for: .init(path: "a.swift", name: "a", kind: .function,
                                                   container: nil, lineRange: 0...0, includeCode: true)),
            name: "a()"
        )
        let wire = await ACPSessionRunner.hydrate([link], promptCapabilities: .init(embeddedContext: true), worktreePath: "/tmp")
        #expect(wire == [link])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPImageBlocksTests`.
Expected: build failure, `type 'ACPSymbolReference' has no member 'resolve'`.

- [ ] **Step 3: Implement resolution and expansion** (append to `enum ACPSymbolReference`)

```swift
    static let maxExcerptLines = 400
    static let maxExcerptBytes = 32 * 1024

    struct Resolution: Equatable, Sendable {
        let target: Target
        let found: Bool
        /// Current range when found; the stored one otherwise.
        let lineRange: ClosedRange<Int>
        /// Full declaration text, uncapped. Nil when not found.
        let declaration: String?
    }

    struct Excerpt: Equatable {
        let text: String
        let shownLines: Int
        let totalLines: Int
        let truncated: Bool
    }

    /// Resolves every symbol link in `blocks`, once per URI, off the main
    /// actor. Each file is read once per pass, however many mentions it has.
    static func resolve(blocks: [ACPContentBlock], worktreeRoot: URL) async -> [String: Resolution] {
        var result: [String: Resolution] = [:]
        var sources: [String: String?] = [:]
        for block in blocks {
            guard case .resourceLink(let uri, _) = block, result[uri] == nil,
                  let target = target(fromURI: uri) else { continue }
            if sources[target.path] == nil {
                sources[target.path] = .some(await SymbolSource.read(root: worktreeRoot, relativePath: target.path))
            }
            result[uri] = resolve(target, source: sources[target.path] ?? nil)
        }
        return result
    }

    static func resolve(_ target: Target, source: String?) -> Resolution {
        let missing = Resolution(target: target, found: false, lineRange: target.lineRange, declaration: nil)
        guard let source else { return missing }
        let candidates = SymbolExtractor.symbols(in: source, relativePath: target.path)
            .filter { $0.name == target.name && $0.container == target.container }
        // Name, kind, and container must all match: a method replaced by a
        // same-named property is reported missing, not silently swapped.
        guard let match = candidates.filter({ $0.kind == target.kind }).min(by: {
            abs($0.lineRange.lowerBound - target.lineRange.lowerBound) < abs($1.lineRange.lowerBound - target.lineRange.lowerBound)
        }) else { return missing }
        let lines = source.components(separatedBy: "\n")
        guard match.lineRange.upperBound < lines.count else { return missing }
        let declaration = lines[match.lineRange].joined(separator: "\n")
        return Resolution(target: target, found: true, lineRange: match.lineRange, declaration: declaration)
    }

    /// Room kept for the cut marker, so marker plus code fit the byte cap.
    private static let markerReserve = 96

    static func excerpt(_ declaration: String) -> Excerpt {
        var lines = declaration.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let whole = lines.joined(separator: "\n")
        if lines.count <= maxExcerptLines, whole.utf8.count <= maxExcerptBytes {
            return Excerpt(text: whole, shownLines: lines.count, totalLines: lines.count, truncated: false)
        }
        let budget = maxExcerptBytes - markerReserve
        var kept: [String] = []
        var bytes = 0
        var shortened = false
        for line in lines {
            let cost = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if kept.count == maxExcerptLines || bytes + cost > budget {
                if kept.isEmpty {
                    // One huge line (minified code): cut it to the byte
                    // budget on a scalar boundary, never mid-character.
                    var cut = String.UnicodeScalarView()
                    var used = 0
                    for scalar in line.unicodeScalars {
                        let width = UTF8.width(scalar)
                        if used + width > budget { break }
                        cut.append(scalar)
                        used += width
                    }
                    kept.append(String(cut))
                    shortened = true
                }
                break
            }
            kept.append(line)
            bytes += cost
        }
        let marker = "… cut: showing \(kept.count) of \(lines.count) lines" + (shortened ? ", first line shortened" : "")
        return Excerpt(text: kept.joined(separator: "\n") + "\n" + marker,
                       shownLines: kept.count, totalLines: lines.count, truncated: true)
    }

    static func referenceText(for resolution: Resolution) -> String {
        let target = resolution.target
        let lines = "lines \(resolution.lineRange.lowerBound + 1)–\(resolution.lineRange.upperBound + 1)"
        let suffix = resolution.found ? "." : " (last known location; not found when sent)."
        return "Referenced symbol: \(target.displayName), \(target.kind.label) in \(target.path), \(lines)\(suffix)"
    }

    /// `blocks` with each resolved symbol link replaced by its reference
    /// text, followed by the declaration when the user included code: a
    /// `resource` block when the agent accepts embedded context, otherwise a
    /// fenced block in the same text.
    static func replacingReferences(
        in blocks: [ACPContentBlock], resolutions: [String: Resolution],
        embeddedContext: Bool, worktreeRoot: URL
    ) -> [ACPContentBlock] {
        blocks.flatMap { block -> [ACPContentBlock] in
            guard case .resourceLink(let uri, let name) = block else { return [block] }
            guard let resolution = resolutions[uri] else {
                // A symbol link that failed validation never reaches the agent.
                guard uri.lowercased().hasPrefix("\(scheme):") else { return [block] }
                return [.text("Referenced symbol: \(name ?? "unknown") (unreadable link; not sent).")]
            }
            let reference = referenceText(for: resolution)
            guard resolution.target.includeCode, resolution.found, let declaration = resolution.declaration else {
                return [.text(reference)]
            }
            let code = excerpt(declaration).text
            if embeddedContext {
                let file = worktreeRoot.appendingPathComponent(resolution.target.path).absoluteString
                let anchor = "#L\(resolution.lineRange.lowerBound + 1)-L\(resolution.lineRange.upperBound + 1)"
                return [.text(reference), .resource(uri: file + anchor, mimeType: "text/plain", text: code)]
            }
            var fence = "```"
            while code.contains(fence) { fence += "`" }
            let language = LanguageRegistry.codeFenceLanguage(forPath: resolution.target.path)
            return [.text("\(reference)\n\n\(fence)\(language)\n\(code)\n\(fence)")]
        }
    }

    static func attachingSnapshots(
        to attachments: [ACPMessage.Attachment], resolutions: [String: Resolution]
    ) -> [ACPMessage.Attachment] {
        attachments.map { attachment in
            guard let resolution = resolutions[attachment.uri] else { return attachment }
            let declaration = resolution.declaration ?? ""
            let hash = resolution.found
                ? SHA256.hash(data: Data(declaration.utf8)).map { String(format: "%02x", $0) }.joined()
                : ""
            let excerpt = resolution.found && resolution.target.includeCode ? Self.excerpt(declaration) : nil
            return ACPMessage.Attachment(
                uri: attachment.uri, name: attachment.name, mimeType: attachment.mimeType,
                textOffset: attachment.textOffset,
                symbol: ACPSymbolSnapshot(lineRange: resolution.lineRange, contentHash: hash,
                                          excerpt: excerpt?.text, truncated: excerpt?.truncated ?? false,
                                          found: resolution.found)
            )
        }
    }
```

In the `attachesSnapshots` test the declaration is three short lines, so `excerpt.text == declaration`.

- [ ] **Step 4: Wire the runner**

Both paths resolve once, before recording, and reuse the result for the wire. In the steer path (~3644), immediately after the first `guard await self.hasConfirmedLeaseForSideEffect() ... else { throw CancellationError() }`:

```swift
                let symbolResolutions = await ACPSymbolReference.resolve(
                    blocks: blocks, worktreeRoot: URL(fileURLWithPath: self.worktreePath))
                var wireBlocks = ACPSymbolReference.replacingReferences(
                    in: await self.expandingSessionReferences(Self.hydrate(
                        blocks, promptCapabilities: self.session.promptCapabilities,
                        worktreePath: self.worktreePath)),
                    resolutions: symbolResolutions,
                    embeddedContext: self.session.promptCapabilities.embeddedContext,
                    worktreeRoot: URL(fileURLWithPath: self.worktreePath))
```

replacing the existing `var wireBlocks = await self.expandingSessionReferences(Self.hydrate(...))` statement, and change that path's `recordUserPrompt` call's attachments argument to:

```swift
                        attachments: ACPSymbolReference.attachingSnapshots(
                            to: Self.attachments(of: blocks, draft: draft), resolutions: symbolResolutions),
```

In `sendNow` (~4098), insert before `let checkpointPrompt = Self.textPreview(of: blocks)`:

```swift
            let symbolResolutions = await ACPSymbolReference.resolve(
                blocks: blocks, worktreeRoot: URL(fileURLWithPath: self.worktreePath))
```

Change its `recordUserPrompt` attachments argument the same way, and replace its `var wireBlocks = await self.expandingSessionReferences(Self.hydrate(...))` with:

```swift
                var wireBlocks = ACPSymbolReference.replacingReferences(
                    in: await self.expandingSessionReferences(Self.hydrate(
                        blocks,
                        promptCapabilities: promptCapabilities,
                        worktreePath: self.worktreePath
                    )),
                    resolutions: symbolResolutions,
                    embeddedContext: promptCapabilities.embeddedContext,
                    worktreeRoot: URL(fileURLWithPath: self.worktreePath))
```

If `worktreePath` is not accessible at the insertion point in `sendNow` (it is read inside the later `do` block), capture `let worktreeRoot = URL(fileURLWithPath: self.worktreePath)` at the top of the task body and use it in both places.

A retry whose prompt is already recorded (`transcriptRecorded == true`, or `recordUserPrompt == false` with a known message) skips recording, but the wire still uses the fresh resolution. Re-stamp the recorded message so its snapshot describes what is actually sent. Add to `ACPSession`, beside `attachCheckpoint`:

```swift
    /// Re-stamps symbol snapshots on an already-recorded user message when a
    /// retried delivery resolved its symbols again. Returns the message index
    /// when a snapshot changed, so the caller can persist it.
    func replaceSymbolSnapshots(
        inUserMessage id: UUID, resolutions: [String: ACPSymbolReference.Resolution]
    ) -> Int? {
        guard !resolutions.isEmpty,
              let index = transcript.messages.firstIndex(where: {
                  guard case .user(let messageID, _, _, _, _, _) = $0 else { return false }
                  return messageID == id
              }),
              case .user(let messageID, let remoteMessageID, let text, let attachments, let delegatedSource, let pastedSpans) = transcript.messages[index]
        else { return nil }
        let updated = ACPSymbolReference.attachingSnapshots(to: attachments, resolutions: resolutions)
        guard updated.map(\.symbol) != attachments.map(\.symbol) else { return nil }
        transcript.replaceMessage(at: index, with: .user(
            id: messageID, messageId: remoteMessageID, text: text, attachments: updated,
            delegatedSource: delegatedSource, pastedSpans: pastedSpans
        ))
        return index
    }
```

In `sendNow`, inside the `MainActor.run` block, in the branch where `shouldRecord` is false, before `self.resetStreamingPersistBuffer()`:

```swift
                let recordedID = recordedUserMessageID
                    ?? queuedItemId.flatMap { self.session.normalQueuedTurnUserMessageIDs[$0] }
                if let recordedID,
                   let index = self.session.replaceSymbolSnapshots(inUserMessage: recordedID, resolutions: symbolResolutions) {
                    self.persistIndices([index])
                }
```

In the steer path, in the `else` of `if recordUserPrompt { … }` (add one if absent), do the same with `recordedUserMessageID`. A retry with no known message id leaves the old snapshot; the queue does not carry one in that case today.

- [ ] **Step 5: Run tests to verify they pass**

Run with `-only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPImageBlocksTests -only-testing AlasTests/ACPSessionReferenceTests -only-testing AlasTests/ACPSessionTests`.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPSymbolReference.swift Alas/Sources/ACP/Session/ACPSessionRunner.swift \
  Alas/Sources/ACP/Session/ACPSession.swift AlasTests/ACP/Session/ACPSymbolReferenceTests.swift \
  AlasTests/ACP/Session/ACPImageBlocksTests.swift AlasTests/ACP/Session/ACPSessionTests.swift
git commit -m "feat(acp): resolve symbol mentions at send time and expand them for the agent"
```

---

### Task 7: Symbols in the `@` picker

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPMentionPicker.swift` (view state, `search`, `list`, rows, `handleKey`, `rescheduleRank`, new `populateSymbols`, frame size)
- Modify: `Alas/Sources/ACP/UI/ACPComposer.swift` (`ACPInputField` property, `Coordinator` property, `presentMentionPopover` 1579–1600, `ACPMentionPanel` 2809–2860, new `insertSymbolMention` near 2705)
- Modify: `Alas/Sources/ACP/UI/ACPComposerShell.swift` (init + forwarding at 189–261, 412–434)
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift` (composer construction at 740–784; new `symbolMentions` near 931)

**Interfaces:**
- Consumes: Task 3 `AppState.symbolIndex`, `SymbolSource`, Task 4 logic, Task 5 `ACPSymbolReference.Target`/`uri(for:)`.
- Produces:
  - `struct ACPSymbolMentionSource { let index: (@MainActor () async -> AsyncStream<WorktreeSymbolIndex.Snapshot>)?; let fileSymbols: @Sendable (_ fileQuery: String) async -> [SymbolEntry] }`
  - `ACPNSTextView.insertSymbolMention(_ entry: SymbolEntry, includeCode: Bool) -> Bool`

This task is UI wiring over tested logic; no new automated test (testing policy). It is verified by the smoke run in Task 10.

- [ ] **Step 1: Add the source type** (top of `ACPMentionSymbols.swift`)

```swift
/// Symbols the `@` picker offers for one worktree.
struct ACPSymbolMentionSource {
    /// Project-wide index; nil for remote worktrees.
    let index: (@MainActor () async -> AsyncStream<WorktreeSymbolIndex.Snapshot>)?
    /// For `File.swift#name`: the symbols of the worktree file that best
    /// matches `fileQuery`. Works local and remote.
    let fileSymbols: @Sendable (_ fileQuery: String) async -> [SymbolEntry]
}
```

- [ ] **Step 2: Build it in `ACPTabView`** (next to `sessionMentions`)

```swift
    private var symbolMentions: ACPSymbolMentionSource {
        let root = worktree.path
        return ACPSymbolMentionSource(
            index: root.isRemoteAlasPath ? nil : { [state] in
                // Fresh listing on every open, like the file provider does;
                // nil on a failed enumeration: the index replays its cache.
                await state.fileIndex.invalidate(forWorktreePath: root)
                let files = (try? await state.fileIndex.entries(forWorktreePath: root))?.map(\.relativePath)
                return await state.symbolIndex.updates(root: root, files: files)
            },
            fileSymbols: { [state] fileQuery in
                // From FileIndex paths, not the picker's file list: that list
                // drops remote entries, and drill-down is remote's only route.
                let entries = (try? await state.fileIndex.entries(forWorktreePath: root)) ?? []
                let urls = entries.map { root.appendingPathComponent($0.relativePath) }
                guard let best = MentionFuzzy.rank(files: urls, query: fileQuery, limit: 1, relativeTo: root).first
                else { return [] }
                let relativePath = String(best.path.dropFirst(root.path.count + 1))
                guard let source = await SymbolSource.read(root: root, relativePath: relativePath) else { return [] }
                return SymbolExtractor.symbols(in: source, relativePath: relativePath)
            }
        )
    }
```

Pass `symbolMentions: symbolMentions` to `ACPComposer(...)` after `sessionMentions:`.

- [ ] **Step 3: Thread it through**

`ACPComposerShell`: add `let symbolMentions: ACPSymbolMentionSource?`, an init parameter `symbolMentions: ACPSymbolMentionSource? = nil` after `sessionMentions`, assign it, and pass `symbolMentions: symbolMentions` to `ACPInputField` after `sessionMentions:`.

`ACPInputField`: add `var symbolMentions: ACPSymbolMentionSource? = nil` after `sessionMentions`. In `makeNSView` and `updateNSView`, next to `context.coordinator.sessionMentions = sessionMentions`, add `context.coordinator.symbolMentions = symbolMentions`. `Coordinator`: add `var symbolMentions: ACPSymbolMentionSource?` after `sessionMentions`.

`ACPMentionPanel.init`: add parameters `symbolMentions: ACPSymbolMentionSource? = nil` and `onPickSymbol: @escaping (SymbolEntry, Bool) -> Void = { _, _ in }`, change both `360, 280` sizes (content rect and host frame) to `440, 330`, and pass to the view:

```swift
            symbolMentions: symbolMentions,
            onPickSymbol: { [weak self] symbol, includeCode in
                self?.close()
                onPickSymbol(symbol, includeCode)
            },
```

`presentMentionPopover`: add `symbolMentions: coord.symbolMentions,` and

```swift
            onPickSymbol: { [weak self] symbol, includeCode in
                self?.insertSymbolMention(symbol, includeCode: includeCode)
            },
```

Next to `insertSessionMention`:

```swift
    @discardableResult
    func insertSymbolMention(_ entry: SymbolEntry, includeCode: Bool) -> Bool {
        let target = ACPSymbolReference.Target(entry: entry, includeCode: includeCode)
        return insertMention(displayName: target.displayName, uri: ACPSymbolReference.uri(for: target))
    }
```

- [ ] **Step 4: Picker state and loading** (`ACPMentionPickerView`)

Add properties and state:

```swift
    var symbolMentions: ACPSymbolMentionSource? = nil
    var onPickSymbol: (SymbolEntry, Bool) -> Void = { _, _ in }

    @State private var scope: MentionScope = .all
    @State private var allSymbols: [SymbolEntry] = []
    @State private var symbolProgress: (indexed: Int, total: Int)? = nil
    @State private var symbolTask: Task<Void, Never>?
```

Change the body's frame to `.frame(width: 440, height: 330)`, insert `scopeBar` between `search` and the divider, append `footer` after `list`, and extend `.onAppear` with `populateSymbols()` plus `.onDisappear { symbolTask?.cancel() }`.

```swift
    private func populateSymbols() {
        guard let index = symbolMentions?.index else { return }
        symbolTask = Task { @MainActor in
            for await snapshot in await index() {
                allSymbols = snapshot.symbols
                symbolProgress = snapshot.isComplete ? nil : (snapshot.indexedFiles, snapshot.totalFiles)
                rescheduleRank(preserveHighlight: true)
            }
            symbolProgress = nil
        }
    }
```

In `.onChange(of: query)` keep `highlight = 0` and call `rescheduleRank(preserveHighlight: false)`. Change `populateSessions` and `populateFiles` to call `rescheduleRank(preserveHighlight: true)`.

- [ ] **Step 5: Ranking per scope** (replace `rescheduleRank`)

```swift
    private func rescheduleRank(preserveHighlight: Bool) {
        rankTask?.cancel()
        rankGeneration &+= 1
        let gen = rankGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = allFiles
        let symbols = allSymbols
        let root = worktreeRoot
        let scope = scope
        let isAbsolute = !root.isRemoteAlasPath && MentionAbsolutePath.isAbsolute(query: q)
        let sessionItems = isAbsolute || !(scope == .all || scope == .sessions)
            ? []
            : MentionSessionRanking.rank(sessions, query: q).map(MentionPickerItem.session)
        let fileSymbols = symbolMentions?.fileSymbols
        rankTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled { return }
            var symbolItems: [SymbolEntry] = []
            if !isAbsolute, scope == .all || scope == .symbols {
                let limit = scope == .symbols ? maxDisplay : MentionSymbolRanking.allScopeLimit
                switch MentionSymbolQuery.parse(q) {
                case .project(let text):
                    if !text.isEmpty || scope == .symbols {
                        symbolItems = MentionSymbolRanking.rank(symbols, query: text, limit: limit)
                    }
                case .file(let fileQuery, let symbolQuery):
                    if let fileSymbols {
                        symbolItems = MentionSymbolRanking.rank(await fileSymbols(fileQuery), query: symbolQuery, limit: maxDisplay)
                    }
                }
            }
            var fileItems: [URL] = []
            if scope == .all || scope == .files {
                let fileQuery: String = if case .file(let file, _) = MentionSymbolQuery.parse(q) { file } else { q }
                if q.isEmpty {
                    fileItems = Array(files.prefix(maxDisplay))
                } else {
                    fileItems = isAbsolute
                        ? MentionAbsolutePath.entries(forQuery: q, limit: maxDisplay)
                        : MentionFuzzy.rank(files: files, query: fileQuery, limit: maxDisplay, relativeTo: root)
                }
            }
            if Task.isCancelled { return }
            let items = sessionItems + symbolItems.map(MentionPickerItem.symbol) + fileItems.map(MentionPickerItem.file)
            await MainActor.run {
                guard rankGeneration == gen else { return }
                // Read the live highlight here, not before the await: the
                // user may have moved it while ranking or a drill-down read ran.
                let current = ranked.indices.contains(highlight) ? ranked[highlight] : nil
                let currentIndex = highlight
                ranked = items
                if preserveHighlight {
                    highlight = MentionPickerNavigation.index(preserving: current, fallback: currentIndex, in: items)
                }
            }
        }
    }
```

- [ ] **Step 6: Scope bar, list headers, symbol rows, footer**

```swift
    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(MentionScope.allCases) { item in
                Button {
                    scope = item
                    highlight = 0
                    rescheduleRank(preserveHighlight: false)
                } label: {
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(scope == item ? theme.color("accent").opacity(0.22) : theme.color("bg-2"))
                        .foregroundStyle(scope == item ? theme.color("accent") : theme.color("fg-faint"))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(item.shortcut), modifiers: .command)
                .help("\(item.title) (⌘\(item.shortcut))")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    @ViewBuilder
    private var footer: some View {
        let text: String? = if let progress = symbolProgress {
            "Indexing symbols… \(progress.indexed) of \(progress.total) files"
        } else if symbolMentions != nil, symbolMentions?.index == nil, scope == .symbols {
            "Project symbols aren't indexed on remote worktrees. Type File.swift#name."
        } else {
            "⏎ insert · ⌥⏎ insert with code · File.swift#name"
        }
        if let text {
            Divider().background(theme.color("line"))
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }
```

In `list`, replace the `ForEach` body so a header precedes the first item of each group:

```swift
                        ForEach(Array(ranked.enumerated()), id: \.element) { idx, item in
                            VStack(alignment: .leading, spacing: 1) {
                                if let header = groupHeader(at: idx) {
                                    Text(header)
                                        .font(.system(size: 10, weight: .medium))
                                        .tracking(0.6)
                                        .foregroundStyle(theme.color("fg-faint"))
                                        .padding(.horizontal, 10).padding(.top, idx == 0 ? 2 : 8)
                                }
                                switch item {
                                case .file(let file): row(idx: idx, file: file)
                                case .session(let session): row(idx: idx, session: session)
                                case .symbol(let symbol): row(idx: idx, symbol: symbol)
                                }
                            }
                            .id(item)
                        }
```

```swift
    private func groupHeader(at index: Int) -> String? {
        func group(_ item: MentionPickerItem) -> String {
            switch item {
            case .session: "SESSIONS"
            case .symbol: "SYMBOLS"
            case .file: "FILES"
            }
        }
        let current = group(ranked[index])
        if index > 0, group(ranked[index - 1]) == current { return nil }
        let groups = Set(ranked.map(group))
        return groups.count > 1 ? current : nil
    }

    private func row(idx: Int, symbol: SymbolEntry) -> some View {
        let isOn = idx == highlight
        return Button { onPickSymbol(symbol, false) } label: {
            HStack(spacing: 8) {
                Text(symbol.kind.badgeLetter)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: symbol.kind.badgeForeground))
                    .frame(width: 16, height: 16)
                    .background(Color(nsColor: symbol.kind.badgeBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                (Text(symbol.container.map { $0 + "." } ?? "").foregroundStyle(theme.color("fg-faint"))
                    + Text(symbol.kind.isCallable ? symbol.name + "()" : symbol.name).fontWeight(.semibold))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                if MentionSymbolRanking.isTestPath(symbol.relativePath) {
                    Text("test")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.color("fg-faint"))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.color("line"), lineWidth: 0.5))
                }
                Spacer(minLength: 8)
                Text(symbol.relativePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                scrollOnHighlightChange = false
                highlight = idx
            }
        }
    }
```

`badgeForeground`/`badgeBackground` are needed here. Create `Alas/Sources/ACP/UI/ACPSymbolChipCell.swift` now with only the `extension SymbolKind { … }` block from Task 8 Step 1; Task 8 adds the cell class to the same file.

Update the search placeholder to `"Search files, symbols & sessions… (/ or ~/ to browse)"` when `sessionsProvider != nil`, otherwise `"Search files, symbols & folders… (/ or ~/ to browse)"`.

- [ ] **Step 7: Keys** (replace the `.return, .tab` case in `handleKey`)

```swift
        case .return, .tab:
            guard ranked.indices.contains(highlight) else { return .handled }
            switch ranked[highlight] {
            case .session(let session):
                onPickSession(session)
            case .symbol(let symbol):
                onPickSymbol(symbol, press.key == .return && press.modifiers.contains(.option))
            case .file(let file) where press.key == .tab && isAbsoluteQuery && file.hasDirectoryPath:
                query = MentionAbsolutePath.query(entering: file)
            case .file(let file):
                onPick(file)
            }
            return .handled
```

- [ ] **Step 8: Build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -quiet build
```

Expected: BUILD SUCCEEDED. Then re-run `-only-testing AlasTests/ACPMentionPickerTests` to confirm nothing regressed.

- [ ] **Step 9: Commit**

```bash
xcodegen
git add Alas/Sources/ACP/UI Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): offer project symbols in the @ picker"
```

---

### Task 8: Style A badge and hover text

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPSymbolChipCell.swift` (created in Task 7 with the `SymbolKind` color extension)
- Modify: `Alas/Sources/ACP/UI/ACPMentionChipAttachment.swift` (`init` at 12–19; `ACPFileMentionHoverController.scheduleShow` card arguments)

**Interfaces:**
- Consumes: `ACPSymbolReference.target(fromURI:)`, `ACPMentionChipMetrics`.
- Produces: `SymbolKind.badgeForeground`, `SymbolKind.badgeBackground` (`NSColor`); `ACPSymbolChipCell(target:)`.

Drawing only; no automated test (testing policy). Verified in Task 10.

- [ ] **Step 1: Implement the cell**

`Alas/Sources/ACP/UI/ACPSymbolChipCell.swift` (full file; the extension already exists from Task 7):

```swift
import AppKit

extension SymbolKind {
    var badgeForeground: NSColor {
        switch self {
        case .class, .interface, .module, .type: NSColor(srgbRed: 0.77, green: 0.65, blue: 1.0, alpha: 1)
        case .struct, .enum: NSColor(srgbRed: 0.61, green: 0.88, blue: 0.54, alpha: 1)
        case .function, .method, .macro: NSColor(srgbRed: 0.36, green: 0.85, blue: 1.0, alpha: 1)
        case .property, .constant: NSColor(srgbRed: 1.0, green: 0.77, blue: 0.42, alpha: 1)
        }
    }

    var badgeBackground: NSColor { badgeForeground.withAlphaComponent(0.2) }
}

/// Style A symbol badge: kind icon, dimmed container, name in the code font,
/// and `{ } N lines` with a filled background when code is included.
final class ACPSymbolChipCell: NSTextAttachmentCell {
    let target: ACPSymbolReference.Target
    private static let iconSize: CGFloat = 13
    private static let iconFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)

    init(target: ACPSymbolReference.Target) {
        self.target = target
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    private var containerText: String { target.container.map { $0 + "." } ?? "" }
    private var nameText: String { target.kind.isCallable ? target.name + "()" : target.name }
    private var codeText: String? {
        guard target.includeCode else { return nil }
        let count = target.lineRange.count
        return count > ACPSymbolReference.maxExcerptLines
            ? "{ } \(ACPSymbolReference.maxExcerptLines)+ lines"
            : "{ } \(count) line\(count == 1 ? "" : "s")"
    }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    override var cellSize: NSSize {
        var total = 4 + Self.iconSize + 5
        total += width(containerText + nameText, ACPMentionChipMetrics.labelFont)
        if let codeText { total += 6 + width(codeText, Self.codeFont) }
        return NSSize(width: total + 7, height: ACPMentionChipMetrics.height)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: ACPMentionChipMetrics.baselineOffset) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(origin: NSPoint(x: 0, y: ACPMentionChipMetrics.baselineOffset), size: cellSize)
    }

    override func highlight(_ flag: Bool, withFrame frame: NSRect, in controlView: NSView?) {
        draw(withFrame: frame, in: controlView)
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let accent = NSColor.controlAccentColor
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        accent.withAlphaComponent(target.includeCode ? 0.3 : 0.14).setFill()
        pill.fill()
        accent.withAlphaComponent(target.includeCode ? 0.9 : 0.45).setStroke()
        pill.lineWidth = 0.75
        pill.stroke()

        var x = frame.minX + 4
        let iconRect = NSRect(x: x, y: frame.midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
        target.kind.badgeBackground.setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 3, yRadius: 3).fill()
        let letter = target.kind.badgeLetter as NSString
        let letterAttrs: [NSAttributedString.Key: Any] = [.font: Self.iconFont, .foregroundColor: target.kind.badgeForeground]
        let letterSize = letter.size(withAttributes: letterAttrs)
        letter.draw(at: NSPoint(x: iconRect.midX - letterSize.width / 2, y: iconRect.midY - letterSize.height / 2),
                    withAttributes: letterAttrs)
        x = iconRect.maxX + 5

        let labelY = ACPMentionChipMetrics.labelOriginY(in: frame)
        let label = accent.chipLabelColor
        let dim: [NSAttributedString.Key: Any] = [.font: ACPMentionChipMetrics.labelFont, .foregroundColor: label.withAlphaComponent(0.6)]
        let strong: [NSAttributedString.Key: Any] = [.font: ACPMentionChipMetrics.labelFont, .foregroundColor: label]
        (containerText as NSString).draw(at: NSPoint(x: x, y: labelY), withAttributes: dim)
        x += width(containerText, ACPMentionChipMetrics.labelFont)
        (nameText as NSString).draw(at: NSPoint(x: x, y: labelY), withAttributes: strong)
        x += width(nameText, ACPMentionChipMetrics.labelFont)

        if let codeText {
            x += 3
            accent.withAlphaComponent(0.6).setStroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: x, y: frame.minY + 4))
            divider.line(to: NSPoint(x: x, y: frame.maxY - 4))
            divider.lineWidth = 0.5
            divider.stroke()
            x += 3
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.codeFont, .foregroundColor: label]
            let size = (codeText as NSString).size(withAttributes: attrs)
            (codeText as NSString).draw(at: NSPoint(x: x, y: frame.midY - size.height / 2), withAttributes: attrs)
        }
    }
}
```

If the composer text view is not flipped and the icon or code label render upside-down, mirror `labelOriginY`'s convention used by `ACPMentionChipCell` (it assumes a flipped context).

- [ ] **Step 2: Use it for symbol links** (`ACPMentionChipAttachment.init`)

```swift
        super.init(data: nil, ofType: nil)
        if let target = ACPSymbolReference.target(fromURI: uri) {
            self.attachmentCell = ACPSymbolChipCell(target: target)
        } else {
            self.attachmentCell = ACPMentionChipCell(displayName: displayName)
        }
```

- [ ] **Step 3: Hover card text for symbols** (inside `scheduleShow`'s work item, replacing the `ACPFileMentionHoverCard(...)` arguments)

```swift
            let symbol = ACPSymbolReference.target(fromURI: next.uri)
            let location: String = if let symbol {
                "\(symbol.path):\(symbol.lineRange.lowerBound + 1)–\(symbol.lineRange.upperBound + 1)"
                    + (symbol.includeCode ? " · code included" : "")
            } else if let sessionId {
                "Agent session \(sessionId)"
            } else {
                isFile ? (url?.path ?? next.uri) : next.uri
            }
            let hosting = NSHostingController(
                rootView: ACPFileMentionHoverCard(
                    name: attachment.displayName,
                    location: location,
                    systemImage: symbol != nil ? "curlybraces"
                        : sessionId != nil ? "bubble.left.and.bubble.right" : isFile ? "doc.text" : "link"
                )
            )
```

- [ ] **Step 4: Build**

Run the build command from Task 7 Step 8. Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Regenerate the project and commit**

```bash
xcodegen
git add Alas/Sources/ACP/UI/ACPSymbolChipCell.swift Alas/Sources/ACP/UI/ACPMentionChipAttachment.swift \
  Alas/Sources/ACP/UI/ACPMentionPicker.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): draw symbol mentions as kind-icon badges"
```

---

### Task 9: Sent symbols in the transcript

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPFileChip.swift`
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift:36-47`
- Modify: `Alas/Sources/ACP/UI/ACPSubagentRowView.swift:236-244`
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift:526-541` (`onOpenTranscriptLink`)
- Modify: `Alas/Sources/ACP/Session/ACPSymbolReference.swift` (link helper)
- Test: `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift`

**Interfaces:**
- Consumes: `ACPMessage.Attachment.symbol`, `ACPSymbolReference.target(fromURI:)`/`uri(for:)`, the per-row `\.openURL` (routes to `ACPTabView`'s `onOpenTranscriptLink`, which knows the worktree).
- Produces: `FileChip.action: (() -> Void)?`; `ACPSymbolReference.openURL(for:snapshot:) -> URL?`.

The chip opens an `alas-symbol://` URL carrying the sent line range. `ACPTabView` claims that scheme and calls `AppState.openFile` with the worktree id, which handles local and remote worktrees and reveals the full range. `AppState.transcriptLinkRoute` is not used: it only resolves remote paths given as absolute paths.

- [ ] **Step 1: Write the failing test** (add to `ACPSymbolReferenceTests`)

```swift
    @Test("transcript links carry the sent range, falling back to the inserted one")
    func openURL() throws {
        let target = ACPSymbolReference.Target(path: "Package.swift", name: "a", kind: .function,
                                               container: nil, lineRange: 4...6, includeCode: true)
        let inserted = try #require(ACPSymbolReference.openURL(for: target, snapshot: nil))
        #expect(ACPSymbolReference.target(fromURI: inserted.absoluteString)?.lineRange == 4...6)
        let snapshot = ACPSymbolSnapshot(lineRange: 9...12, contentHash: "", excerpt: nil, truncated: false, found: true)
        let sent = try #require(ACPSymbolReference.openURL(for: target, snapshot: snapshot))
        #expect(ACPSymbolReference.target(fromURI: sent.absoluteString)?.lineRange == 9...12)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run with `-only-testing AlasTests/ACPSymbolReferenceTests`.
Expected: build failure, `has no member 'openURL'`.

- [ ] **Step 3: Implement**

Append to `enum ACPSymbolReference`:

```swift
    /// URL a transcript chip opens: the symbol's link, moved to the range
    /// that was sent. `ACPTabView` routes it to the editor.
    static func openURL(for target: Target, snapshot: ACPSymbolSnapshot?) -> URL? {
        let sent = Target(path: target.path, name: target.name, kind: target.kind, container: target.container,
                          lineRange: snapshot?.lineRange ?? target.lineRange, includeCode: target.includeCode)
        return URL(string: uri(for: sent))
    }
```

`ACPTabView.swift`, at the top of the `onOpenTranscriptLink: { url in` closure (before the `switch`):

```swift
                if let target = ACPSymbolReference.target(fromURI: url.absoluteString) {
                    state.openFile(
                        relativePath: target.path,
                        worktreeId: worktree.id,
                        revealLine: target.lineRange.lowerBound,
                        revealEndLine: target.lineRange.upperBound,
                        revealCharacter: 0
                    )
                    return true
                }
```

`ACPFileChip.swift`: add `var action: (() -> Void)? = nil` after `iconSystemName`, rename the current `body` to `private var label: some View`, and add:

```swift
    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
```

`ACPTranscriptMessageRows.swift`: add `@Environment(\.openURL) private var openURL` to `UserMessageRow`. Change `ForEach(others, id: \.uri) { a in` to `ForEach(Array(others.enumerated()), id: \.offset) { _, a in`: the same symbol mentioned twice has the same URI, and duplicate ids collapse chips (the image row already keys by index for the same reason). Then replace the `FileChip(...)` inside it with:

```swift
                                if let target = ACPSymbolReference.target(fromURI: a.uri) {
                                    FileChip(
                                        path: target.displayName,
                                        lines: "\((target.path as NSString).lastPathComponent):\((a.symbol?.lineRange ?? target.lineRange).lowerBound + 1)",
                                        iconSystemName: "curlybraces",
                                        action: {
                                            if let url = ACPSymbolReference.openURL(for: target, snapshot: a.symbol) {
                                                openURL(url)
                                            }
                                        }
                                    )
                                } else {
                                    FileChip(
                                        path: a.name ?? a.uri,
                                        lines: nil,
                                        iconSystemName: ACPSessionReference.sessionId(fromURI: a.uri) == nil
                                            ? "at" : "bubble.left.and.bubble.right"
                                    )
                                }
```

Apply the same `ForEach` change and branch in `ACPSubagentPromptRow` (with its own `@Environment(\.openURL) private var openURL`), keeping its existing non-symbol `FileChip(path:lines:iconSystemName: "at")`.

- [ ] **Step 4: Run tests and build**

Run with `-only-testing AlasTests/ACPSymbolReferenceTests`, then the build command. Expected: PASS, BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPFileChip.swift Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift \
  Alas/Sources/ACP/UI/ACPSubagentRowView.swift Alas/Sources/ACP/UI/ACPTabView.swift \
  Alas/Sources/ACP/Session/ACPSymbolReference.swift AlasTests/ACP/Session/ACPSymbolReferenceTests.swift
git commit -m "feat(acp): open sent symbol mentions from the transcript"
```

---

### Task 10: Verification and measurement

**Files:**
- Modify (only if the measurement requires it): `docs/plans/2026-10-06-composer-symbol-mentions-design.md` ("Storage" bullet)

- [ ] **Step 1: Run every affected suite**

```bash
(cd ThirdParty/treesitter-pack && cargo test)
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/SymbolExtractorTests -only-testing AlasTests/LanguageRegistryTests \
  -only-testing AlasTests/WorktreeSymbolIndexTests -only-testing AlasTests/ACPMentionPickerTests \
  -only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPMessageTests \
  -only-testing AlasTests/ACPImageBlocksTests -only-testing AlasTests/ACPSessionReferenceTests \
  -only-testing AlasTests/ACPComposerDraftTests -only-testing AlasTests/TreeSitterHighlighterTests \
  -only-testing AlasTests/ACPSessionTests test
```

Expected: all PASS; the summary names 11 suites.

- [ ] **Step 2: Smoke-run the app**

Build and launch the Debug app, open an ACP tab on this Alas worktree, and check, in order:

1. Type `@restore`. Symbols appear in a SYMBOLS group above FILES; the footer shows indexing progress on first open, then the key hints.
2. ⌘3 shows only symbols; ⌘1 returns to All; ⇥ still inserts the highlighted row.
3. While indexing, the highlighted row does not change under the pointer as results arrive.
4. ⏎ on `SessionManager…` (or any method) inserts a style A badge; ⌥⏎ inserts the filled badge with `{ } N lines`. Hovering shows `path:start–end`.
5. `LSPClient.swift#docum` lists that file's symbols only.
6. Send a prompt with one plain and one code badge to an agent. The transcript shows two `curlybraces` chips; clicking one opens the editor with the symbol's lines revealed. Repeat steps 5–6 on a remote (SSH) worktree: drill-down lists symbols and the chip opens the remote file.
7. Inspect what the agent received (agent log or ask the agent to quote it): the reference line, and the code as a fence or resource.
8. In `~/Library/Application Support/Alas/acp-sessions`, the persisted user message's attachments include `symbol` with `found: true` and a 64-character `contentHash`.

- [ ] **Step 3: Measure the cold index**

With Console filtered on subsystem `io.nlopez.alas`, category `symbols.index`, open the picker on this worktree after relaunching the app. Record the `refreshed … in N s` line. If N exceeds 5 seconds on Alas, add an on-disk cache task to the phase 2 plan and note the number in the design's "Storage" bullet; otherwise note the measured value there.

- [ ] **Step 4: Commit any doc update**

```bash
git add docs/plans/2026-10-06-composer-symbol-mentions-design.md
git commit -m "docs: record symbol index cold build time"
```
