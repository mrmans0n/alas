---
title: "Review-ready split and stacked diff pane"
date: 2026-06-11
project: alas
phase: design
prior_art:
  - Alas/Sources/Git/DiffParser.swift
  - Alas/Sources/Center/DiffTabView.swift
  - Alas/Sources/Center/DiffSelectableTextView.swift
  - Alas/Sources/Center/DiffSelectableTextBuilder.swift
  - Alas/Sources/Center/Commit/CommitDiffView.swift
  - Alas/Sources/ACP/UI/InlineDiffView.swift
  - Alas/Sources/Integrations/CodeHost/CodeHostModels.swift
  - Alas/Sources/Integrations/CodeHost/ReviewLoopHandoffBuilder.swift
---

## TL;DR

Replace the text rendering in single-file diff tabs with a native,
review-ready diff surface inspired by diffs.com and adapted to Alas themes.
V1 supports split and stacked layouts, inline word highlights, collapsed
unchanged regions, wrapping and whitespace controls, line/range selection, and
non-posting local review affordances.

The first implementation stays focused on working-tree and staged single-file
diff tabs. The renderer and anchors must be reusable so commit diffs,
draft-commit diffs, multi-file review, GitHub/GitLab review threads, and agent
handoff can layer on top as fast follows.

## Product Direction

Alas should move from a styled `git diff` transcript to a proper diff review
surface. The reader should feel like a native, focused code-review pane: clear
split comparison when there is space, stacked review flow when that reads
better, low-noise controls, strong syntax highlighting, and stable anchors for
future comments and agent handoff.

This feature is also the foundation for a later human review workflow. The
user should eventually be able to review local changes in Alas, read
GitHub/GitLab review comments, create their own review notes, and send selected
diff context to the current agent or another chosen agent.

## V1 Scope

### In Scope

- Replace text diff rendering in `DiffTabView` for working-tree and staged
  single-file tabs.
- Preserve image diff behavior through the existing `ImageDiffView` path.
- Preserve current file-level actions: open file and discard file.
- Preserve current hunk-level actions: stage hunk and discard hunk.
- Add `Split / Stacked` layout switching.
- Add inline word or token highlights for paired delete/add replacements.
- Add unchanged-region collapsing with expand controls.
- Add line wrapping and whitespace visibility controls.
- Add layout-neutral line and range selection.
- Add local, non-posting review affordances and in-memory draft note state
  suitable for future comment UI.
- Keep rendering native and theme-driven.

### Out Of Scope For V1

- Posting comments or replies to GitHub/GitLab.
- Resolving GitHub/GitLab review threads.
- Rendering remote review threads inside the diff.
- Multi-file review sessions.
- Review queue navigation.
- Full keyboard-first review workflow.
- Replacing commit and draft-commit diff views unless reuse is trivial during
  implementation.
- Replacing image diff behavior.
- Introducing a web diff viewer.

## UX Design

The diff tab remains code-first. Its header keeps the current file identity,
path, staged badge, change counts, open-file action, and discard-file action.
Below the header, a compact diff toolbar adds:

- segmented `Split / Stacked` mode
- wrap toggle
- whitespace toggle
- collapsed-context control
- optional overflow controls for copy and future review actions

In split layout, each render row has old and new cells. Context appears on both
sides, deletions appear on the old side, additions appear on the new side, and
empty cells use a quiet background. Replacement lines should be paired where
possible so inline highlights show exactly what changed inside the old and new
text.

In stacked layout, the same model renders sequentially: context rows, deleted
rows, added rows, and expandable unchanged regions. Stacked mode is both a
user-selectable layout and the natural fallback for narrow panes.

Large unchanged regions collapse into rows such as `24 unchanged lines`, with
controls to expand that region. Collapsed state belongs to view state, not the
loaded diff, so expanding does not reload or re-parse.

Hovering a line shows a subtle gutter affordance for selection or future
commenting. Clicking selects a line. Shift-click extends to a range. Selection
must survive switching between split and stacked because it is anchored to
file/side/line metadata rather than row indexes.

V1 exposes local note affordances as in-memory UI state only. A selected
line/range can open a small draft note surface, and clearing the tab clears the
draft. These notes are not provider-backed and do not imply remote posting
support.

## Architecture

Keep the existing git loading path and add a derived display model.

`ParsedDiff` remains the ingestion format. It is already used by staging,
discarding, ACP inline diffs, and commit diff views, and it preserves patch
details such as `\ No newline at end of file`. V1 should not replace that
contract.

Add a model builder, working name `DiffDisplayModelBuilder`, that converts a
`ParsedDiff` and file identity into render-ready groups:

- file path and display metadata
- hunk groups
- split-aligned rows
- stacked row representation
- old/new line numbers
- row kind: context, add, delete, replacement, empty, collapsed
- inline highlight spans
- stable anchors
- hunk action mapping back to the source `ParsedDiff.Hunk`

Add a reusable native renderer, working name `DiffPaneView`, with presentation
state:

- layout mode
- wrap enabled
- whitespace visible
- collapsed group expansion
- selected line/range anchors
- local draft note state

`DiffTabView` continues to own:

