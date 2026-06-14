# Create PR Diff Review Surface Design

## Context

The create PR/MR tab currently has its own lower context browser: commits on the
left, changed files below them, and a selected-file diff preview on the right.
That preview already uses the newer `DiffPaneView`, but the surrounding
navigation and preview flow predate the shared multi-file review surface.

The rest of the app now uses `DiffReviewSurface` for review-oriented file
navigation: collapsible file rail, scroll-synced stacked file sections,
split/stacked controls, wrapping, whitespace visibility, virtualization, and the
polished diff card treatment. The create PR/MR draft tab should use that same
surface so drafting and reviewing a PR feel like the same workflow.

## Goals

- Replace the create PR/MR tab's custom file list and selected-file preview with
  the shared `DiffReviewSurface`.
- Keep the title/body/draft/create controls unchanged.
- Preserve branch context loading from `ReviewRequestDraftContext`.
- Preserve selected-file persistence through `DraftReviewRequestTabState.selectedPath`.
- Preserve split/stacked, wrap, and whitespace preferences through
  `DiffPreferenceBindings`.
- Keep the create PR/MR draft surface focused on committed branch changes.
- Keep uncommitted changes excluded and keep the existing warning when they are
  present.

## Non-Goals

- Do not add review comments, CI rows, or feedback actions to the create PR/MR
  draft surface.
- Do not change provider create APIs or validation rules.
- Do not change how the AI-generated title/body prompt is built.
- Do not render uncommitted changes in this tab.
- Do not redesign the top editor composer.

## User Experience

The top composer remains the first thing in the tab. It still shows the target
provider, repository, branch, base branch, title/body fields, draft checkbox,
generate action, and create action.

The lower context area becomes a branch-review surface:

- A compact branch context header shows commit count, file count, total
  additions/deletions, and the current base/head range.
- Commits remain available as context, but they should not compete with the file
  rail. V1 should show them in a compact strip or collapsible context section
  above the diff review surface.
- The main area is `DiffReviewSurface`:
  - left collapsible file rail
  - one vertical stack of file diff cards
  - scroll spy updates the selected file in the rail
  - clicking a file in the rail scrolls to that file section
  - split/stacked, wrap, and whitespace controls use the same preferences as
    other diff surfaces

Source badges should be hidden because the draft context is a single committed
branch diff, not a staged/unstaged grouped session. File sections should still
show path, status, additions, deletions, gutters, hunk headers, collapsed
context controls, LSP-aware diff behavior where available, and non-renderable
file placeholders.

When the branch has no committed diff, the lower context area should show the
existing empty state, not a blank rail.

## Data Flow

`DraftReviewRequestTabView` continues to load `ReviewRequestDraftContext` via:

```swift
git.reviewRequestDraftContext(worktreePath:baseRef:)
```

After the context loads, a new pure builder converts it into
`DiffReviewLoadedSession`.

The builder should:

- iterate over `ReviewRequestDraftContext.changedFiles`
- read each file's raw diff from `fileDiffsByPath`
- parse each raw diff with `DiffParser`
- build a `DiffDisplayModel` off the main actor for renderable text diffs
- produce a `DiffReviewFileSummary` with namespace `draft-review-request`
- preserve `originalPath`, status, additions, and deletions from
  `CommitChangedFile`
- use parsed hunk counts for display counts when available, while preserving
  `CommitChangedFile` counts for no-hunk placeholders
- mark image and no-hunk files as non-renderable placeholders
- attach an `openFile` closure for files that exist in the worktree

The loaded session uses `groupsEnabled: false`.

`selectedPath` remains the persisted tab state. The view maps it to and from
`DiffReviewFileID(namespace: "draft-review-request", path: selectedPath)`.
When a new context loads:

- if the persisted path exists in the loaded session, select it
- otherwise select the first file
- when the user selects a file in the rail or scrolls to a file, persist that
  path back to `DraftReviewRequestTabState.selectedPath`

## Rendering Integration

`DraftReviewRequestTabView` should remove the selected-file preview path:

- remove `selectedDisplayPreview`
- remove `selectedDisplayPreviewLoadingKey`
- remove `selectedDisplayPreviewTask`
- remove `DraftReviewRequestDiffDisplayPreview`
- remove `DraftReviewRequestDiffPreviewView`

The tab should instead own:

- `draftReviewSession: DiffReviewLoadedSession?`
- `selectedFileID: DiffReviewFileID?`
- `railCollapsed: Bool`
- a load token/key for race-safe session publication if the existing context key
  is not sufficient after async display-model building

The right/bottom context pane should render `DiffReviewSurface` with:

- `showsSourceBadges: false`
- `showsRailDisplayControls: true`, so create PR/MR uses the same rail-level
  split/stacked, wrap, and whitespace controls as the review surfaces
- `inlineFeedbackByFileID: [:]`
- no inline feedback actions
- `lspContextForFile` matching the review changes surface when the file exists
  locally

The existing manual file list and raw branch diff fallback should be removed.
The aggregate raw diff is still used for AI prompt generation.

## Error Handling

If context loading fails, keep the current error message behavior.

If a single file diff cannot be rendered:

- keep that file in the rail
- show a placeholder in the stack
- do not fail the whole draft context

If the context changes while display models are building, stale results must not
publish into the view. Cancellation checks should happen before and after
detached display-model construction.

## Testing

Add focused tests for the new builder:

- converts a draft context with one modified file into a
  `DiffReviewLoadedSession`
- preserves status, original path, additions, deletions, namespace, and path
- marks image/no-hunk files as placeholders while keeping them in the session
- builds display models off the parsed file diffs
- preserves the old selected path when the loaded session still contains it
- falls back to the first file when the selected path is missing

Update existing draft review request view tests:

- remove expectations for `DraftReviewRequestDiffPreviewView`
- assert the draft surface hosts the shared `DiffReviewSurface`/diff section
  structure for committed branch diffs
- assert split mode exposes the native diff text panes through the shared
  surface

Final verification remains:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
