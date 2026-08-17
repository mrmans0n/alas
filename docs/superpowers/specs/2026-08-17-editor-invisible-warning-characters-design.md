# Editor Invisible and Warning Characters Design

Date: 2026-08-17

## Summary

Add global text-rendering preferences for editable file tabs. Alas will render
fixed markers for ordinary invisible characters and highlight a configurable
set of suspicious Unicode scalars without changing the editor buffer. This is
the first implementation slice from a broader audit of Agentastic's Text
Editing settings.

## Goals

- Make spaces, tabs, and logical line endings optionally visible.
- Highlight suspicious Unicode scalars by default.
- Explain each highlighted scalar through a native hover tooltip.
- Let users add, remove, and restore warning entries.
- Apply settings live to every mounted editable file tab.
- Preserve copied text, saved text, undo history, syntax styling, diagnostics,
  selections, and LSP offsets.
- Remain responsive on large files by decorating only requested glyph ranges.

## Non-goals

- Read-only diffs, merge panes, Markdown previews, chat code blocks, or prompt
  editors.
- Workspace-specific or language-specific overrides.
- Arbitrary replacement glyphs for invisible characters.
- A menu item or keyboard shortcut for toggling these settings.
- Minimap, folding, overscroll, bracket highlighting, or indentation-policy
  changes.

## Current Alas behavior

Alas uses an AppKit `NSTextView` and TextKit 1 chain built in
`CodeEditorView`. Each tab owns an `EditorBuffer` whose `NSTextStorage` is
shared across view remounts. `CodeEditorCoordinator` reapplies base,
tree-sitter, diagnostic, and reveal styling. `CodeEditorView` already receives
font and line-number settings as explicit inputs so SwiftUI calls
`updateNSView` when they change.

Line endings are canonicalized to LF in memory. `EditorBuffer` separately
records whether the file uses LF or CRLF and restores that style on save.
Consequently, the editor cannot meaningfully draw distinct in-memory LF and CR
characters. It will display one logical line-ending marker.

## Settings UI

Add a **Text Rendering** group to Settings > Code.

1. **Show invisible characters** defaults to off.
2. Three inline subordinate toggles show their fixed markers:
   - **Spaces** `·`
   - **Tabs** `→`
   - **Line endings** `↵`
3. The subordinate toggles default to on. They remain persisted but appear
   disabled while the master toggle is off.
4. **Show warning characters** defaults to on and has a **Configure…** button.
5. **Configure…** opens a sheet containing an ordered table with Unicode code,
   note, add, remove, **Restore Defaults**, and **Done** controls.
6. Table changes save immediately. **Done** only closes the sheet.
7. Adding an entry accepts either `U+XXXX` notation or one pasted Unicode
   scalar, plus an optional note.

The invisible-character configuration sheet shown by Agentastic is omitted:
with fixed markers it would contain only the same three toggles already visible
inline.

## Configuration model

Extend global `AppConfig.Code` with:

- `showInvisibleCharacters: Bool` (default `false`)
- `showSpaces: Bool` (default `true`)
- `showTabs: Bool` (default `true`)
- `showLineEndings: Bool` (default `true`)
- `showWarningCharacters: Bool` (default `true`)
- `warningCharacters: [WarningCharacter]` (default list below)

`WarningCharacter` is a small Codable, Equatable value containing a Unicode
scalar value and a note. Order is preserved for the settings table; rendering
builds a scalar-keyed lookup dictionary.

Missing keys decode to defaults. During decode, invalid scalar values are
discarded individually and duplicate values keep their first occurrence. An
empty warning list is valid and remains empty. **Restore Defaults** replaces
the list with the complete default list.

## Default warning characters

The defaults retain the characters shown by Agentastic, correct U+2013's name
to En dash, and add common zero-width and bidirectional controls.

| Code | Note |
|---|---|
| U+0003 | End of text |
| U+00A0 | Non-breaking space |
| U+00AD | Soft hyphen |
| U+034F | Combining grapheme joiner |
| U+037E | Greek question mark |
| U+061C | Arabic letter mark |
| U+180E | Mongolian vowel separator |
| U+200B | Zero-width space |
| U+200C | Zero-width non-joiner |
| U+200D | Zero-width joiner |
| U+200E | Left-to-right mark |
| U+200F | Right-to-left mark |
| U+2013 | En dash |
| U+2018 | Left single quote |
| U+2019 | Right single quote |
| U+201C | Left double quote |
| U+201D | Right double quote |
| U+2029 | Paragraph separator |
| U+202A | Left-to-right embedding |
| U+202B | Right-to-left embedding |
| U+202C | Pop directional formatting |
| U+202D | Left-to-right override |
| U+202E | Right-to-left override |
| U+202F | Narrow non-breaking space |
| U+2060 | Word joiner |
| U+2061 | Function application |
| U+2062 | Invisible times |
| U+2063 | Invisible separator |
| U+2064 | Invisible plus |
| U+2066 | Left-to-right isolate |
| U+2067 | Right-to-left isolate |
| U+2068 | First strong isolate |
| U+2069 | Pop directional isolate |
| U+FEFF | Zero-width no-break space / byte-order mark |

This intentionally does not warn on all non-ASCII text. Legitimate
multilingual source remains usable.

