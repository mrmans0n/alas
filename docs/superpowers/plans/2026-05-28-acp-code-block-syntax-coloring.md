# ACP Code Block Syntax Coloring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add theme-consistent syntax coloring to fenced code blocks rendered in ACP chat.

**Architecture:** Keep ACP markdown parsing unchanged and add a focused code-block highlighter helper used by `CodeBlockView`. The helper maps Markdown fence labels to the existing `TreeSitterHighlighter` extension API, builds an `NSAttributedString`, and applies `EditorTheme` colors to valid highlight spans while preserving plain text behavior for unknown languages.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSAttributedString`, Swift Testing, existing `TreeSitterHighlighter`, existing `EditorTheme`.

---

## File Structure

- Create `Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift`
  - Owns ACP-specific fence-label normalization.
  - Builds attributed code strings for ACP code blocks.
  - Has no SwiftUI view responsibility.
- Modify `Alas/Sources/ACP/UI/ACPMarkdownText.swift`
  - Replaces `Text(code)` in `CodeBlockView` with attributed highlighted text.
  - Keeps layout, copy behavior, scrolling, selection, spacing, and code block chrome unchanged.
- Modify `Alas/Sources/Code/Highlight/TreeSitterHighlighter.swift`
  - Extends the existing private regex fallback for chat-only pseudo-extensions: `diff`, `patch`, `html`, `xml`, `css`, `scss`, `sass`, `sql`.
  - Does not add Tree-sitter packages.
- Create `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift`
  - Tests alias mapping and attributed output.
- Modify `AlasTests/Code/Highlight/TreeSitterHighlighterTests.swift`
  - Tests the regex fallback additions through the public `TreeSitterHighlighter.highlight` API.

---

### Task 1: ACP Code Block Highlighter Helper

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift`
- Create: `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift`

- [ ] **Step 1: Write failing tests for ACP language mapping and attributed output**

Create `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift`:

```swift
import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("ACP code block highlighter")
struct ACPCodeBlockHighlighterTests {
    @Test("maps common ACP fence labels to highlighter extensions")
    func mapsFenceLabels() {
        #expect(ACPCodeLanguage.highlighterExtension(for: "swift") == "swift")
        #expect(ACPCodeLanguage.highlighterExtension(for: "python") == "py")
        #expect(ACPCodeLanguage.highlighterExtension(for: "typescript") == "ts")
        #expect(ACPCodeLanguage.highlighterExtension(for: "javascript") == "js")
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
}
```

- [ ] **Step 2: Run the new test file to verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPCodeBlockHighlighterTests
```

Expected: FAIL because `ACPCodeLanguage` and `ACPCodeBlockHighlighter` do not exist.

- [ ] **Step 3: Implement the helper**

Create `Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift`:

```swift
import AppKit
import Foundation

enum ACPCodeLanguage {
    static func highlighterExtension(for label: String?) -> String? {
        guard let label else { return nil }
        var normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let first = normalized.split(whereSeparator: { $0.isWhitespace }).first {
            normalized = String(first)
        }
        normalized = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            .lowercased()

        if normalized.hasPrefix("{."), normalized.hasSuffix("}") {
            normalized = String(normalized.dropFirst(2).dropLast())
        } else if normalized.hasPrefix(".") {
            normalized = String(normalized.dropFirst())
        }

        switch normalized {
        case "swift": return "swift"
        case "py", "python": return "py"
        case "js", "javascript", "mjs", "cjs": return "js"
        case "jsx": return "jsx"
        case "ts", "typescript": return "ts"
        case "tsx": return "tsx"
        case "sh", "bash", "shell", "zsh", "console", "terminal": return "sh"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "rs", "rust": return "rs"
        case "go", "golang": return "go"
        case "java": return "java"
        case "kt", "kotlin": return "kt"
        case "kts": return "kts"
        case "c": return "c"
        case "h": return "h"
        case "cpp", "c++": return "cpp"
        case "cc": return "cc"
        case "cxx": return "cxx"
        case "hpp": return "hpp"
        case "diff", "patch": return "diff"
        case "html": return "html"
        case "xml": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "sass": return "sass"
        case "sql": return "sql"
        default: return nil
        }
    }
}

