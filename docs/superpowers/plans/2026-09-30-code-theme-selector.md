# Code Theme Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users pick a well-known editor color theme family (Solarized, Ayu, Catppuccin, …) that recolors every code surface, following the app's light/dark theme.

**Architecture:** 16 bundled JSON palettes decode into `CodePalette`. `ThemeStore` resolves the chosen family to a variant by `Theme.darkMode` and stores it on `Theme.codePalette` (a runtime field like `accentOverride`), so every existing `EditorTheme(theme:)` call site picks it up without new plumbing. `EditorTheme` becomes the single capture→color mapping; the two diff copies are deleted.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-30-code-theme-selector-design.md`

## Global Constraints

- Code, comments, logs, UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest. Extend existing suites; no new test files.
- After editing `project.yml`, run `xcodegen` and commit both `project.yml` and `Alas.xcodeproj`.
- Commit titles: Conventional Commits (`feat(code): …`). No `Co-Authored-By` trailers or AI attribution of any kind.
- Family ids: `default`, `ayu`, `catppuccin`, `dracula`, `github`, `gruvbox`, `nord`, `one`, `solarized`, `tokyo-night`. Config default: `"default"`.
- Unknown family or unloadable palette → Default (`codePalette == nil`). Never crash, never show the pink sentinel.
- App chrome, diagnostics squiggles, diff backgrounds/add/delete tints, and `ACPComposerShell`'s `syntax-keyword` accent stay on app tokens.
- Local test command (run only the listed suites):
  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -only-testing AlasTests/<SuiteName> test > /tmp/alas-test.log 2>&1; \
    grep -E "✘|✔ Test run|TEST (SUCCEEDED|FAILED)|error:" /tmp/alas-test.log | tail -20
  ```
  Swift Testing's truth is the ◇/✔/✘ lines; ignore the XCTest bridge's "Executed 0 tests". Never pipe xcodebuild directly to `tail` (hides the exit status). Never `pkill` the Alas app — only `xcodebuild`.

## Review Focus

1. User picks Solarized, then switches the app theme to light (or match-system flips) → code must switch to Solarized Light, not stay dark. Pinned by Task 2's test (sets family *before* `activate`). The match-system path (`applyForCurrentMode`) shares the same helper; reviewer should confirm both assignment sites call it.
2. User picks Nord in light mode → Default colors, not a dark editor inside a light app. Pinned by Task 2.
3. A config with a family id from a future/older build (`"monokai"`) → Default, no crash. Pinned by Task 2.
4. A palette file with a typo'd hex or missing slot → caught at test time, not a silent fallback in production. Pinned by Task 1's strict parser + test.
5. Changing the accent after picking a code theme must not drop the palette. `setAccent` copies `current`, so the palette survives by construction; reviewer should confirm no new assignment to `current` bypasses `withCodePalette`.

---

### Task 1: `CodePalette` model and bundled palettes

**Files:**
- Create: `Alas/Sources/Theme/CodePalette.swift`
- Create: `Alas/Resources/CodeThemes/*.json` (16 files, table below)
- Modify: `project.yml` (resources list, after `Alas/Resources/Themes`)
- Test: `AlasTests/ThemeTests.swift`

**Interfaces:**
- Produces:
  - `struct CodePalette: Equatable` with `let id: String`, `let name: String`, and `NSColor` properties `bg, fg, gutterFG, selection, comment, keyword, string, number, type, function, constant, attribute`. Equality by `id`.
  - `struct CodePalette.Family: Identifiable { let id: String; let name: String; let light: String?; let dark: String? }` (`nil` = Default)
  - `static let CodePalette.families: [Family]`
  - `static func CodePalette.loadBundled(id: String) -> CodePalette?`
  - `static func CodePalette.resolve(family: String, darkMode: Bool) -> CodePalette?`

- [ ] **Step 1: Write the failing test** — append to `ThemeTests` in `AlasTests/ThemeTests.swift`:

