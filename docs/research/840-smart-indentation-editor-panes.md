---
task_id: 840
title: "Smart indentation in editor panes"
date: 2026-05-16
project: alas
phase: groomed
prior_art:
  - Alas/Sources/Code/Editor/CodeTextView.swift
  - Alas/Sources/Code/Editor/EditorBuffer.swift
  - Alas/Sources/Code/Editor/CodeEditorCoordinator.swift
  - Alas/Sources/Code/Highlight/LanguageRegistry.swift
  - Alas/Sources/Code/Highlight/TreeSitterHighlighter.swift
  - AlasTests/CodeTextViewAutoPairTests.swift
---

## TL;DR

Well-scoped feature with a clear entry point. `CodeTextView` already overrides
`insertText(_:replacementRange:)` for auto-pairing; smart indentation adds a
parallel `insertNewline(_:)` override in the same class. No custom newline
handling exists today — NSTextView's default just inserts `\n` with zero
indentation awareness. The implementation is purely local to `CodeTextView`
(with a small extracted helper for testability) and does not touch the buffer,
coordinator, or LSP layers.

## Scope confirmation

### In scope (v1)

1. **Preserve current indentation on newline** — copy leading whitespace from
   the current line when Enter is pressed.
2. **Increase indentation after block openers** — if the line ends with `{`,
   `(`, `[`, `:` (for Python-style languages), or a trailing `{` before a
   comment, add one extra indent level on the new line.
3. **Dedent closing delimiters** — typing `}`, `)`, or `]` on a
   whitespace-only line reduces indentation by one level to align with the
   matching opener's line.
4. **Newline between paired delimiters** — pressing Enter between `{}`, `()`,
   or `[]` that were auto-paired produces a three-line expansion:
   opener line / indented cursor / dedented closer.
5. **Tab size detection** — detect whether the file uses tabs or spaces (and
   how many) from the buffer content. Fall back to 4-space indent.

### Out of scope (v1)

- **Language-specific indent rules via tree-sitter AST** — tree-sitter is
  available but only has a Swift grammar. Querying the AST for indent context
  would be fragile and limited to one language. The heuristic approach
  (trailing delimiter detection) works across all file types with acceptable
  accuracy. Can revisit once more grammars are added.
- **LSP `onTypeFormatting` / `onEnterFormatting`** — the LSP layer does not
  currently implement formatting features. Wiring this up is a separate task.
- **EditorConfig / per-project indent settings** — not yet modeled in alas.
  A future settings feature would feed into the indent-width detection.
- **Re-indenting pasted blocks** — paste indentation normalization is a
  distinct feature.
- **Smart indent in diff panes** — diff views are read-only.

## Architectural alignment

### Entry point: `CodeTextView` (`Alas/Sources/Code/Editor/CodeTextView.swift`)

The class already:
- Overrides `insertText(_:replacementRange:)` (line 54) for auto-pairing.
- Maintains `pairedDelimiters` (line 9) and `closingDelimiters` (line 18) —
  reusable for indent logic.
- Has helper methods `previousCharacter(before:)` (line 170) and
  `nextCharacter(at:)` (line 164).

New code hooks into `override func insertNewline(_ sender: Any?)` — an
NSTextView override that fires on Enter. This is the standard Cocoa extension
point (used by Xcode, TextMate, etc.).

For the dedent-on-close-delimiter case, the existing `insertText` override
(line 54) gains a branch: when a closing delimiter is typed on a
whitespace-only line, reduce the line's leading whitespace before inserting.

### Extracted helper: `IndentationHelper`

A small struct (new file `Alas/Sources/Code/Editor/IndentationHelper.swift`)
with pure functions:

- `leadingWhitespace(of line: String) -> String` — returns the whitespace
  prefix.
- `indentUnit(in text: String) -> String` — scans the buffer to detect
  tab-vs-spaces and width. Falls back to 4 spaces.
- `shouldIncreaseIndent(afterLine line: String) -> Bool` — checks for
  trailing `{`, `(`, `[`, `:` (ignoring trailing comments/whitespace).
- `shouldDecreaseIndent(forCharacter char: Character, currentLineText: String) -> Bool`
  — returns true when a closing delimiter is typed on a whitespace-only line.
- `expandBetweenPair(opener: Character, closer: Character, currentIndent: String, indentUnit: String, lineEnding: String) -> (text: String, cursorOffset: Int)`
  — produces the three-line expansion for Enter between `{}` etc.

All methods are pure `String → String` / `String → Bool`, making them trivially
testable without NSTextView.

### Test pattern