enum ACPCodeBlockHighlighter {
    static func attributedString(
        code: String,
        language: String?,
        theme: Theme,
        fontSize: CGFloat = 12
    ) -> NSAttributedString {
        let editorTheme = EditorTheme(theme: theme)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: editorTheme.defaultFG,
        ]
        let attributed = NSMutableAttributedString(string: code, attributes: baseAttributes)
        guard !code.isEmpty,
              let ext = ACPCodeLanguage.highlighterExtension(for: language) else {
            return attributed
        }

        let length = (code as NSString).length
        let spans = TreeSitterHighlighter.highlight(source: code, fileExtension: ext)
        for span in spans {
            guard span.range.location != NSNotFound,
                  span.range.location >= 0,
                  NSMaxRange(span.range) <= length else {
                continue
            }
            attributed.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
        }
        return attributed
    }
}
```

- [ ] **Step 4: Run the helper tests to verify they pass**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPCodeBlockHighlighterTests
```

Expected: PASS.

- [ ] **Step 5: Commit Task 1**

```bash
git add Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift
git commit -m "feat(acp): add code block highlighter helper"
```

---

### Task 2: Chat-Oriented Regex Fallback Extensions

**Files:**
- Modify: `Alas/Sources/Code/Highlight/TreeSitterHighlighter.swift`
- Modify: `AlasTests/Code/Highlight/TreeSitterHighlighterTests.swift`

- [ ] **Step 1: Write failing tests for chat-only fallback extensions**

Append these tests to `AlasTests/Code/Highlight/TreeSitterHighlighterTests.swift` inside `TreeSitterHighlighterTests`:

```swift
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
```

- [ ] **Step 2: Run the fallback tests to verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/TreeSitterHighlighterTests/diffFallbackBasics -only-testing:AlasTests/TreeSitterHighlighterTests/chatFallbackBasics
```

Expected: FAIL because these extensions currently return no spans.

- [ ] **Step 3: Extend the regex fallback**

In `Alas/Sources/Code/Highlight/TreeSitterHighlighter.swift`, update `RegexFallbackHighlighter.highlight(source:fileExtension:)` so it dispatches special fallback lexers before the generic regex:

```swift
    static func highlight(source: String, fileExtension ext: String) -> [HighlightSpan] {
        let language = language(forFileExtension: ext)
        guard language != "plain" else { return [] }
        switch language {
        case "diff": return diffSpans(source: source)
        case "markup": return markupSpans(source: source)
        default: break
        }

        let keywords = keywordSet(for: language)
        let pattern = #"(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var spans: [HighlightSpan] = []
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match else { return }
            let text = nsSource.substring(with: match.range)
            let capture: HighlightCapture
            if match.range(at: 1).location != NSNotFound {
                capture = .comment
            } else if match.range(at: 2).location != NSNotFound {
                capture = .string
            } else if match.range(at: 3).location != NSNotFound {
                capture = .number
            } else if keywords.contains(text) || keywords.contains(text.lowercased()) {
                capture = .keyword
            } else if text.first?.isUppercase == true {
                capture = .type
            } else {
                capture = .plain
            }
            if capture != .plain {
                spans.append(HighlightSpan(range: match.range, capture: capture))
            }
        }
        return spans
    }
```

Add these private helpers inside `RegexFallbackHighlighter`:

```swift
    private static func diffSpans(source: String) -> [HighlightSpan] {
        let pattern = #"(?m)^(@@.*@@|diff --git .*$|index .*$|--- .*$|\+\+\+ .*$|\+.*$|-.*$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var spans: [HighlightSpan] = []
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match else { return }
            let text = nsSource.substring(with: match.range)
            let capture: HighlightCapture
            if text.hasPrefix("+"), !text.hasPrefix("+++") {
                capture = .string
            } else if text.hasPrefix("-"), !text.hasPrefix("---") {
                capture = .comment
            } else {
                capture = .keyword
            }
            spans.append(HighlightSpan(range: match.range, capture: capture))
        }
        return spans
    }

    private static func markupSpans(source: String) -> [HighlightSpan] {
        let pattern = #"(<!--[\s\S]*?-->)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(<\/?[A-Za-z][A-Za-z0-9:-]*)|([A-Za-z_:][A-Za-z0-9_:.-]*)(?=\=)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var spans: [HighlightSpan] = []
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
            guard let match else { return }
            let capture: HighlightCapture
            if match.range(at: 1).location != NSNotFound {
                capture = .comment
            } else if match.range(at: 2).location != NSNotFound {
                capture = .string
            } else if match.range(at: 3).location != NSNotFound {
                capture = .keyword
            } else if match.range(at: 4).location != NSNotFound {
                capture = .attribute
            } else {
                capture = .plain
            }
            if capture != .plain {
                spans.append(HighlightSpan(range: match.range, capture: capture))
            }
        }
        return spans
    }
