---
title: "Shared diff renderer for commit and review drafts"
date: 2026-06-12
project: alas
phase: design
prior_art:
  - docs/superpowers/specs/2026-06-11-review-ready-diff-pane-design.md
  - docs/superpowers/specs/2026-06-12-multi-file-review-tab-design.md
  - Alas/Sources/Center/Diff/DiffPaneView.swift
  - Alas/Sources/Center/Diff/DiffDisplayModelBuilder.swift
  - Alas/Sources/Center/Commit/CommitDiffView.swift
  - Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift
---

## TL;DR

Use the new review-ready diff pane for the remaining first-class diff detail
surfaces that already own `ParsedDiff` data:

- commit details
- commit editor details
- draft commit details
- draft review request diff preview

The work should reuse the existing `DiffPaneView` and `DiffDisplayModel`
pipeline. It should not introduce a second renderer, change git/provider
loading behavior, or migrate unrelated inline ACP diffs.

## Product Direction

The new diff pane is now the app's high-quality code review surface. Commit and
draft review request screens still use the older `HunkView`/`DiffSelectableText`
renderer, which makes the app feel inconsistent and keeps visual fixes split
across two stacks.

This pass makes the polished split/stacked renderer the standard UI for commit
and PR-draft diff details while preserving each screen's current workflow:
file selection, image diffs, loading states, open-file behavior, and hunk-drop
actions.

## Scope

### In Scope

- Replace text diff rendering inside `CommitDiffView` with `DiffPaneView`.
- Preserve `CommitDiffView` image handling via `ImageDiffView`.
- Preserve commit detail loading and file selection behavior.
- Preserve commit editor and draft commit hunk-drop behavior by mapping
  enabled hunks to `DiffPaneHunkActions.dropFromCommit`.
- Replace text diff rendering inside `DraftReviewRequestDiffPreviewView` with
  `DiffPaneView`.
- Reuse persisted diff preferences from `AppConfig.changes`:
  - split/stacked layout
  - line wrapping
  - whitespace visibility
- Render these detail views in embedded/static-height mode so they fit their
  existing containers.
- Add focused tests proving the commit and draft review request preview paths
  host the new AppKit-backed diff pane.

### Out Of Scope

- Remote GitHub/GitLab review comments or threads.
- Provider-side PR/MR detail loading changes.
- Multi-file PR detail navigation.
- ACP inline diff migration.
- Deleting `HunkView` or `DiffSelectableTextView`; they remain for surfaces
  that still use them.
- New diff preferences.
- New image diff behavior.

## Architecture

`CommitDiffView` should stay the shared commit diff wrapper. It already owns
the file header, image diff branch, loading/error/empty states, open-file
action, and optional hunk-drop action. Only the non-image text content should
change.

For text content, `CommitDiffView` builds:

```swift
let model = DiffDisplayModelBuilder.build(diff: diff, filePath: path)
```

Then it renders:

```swift
DiffPaneView(
    model: model,
    fileExtension: LanguageRegistry.highlighterExtension(forPath: path),
    layoutMode: ...,
    wrapLines: ...,
    showWhitespace: ...,
    showsToolbar: false,
    verticalScrollMode: .staticHeight,
    hunkActions: ...
)
```

The `hunkActions` closure should return a `dropFromCommit` action only when
the existing `dropHunkEnabled(file, hunk)` says it is available.

`DraftReviewRequestDiffPreviewView` follows the same model-building path from
its parsed raw diff, but its `hunkActions` closure returns no actions.

## Preferences

These surfaces should use the same app-level diff display preferences as
single-file and multi-file review diffs. The most direct integration is to pass
bindings from the owning views into `CommitDiffView` and
`DraftReviewRequestDiffPreviewView`.

For commit surfaces, callers already have `AppState`, so the bindings should
read/write:

- `appState.config.changes.diffLayoutMode`
- `appState.config.changes.diffWrapLines`
- `appState.config.changes.diffShowWhitespace`

Each setter should call `appState.saveConfig()`, matching the existing diff tab
preference pattern.

For the draft review request preview, the parent tab also has `AppState`, so it
should pass the same bindings into the preview view.

## UX

Commit detail and draft review request screens keep their existing surrounding
layout. The diff body changes to the polished renderer:

- split/stacked layout support
- aligned gutters
- themed add/delete backgrounds
- inline highlights
- collapsed unchanged regions
- native selectable text

The per-file commit header remains outside the diff pane. The embedded
`DiffPaneView` should hide its toolbar so these screens do not get nested
toolbars. Users control layout/wrap/whitespace from existing global diff
preferences rather than per-surface controls.

Image files continue to render as image diffs, not text diffs.

## Testing

Add or update tests for:

- `CommitDiffView` renders `DiffPaneTextScrollView` for a text `ParsedDiff`.
- `CommitDiffView` does not render the old hunk body for text diffs in this
  path.
- `CommitDiffView` maps enabled drop-hunk actions to a visible hunk action in
  the new pane.
- `DraftReviewRequestDiffPreviewView` renders `DiffPaneTextScrollView` for a
  parsed text diff.
- Existing image-diff behavior remains covered by current image tests.

Keep existing `HunkView` tests because `HunkView` remains valid for older
inline surfaces and direct renderer tests.

## Risks

- `DiffPaneView` static-height rendering is heavier than the old hunk renderer.
  The migration should rely on the existing AppKit diff body and recent scroll
  churn fixes rather than adding another rendering path.
- Hunk action mapping must preserve identity by using `sourceHunk` from the
  display model. Tests should cover that an enabled commit hunk exposes the
  drop action.
- Preference bindings must not create save loops. Setters should only save when
  assigning new values from user-triggered UI.
