# Design: Styled LSP Hover Content

**Date:** 2026-05-22
**Status:** Draft

## Problem

The LSP hover popover in `Alas/Sources/Code/LSP/Features/HoverFeature.swift` renders markdown via SwiftUI's `AttributedString(markdown:)` with a 12pt proportional system font. This gives:

- No syntax highlighting in code blocks
- No monospaced font for code
- No visual separation between documentation prose and code examples
- No themed styling (plain white/black based on system appearance)

The project already has a capable `MarkdownRenderer` that produces themed `NSAttributedString` with TreeSitter syntax-highlighted code blocks, used for `.md` file previews. This renderer is not leveraged for LSP hover content.

## Solution

Reuse the existing `MarkdownRenderer` to render LSP hover markdown content. Replace the pure SwiftUI `HoverContentView` with an `NSViewRepresentable` wrapper around a read-only `NSTextView` that displays the rendered `NSAttributedString`. Allow the popover to grow dynamically up to a maximum size.

### Component Changes

#### HoverFeature (modified — `HoverFeature.swift`)

- `init()` gains parameters: `themeProvider: () -> Theme`, `monospacedFontFamily: () -> String`, `monospacedFontSize: () -> Int`
- `presentPopover()`:
  1. Parses the LSP hover markdown string with `Document(parsing:)` (swift-markdown)
  2. Creates a fresh `MarkdownRenderer` and calls `render(document:theme:monospacedFontFamily:monospacedFontSize:baseDirectory:worktreeRoot:)`
  3. Passes the `MarkdownRenderResult` and `Theme` to the new `HoverContentView`
  4. Computes preferred popover size from the rendered content (clamped 360×220 … 500×400)
- Plain text (non-markdown) LSP responses: wrap in backtick-delimited inline code so monospaced font is used

#### HoverContentView (replaced — `HoverFeature.swift`)

From a SwiftUI `Text(attributed)` view to a `struct HoverContentView: NSViewRepresentable`:

```
struct HoverContentView: NSViewRepresentable {
    let result: MarkdownRenderResult
    let theme: Theme

    func makeNSView(context:) -> NSView   // NSScrollView + NSTextView
    func updateNSView(_:context:)          // apply attributed string + theme bg
}
```

- NSTextView: `isEditable = false`, `drawsBackground = false`, `textContainerInset = NSSize(width: 8, height: 8)`, `isHorizontallyResizable = true`
- Wrapped in `NSScrollView` with `drawsBackground = true` using `theme.color("bg-1")`
- Links are clickable but intercepted (no navigation), same as markdown preview behavior

#### Popover Sizing

- Compute preferred size from `NSTextView.layoutManager.usedRect(for:)` on the text container
- Clamp: min 360×220 (current fixed size), max 500×400
- Layout is synchronous at NSAttributedString insert time — correct on first appearance
- ScrollView shows scrollbars only when content exceeds max height

#### CodeEditorCoordinator (minor — `CodeEditorCoordinator.swift`)

- Pass `{ appState.config.themeStore.current }` and font settings when constructing `HoverFeature`

### Files Touched

| File | Change |
|------|--------|
| `Alas/Sources/Code/LSP/Features/HoverFeature.swift` | Major — new HoverContentView, MarkdownRenderer integration, dynamic sizing |
| `Alas/Sources/Code/Editor/CodeEditorCoordinator.swift` | Minor — pass theme + font to HoverFeature init |

### Files Unchanged

- `Alas/Sources/Code/Markdown/MarkdownRenderer.swift` — used as-is
- `Alas/Sources/Code/Editor/EditorTheme.swift` — used as-is
- All other LSP features (DefinitionFeature, HoverHighlightFeature, etc.)

### Styling

| Element | Style |
|---------|-------|
| Background | `theme.bg-1` (matches editor) |
| Prose text | `theme.fg`, 12pt system font (MarkdownRenderer default) |
| Code blocks | `theme.bg-2` background, monospaced nerd font, TreeSitter syntax colors via `EditorTheme` |
| Inline code | Monospaced nerd font, `theme.bg-2` background |
| Headings | Bold, `theme.fg`, scaled sizes (MarkdownRenderer headings) |
| Links | `theme.accent` + underline |
| Padding | 8pt `textContainerInset` (matches editor inset) |

### Error Handling & Edge Cases

- **No theme available:** not possible — ThemeStore always has a current theme
- **Non-markdown hover:** plain text wrapped in backticks, rendered as monospaced inline code
- **swift-markdown parse failure:** `Document(parsing:)` is lenient — produces valid AST for malformed markdown
- **TreeSitter not loaded for a language:** code blocks render as plain monospaced text, no crash
- **Empty hover content:** already handled at line 63 of HoverFeature (closes popover), no change
- **Very long documentation:** content scrolls at max 400px height, not cut off
- **What doesn't change:** hover trigger logic (250ms debounce, 3px threshold, request ID deduplication), popover behavior (.transient, anchor-to-character-rect), NSPopover + NSHostingController hosting approach

### Testing

- Unit tests: verify `HoverContentView` renders markdown with expected font attributes and theme colors
- Integration: verify hover popover shows syntax-highlighted code blocks when sourcekit-lsp returns Swift declarations
- Edge case: hover on a symbol that returns only plain text (not markdown) — should render in monospaced font
