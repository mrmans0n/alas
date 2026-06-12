---
title: "Multi-file review tab"
date: 2026-06-12
project: alas
phase: design
prior_art:
  - docs/superpowers/specs/2026-06-11-review-ready-diff-pane-design.md
  - Alas/Sources/Center/DiffTabView.swift
  - Alas/Sources/Center/Diff/DiffPaneView.swift
  - Alas/Sources/Center/Diff/DiffDisplayModelBuilder.swift
  - Alas/Sources/Center/TabsManager.swift
  - /Volumes/Workspace/ai-review/src/hooks/useVisibleDiffFile.ts
  - /Volumes/Workspace/ai-review/src/components/FileList.tsx
  - /Volumes/Workspace/ai-review/src/components/LazyDiffFile.tsx
---

## TL;DR

Add a polished multi-file `Review Changes` tab for local changes. The tab uses
a collapsible left file rail and one vertically scrolling stream of file diff
cards. Scrolling the stream updates the active file in the rail; clicking a
file in the rail scrolls to that file section.

The target quality bar is diffs.com-level: clear file navigation, strong
split/stacked diff styling, sticky file context, calm gutters, precise change
colors, and a review surface that feels purpose-built rather than assembled
from individual file tabs.

## Product Direction

The first diff-pane release made single-file text diffs review-ready. The next
fast follow should let a user read a whole local change as one review document.
This is the workflow the user expects from diffs.com, GitHub, GitLab, and the
existing `ai-review` app: a changed-file rail for orientation, a continuous
diff stream for reading, and automatic synchronization between the two.

The feature should be useful before provider comments exist. It should also
leave clean attachment points for later review work: viewed state, comments,
remote review threads, selected range to agent, and keyboard review queue.

## Scope

### In Scope

- Add a new persistent center tab, working name `ReviewChangesTabView`.
- Add a new tab state, working name `ReviewChangesTabState`, scoped to one
  worktree.
- Add an app action to open or focus the review tab for the active worktree.
- Load all local text changes into one review session:
  - unstaged tracked changes
  - unstaged untracked text files when a textual diff is available
  - staged text changes
- Group files by change source when needed, with a clear `Unstaged` and
  `Staged` section boundary.
- Keep image/binary files visible in the rail and main stream, but render them
  with a lightweight placeholder or the existing image diff path rather than
  forcing them through `DiffPaneView`.
- Render one vertically scrolling stream of file diff cards.
- Reuse `DiffPaneView` and `DiffDisplayModel` for each text file section.
- Add a collapsible left file rail:
  - tree-style path grouping
  - active file highlight
  - status glyph
  - additions/deletions
  - staged/unstaged source badge when ambiguous
  - collapsed narrow mode that preserves active-file orientation
- Synchronize rail and stream:
  - scrolling updates the active rail item based on the file section nearest
    the top of the diff viewport
  - clicking a rail item scrolls the stream to that file section
  - programmatic scroll temporarily suppresses scroll-spy updates until the
    target settles
- Preserve existing diff preferences: split/stacked, wrap, whitespace, and
  collapsed context.
- Make the visual treatment match the merged diff pane and diffs.com-style
  review polish: sticky file headers, consistent gutters, clear hunk chrome,
  subdued separators, and theme-driven change colors.
- Add focused tests for file-tree construction, active-file selection, rail
  click scroll targets, loading state aggregation, and tab persistence.

### Out Of Scope

- Posting review comments.
- Rendering GitHub/GitLab review threads.
- Persisting viewed state across app launches.
- Keyboard review queue commands.
- Sending selected ranges or threads to an agent.
- Replacing commit and draft-commit diff views.
- Replacing the right Changes pane.
- Full virtualization of extremely large review sessions.

## UX Design

The tab title should be `Review Changes`. The tab icon should be diff/review
oriented, consistent with the existing diff icon set.

The view has two main regions:

1. A collapsible left rail.
2. A main diff document.

The left rail is navigation, not a separate review surface. Expanded mode shows
a compact header with total file count and `+/-` totals, then a tree of changed
files. Directory chains collapse visually when they contain only one child.
Files show status, basename, additions/deletions, and staged/unstaged source
when relevant. The active file gets a strong but tasteful accent and should
remain visible by auto-scrolling the rail when the active file changes.

Collapsed rail mode keeps a narrow strip. It should still show a collapse
toggle, active-file indication, and enough file markers to orient the user.
Collapsed mode is for code-heavy reading, not for hiding state completely.

The main area is one vertical scroll view. Each file section is a card with a
sticky header. The header shows file status, path, additions/deletions, and
source group. The body uses the existing `DiffPaneView` for text files. The
toolbar for split/stacked/wrap/whitespace should appear once at the top of the
review tab, not repeated for every file, because these are review-session
preferences.

When the user scrolls, the selected rail item follows the file section nearest
the top of the viewport. The rule should match the `ai-review` behavior:
prefer an intersecting file whose top is at or below the viewport top; if all
visible file tops are above the viewport, keep the long file whose bottom still
extends through the viewport. This prevents a long file from losing active
state while the user is still reading it.

