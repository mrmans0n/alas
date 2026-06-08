# Editor Find and Replace Design

## Context

Alas already has a partial editor find/replace implementation in `EditorFindController`, `EditorFindBarView`, and `EditorTabView`. The current version opens a replace-oriented bar through the configurable `findAndReplace` action, defaults to `Cmd-Option-F`, searches case-sensitively, and does not yet provide standard find-only behavior, match counters, wrapping navigation, selected-text prefill, case controls, or all-match highlighting.

This design evolves that existing editor-scoped implementation. It does not introduce project-wide search, regex, whole-word matching, or native `NSTextFinder` integration.

## User Behavior

`Cmd-F` opens a compact find UI in the active text editor pane, focuses the find field, and preloads the current editor selection when the selection is non-empty and single-line. Typing updates matches live. The default search is plain-text and case-insensitive.

`Cmd-R` opens the same UI with replace controls visible. If a search term already exists, it focuses the replace field; otherwise it focuses the find field. The replace value may be empty, which deletes matches.

Navigation wraps around the document. `Enter` and `Cmd-G` select the next match. `Shift-Enter` and `Cmd-Shift-G` select the previous match. Buttons in the find bar provide the same previous and next behavior. The UI shows the active match and total count as `3 of 12`; no matches shows `No matches`.

Replace supports:

- `Replace`: replace the active selected match, then move to the next match.
- `All`: replace all non-overlapping matches in the document.
- Read-only editors: no mutation, with the UI staying in find mode and reporting no replacement.

`Esc` closes the bar, clears find highlights, and returns focus to the editor.

## Matching Semantics

Search is plain text only. Matching uses UTF-16 `NSRange` values so it remains compatible with `NSTextView`, existing selection APIs, and replacement operations.

The default is case-insensitive matching. A visible `Aa` toggle switches to case-sensitive matching. Changing the query or case toggle recomputes the match list and updates the active match/count.

Matches are non-overlapping. Empty queries produce no matches, no highlights, and disabled replacement actions.

## Components

`EditorFindController` remains a `@MainActor` controller scoped to one `CodeTextView`. It becomes the state and behavior owner for:

- `findString`
- `replacementString`
- `isCaseSensitive`
- current `matches: [NSRange]`
- active match index
- match count/status
- next/previous selection with wrapping
- replace current
- replace all

The active match remains the normal `CodeTextView` selection. That preserves native scrolling, cursor visibility, editing, undo, dirty tracking, and LSP `didChange` behavior.

`EditorTabView` owns presentation state:

- hidden
- find visible
- replace visible

It listens for editor find requests only when its tab is active. It wires the controller to the `CodeTextView` through the existing `.codeEditorDidAttach` / `.codeEditorDidDetach` notifications. It also handles selection prefill, field focus, close behavior, and focus return to the editor.

`EditorFindBarView` becomes a compact reusable SwiftUI bar. It renders:

- find text field
- optional replace text field/row
- previous and next controls
- `Aa` case-sensitive toggle
- match count/status text
- replace current and replace all buttons when replace mode is visible
- close button

The bar should keep stable dimensions for controls so changing count text or button states does not shift the editor layout.

## Commands and Shortcuts

The app commands post richer editor find notifications:

- Find: `Cmd-F`
- Find and Replace: `Cmd-R`
- Find Next: `Cmd-G`
- Find Previous: `Cmd-Shift-G`

The existing `ShortcutAction.findAndReplace` raw action should be retained for settings compatibility, but relabeled and re-defaulted as the configurable Find action with `Cmd-F`. A new shortcut action owns Find and Replace with default `Cmd-R`.

`Cmd-G` and `Cmd-Shift-G` are fixed standard editor commands rather than user-configurable shortcuts, matching common macOS editor behavior.

Terminal focus must not reserve these editor shortcuts. The command buttons should remain disabled when there is no active code editor tab.

## Highlighting

Find highlighting is a small editor-scoped helper that applies temporary background attributes through the active text view/layout manager for all current matches. The active match is represented by the normal text selection; non-active matches receive the temporary highlight.

Highlights clear when:

- the query becomes empty
- the bar closes
- the tab detaches
- the text view changes
- the active editor changes

The syntax highlighter and LSP coordinator remain responsible for their existing attributes. Find highlighting should not be folded into the Tree-sitter or LSP feature code.

## Data Flow

1. A command posts an editor find request with a mode or navigation direction.
2. The active `EditorTabView` receives it and opens or updates the find bar.
3. `EditorTabView` optionally prefills from the current single-line editor selection.
4. User edits to the query or case toggle update `EditorFindController`.
5. The controller recomputes matches and selects an appropriate active match.
6. The highlight helper redraws non-active matches.
7. Navigation changes the active match and scrolls it into view.
8. Replacement uses `CodeTextView.insertText(_:replacementRange:)` so undo, dirty tracking, auto-pair suppression, and LSP edit propagation use existing editor paths.

## Error Handling and Edge Cases

No active text view: find commands do nothing.

Empty query: no matches, no highlight, replacement buttons disabled.

No matches: show `No matches`, leave document text unchanged.

Read-only text view: replacement operations return no mutation and leave text unchanged.

Replacement changes match ranges: recompute matches after each replacement operation.

Selection prefill: only use selected text when the selected range is non-empty and does not include a line break. Multi-cursor selections do not prefill from multiple ranges.

## Testing

Tests should be added before implementation for controller behavior:

- default case-insensitive matching
- case-sensitive toggle
- match index and count
- next and previous wrapping
- empty query behavior
- selected-match replacement under case-insensitive matching
- replace current recomputes and advances
- replace all count and document mutation
- read-only replacement no-op

Shortcut tests should update the expected defaults for Find and Find and Replace, verify no duplicate defaults, and cover the new action grouping.

UI behavior that is difficult to unit test should be covered by focused Swift tests around notification payload parsing and tab-level state helpers where practical.
