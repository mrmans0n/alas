# Draft Commit Stacked Diffs Design

## Goal

Use the shared file rail and stacked/split all-files diff surface in the draft commit tab. The commit message composer stays unchanged at the top of the pane. Only the lower staged-file review area changes.

## Current State

`DraftCommitTabView` currently renders staged files with `CommitFilesListView` on the left and a single selected `CommitDiffView` on the right. This differs from Review Changes and commit review tabs, which use `DiffReviewSurface` for the file rail, scroll-synced all-files diff, and shared split/stacked display controls.

The existing draft commit behavior also supports:

- persisting subject, body, amend mode, and selected staged path in `DraftCommitTabState`
- refreshing when the right-pane staged change fingerprint changes
- unstaging a full staged file
- unstaging an eligible staged hunk
- refreshing the right pane after staging mutations

Those behaviors must remain intact.

## Proposed Approach

Add a small staged-diff loading path for the draft commit tab and render its result through `DiffReviewSurface`.

The loader should be focused on staged/index diffs. It will:

- load staged files with `GitService.stagedChangedFiles(at:)`
- load each file diff with `GitService.diff(worktreePath:file:staged:originalPath:)`
- build `DiffReviewFileSectionModel` values with a staged namespace
- build text display models for renderable non-image diffs
- provide placeholders for files that the shared review surface cannot render
- attach staged mutation actions needed by the draft commit pane

`DraftCommitTabView` will keep `CommitMessageEditorView` and amend warning UI as-is. Below that, it will render:

- a loading state while staged diff sections are loading
- the existing empty copy when no staged changes exist
- an error state when staged files or staged diffs fail to load
- `DiffReviewSurface` when staged sections are available

The shared surface will use the app-wide diff preferences through `DiffPreferenceBindings`, preserving existing behavior for split/stacked layout, line wrapping, and whitespace display.

## Selection

The draft tab currently persists `selectedPath`. The new surface uses `DiffReviewFileID`. The tab should bridge the two:

- when hydrating tab state, turn the stored selected path into `DiffReviewFileID(namespace: "staged", path: selectedPath)`
- when the user selects a file through the rail or scroll-synced surface, persist `selectedFileID?.path`
- when a staged refresh removes the selected file, fall back to the first staged file and persist that path
- when no staged files remain, clear the selected path

This preserves tab restoration without changing the serialized tab model.

## Actions

The draft commit pane must continue to support unstaging staged content.

Full-file unstage remains equivalent to the current `unstageFile(_:)` behavior, including passing both the new and original path for staged renames or copies when `originalPath` is present.

Hunk unstage remains available only when the file and hunk are eligible under the current rule:

- the draft tab is not busy
- the file status is `M`
- the hunk has at least one line

The shared file section needs an action surface for draft-commit staged mutations. This can be implemented as a small optional action model on `DiffReviewFileSectionModel` or `DiffReviewFileSection`, scoped to file-level and hunk-level actions. Other review surfaces should keep their current default behavior when these actions are absent.

## Data Flow

1. `stagedKey` changes when the right-pane staged change fingerprint changes.
2. `DraftCommitTabView` starts a staged review session load.
3. The loader builds a `DiffReviewLoadedSession` from staged files and staged diffs.
4. The tab synchronizes `selectedFileID` with the loaded file set and persisted `selectedPath`.
5. `DiffReviewSurface` renders the file rail and all staged file sections.
6. File or hunk unstage actions call the existing git operations.
7. After mutation, the tab reloads the staged session and refreshes the right pane.

## Error Handling

Loading errors should set the draft tab error and show a lower-pane error state without clearing the composer. Staging mutation errors should reuse the existing error display in `CommitMessageEditorView`.

Cancelled or stale loads must not overwrite newer staged sessions. Use the same active-key pattern already present in the tab or the load-token pattern used by `ReviewChangesTabView`.

## Testing

Add focused Swift Testing coverage where practical:

- staged loader builds a `DiffReviewLoadedSession` with staged namespace, counts, original paths, and renderability
- selected path to selected file ID bridging handles restoration, removal, and empty staged sets
- optional file/hunk action defaults do not affect other `DiffReviewSurface` consumers
- hunk unstage availability matches the current draft commit rule

Run the project verification commands after implementation:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

## Out of Scope

- changing the commit message composer layout
- changing amend prefill or amend warning behavior
- adding review draft comments to the draft commit tab
- adding image diff support to the shared review surface
- changing `DraftCommitTabState` serialization