## Rendering architecture

Replace the plain layout manager created by `CodeEditorView` with a small
`CodeEditorLayoutManager` subclass. It owns the current rendering settings,
warning lookup, and theme colors.

The layout manager lets TextKit draw text normally, then decorates only the
glyph range TextKit requested:

- Enabled spaces, tabs, and logical newlines receive their fixed marker in the
  theme's faint foreground color.
- A visible warning scalar keeps its syntax foreground color and receives a
  theme-aware red background based on the existing deletion color.
- A zero-width warning receives a one-character-width red marker at its
  insertion position without changing layout.
- Warning treatment takes precedence when a scalar also belongs to an enabled
  invisible category.

Decoration never adds attributes to `NSTextStorage` and never substitutes its
characters. Text edits continue through the existing buffer/coordinator path;
TextKit invalidates affected layout naturally.

`CodeEditorView` receives the rendering configuration as explicit value inputs.
In `updateNSView`, it updates the layout manager and invalidates display if the
configuration or theme changed. This makes every currently mounted editor
react immediately while preserving the existing SwiftUI/AppKit boundary.

## Warning hover behavior

`CodeTextView`'s existing mouse tracking also asks the layout manager for a
warning decoration at the pointer location. The hit region is the normal glyph
bounds for visible characters and the drawn marker bounds for zero-width
characters.

AppKit's native tooltip displays:

```text
U+200B — Zero-width space
```

If the note is empty, it displays only the normalized code. The warning tooltip
wins only while the pointer is directly over a warning decoration and does not
disable LSP hover elsewhere. The tooltip contains no actions or links.

## Input validation

- Trim surrounding whitespace.
- Accept case-insensitive `U+` notation with four to six hexadecimal digits,
  or a literal containing exactly one Unicode scalar.
- Reject surrogate values, values above U+10FFFF, empty input, multiple
  scalars, and duplicates.
- Normalize displayed codes to uppercase `U+` notation with at least four
  hexadecimal digits.
- Allow an empty note.

Validation occurs before mutating or saving the table.

## Performance

Rendering scans only the character range corresponding to the glyph range
TextKit already asked to draw. Warning membership is an O(1) dictionary lookup.
No document-wide scan, background task, decoration cache, observer graph, or
new dependency is introduced.

Supplementary-plane scalars are treated as one warning even though their
TextKit character range contains two UTF-16 code units.

## Tests

Automated tests use Swift Testing and cover:

- Decoding old configuration without the new keys.
- Configuration round trips and default restoration.
- Per-entry filtering of invalid persisted values and first-entry duplicate
  handling.
- Parsing `U+` notation and literal scalars, including supplementary-plane
  values.
- Rejecting malformed, surrogate, multi-scalar, and duplicate input.
- Decoration ranges for enabled spaces, tabs, and newlines.
- Independent category and master-toggle behavior.
- Visible and zero-width warnings, including warning precedence.
- UTF-16 range correctness for supplementary-plane scalars.
- Rendering configuration changes without any mutation to storage text.

Manual verification covers live changes across multiple tabs, warning
tooltips, syntax highlighting, diagnostics, selections, light and dark themes,
CRLF save preservation, and scrolling/editing a large file.

## Acceptance criteria

1. Existing users receive invisible characters off and warning characters on
   without a migration failure.
2. The three invisible categories can be toggled independently and update open
   editable file tabs immediately.
3. Disabling and re-enabling the invisible master toggle preserves category
   choices.
4. LF and CRLF files show the same logical line marker and retain their original
   disk line-ending style after save.
5. Warning defaults match the table in this document.
6. Users can add entries using normalized code notation or a literal scalar,
   remove any entry, and restore defaults.
7. Warning matches appear in code, comments, and strings.
8. Visible warning characters receive a red background; zero-width warning
   characters receive a visible red marker.
9. Hovering either treatment shows its normalized code and configured note.
10. Copy, save, undo, highlighting, diagnostics, selection, and LSP positions
    behave as they did before the feature.
11. Read-only and non-file editor surfaces are unchanged.

## Broader Text Editing audit

| Agentastic option | Alas status and follow-up |
|---|---|
| Font and Markdown mode | Already supported; retain existing locations |
| Use System Cursor | Native `NSTextView` behavior; no setting needed |
| Show Gutter | Existing Show Line Numbers setting is sufficient |
| Autocomplete braces and type-over | Already implemented and always on; optional future toggles |
| Indent style, indent width, tab width | Current editor auto-detects; design separately with possible EditorConfig support |
| Line wrapping | Small editor-preferences follow-up |
| Reformatting guide and column | Small editor-preferences follow-up |
| Overscroll | Independent follow-up |
| Bracket-pair highlight | Independent editor feature |
| Minimap and folding ribbon | Substantial features requiring dedicated designs |
| Invisible and warning characters | This implementation slice |

After this slice, wrapping, delimiter toggles, and a column guide may be grouped
into one small editor-preferences change. Indentation policy, minimap, and
folding remain separate until explicitly prioritized.

## References

- Apple `NSLayoutManager`: https://developer.apple.com/documentation/appkit/nslayoutmanager
- CodeEdit release notes describing customizable invisible and warning
  characters: https://www.codeedit.app/whats-new
