# Commit Detail Review Stack Design

## Goal

Bring the multi-file review experience into read-only commit details while preserving the existing commit metadata header. The commit detail tab should show a file rail and a stacked diff stream for every file in the commit, matching the diffs.com-inspired Review Changes experience.

## Scope

V1 applies only to `CommitTabView`, the read-only commit detail surface.

In scope:

- Keep `CommitHeaderView` unchanged at the top of the tab.
- Replace the lower selected-file split pane with a multi-file review surface.
- Show a collapsible file rail on the left.
- Show all changed files in a continuous diff stack on the right.
- Keep rail selection synchronized with scroll position.
- Scroll to a file when its rail row is selected.
- Reuse existing diff display preferences for split/stacked layout, wrapping, and whitespace.
- Preserve `Open File` behavior for files that exist in the working tree.
- Keep unsupported files visible with placeholder cards.

Out of scope for V1:

- `CommitEditorTabView`.
- `DraftCommitTabView`.
- Drop file or drop hunk actions.
- Incremental per-file streaming.
- Remote provider review comments.
- Image diff rendering inside the commit review stack. Images remain placeholder cards in V1.

Fast follow:

- Apply the same shared surface to `CommitEditorTabView`, with drop-file and drop-hunk actions.
- Apply the same shared surface to `DraftCommitTabView`, with unstage actions.
- Add per-file progressive loading if large commits need it.

## Architecture

Extract the reusable rail and stacked stream shell from the current Review Changes implementation. The result should be a generic multi-file diff review surface that is not tied to staged or unstaged working-tree concepts.

New or refactored components:

- `DiffReviewSessionModel`: generic session summary and file section model.
- `DiffReviewRail`: shared left rail with collapsed and expanded modes.
- `DiffReviewFileSection`: shared file card that embeds `DiffPaneView`.
- `DiffReviewSurface`: shared layout shell with rail, vertical stream, programmatic scrolling, and scroll-spy selection.
- `CommitReviewLoader`: read-only commit loader that turns `CommitDetails.files` into a `DiffReviewSessionModel`.

Review Changes migrates to these shared components through thin adapters. Working-tree-specific concepts such as staged and unstaged sources belong in Review Changes adapters, not in the shared surface.

`CommitDiffView` remains in the codebase for editor and draft commit surfaces until their fast follow migrations.

## Commit Data Flow

`CommitTabView` keeps its existing details load:

1. Load `CommitDetails` for the selected SHA.
2. Render `CommitHeaderView` from those details.
3. Ask `CommitReviewLoader` to load a multi-file review session from `details.files`.

For each file:

1. Call `GitService.diff(worktreePath:sha:file:originalPath:)`.
2. Pass `originalPath` for renames and copies.
3. Build the `DiffDisplayModel` off-main.
4. Derive add/delete counts from the parsed diff.
5. Return a renderable file section when the parsed diff has text hunks and the file is not an unsupported image.
6. Return a placeholder section for unsupported or empty text diffs.

The initial V1 loader can load the whole commit stack as one async operation. It should still check cancellation between files and before publishing the loaded session, so switching commits does not publish stale content.

## UI Behavior

The read-only commit detail layout becomes:

- Top region: existing commit header.
- Body region: shared review surface.

The left rail:

- Is collapsible.
- Uses the same visual language as the Review Changes rail.
- Groups files by directory.
- Does not show staged or unstaged source headers.
- Shows file status and add/delete counts.
- Tracks the currently visible file while scrolling.
- Scrolls the main stack to a selected file when clicked.

The main stack:

- Shows one card per commit file.
- Uses the shared diffs.com-style diff pane inside each card.
- Applies split/stacked layout globally across all file cards.
- Applies wrapping and whitespace preferences globally.
- Hides per-file `DiffPaneView` toolbars.
- Shows an `Open File` action when the file is available in the working tree.
- Shows placeholder cards for images, unsupported files, and files with no text diff.

Commit-specific destructive actions are not shown in V1. Read-only commit detail should inspect commits, not rewrite them.

## Review Changes Compatibility

The extraction must preserve current Review Changes behavior:

- Left rail remains collapsible.
- Staged and unstaged sections still appear in Review Changes.
- Scroll-spy selection still tracks the visible file.
- Rail clicks still scroll to file sections.
- File cards still use `DiffPaneView` without per-file toolbar.
- Review Changes load key behavior from the merged PR remains intact.

Any shared model should support optional source grouping so Review Changes can keep staged and unstaged sections while commit details omit them.

## Testing

Shared surface tests should cover:

- Rail and file sections render from the shared session model.
- Collapsed rail keeps selectable file markers.
- Selecting a rail row updates selection and can trigger programmatic scroll.
- Embedded `DiffPaneView` does not show a per-file toolbar.
- Review Changes still renders through the shared surface with staged and unstaged grouping.

Commit loader tests should cover:

- Multiple commit files load into one session.
- Commit file order is preserved.
- Renames and copies pass `originalPath`.
- Add/delete counts are derived from parsed diffs.
- Unsupported files remain visible as placeholders.
- Display models are built off-main and not from SwiftUI body evaluation.
- Cancellation prevents stale sessions from being published.

Commit tab integration tests should cover:

- `CommitHeaderView` still renders above the body.
- The body hosts the shared review surface.
- Existing selected-file `CommitDiffView` tests remain for editor and draft commit surfaces.

## Migration Plan

1. Extract the shared review surface from `ReviewChangesTabView` and keep Review Changes behavior equivalent.
2. Add `CommitReviewLoader`.
3. Update `CommitTabView` to render `CommitHeaderView` plus the shared review surface.
4. Keep `CommitDiffView` and selected-file commit loading in place for `CommitEditorTabView` and `DraftCommitTabView`.
5. Verify focused shared-surface, Review Changes, commit loader, and commit tab tests, then run the project build and full test suite before implementation is considered complete.