- `GitService.diff(...)` loading
- image-vs-text routing
- total additions/deletions
- tracked/deleted file detection
- file-level actions
- stage/discard hunk actions
- error and loading states

Commit and draft-commit views can continue using the current renderer until the
fast follow, but the new renderer should be designed so those views can pass an
already-loaded `ParsedDiff` into the same component later.

## Data Flow

1. `DiffTabView` asks `GitService.diff(worktreePath:file:staged:)`.
2. Git returns unified diff text.
3. `DiffParser` produces `ParsedDiff`.
4. `DiffTabView` computes totals and file state as it does today.
5. `DiffDisplayModelBuilder` builds render-ready groups through a pure,
   value-type API that `DiffTabView` can run off the main actor before
   publishing the display model.
6. `DiffPaneView` renders the display model using Alas theme tokens.
7. Hunk actions call back to the existing `DiffTabView` staging and discard
   paths with the original `ParsedDiff.Hunk`.

View state should be independent of parsing. Changing layout mode, wrapping,
whitespace visibility, expanded collapsed groups, or selected anchors must not
reload the diff.

## Anchors

Stable anchors are required in V1 because the future review features depend on
them. Anchor identity should be layout-neutral and derived from durable diff
metadata:

- file path
- hunk index or hunk identity
- side: old, new, or paired
- old line number when present
- new line number when present

Representative anchors:

- old-side anchor: file path + old line
- new-side anchor: file path + new line
- paired replacement anchor: file path + old line + new line
- range anchor: first anchor + last anchor + side/layout-neutral metadata

The exact ID string can be internal, but tests should prove anchors stay stable
when switching split/stacked layout and when collapsed regions expand.

## Inline Highlights

Inline highlights are computed in the display-model layer. Start with a
pragmatic pairing algorithm:

1. Within a contiguous change block, collect deleted lines and added lines.
2. Pair one delete with one add when counts match.
3. For near matches, pair lines by order when the block is small.
4. Tokenize by words and punctuation.
5. Mark changed token ranges on each side.
6. Fall back to full-line add/delete emphasis for complex many-to-many blocks.

This should produce useful highlights without turning V1 into a general-purpose
diff algorithm project.

## Rendering

Rendering should stay native. The current `DiffSelectableTextView` proves the
app can host selectable, syntax-highlighted AppKit text with custom gutters.
V1 can evolve that component or introduce a sibling AppKit-backed renderer if
split alignment and range selection are cleaner with a new structure.

Split layout should not use two independent vertical scroll views. The diff
body should have one vertical scroll source so old/new rows stay aligned. Each
group or row can render two columns inside that single scroll context.

Horizontal scrolling may be shared at the body level or handled per code pane
if AppKit text measurement makes that more reliable. The design requirement is
that vertical alignment is deterministic and layout changes do not lose
selection.

Syntax highlighting should keep using `TreeSitterHighlighter` per line and the
existing theme tokens:

- `add`
- `del`
- `bg-1`
- `bg-2`
- `fg`
- `fg-dim`
- `fg-faint`
- `accent`
- existing syntax tokens

No new theme tokens should be added unless implementation shows a real missing
semantic color.

## Settings And Persistence

Persist diff display preferences in `AppConfig` so the pane keeps the user's
preferred reading mode across app launches:

- preferred layout mode
- wrap enabled
- whitespace visible
- collapsed-context default

Do not add a full settings pane for V1. The toolbar controls are the only V1
preference UI.

## Fast Follows

After V1 lands, use the same renderer and anchors for:

- commit diff views
- draft-commit diff views
- a multi-file review tab over all changed files
- GitHub/GitLab review thread rendering
- selecting a line/range/thread and sending it to an agent
- review queue navigation
- keyboard-first review flow

The multi-file review tab is the highest-priority fast follow. V1 should not
make choices that assume one file forever.

## Risks And Mitigations

Large diffs can stall UI if model building or text layout happens on the main
actor. Keep display-model construction pure and run it off-main from
`DiffTabView`, keep parsing deterministic, and consider lazy group rendering if
large files expose performance issues.

Split alignment can get complicated when long lines wrap. Keep a single
vertical scroll source and define row heights from measured content. Wrapping
can be opt-in if initial implementation is safer without default wrapping.

Review comments need stable anchors. Add anchors in V1 even though remote
review comments are out of scope. Tests should lock down anchor stability before
the future code-host integration depends on it.

Hunk actions must keep working. Preserve the original `ParsedDiff.Hunk` for
each hunk-level action instead of reconstructing patches from display rows.

## Testing Strategy

Unit tests should cover:

- display-model construction from representative `ParsedDiff` hunks
- split row alignment for context, add-only, delete-only, and replacement
  blocks
- stacked row order
- inline highlight pairing and fallback cases
- collapsed unchanged-region grouping
- anchor stability across layout modes
- selection range normalization
- hunk action mapping back to the original hunk

Hosted rendering tests should cover basic AppKit/SwiftUI construction and
selection surfaces. Snapshot tests are not required unless the repo already has
a stable pattern for them.

Manual verification should include:

- working-tree unstaged diff
- staged diff
- untracked file
- deleted file
- renamed file
- large file with long lines
- syntax-highlighted Swift file
- plain-text file
- image diff still routed to `ImageDiffView`
