# Design: ACP Code Block Syntax Coloring

**Date:** 2026-05-28
**Status:** Approved

## Problem

ACP chat messages render fenced code blocks in `Alas/Sources/ACP/UI/ACPMarkdownText.swift` as plain monospaced text. This preserves content and copy behavior, but makes agent answers harder to scan when they include Swift, shell, JSON, TypeScript, or other code examples.

The app already has a Tree-sitter backed highlighter in `TreeSitterHighlighter`, a regex fallback for supported-but-unavailable language paths, and theme-aware capture styling in `EditorTheme`. Markdown file preview already uses this path for fenced code blocks. ACP chat should reuse the same infrastructure instead of adding a second syntax coloring system, while keeping this pass scoped to ACP rendering.

## Solution

Add syntax coloring to ACP fenced code blocks by converting each code fence language label into the file extension expected by `TreeSitterHighlighter.highlight(source:fileExtension:)`, then applying the returned `HighlightSpan`s to an attributed string displayed by `CodeBlockView`.

The change is scoped to ACP chat rendering:

- Existing code block layout, header, copy button, scrolling, selection, spacing, and background chrome stay unchanged.
- The visible code fence label stays exactly as the agent wrote it; normalization only affects highlighting.
- Supported Tree-sitter languages use the existing parser and query path.
- Labels supported by the existing regex fallback, such as `diff`, `patch`, `html`, `xml`, and `css`, can be highlighted without adding new parser packages.
- Known labels with no useful parser or fallback coverage, such as `sql` in this pass, remain plain until support is added deliberately.
- Unknown or missing language labels render as plain monospaced text.
- Syntax colors come from `EditorTheme.attributes(for:)`, keeping ACP chat consistent with the editor and Markdown preview.

## Component Changes

### ACPCodeLanguage

Add a small, testable mapper near the ACP markdown renderer or in a focused ACP UI support file:

```swift
enum ACPCodeLanguage {
    static func highlighterExtension(for label: String?) -> String?
}
```

The mapper normalizes fence labels by lowercasing and trimming common Markdown fence metadata, including labels such as `{.swift}`, `.swift`, and `swift title=Example.swift`.

It should recognize common labels for languages supported today and typical labels expected in agent output. Recognition does not guarantee coloring: labels without highlighter support should return nil or otherwise be filtered out by the ACP helper so the body stays plain.

Supported examples:

| Labels | Extension |
|--------|-----------|
| `swift` | `swift` |
| `py`, `python` | `py` |
| `js`, `javascript`, `mjs`, `cjs` | `js` |
| `jsx` | `jsx` |
| `ts`, `typescript` | `ts` |
| `tsx` | `tsx` |
| `sh`, `bash`, `shell`, `zsh`, `console`, `terminal` | `sh` |
| `json` | `json` |
| `yaml`, `yml` | `yaml` |
| `toml` | `toml` |
| `rs`, `rust` | `rs` |
| `go`, `golang` | `go` |
| `java` | `java` |
| `kt`, `kotlin`, `kts` | `kt` / `kts` |
| `c`, `h` | `c` / `h` |
| `cpp`, `c++`, `cc`, `cxx`, `hpp` | `cpp` / matching C++ extension |
| `diff`, `patch` | `diff` / `patch` |
| `html`, `xml` | `html` / `xml` |
| `css`, `scss`, `sass` | `css` / matching CSS-like extension |

Common chat labels without current Tree-sitter coverage are allowed but should degrade predictably:

- `sql`
- `rb`, `ruby`
- `php`
- `pl`, `perl`
- `lua`
- `ex`, `exs`, `elixir`
- `dockerfile`
- `ini`

For these labels, the mapper may recognize the label for future alignment, but ACP should only request highlighting when the existing highlighter can color something useful. Otherwise it should render plain text. The implementation should not add new parser packages for this feature.

### CodeBlockView

Replace `Text(code)` with a small attributed string builder:

```swift
private func highlightedCode() -> AttributedString
```

Behavior:

1. Start with the full code string in the existing monospaced 12pt font and default foreground color.
2. Resolve the fence label through `ACPCodeLanguage`.
3. If no extension is found, return the plain attributed string.
4. Call `TreeSitterHighlighter.highlight(source:fileExtension:)`.
5. Apply `EditorTheme(theme: theme).attributes(for:)` to each valid span.
6. Return the attributed string to SwiftUI `Text`.

Invalid spans should be ignored defensively. Highlighting should not change the copied text.

### Streaming Behavior

ACP may re-render a message while the agent is still streaming. Stable parsed code blocks can be highlighted immediately, but the active streaming tail may remain plain until its closing fence arrives or until the block is promoted into `ACPMarkdownBlockCache.stableBlocks`.

This pass should not add a Tree-sitter incremental cache for chat. If repeated highlighting of unstable blocks becomes measurable later, add that as a separate performance change.

### Optional Regex Coverage

If the current fallback does not color desired chat-only labels, extend `RegexFallbackHighlighter` conservatively for simple languages only. This is optional and should be limited to labels where a small keyword/string/comment pattern gives useful output without pretending to be a full parser.

`sql` is explicitly out of the first pass unless a small SQL fallback is added intentionally with tests. A broad alias table may still know about `sql`, but SQL blocks should remain plain without fallback support.

## Error Handling

- Empty code block: render an empty monospaced block as today.
- Empty or missing language label: render plain monospaced text.
- Unknown language label: render plain monospaced text.
- Known-but-unsupported language label: render plain monospaced text.
- Tree-sitter parser or query unavailable: use the existing highlighter fallback behavior.
- Malformed source for a language: return whatever spans Tree-sitter produces; never hide or modify code text.
- Span range outside the string: skip that span.

## Testing

Add focused Swift Testing coverage:

- `ACPCodeLanguage` maps common aliases such as `python`, `typescript`, `shell`, `zsh`, `javascript`, and `c++`.
- Supported regex-backed labels such as `diff`, `patch`, `html`, `xml`, and `css` route through the shared highlighter path.
- Known-but-unsupported future labels such as `sql`, `ruby`, and `php` do not apply syntax colors until support exists.
- Unknown labels map to nil or produce plain attributed output.
- The attributed code builder applies a non-default foreground color to `func` in a Swift code block.
- Unknown-language code remains monospaced and default-colored.
- Highlighting does not change the visible header label or copied code string.

If direct SwiftUI `View` inspection is awkward, keep the highlight application in a pure helper and test that helper.

## Fast Follow: Markdown Preview

Markdown file preview already highlights fenced code blocks, but its label mapping should not be changed in this ACP-first pass. After ACP lands, extract the fence-label normalization into shared code and have both ACP chat and Markdown preview use it.

That follow-up should compare ACP and Markdown preview behavior explicitly so the two renderers converge without surprising existing Markdown preview users.

## Out of Scope

- Adding new Tree-sitter parser packages.
- Replacing `ACPMarkdownText` with the full Markdown preview renderer.
- Syntax coloring inline code in ACP prose.
- Highlighting code while the user types in the ACP composer.
- Changing ACP message persistence or protocol handling.
- Changing Markdown preview behavior in this pass.
