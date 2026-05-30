# ACP Code Block Syntax Coloring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align ACP fenced code block highlighting with the approved ACP-only design: Tree-sitter plus existing regex fallback for supported labels, with future-known unsupported labels remaining plain.

**Architecture:** Keep `ACPCodeBlockHighlighter` as the ACP-local adapter between chat fence labels and the shared `TreeSitterHighlighter`. The shared highlighter can keep its broader capabilities, but ACP must only request highlighting for labels approved in the ACP spec. `CodeBlockView` continues to render the original visible label and copied code unchanged.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit attributed strings, Swift Testing, existing `TreeSitterHighlighter`, `EditorTheme`, and `Theme`.

---

## File Structure

- Modify `Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift`
  - Responsibility: normalize ACP fence labels into currently supported highlighter extensions and build attributed strings for ACP code blocks.
- Modify `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift`
  - Responsibility: test ACP label mapping, supported regex fallback routing, unsupported future labels, default/plain output, and string preservation.
- No changes to `Alas/Sources/Code/Markdown/MarkdownRenderer.swift`
  - Markdown preview mapping is a fast follow and remains out of scope.
- No changes to `Alas/Sources/Code/Highlight/TreeSitterHighlighter.swift`
  - Existing shared fallback behavior remains available to other callers.

---

### Task 1: Gate ACP Fence Labels To Supported ACP Highlighting

**Files:**
- Modify: `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift`
- Modify: `Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift`

- [ ] **Step 1: Write failing label mapping tests**

Add these test methods to `ACPCodeBlockHighlighterTests`:

```swift
@Test("maps regex-backed ACP fence labels to fallback extensions")
func mapsRegexBackedFenceLabels() {
    #expect(ACPCodeLanguage.highlighterExtension(for: "diff") == "diff")
    #expect(ACPCodeLanguage.highlighterExtension(for: "patch") == "patch")
    #expect(ACPCodeLanguage.highlighterExtension(for: "html") == "html")
    #expect(ACPCodeLanguage.highlighterExtension(for: "xml") == "xml")
    #expect(ACPCodeLanguage.highlighterExtension(for: "css") == "css")
    #expect(ACPCodeLanguage.highlighterExtension(for: "scss") == "scss")
    #expect(ACPCodeLanguage.highlighterExtension(for: "sass") == "sass")
}

@Test("future-known unsupported ACP fence labels remain plain")
func futureKnownUnsupportedFenceLabelsRemainPlain() {
    #expect(ACPCodeLanguage.highlighterExtension(for: "sql") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "ruby") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "rb") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "php") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "perl") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "lua") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "elixir") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "dockerfile") == nil)
    #expect(ACPCodeLanguage.highlighterExtension(for: "ini") == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPCodeBlockHighlighterTests test
```

Expected: the new unsupported-label test fails because `sql` currently maps to `"sql"` or any newly tested future labels are not yet covered by the desired behavior.

- [ ] **Step 3: Update `ACPCodeLanguage` mapping**

In `ACPCodeLanguage.highlighterExtension(for:)`, keep supported Tree-sitter and regex-backed labels returning extensions, remove ACP `sql` highlighting, and explicitly keep future-known unsupported labels plain.

The switch should include this shape:

```swift
switch normalized {
case "swift": return "swift"
case "py", "python": return "py"
case "js", "javascript", "mjs", "cjs": return "js"
case "jsx": return "jsx"
case "ts", "typescript": return "ts"
case "tsx": return "tsx"
case "sh", "bash", "shell", "zsh", "console", "terminal": return "sh"
case "md", "markdown": return "md"
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
case "hh": return "hh"
case "hxx": return "hxx"
case "diff": return "diff"
case "patch": return "patch"
case "html": return "html"
case "xml": return "xml"
case "css": return "css"
case "scss": return "scss"
case "sass": return "sass"
case "sql", "rb", "ruby", "php", "pl", "perl", "lua", "ex", "exs", "elixir", "dockerfile", "ini":
    return nil
default:
    return nil
}
```