```

Update `language(forFileExtension:)`:

```swift
    private static func language(forFileExtension ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "rs": return "rust"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "py": return "python"
        case "ts", "tsx", "js", "jsx": return "ts"
        case "kt", "kts": return "kotlin"
        case "diff", "patch": return "diff"
        case "html", "xml": return "markup"
        case "css", "scss", "sass": return "css"
        case "sql": return "sql"
        default: return "plain"
        }
    }
```

Extend `keywordSet(for:)` with CSS and SQL:

```swift
        case "css":
            return [
                "display", "flex", "grid", "block", "inline", "none", "color", "background", "border",
                "margin", "padding", "position", "relative", "absolute", "fixed", "var", "calc",
                "media", "import", "font", "width", "height", "min", "max"
            ]
        case "sql":
            return [
                "select", "from", "where", "join", "inner", "left", "right", "full", "outer", "on",
                "insert", "into", "update", "delete", "values", "set", "create", "alter", "drop",
                "table", "view", "index", "and", "or", "not", "null", "true", "false", "group",
                "by", "order", "having", "limit", "offset", "as", "distinct"
            ]
```

- [ ] **Step 4: Run the fallback tests to verify they pass**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/TreeSitterHighlighterTests/diffFallbackBasics -only-testing:AlasTests/TreeSitterHighlighterTests/chatFallbackBasics
```

Expected: PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git add Alas/Sources/Code/Highlight/TreeSitterHighlighter.swift AlasTests/Code/Highlight/TreeSitterHighlighterTests.swift
git commit -m "feat(code): extend regex highlighting fallbacks"
```

---

### Task 3: Wire Highlighting Into ACP Code Blocks

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPMarkdownText.swift`
- Modify: `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift`

- [ ] **Step 1: Add a bridge test for SwiftUI-compatible attributed output**

Append this test to `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift` inside `ACPCodeBlockHighlighterTests`:

```swift
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
```

- [ ] **Step 2: Run the ACP helper tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPCodeBlockHighlighterTests
```

Expected: PASS.

- [ ] **Step 3: Update `CodeBlockView` to render highlighted attributed text**

In `Alas/Sources/ACP/UI/ACPMarkdownText.swift`, replace this block:

```swift
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
```

with:

```swift
                Text(AttributedString(ACPCodeBlockHighlighter.attributedString(
                    code: code,
                    language: language,
                    theme: theme
                )))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
```

Keep all other `CodeBlockView` code unchanged.

- [ ] **Step 4: Run the ACP helper tests again**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPCodeBlockHighlighterTests
```

Expected: PASS.

- [ ] **Step 5: Commit Task 3**

```bash
git add Alas/Sources/ACP/UI/ACPMarkdownText.swift AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift
git commit -m "feat(acp): color chat code blocks"
```

---

### Task 4: Final Verification

**Files:**
- Verify all files changed by Tasks 1-3.

- [ ] **Step 1: Regenerate the Xcode project**

Run:

```bash
xcodegen
```

Expected: exits 0. This may be a no-op if the source tree is already picked up by folder references, but run it because project instructions require it before finishing.

- [ ] **Step 2: Build the app**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exits 0.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exits 0.

- [ ] **Step 4: Inspect the final diff**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: only intentional generated changes remain uncommitted, or the worktree is clean. Recent commits should include the task commits from this plan.

- [ ] **Step 5: Commit generated project changes if xcodegen changed them**

If `git status --short` shows changes to `Alas.xcodeproj/project.pbxproj`, run:

```bash
git add Alas.xcodeproj/project.pbxproj
git commit -m "chore: regenerate Xcode project"
```

Expected: generated project updates are committed. If `git status --short` is clean, skip this step.