```swift
    @Test(arguments: CodePalette.families.flatMap { [$0.light, $0.dark] }.compactMap { $0 })
    func bundledCodePaletteLoadsEverySlot(id: String) throws {
        // `loadBundled` returns nil unless every slot parses as #rrggbb,
        // so non-nil proves the file is bundled and complete.
        let palette = try #require(CodePalette.loadBundled(id: id))
        #expect(palette.id == id)
    }
```

- [ ] **Step 2: Create `Alas/Sources/Theme/CodePalette.swift`**

```swift
import AppKit
import Foundation

/// A bundled editor color theme variant (e.g. "Solarized Dark"). Applied to
/// code surfaces through `Theme.codePalette`; `nil` there means the app
/// theme's own syntax tokens ("Default").
struct CodePalette: Equatable {
    let id: String
    let name: String
    let bg, fg, gutterFG, selection: NSColor
    let comment, keyword, string, number, type, function, constant, attribute: NSColor

    static func == (lhs: CodePalette, rhs: CodePalette) -> Bool { lhs.id == rhs.id }

    struct Family: Identifiable {
        let id: String
        let name: String
        let light: String?
        let dark: String?
    }

    static let families: [Family] = [
        Family(id: "default", name: "Default", light: nil, dark: nil),
        Family(id: "ayu", name: "Ayu", light: "ayu-light", dark: "ayu-mirage"),
        Family(id: "catppuccin", name: "Catppuccin", light: "catppuccin-latte", dark: "catppuccin-mocha"),
        Family(id: "dracula", name: "Dracula", light: nil, dark: "dracula"),
        Family(id: "github", name: "GitHub", light: "github-light", dark: "github-dark"),
        Family(id: "gruvbox", name: "Gruvbox", light: "gruvbox-light", dark: "gruvbox-dark"),
        Family(id: "nord", name: "Nord", light: nil, dark: "nord"),
        Family(id: "one", name: "One", light: "one-light", dark: "one-dark"),
        Family(id: "solarized", name: "Solarized", light: "solarized-light", dark: "solarized-dark"),
        Family(id: "tokyo-night", name: "Tokyo Night", light: "tokyo-night-day", dark: "tokyo-night-night"),
    ]

    /// Unknown families and unloadable palettes resolve to nil (Default).
    static func resolve(family: String, darkMode: Bool) -> CodePalette? {
        guard let entry = families.first(where: { $0.id == family }),
              let id = darkMode ? entry.dark : entry.light else { return nil }
        return loadBundled(id: id)
    }

    static func loadBundled(id: String) -> CodePalette? {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            #if DEBUG
            NSLog("CodePalette: failed to load \(id)")
            #endif
            return nil
        }
        return CodePalette(file: file)
    }

    private struct File: Decodable {
        let id: String
        let name: String
        let colors: [String: String]
    }

    private init?(file: File) {
        func c(_ key: String) -> NSColor? { file.colors[key].flatMap(Self.parseHex) }
        guard let bg = c("bg"), let fg = c("fg"), let gutterFG = c("gutter-fg"),
              let selection = c("selection"), let comment = c("comment"),
              let keyword = c("keyword"), let string = c("string"), let number = c("number"),
              let type = c("type"), let function = c("function"),
              let constant = c("constant"), let attribute = c("attribute") else { return nil }
        self.id = file.id
        self.name = file.name
        self.bg = bg; self.fg = fg; self.gutterFG = gutterFG; self.selection = selection
        self.comment = comment; self.keyword = keyword; self.string = string; self.number = number
        self.type = type; self.function = function; self.constant = constant; self.attribute = attribute
    }

    /// Strict `#rrggbb`; anything else is rejected so typos fail the test.
    private static func parseHex(_ raw: String) -> NSColor? {
        guard raw.count == 7, raw.hasPrefix("#"),
              let value = UInt32(raw.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
```

- [ ] **Step 3: Create the 16 palette files.** Each file is `Alas/Resources/CodeThemes/<id>.json` with exactly this shape (example = `solarized-dark.json`):

```json
{
  "id": "solarized-dark",
  "name": "Solarized Dark",
  "colors": {
    "bg": "#002b36", "fg": "#839496", "gutter-fg": "#586e75", "selection": "#073642",
    "comment": "#586e75", "keyword": "#859900", "string": "#2aa198", "number": "#d33682",
    "type": "#b58900", "function": "#268bd2", "constant": "#cb4b16", "attribute": "#6c71c4"
  }
}
```

Values for all 16 (columns in the order bg, fg, gutter-fg, selection, comment, keyword, string, number, type, function, constant, attribute):

| id | name | bg | fg | gutter-fg | selection | comment | keyword | string | number | type | function | constant | attribute |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ayu-light | Ayu Light | #fcfcfc | #5c6166 | #adaeb1 | #d1e4f4 | #acafb3 | #fa8d3e | #86b300 | #a37acc | #399ee6 | #f2ae49 | #a37acc | #e6ba7e |
| ayu-mirage | Ayu Mirage | #1f2430 | #cccac2 | #707a8c | #33415e | #6c7a8b | #ffad66 | #d5ff80 | #dfbfff | #73d0ff | #ffd173 | #dfbfff | #f29e74 |
| catppuccin-latte | Catppuccin Latte | #eff1f5 | #4c4f69 | #9ca0b0 | #ccd0da | #7c7f93 | #8839ef | #40a02b | #fe640b | #df8e1d | #1e66f5 | #fe640b | #ea76cb |
| catppuccin-mocha | Catppuccin Mocha | #1e1e2e | #cdd6f4 | #6c7086 | #313244 | #9399b2 | #cba6f7 | #a6e3a1 | #fab387 | #f9e2af | #89b4fa | #fab387 | #f5c2e7 |
| dracula | Dracula | #282a36 | #f8f8f2 | #6272a4 | #44475a | #6272a4 | #ff79c6 | #f1fa8c | #bd93f9 | #8be9fd | #50fa7b | #bd93f9 | #50fa7b |
| github-light | GitHub Light | #ffffff | #1f2328 | #8c959f | #dbe9f9 | #59636e | #cf222e | #0a3069 | #0550ae | #953800 | #8250df | #0550ae | #116329 |
| github-dark | GitHub Dark | #0d1117 | #e6edf3 | #6e7681 | #264f78 | #8b949e | #ff7b72 | #a5d6ff | #79c0ff | #ffa657 | #d2a8ff | #79c0ff | #7ee787 |
| gruvbox-light | Gruvbox Light | #fbf1c7 | #3c3836 | #a89984 | #ebdbb2 | #928374 | #9d0006 | #79740e | #8f3f71 | #b57614 | #427b58 | #8f3f71 | #af3a03 |
| gruvbox-dark | Gruvbox Dark | #282828 | #ebdbb2 | #7c6f64 | #504945 | #928374 | #fb4934 | #b8bb26 | #d3869b | #fabd2f | #8ec07c | #d3869b | #fe8019 |
| nord | Nord | #2e3440 | #d8dee9 | #4c566a | #434c5e | #616e88 | #81a1c1 | #a3be8c | #b48ead | #8fbcbb | #88c0d0 | #b48ead | #d08770 |
| one-light | One Light | #fafafa | #383a42 | #9d9d9f | #e5e5e6 | #a0a1a7 | #a626a4 | #50a14f | #986801 | #c18401 | #4078f2 | #986801 | #0184bc |
| one-dark | One Dark | #282c34 | #abb2bf | #636d83 | #3e4451 | #5c6370 | #c678dd | #98c379 | #d19a66 | #e5c07b | #61afef | #d19a66 | #56b6c2 |
| solarized-light | Solarized Light | #fdf6e3 | #657b83 | #93a1a1 | #eee8d5 | #93a1a1 | #859900 | #2aa198 | #d33682 | #b58900 | #268bd2 | #cb4b16 | #6c71c4 |
| solarized-dark | Solarized Dark | #002b36 | #839496 | #586e75 | #073642 | #586e75 | #859900 | #2aa198 | #d33682 | #b58900 | #268bd2 | #cb4b16 | #6c71c4 |
| tokyo-night-day | Tokyo Night Day | #e1e2e7 | #3760bf | #a8aecb | #b7c1e3 | #848cb5 | #9854f1 | #587539 | #b15c00 | #07879d | #2e7de9 | #b15c00 | #007197 |
| tokyo-night-night | Tokyo Night | #1a1b26 | #c0caf5 | #737aa2 | #283457 | #565f89 | #bb9af7 | #9ece6a | #ff9e64 | #2ac3de | #7aa2f7 | #ff9e64 | #7dcfff |

- [ ] **Step 4: Bundle the folder.** In `project.yml`, directly after the `Alas/Resources/Themes` entry (line ~52), add:

```yaml
      - path: Alas/Resources/CodeThemes
        buildPhase: resources
```

Then run `xcodegen`. (Resources are flattened into the bundle root; every palette id carries a family prefix so it cannot collide with `light.json` / `cool-slate.json`.)

- [ ] **Step 5: Run the test** — `-only-testing AlasTests/ThemeTests`. Expected: all 16 `bundledCodePaletteLoadsEverySlot` cases ✔. If one ✘, fix that JSON file.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Theme/CodePalette.swift Alas/Resources/CodeThemes project.yml Alas.xcodeproj AlasTests/ThemeTests.swift
git commit -m "feat(code): add bundled code theme palettes"
```

---

### Task 2: Resolve the palette onto `Theme` in `ThemeStore`

**Files:**
- Modify: `Alas/Sources/Theme/Theme.swift` (stored property, `==`, `hash`)
- Modify: `Alas/Sources/Theme/ThemeStore.swift` (`activate`, `applyForCurrentMode`, new `setCodeTheme`)
- Test: `AlasTests/ThemeStoreTests.swift`

**Interfaces:**
- Consumes: `CodePalette.resolve(family:darkMode:)` (Task 1)
- Produces: `var Theme.codePalette: CodePalette?`; `ThemeStore.setCodeTheme(family: String)`

- [ ] **Step 1: Write the failing test** — append to `ThemeStoreTests`:

```swift
    @Test(arguments: [
        ("solarized", "cool-slate", "solarized-dark"),
        ("solarized", "light", "solarized-light"),
        ("nord", "light", nil),
        ("default", "cool-slate", nil),
        ("monokai", "cool-slate", nil),
    ] as [(String, String, String?)])
    func codeThemeResolvesVariantFromAppTheme(family: String, appTheme: String, expected: String?) throws {
        let store = try ThemeStore()
        // Family first, app theme second: switching the app theme must
        // re-resolve the variant.
        store.setCodeTheme(family: family)
        try store.activate(id: appTheme)
        #expect(store.current.codePalette?.id == expected)
    }
```

- [ ] **Step 2: Run to verify it fails** — `-only-testing AlasTests/ThemeStoreTests`. Expected: compile error, `setCodeTheme` / `codePalette` not found.

- [ ] **Step 3: Add the field to `Theme`** (`Alas/Sources/Theme/Theme.swift`). After `resolvedColors` (line ~40):

```swift
    /// Editor palette for code surfaces, resolved by `ThemeStore` from the
    /// user's code theme family. `nil` = use this theme's syntax tokens.
    /// Runtime-only: excluded from `Codable` via `CodingKeys`.
    var codePalette: CodePalette? = nil
```

In `static func ==` add `&& lhs.codePalette == rhs.codePalette`. In `hash(into:)` add `hasher.combine(codePalette?.id)`.

- [ ] **Step 4: Resolve it in `ThemeStore`** (`Alas/Sources/Theme/ThemeStore.swift`). Add below `matchSystem`:

```swift
    /// Code theme family id (see `CodePalette.families`); re-resolved
    /// against every new `current` so the variant tracks light/dark.
    private var codeFamily = "default"
```

Add after `setAccent`:

```swift
    func setCodeTheme(family: String) {
        codeFamily = family
        current = withCodePalette(current)
    }

    private func withCodePalette(_ theme: Theme) -> Theme {
        var next = theme
        next.codePalette = CodePalette.resolve(family: codeFamily, darkMode: theme.darkMode)
        return next
    }
```

In `activate(id:)` replace `self.current = next` with `self.current = withCodePalette(next)`.
In `applyForCurrentMode()` replace `current = withAccent` with `current = withCodePalette(withAccent)`.
(`setAccent` copies `current`, so it keeps the palette unchanged.)

- [ ] **Step 5: Run the tests** — `-only-testing AlasTests/ThemeStoreTests` and `AlasTests/ThemeTests`. Expected: all ✔.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Theme/Theme.swift Alas/Sources/Theme/ThemeStore.swift AlasTests/ThemeStoreTests.swift
git commit -m "feat(code): resolve code theme variant from the app theme"
```

---

### Task 3: `EditorTheme` as the single capture→color mapping

**Files:**
- Modify: `Alas/Sources/Code/Editor/EditorTheme.swift`
- Modify: `Alas/Sources/Center/Diff/DiffCodeText.swift:81,121-143` (delete `syntaxColor`)
- Modify: `Alas/Sources/Center/DiffSelectableTextBuilder.swift:125-155` (delete `color(for:kind:theme:)`)
- Test: none new. Existing `DiffSelectableTextTests.diffSelectableTextBuilderUsesReadableCommentColorOnChangedRows`, `DiffSelectableTextTests.diffCodeTextUsesReadableCommentColorOnChangedRows`, and `DiffPaneViewTests` keyword/comment tests already pin the diff rules this task moves.

**Interfaces:**
- Consumes: `Theme.codePalette` (Task 2)
- Produces (on `EditorTheme`): `defaultFG`, `bg`, `faint`, `gutterFG: NSColor`, `selection: NSColor`, `func color(for capture: HighlightCapture, onChangedLine: Bool = false) -> NSColor`

- [ ] **Step 1: Rewrite the color section of `EditorTheme`.** Replace the three accessors and `private func color(for:)` with:

```swift
    private var palette: CodePalette? { theme.codePalette }

    var defaultFG: NSColor { palette?.fg ?? nsColor("fg") }
    var bg: NSColor { palette?.bg ?? nsColor("bg-1") }
    var faint: NSColor { palette?.comment ?? nsColor("fg-faint") }
    var gutterFG: NSColor { palette?.gutterFG ?? nsColor("fg-faint") }
    /// Default keeps AppKit's system selection color.
    var selection: NSColor { palette?.selection ?? .selectedTextBackgroundColor }
```

```swift
    /// The one capture→color mapping for every code surface. On added or
    /// deleted diff lines (`onChangedLine`), comments use the default
    /// foreground so they stay legible over the row tint.
    func color(for capture: HighlightCapture, onChangedLine: Bool = false) -> NSColor {
        if capture == .comment, onChangedLine { return defaultFG }
        if let palette {
            switch capture {
            case .keyword:     return palette.keyword
            case .type:        return palette.type
            case .function:    return palette.function
            case .string:      return palette.string
            case .number:      return palette.number
            case .comment:     return palette.comment
            case .constant:    return palette.constant
            case .attribute:   return palette.attribute
            case .variable, .parameter, .property, .operator, .punctuation, .plain:
                return palette.fg
            }
        }
        switch capture {
        case .keyword:                       return nsColor("syntax-keyword")
        case .type:                          return nsColor("syntax-type")
        case .function:                      return nsColor("syntax-function")
        case .string:                        return nsColor("add")
        case .number:                        return nsColor("mod")
        case .comment:                       return nsColor("fg-faint")
        case .attribute, .constant:          return nsColor("syntax-keyword")
        case .variable, .parameter, .property,
             .operator, .punctuation, .plain:
            return defaultFG
        }
    }
```

Leave `attributes(for:)` (it calls `color(for:)`), `diagnosticAttributes`, and `nsColor` as they are.

- [ ] **Step 2: Route `DiffCodeText` through it.** In `applySyntaxSpans` (line ~81) replace the value with:

```swift
                value: EditorTheme(theme: theme).color(
                    for: span.capture,
                    onChangedLine: inlineTone == .add || inlineTone == .del
                ),
```

Hoist `let editorTheme = EditorTheme(theme: theme)` above the `for` loop and use `editorTheme.color(...)` inside. Delete `private static func syntaxColor(for:inlineTone:theme:)`.

- [ ] **Step 3: Route `DiffSelectableTextBuilder` through it.** In `attributes(for:kind:font:theme:)` replace the foreground line with:

```swift
        attributes[.foregroundColor] = EditorTheme(theme: theme).color(
            for: capture,
            onChangedLine: kind == .add || kind == .delete
        )
```

Delete `private static func color(for:kind:theme:)`. Note: this builder used to render `.attribute`/`.constant` in `fg`; it now matches the editor and `DiffCodeText` (keyword color). Intentional.

- [ ] **Step 4: Run the tests** — `-only-testing AlasTests/DiffSelectableTextTests`, `AlasTests/DiffPaneViewTests`, `AlasTests/ACPCodeBlockHighlighterTests`, `AlasTests/MarkdownRendererTests`. Expected: all ✔ (no palette in these tests, so Default colors are unchanged).

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Code/Editor/EditorTheme.swift Alas/Sources/Center/Diff/DiffCodeText.swift Alas/Sources/Center/DiffSelectableTextBuilder.swift
git commit -m "refactor(code): route diff syntax colors through EditorTheme"
```

---

### Task 4: Apply palette background, gutter, and selection to code surfaces

**Files:**
- Modify: `Alas/Sources/Code/Editor/CodeEditorCoordinator.swift:1246` (`applyBaseStyle`)
- Modify: `Alas/Sources/Code/Editor/CodeEditorView.swift:148,207`
- Modify: `Alas/Sources/Code/Editor/CodeEditorLineNumberRulerView.swift:59,197`
- Modify: `Alas/Sources/Center/Merge/MergeResultPane.swift:48,136`
- Modify: `Alas/Sources/Code/Markdown/MarkdownRenderer.swift:383` (code block fg only)
- Test: none (forwarding only; Task 2 + Task 3 pin the logic).

**Interfaces:**
- Consumes: `EditorTheme.bg`, `.defaultFG`, `.gutterFG`, `.selection` (Task 3)

- [ ] **Step 1: Editor.** In `CodeEditorCoordinator.applyBaseStyle(theme:)`, move `let editorTheme = EditorTheme(theme: theme)` above the background line, then:

```swift
        let editorTheme = EditorTheme(theme: theme)
        textView.backgroundColor = editorTheme.bg
        textView.selectedTextAttributes = [.backgroundColor: editorTheme.selection]
```

In `CodeEditorView.swift` lines 148 and 207 replace `NSColor(theme.color("bg-1"))` with `EditorTheme(theme: theme).bg`.

- [ ] **Step 2: Gutter.** In `CodeEditorLineNumberRulerView.swift`, line 59: `EditorTheme(theme: theme).bg.setFill()`; line 197: `.foregroundColor: EditorTheme(theme: theme).gutterFG,`.

- [ ] **Step 3: Merge result pane.** `MergeResultPane.swift` lines 48 and 136: replace `NSColor(theme.color("bg-1"))` with `EditorTheme(theme: theme).bg`. (`MergeConflictTextStorage` already uses `EditorTheme` for syntax.)

- [ ] **Step 4: Markdown code blocks.** `MarkdownRenderer.swift` line ~383, in the fenced-block `baseAttrs`, replace `.foregroundColor: NSColor(theme.color("fg"))` with `.foregroundColor: EditorTheme(theme: theme).defaultFG`. Keep `.backgroundColor` on `bg-2`: markdown and ACP code blocks sit inside app-chrome cards, and a per-palette background there would need card-level changes in several ACP views. ACP code blocks already use `editorTheme.defaultFG`.

- [ ] **Step 5: Build** (no focused test covers this):

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -quiet build > /tmp/alas-build.log 2>&1; echo "exit $?"; grep -E "error:" /tmp/alas-build.log | head
```

Expected: `exit 0`, no errors.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Code/Editor Alas/Sources/Center/Merge/MergeResultPane.swift Alas/Sources/Code/Markdown/MarkdownRenderer.swift
git commit -m "feat(code): apply code theme background, gutter, and selection"
```

---

### Task 5: Persist the choice and add the settings picker

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift` (`Code` struct ~line 372, `CodingKeys` ~401, decode ~799)
- Modify: `Alas/Sources/App/AppState.swift:1470`
- Modify: `Alas/Sources/Settings/CodePane.swift:24` (Appearance group)
- Test: none (decode default and view composition are excluded by the test policy).

**Interfaces:**
- Consumes: `ThemeStore.setCodeTheme(family:)` (Task 2), `CodePalette.families` (Task 1), `EditorTheme` accessors (Task 3)
- Produces: `AppConfig.Code.codeThemeFamily: String`

- [ ] **Step 1: Config field.** In `struct Code`, after `inlayHintsByLanguage`:

```swift
        var codeThemeFamily: String = "default"
```

Add `codeThemeFamily` to `Code.CodingKeys`. In `AppConfig.init(from:)`, add the final argument to the `code = Code(...)` call that decodes from `codeContainer` (~line 807):

```swift
                inlayHintsByLanguage: (try? codeContainer.decode([String: InlayHintSettings].self, forKey: .inlayHintsByLanguage)) ?? [:],
                codeThemeFamily: (try? codeContainer.decode(String.self, forKey: .codeThemeFamily)) ?? "default"
```

The other `Code(...)` constructions pick up the `"default"` default automatically.

- [ ] **Step 2: Startup wiring.** In `AppState.swift` after `themeStore.setAccent(config.accent)` (~line 1470):

```swift
        themeStore.setCodeTheme(family: config.code.codeThemeFamily)
```

- [ ] **Step 3: Picker row.** At the top of `SettingsGroup(title: "Appearance")` in `CodePane.swift`, before "Font family":

```swift
                    SettingsRow(name: "Theme",
                                desc: "Follows the app's light/dark theme; dark-only themes use Default in light mode.") {
                        HStack(spacing: 8) {
                            codeThemeSwatch
                            Picker("", selection: Binding(
                                get: { state.config.code.codeThemeFamily },
                                set: {
                                    state.config.code.codeThemeFamily = $0
                                    state.saveConfig()
                                    state.themeStore.setCodeTheme(family: $0)
                                }
                            )) {
                                ForEach(CodePalette.families) { family in
                                    Text(family.name).tag(family.id)
                                }
                            }
                            .labelsHidden()
                            .settingsDropdownFrame()
                        }
                    }
```

And add to `CodePane`:

```swift
    /// Keyword / string / function dots of the active code theme, so the
    /// row shows what the pick looks like without opening a file.
    private var codeThemeSwatch: some View {
        let editorTheme = EditorTheme(theme: theme)
        return HStack(spacing: 3) {
            ForEach(Array([HighlightCapture.keyword, .string, .function].enumerated()), id: \.offset) { _, capture in
                Circle().fill(Color(nsColor: editorTheme.color(for: capture))).frame(width: 8, height: 8)
            }
        }
    }
```

(Dots sit beside the picker rather than inside each menu item: macOS menus template-tint SwiftUI images, so per-item colored dots do not render.)

- [ ] **Step 4: Build** (same command as Task 4 Step 5). Expected: `exit 0`.

- [ ] **Step 5: Manual check.** Launch the Debug build, not the installed app. Settings → Code → Theme → Solarized. The open editor and the gutter turn Solarized Dark. Switch Settings → Appearance to Light: they turn Solarized Light. Pick Nord in light mode: Default colors. Relaunch: the choice persists.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Persistence/AppConfig.swift Alas/Sources/App/AppState.swift Alas/Sources/Settings/CodePane.swift
git commit -m "feat(code): add code theme picker to settings"
```
