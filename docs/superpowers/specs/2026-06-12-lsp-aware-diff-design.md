# LSP-Aware Diff Design

## Goal

Make the new diff and review surfaces LSP-aware for code review without turning
them into editors. The first version supports hover/type information and
Cmd-click go-to-definition on the current/new side of text diffs. Completion,
diagnostics, old-side intelligence, and historical virtual documents are out of
scope.

## Context

Alas already has editor LSP support through `CodeEditorCoordinator`,
`EditorBuffer`, and `WorkspaceLSPManager`. The review surfaces render diffs
through `DiffPaneView`, `DiffPaneTextDocumentView`, and
`DiffPaneCodeTextView`. `DiffDisplayLine` already carries source line numbers
for old and new sides, which gives the diff enough information to map visible
new-side rows back to positions in the real worktree file.

Current manual testing documents the diff pane as syntax-highlight-only. This
feature changes that behavior for renderable text diffs when a matching
language server is available.

## User-Facing Behavior

- Hover over a symbol on a new/current-side diff line to show the same hover
  information style used by the editor.
- Cmd-click a symbol on a new/current-side diff line to go to its definition.
- Old/deleted-side lines remain plain selectable diff text.
- Files without a configured language server, deleted files, binary/image
  files, or unrenderable diffs keep today's behavior.
- LSP failures are quiet in the diff body: no popup, no inline error, and no
  interruption to text selection.

## Architecture

Add a small read-only LSP layer around the existing diff text views.

`DiffPaneLSPContext` describes the real document behind a rendered diff:
worktree id, worktree root, relative path, inferred language id, and the
navigation closure used to open definitions in editor tabs. The context is
optional and is only created for files that have a current worktree path and a
configured language.

`DiffPaneLSPLineMap` is a pure mapping helper. It converts a character location
inside a rendered diff text view into an LSP position for the real current file.
It only returns positions for new-side lines. Split mode maps only the new
pane. Stacked mode maps only rows whose anchor side is `.new`.

`DiffPaneLSPController` is the AppKit lifecycle object attached to a
`DiffPaneCodeTextView`. It installs hover and Cmd-click handlers, asks the line
map for a real-file position, requests LSP hover or definition data from the
existing LSP client, and reuses the editor popup/navigation behavior where
practical.

`DiffPaneTextDocumentBuilder.CodeDocument.LineMetadata` carries the source
`DiffDisplayLine` for rows backed by real diff lines. This keeps the mapping
close to the rendered attributed string instead of reconstructing rows from the
display model later.

When a diff file has no already-open editor buffer, the controller opens a
balanced read-only LSP retain for the current worktree file by loading the file
text from disk and calling the existing document-open path. The retain is owned
by the mounted diff text view and is released when that view is replaced or
tears down.

## Data Flow

When a diff file renders:

1. The existing loader builds `ParsedDiff` and `DiffDisplayModel`.
2. The owning tab builds an optional `DiffPaneLSPContext` if the file has a
   current worktree path and maps to a configured language.
3. `DiffPaneTextDocumentBuilder` emits attributed text plus line metadata for
   every visible rendered row.
4. `DiffPaneTextScrollView` receives the document, metadata, and optional LSP
   context, then attaches or updates `DiffPaneLSPController`.
5. On hover or Cmd-click, the text view converts the mouse point to a character
   index.
6. `DiffPaneLSPLineMap` maps that character index to the real file URI and
   `LSPPosition(line: newLine - 1, character: offset)`.
7. The controller uses `WorkspaceLSPManager.openedClient(forFile:worktreeRoot:language:)`
   when a client already serves the file. If no client is open, it opens a
   read-only LSP retain using the current file text from disk, then releases
   that retain when the diff text view is replaced or tears down.
8. Hover displays the existing hover popup. Definition opens the resolved
   target through the same editor navigation path used by normal editor tabs.

LSP positions always target the real current file. The diff layer must not send
positions for synthetic diff text. If the diff has gone stale relative to disk,
the controller should prefer no result over sending a known-wrong request.

## Error Handling

- No language, no LSP config, unavailable server, blocked server, starting
  server, deleted file, or old-side line: do nothing.
- Hover timeout, definition timeout, empty response, or request failure: do
  nothing.
- Definition outside the worktree: reuse the editor's external read-only file
  behavior.
- Stale line or character mapping: skip the request.
- Background LSP opens created by a diff view must be balanced on teardown so a
  review tab does not leave servers running indefinitely.

## Testing

Unit tests should cover `DiffPaneLSPLineMap`:

- Split mode routes only new-pane rows.
- Stacked mode routes only `.new` lines.
- Old/deleted/collapsed/placeholder rows return no position.
- Character offsets outside the rendered source text return no position.
- Missing `newLine` returns no position.

AppKit-focused tests should cover:

- `DiffPaneTextScrollView` installs LSP handlers only when context exists.
- Updating a diff section replaces stale line metadata.
- Teardown removes hover/Cmd-click hooks and releases any retained LSP document.

Manual tests should update the existing diff-pane section:

- Stage or create a Swift change.
- Open the review diff.
- Hover over a symbol on the new/current side and confirm hover information
  appears after the language server is ready.
- Cmd-click a symbol on the new/current side and confirm Alas opens the
  definition in an editor tab.
- Confirm old/deleted-side hover still does nothing.
