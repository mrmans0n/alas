# Shared Composer Paired Delimiters

## Goal

Give authored-content fields throughout Alas the code editor's paired-delimiter behavior. Typing a supported opener around selected text must wrap the selection instead of replacing it. Empty-caret pairing and closer step-over must behave consistently as well.

This behavior belongs to content composition, not to every editable control.

## Supported Behavior

The canonical pairs remain exactly those supported by `CodeTextView`:

- `(` and `)`
- `[` and `]`
- `{` and `}`
- `"` and `"`
- `'` and `'`
- `` ` `` and `` ` ``

For a non-empty selection, typing an opener wraps the selected content and keeps the inner content selected. For an empty selection, typing an opener inserts both delimiters and leaves the caret between them. Typing a closer when the same closer is immediately ahead moves the caret past the existing character.

Symmetric delimiters retain the code editor's safeguards: empty-caret auto-pairing does not activate when the delimiter is escaped or directly adjacent to identifier-like text. These safeguards do not prevent wrapping an explicit selection.

Paste, dictation, marked-text composition, and other multi-character input bypass pairing. If the selection or text-storage state is invalid, the control falls back to native insertion so user input is never discarded.

## Surface Boundary

Pair-aware editing applies to fields whose primary purpose is authoring content:

- ACP prompts
- commit subjects and bodies
- review-request titles and descriptions
- review comments and replies
- Mission instructions and prompts
- reusable prompt editors
- script editors

It does not apply to utility or identity inputs, including search and filter controls, names, paths, branches, picker queries, and session titles. The implementation plan must inventory current call sites against this rule rather than migrating every `TextField` or `TextEditor` mechanically.

## Architecture

### Shared decision engine

Add a small, pure `PairedDelimiterEditing` component that owns the pair table and resolves a single-character insertion into one of four outcomes:

1. wrap the current selection;
2. insert an empty pair;
3. move past an existing closer;
4. use native insertion.

The resolver accepts the typed character, selected range, and the adjacent text it needs for contextual safeguards. It does not own a view, mutate text storage, or depend on SwiftUI. This makes the behavior independently testable and keeps every surface on one canonical rule set.

### AppKit adapters

View-specific adapters apply the resolved action through their native editing APIs:

- `CodeTextView` uses the shared rules while retaining its existing multi-cursor, indentation, completion, and edit-notification behavior.
- `ACPNSTextView` applies wrappers directly around the selected attributed range. It inserts only the delimiter characters, preserving Markdown attributes, mention chips, image attachments, and other attributed content inside the selection.
- Reusable AppKit-backed single-line and multiline composer controls expose SwiftUI bindings while providing pair-aware insertion to the remaining authored-content surfaces.

The controls must preserve current visual chrome, typography, sizing, scrolling, focus bindings, submit shortcuts, enabled/read-only state, and accessibility identifiers. Pairing is an editing capability, not a visual redesign.

### Editing semantics

Each pair operation is one undoable user edit. Selection and caret updates use UTF-16 ranges, matching AppKit. Normal delegate and text-change notifications continue to fire so SwiftUI bindings, ACP draft persistence, Markdown restyling, and dirty-state tracking observe the final edit.

ACP attributed selections must never be flattened to plain text. Programmatic replacements and synchronization updates do not invoke auto-pairing.

## Error Handling and Compatibility

The resolver returns native insertion for unsupported characters, multi-character input, invalid ranges, or insufficient context. Adapters must validate ranges against their current storage before mutation and fall back rather than swallow input.

Refactoring `CodeTextView` must preserve its current behavior exactly, including multi-cursor pairing and closing-delimiter indentation. The shared component owns delimiter decisions only; editor-specific behavior remains in the editor adapter.

## Testing

Add focused coverage at four levels:

1. Pure resolver tests cover all six pairs, selected and empty ranges, closer step-over, escaping, identifier adjacency, invalid ranges, and multi-character input.
2. Existing `CodeTextView` tests remain compatibility coverage, including multi-cursor cases.
3. ACP tests prove that wrapping styled text and attachment chips preserves attributes, selection, draft synchronization, and single-step undo.
4. Reusable composer-control and representative surface tests cover binding updates, focus preservation, disabled/read-only behavior, undo, and the intended inclusion/exclusion boundary.

Implementation verification proceeds from focused tests to project generation, the full macOS test suite, and a macOS build, following the repository's standard gates.

## Non-Goals

- Adding configurable delimiter sets or a settings toggle
- Markdown-aware toggling that removes an existing wrapper
- Changing the appearance or layout of composer fields
- Adding pairing to search, naming, path, branch, picker, or session-title inputs
- Expanding beyond the six delimiters already supported by the code editor