- [ ] **Step 4: Run focused tests and verify they pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPCodeBlockHighlighterTests test
```

Expected: `ACPCodeBlockHighlighterTests` pass.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
rtk git add Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift
rtk git commit -m "fix(acp): gate code block language highlighting"
```

---

### Task 2: Verify ACP Attributed Output For Fallback And Plain Paths

**Files:**
- Modify: `AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift`
- Modify: `Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift` only if the tests expose a defect.

- [ ] **Step 1: Add failing attributed-output tests**

Add these helpers and tests to `ACPCodeBlockHighlighterTests`:

```swift
private func foregroundColor(
    for needle: String,
    in attributed: NSAttributedString
) throws -> NSColor {
    let range = (attributed.string as NSString).range(of: needle)
    #expect(range.location != NSNotFound)
    let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    return try #require(color)
}

@Test("regex fallback labels apply non-default ACP syntax colors")
func regexFallbackLabelsApplySyntaxColors() throws {
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
    #expect(try foregroundColor(for: "<button", in: html) != editorTheme.defaultFG)
    #expect(try foregroundColor(for: "display", in: css) != editorTheme.defaultFG)
}

@Test("future-known unsupported ACP labels keep attributed output plain")
func futureKnownUnsupportedAttributedOutputRemainsPlain() throws {
    let theme = try Theme.loadBundled(id: "cool-slate")
    let editorTheme = EditorTheme(theme: theme)
    let attributed = ACPCodeBlockHighlighter.attributedString(
        code: "SELECT id FROM users WHERE active = true;",
        language: "sql",
        theme: theme
    )

    #expect(attributed.string == "SELECT id FROM users WHERE active = true;")
    #expect(try foregroundColor(for: "SELECT", in: attributed) == editorTheme.defaultFG)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail if implementation is incomplete**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPCodeBlockHighlighterTests test
```

Expected before Task 1 implementation: the SQL plain-output assertion fails. Expected after Task 1 implementation: these tests pass.

- [ ] **Step 3: Fix only defects exposed by the tests**

If the tests fail after Task 1, update `ACPCodeBlockHighlighter.attributedString` so it returns the base attributed string whenever `ACPCodeLanguage.highlighterExtension(for:)` returns nil. Preserve the existing span bounds checks:

```swift
guard !code.isEmpty,
      let ext = ACPCodeLanguage.highlighterExtension(for: language) else {
    return attributed
}
```

- [ ] **Step 4: Run focused tests and verify they pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPCodeBlockHighlighterTests test
```

Expected: `ACPCodeBlockHighlighterTests` pass.

- [ ] **Step 5: Commit Task 2**

Run:

```bash
rtk git add Alas/Sources/ACP/UI/ACPCodeBlockHighlighter.swift AlasTests/ACP/UI/ACPCodeBlockHighlighterTests.swift
rtk git commit -m "test(acp): cover code block fallback highlighting"
```

---

### Task 3: Final Verification

**Files:**
- No intended source edits.

- [ ] **Step 1: Confirm no unintended Markdown preview changes**

Run:

```bash
rtk git diff origin/main -- Alas/Sources/Code/Markdown/MarkdownRenderer.swift
```

Expected: no diff.

- [ ] **Step 2: Run project generation**

Run:

```bash
rtk xcodegen
```

Expected: command exits 0.

- [ ] **Step 3: Run macOS build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: command exits 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: command exits 0.

- [ ] **Step 5: Commit verification-only generated changes if any**

If `xcodegen` changes project files, inspect the diff and commit only those generated project changes:

```bash
rtk git status --short
rtk git add Alas.xcodeproj project.yml
rtk git commit -m "chore: regenerate Xcode project"
```

Expected: commit only if there are actual project-generation diffs.
