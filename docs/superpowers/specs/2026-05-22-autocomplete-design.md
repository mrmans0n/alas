# IDE Autocomplete Design

## Context

Alas already has a native AppKit-backed code editor with LSP features for diagnostics, hover, definitions, symbols, formatting, and language-server installation. `EditorBuffer` owns file contents, dirty state, hot-exit snapshots, file watching, LSP document open/close, and debounced `didChange`. `CodeEditorCoordinator` owns mounted editor features such as hover, definition, hover highlight, diagnostics rendering, syntax highlighting, and active client/URI lookup.

Autocomplete should extend this existing LSP path instead of introducing a parallel editor or language-service lifecycle.

## Goals

- Provide IDE-level autocomplete in code editor panes.
- Support both automatic suggestions while typing and a manual completion trigger.
- Use LSP completions as the primary source.
- Show a compact popup for suggestions and documentation.
- Fall back to current-buffer word completions when LSP is unavailable, slow, or returns no useful items.
- Keep v1 focused: no snippet expansion engine, no persistent ranking, no workspace-symbol fallback, and no signature-help integration.

## User Experience

Autocomplete appears only in editable in-worktree editor buffers with a single caret. It is disabled for read-only external buffers, multi-cursor mode, unsupported languages, and states where there is no usable caret position.

Automatic suggestions appear after a short debounce when typing creates a useful prefix. Manual completion opens through an explicit keyboard command and may request completions even for a short or empty prefix when an LSP client is ready.

The visual model follows the popup-first design that replaced inline preview after user testing:

- A compact popup anchored near the caret lists completions.
- `Tab` accepts the top match.
- `Return` accepts the selected popup item.
- Up/down arrows move the popup selection.
- `Esc` dismisses the current completion session.
- Continued typing filters existing candidates and may schedule a fresh LSP request.

Completion closes on cursor movement, selection changes, buffer rebind, tab switch, unsupported edit states, or stale request results.

## Architecture

Autocomplete is a new coordinator-owned LSP feature, parallel to hover and definition.

### `CodeTextView`

`CodeTextView` remains the editor surface. It should expose the small hooks needed by completion:

- Key routing while a completion session is open.
- Caret-to-LSP-position and caret-rect helpers.
- Safe text edit application through the normal `NSTextView` editing path.
- Session invalidation signals for selection movement and editing states that should dismiss completion.

The view should not own LSP request logic or candidate ranking.

### `CodeEditorCoordinator`

`CodeEditorCoordinator` constructs and tears down `CompletionFeature` alongside `HoverFeature`, `DefinitionFeature`, and `HoverHighlightFeature`. It should pass closures that resolve the active `LSPClient` and document URI using the same patterns already used by hover and definition, including external-origin handling where applicable.

Coordinator rebind/detach paths must dismiss active completion UI and cancel outstanding completion work.

### `CompletionFeature`

`CompletionFeature` owns the completion session:

- Automatic debounce and manual trigger handling.
- LSP request cancellation and stale-response guards.
- Candidate normalization, filtering, ranking, and fallback merging.
- Popup presentation.
- Keyboard navigation and acceptance.
- Applying the accepted item into the editor.

The feature should be `@MainActor` for UI state, with async LSP requests guarded by request IDs, active URI checks, and current caret position checks before presenting results.

### LSP Layer

`LSPMessages` gains typed completion models for request parameters and results. `LSPClient` gains `completion(uri:position:context:)`.

`WorkspaceLSPManager` does not need a new lifecycle role for v1. `EditorBuffer` already opens documents, updates text through debounced `didChange`, and closes documents when buffers are released. Completion should use the active client that already serves the open document.

## Completion Data

The decoder must support both valid LSP result shapes:

- `CompletionItem[]`
- `CompletionList`

Completion items should preserve:

- `label`
- `kind`
- `detail`
- `documentation`
- `sortText`
- `filterText`
- `insertText`
- `insertTextFormat`
- `textEdit`
- `additionalTextEdits`

v1 treats plain-text insertions as first-class. Snippet-formatted items may be shown, but acceptance uses a conservative plain-text fallback rather than interpreting placeholder syntax. Snippet expansion is explicitly out of scope for this design.

## Candidate Sources

LSP completions are the primary source. Current-buffer word completions are a fallback source when LSP is unavailable, times out, or returns no useful candidates. The fallback should:

- Extract identifier-like words from the active buffer.
- Exclude the current prefix as an exact duplicate.
- Prefer words that start with the typed prefix.
- Avoid adding persistent global state.

LSP and fallback candidates should not be presented as two separate modes to the user; the feature presents one candidate list with source-specific metadata kept internal.

## Applying Completions

When accepting a completion:

1. Prefer the LSP item's `textEdit` range and replacement text when present.
2. Otherwise replace the detected prefix immediately before the caret with `insertText` or `label`.
3. Apply non-overlapping `additionalTextEdits` in a stable order before the primary edit.
4. Reject or skip additional edits that overlap the primary edit or each other.
5. Perform edits through the editor's normal text mutation path so existing dirty tracking, undo, highlighting, hot-exit snapshots, and debounced LSP `didChange` continue to work.

After acceptance, the completion UI closes. The editor's existing observer path handles downstream state updates.

## Error Handling

Autocomplete should fail closed:

- If there is no LSP client, use buffer-word fallback.
- If the LSP request fails or times out, use fallback when possible.
- If a response arrives for an old request, old URI, old caret position, or unmounted view, discard it.
- If candidate application cannot produce a safe edit range, dismiss without changing text.
- If popup presentation cannot anchor to a visible caret, skip UI presentation.

Failures should not surface blocking alerts. Diagnostics are not part of autocomplete error reporting.

## Testing

Swift Testing coverage should focus on non-UI logic:

- Completion request encoding.
- Completion result decoding for array and `CompletionList` shapes.
- Completion item documentation/detail preservation.
- Prefix detection.
- Candidate filtering and ranking.
- Buffer-word fallback extraction.
- Snippet fallback stripping.
- Replacement range computation.
- `textEdit` and `additionalTextEdits` application ordering.
- Rejection of overlapping edits.

AppKit-focused tests should remain narrow:

- `CodeTextView` routes `Tab`, `Return`, arrows, and `Esc` only while completion is active.
- Completion dismisses on selection/caret states that invalidate the session.
- Accepted completions mutate text through the same observer path used by normal edits.

Manual verification should cover a real Swift project with `sourcekit-lsp`:

- Automatic suggestions after typing.
- Manual completion trigger.
- Top suggestion acceptance with `Tab`.
- Popup navigation and acceptance with `Return`.
- Fallback behavior with no live LSP.
- Stale responses do not flash old candidates.
- Completion UI does not appear in external read-only tabs or multi-cursor mode.

## Out Of Scope

- Snippet placeholder expansion.
- Signature help.
- Completion item resolve.
- Persistent ranking or telemetry.
- Workspace-wide symbol fallback.
- New language-server lifecycle management.
- Changes to language-server installation UX.