`CodeTextViewAutoPairTests` (line 7) shows the exact pattern: create a
`CodeTextView` with `NSTextStorage` + `NSLayoutManager` + `NSTextContainer`,
call methods on it, assert `string` and `selectedRange()`. The same harness
works for newline tests.

Unit tests for `IndentationHelper` are even simpler — pure function calls.

## Acceptance criteria

1. Pressing Enter preserves the current line's leading whitespace on the new
   line.
2. Pressing Enter at the end of a line ending with `{` adds one indent level
   beyond the current line's indentation.
3. Same for `(`, `[`, and `:`.
4. Pressing Enter between auto-paired `{}`, `()`, or `[]` produces a
   three-line expansion with the cursor indented one level on the middle line
   and the closer dedented on the third line.
5. Typing `}`, `)`, or `]` on a whitespace-only line dedents that line by one
   indent level.
6. Indent unit is auto-detected from file content (tabs vs N-spaces). Falls
   back to 4 spaces.
7. Plain-text / unknown file types get behavior from criteria 1 only (preserve
   indent). Block-opener heuristics still apply since they are
   language-agnostic.
8. Undo (⌘Z) after an auto-indented newline reverts the full insertion
   (newline + whitespace) in one step.
9. All existing `CodeTextViewAutoPairTests` continue to pass.
10. `swift build` compiles with zero warnings; all tests pass.

## Open questions

1. **Should `:` trigger indent-increase?** It helps Python/YAML but is noisy
   in Swift (case labels, dictionary literals). **Recommendation:** include `:`
   only when it is the last non-whitespace character on the line (matches
   Python `def foo():` and YAML keys). Swift `case .foo:` typically has more
   content after the colon, so it won't false-trigger.

2. **Should the feature be toggleable?** No settings infrastructure exists.
   **Recommendation:** ship always-on for v1. If users complain, add a toggle
   in a future settings task.

3. **Indent width: detect per-file or use a global default?** **Recommendation:**
   detect per-file from buffer content at load time. The detection is cheap
   (scan first ~100 indented lines) and avoids needing a config system.

## Implementation order

1. **`IndentationHelper.swift`** — new file under
   `Alas/Sources/Code/Editor/`. Implement `leadingWhitespace`,
   `indentUnit`, `shouldIncreaseIndent`, `shouldDecreaseIndent`,
   `expandBetweenPair`.

2. **`IndentationHelperTests.swift`** — new file under `AlasTests/`.
   Cover all pure-function cases: preserve indent, increase after openers,
   dedent closers, tab detection, edge cases (empty line, line with only
   whitespace, nested delimiters).

3. **`CodeTextView.swift`** — add `override func insertNewline(_ sender: Any?)`
   that uses `IndentationHelper` to compute the replacement text and cursor
   position. Modify `insertText` to handle dedent-on-close-delimiter.

4. **`CodeTextViewIndentTests.swift`** — new file under `AlasTests/`.
   Integration tests using the `makeTextView` pattern from
   `CodeTextViewAutoPairTests`: call `insertNewline` / `insertText` on a
   wired-up `CodeTextView` and assert `string` + `selectedRange()`.

5. **`xcodegen`** — regenerate `Alas.xcodeproj` to include new files.

## Risks / things to watch

- **Undo coalescing** — `insertText` calls on NSTextView register with the
  undo manager automatically. `insertNewline` that manually replaces text must
  group the newline + whitespace insertion into a single undo group
  (`undoManager?.groupsByEvent` or explicit `beginUndoGrouping` /
  `endUndoGrouping`). Verify with a manual test.

- **`replacementRange` semantics** — `insertNewline` does not receive a
  `replacementRange` like `insertText` does. Use `selectedRange()` directly.
  If there is a selection, the newline replaces it (standard behavior).

- **Performance on large files** — `indentUnit` scans the buffer. Capping at
  ~100 lines and caching per buffer load makes this negligible.

- **Interaction with auto-pair** — pressing Enter between `{}` must not
  re-trigger the auto-pair `insertText` path. Since `insertNewline` is a
  separate override, this should be clean — but verify with the paired test
  case.

- **Tree-sitter re-highlight** — the coordinator debounces highlight at 150ms.
  Multi-line insertions (three-line expansion) produce a single
  `didProcessEditing` callback, so highlighting works as-is.

## Definition of done (handoff sign-off)

- [ ] `IndentationHelper` pure-function tests green.
- [ ] `CodeTextView` integration tests green for all acceptance criteria.
- [ ] All pre-existing tests (794 at last count) still pass.
- [ ] Manual verification: open a Swift file, press Enter after `{`, verify
      indent. Type `}`, verify dedent. ⌘Z reverts cleanly.
- [ ] `xcodegen` regenerated, project builds with zero new warnings.