When the user clicks a rail file, the main stream scrolls to that file's sticky
header. During this programmatic scroll, scroll-spy updates are suppressed
briefly so the rail does not flicker through intermediate files. Once scrolling
settles, normal scroll-spy resumes.

Empty, deleted, binary, or unsupported files should remain visible as file
sections with clear placeholders. The rail must not silently hide files just
because the diff body is not textual.

## Architecture

Add a reusable model layer for the review session:

- `ReviewChangesFile`
- `ReviewChangesSource` (`unstaged`, `staged`)
- `ReviewChangesFileStatus`
- `ReviewChangesFileTree`
- `ReviewChangesSessionModel`

The session model should be value-oriented and testable. It should not depend
on SwiftUI or AppKit.

Add a loader, working name `ReviewChangesLoader`, that coordinates git status
and per-file diff loading. It should reuse existing `GitService` APIs where
possible and preserve the current `DiffTabView` loading behavior for a single
file. Text file sections get both `ParsedDiff` and `DiffDisplayModel`. Image or
unsupported sections get enough metadata for placeholders or `ImageDiffView`.

Add `ReviewChangesTabView` as the top-level UI. It owns:

- loading state
- active file identity
- rail collapsed state
- programmatic scroll suppression
- per-file collapsed-context state if the existing `DiffPaneView` state remains
  local to each section
- bindings to persisted diff display preferences in `AppConfig`

Add small subviews:

- `ReviewChangesRail`
- `ReviewChangesRailTree`
- `ReviewChangesFileSection`
- `ReviewChangesToolbar`
- `ReviewChangesEmptyState`

Do not put the entire feature in one large view. The rail tree, scroll-spy
logic, and loader should each have a narrow, testable boundary.

## Data Flow

1. User opens `Review Changes` from the Changes pane, command palette, or an
   existing suitable entry point.
2. `TabsManager` opens or focuses one review tab per worktree.
3. `ReviewChangesTabView` starts a reload for that worktree.
4. `ReviewChangesLoader` gathers local changes and builds ordered file items.
5. For each text file, the loader fetches unified diff text and builds:
   - `ParsedDiff`
   - additions/deletions
   - `DiffDisplayModel`
6. The tab renders the rail from the ordered file list and the main stream from
   file sections.
7. Scroll visibility updates active file identity.
8. Rail clicks set active file immediately and scroll the stream to the file
   section.

Reloads must be race-safe. If the worktree changes or a manual refresh starts
while a prior load is in flight, stale results must not publish over newer
state. The existing `DiffLoadToken` pattern is a good precedent.

## Scroll Sync

The scroll-spy logic should be isolated in a small controller or model so it
can be tested without screenshots. Given viewport bounds and file-section
frames, it returns the active file:

- Ignore sections that do not intersect the viewport.
- Prefer visible sections whose top is at or below the viewport top.
- Among those, choose the smallest top distance.
- If no visible section top is below the viewport top, choose the intersecting
  section whose top is closest above the viewport top.

Programmatic rail-click scroll should set a suppression flag before calling
`scrollTo(fileID, anchor: .top)`, then clear suppression after a short delay or
after the target file becomes the visible section. The exact mechanism can be
native SwiftUI/AppKit, but the behavior must be deterministic and covered by a
controller test.

## Visual Design

The review tab should reuse the merged diff pane's visual language and push it
to a full review workspace:

- The rail uses `bg-2`/`bg-3` surfaces with a subtle border against the diff
  document.
- Active rail item uses the accent color and a left rail, not a loud full-row
  fill.
- File sections use card borders and sticky headers.
- Headers are compact and code-review oriented, not marketing-style cards.
- The diff body keeps the existing AppKit-backed gutters and row treatment.
- Add/delete colors come from theme tokens, with low-opacity backgrounds and
  higher-contrast inline highlights.
- Collapsed context controls remain visible and polished inside file sections.
- Text should never overlap or be clipped in the rail; use middle ellipsis for
  long paths.

The UX inspiration is diffs.com, GitHub, GitLab, and `ai-review`, adapted to
Alas themes and native macOS controls.

## Entry Points

V1 needs one obvious entry point. Prefer adding a `Review Changes` action to
the right Changes pane header or toolbar. If a command palette or equivalent
central command system already has a clean pattern, add the action there too,
but do not block V1 on command discovery.

Clicking individual files in the existing Changes pane should continue to open
single-file diff tabs. The new review tab is additive, not a replacement.

## Testing

Unit tests:

- file tree building and directory-chain flattening
- file ordering and staged/unstaged grouping
- scroll-spy active-file selection
- programmatic scroll suppression controller
- loader aggregation for staged and unstaged text diffs using fakes
- tab state identity and persistence

View or hosted tests:

- review tab renders rail and diff stream for multiple files
- rail click triggers the expected scroll target
- collapsed rail changes width/state without losing active file
- empty state appears when there are no local changes

Final verification should include the project-required `xcodegen`, quiet build,
and full test suite.

## Future Work

After this lands, use the same tab foundation for:

- viewed state
- local comments and draft review notes
- GitHub/GitLab review thread rendering
- selected line/range/thread to agent
- review queue navigation
- keyboard-first review workflow
- commit and draft-commit diff migration
