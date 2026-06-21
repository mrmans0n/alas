# Changed File HEAD View and History Design

## Goal

Add three changed-file context menu actions:

- `View at HEAD`: open the committed `HEAD:<path>` content as a read-only tab.
- `Compare with HEAD`: open or focus the existing working-tree diff tab for the file.
- `File History`: open a path-scoped commit history tab.

This covers the common right-click workflow for comparing a dirty file with its committed version and reviewing prior changes to that file.

## Scope

In scope:

- File-level context menu items in `ChangedRow`.
- Callback plumbing through `WorkingTreeSectionView` and `ChangesTabView`.
- New tab state and views for a read-only HEAD snapshot and file history.
- Git helpers for reading `HEAD:<path>` and listing commits that touched a path.
- Tests for tab identity, GitService parsing, and callback/menu wiring where practical.

Out of scope:

- Blame / annotate.
- Folder history.
- Editing historical or HEAD snapshot content.
- Replacing the existing diff tab UI.

## User Experience

The changed-file context menu gains:

- `Open File`
- `View at HEAD`
- `Compare with HEAD`
- `File History`
- existing copy/reveal/diff/stage/discard/ignore actions

`View at HEAD` opens a read-only center tab titled like `filename @ HEAD`. The tab renders text with the same editor typography and syntax highlighting path where practical, but does not create an editable `EditorBuffer`. If the file is absent at `HEAD` or is not UTF-8 text, the tab shows a small empty/error state.

`Compare with HEAD` opens or focuses the current unstaged `DiffTabView` for the path. This makes the action explicit in the context menu while reusing existing diff behavior.

`File History` opens a center tab titled like `filename History`. It lists commits returned by `git log --follow -- <path>` newest-first using the existing `CommitRow` presentation. Selecting a row opens the existing commit tab for that SHA. Empty history and git failures show inline states inside the tab.

## Architecture

Add two new tab cases:

- `Tab.fileSnapshot(FileSnapshotTabState)`
- `Tab.fileHistory(FileHistoryTabState)`

The snapshot tab state contains `worktreeId`, `relativePath`, `ref` initially fixed to `HEAD`, and a stable ID keyed by all three. The history tab state contains `worktreeId` and `relativePath`, with a stable ID keyed by both. `TabsManager` gets open-or-focus helpers for both cases so repeated context-menu actions focus existing tabs.

Add center views:

- `FileSnapshotTabView`
- `FileHistoryTabView`

`CenterPaneView` renders the new tab cases. Snapshot loading happens in the snapshot view with `GitService.headBlobText(...)`. History loading happens in the history view with `GitService.fileHistory(...)`. Both views keep loading/error state local and reload when their tab key changes.

## Git Behavior

Add public GitService helpers:

- `headBlobText(worktreePath:relativePath:) async throws -> HeadBlobTextResult`
- `fileHistory(worktreePath:relativePath:limit:) async throws -> [CommitInfo]`

`HeadBlobTextResult` distinguishes `.available(String)`, `.missing`, and `.undisplayable` so the view can show the correct empty state. `headBlobText` uses `git show HEAD:<path>` via `Process.gitData`, returns `.missing` for absent blobs, returns `.undisplayable` for binary or non-UTF-8 content, and throws only for unexpected process failures that should surface as an error state.

`fileHistory` uses a single `git log --follow -n 200 --pretty=tformat:... --numstat -- <path>` pass and parses into the existing `CommitInfo` model. Rename following is handled by Git. The first version uses this fixed 200-commit limit without pagination.

Paths are passed as pathspecs after `--` and never interpolated into shell commands.

## Error Handling

`View at HEAD` is disabled for untracked added files. If a tracked file is deleted in the working tree, the action remains available because `HEAD:<path>` is exactly what the user wants.

Snapshot states:

- Loading: spinner.
- Missing at HEAD: `No HEAD version for <path>`.
- Binary or non-UTF-8: `HEAD version is not displayable as text`.
- Git error: concise error strip.

History states:

- Loading: spinner.
- Empty: `No history for <path>`.
- Git error: concise error strip with retry by re-opening or automatic task reload.

## Testing

Add focused tests:

- `TabsManagerTests`: snapshot and history tabs reuse existing tab IDs for the same worktree/path/ref and create distinct tabs for distinct paths.
- `GitServiceTests` or a dedicated file: `headBlobText` returns `.available` with committed text, returns `.missing` for paths missing at HEAD, returns `.undisplayable` for binary content, and `fileHistory` returns only commits touching the path.
- `ChangedRow` / `WorkingTreeSectionView` callback tests if the existing test harness supports SwiftUI context-menu inspection; otherwise cover callback plumbing with small model-level tests and rely on compile-time integration.

Manual verification:

- Modified tracked file: all three actions work.
- Deleted tracked file: `View at HEAD` works; `Open File` stays unavailable if the working-tree file is gone.
- Added untracked file: `View at HEAD` is disabled; `File History` shows empty history.
- Renamed file: history follows prior path where Git can detect the rename.
