# Diff Context Expansion Design

## Context

Alas has new diff stack screens built on the shared `DiffReviewSurface` path. The relevant implementation is concentrated around:

- `DiffReviewSurface`
- `DiffReviewFileSection`
- `DiffDisplayModel`
- `DiffDisplayModelBuilder`
- `DiffPaneTextDocumentView`
- `ReviewChangesLoader`
- `CommitReviewLoader`
- `DraftReviewRequestDiffSessionBuilder`

The current diff display can collapse long unchanged runs that already exist inside a parsed diff hunk. It does not yet fetch or reveal unchanged file lines outside the hunk boundaries. The desired behavior is closer to diffs.com: reviewers can expand context outward from a visible hunk while staying in the review surface.

## Goals

- Add context expansion to all screens that use the shared diff review surface.
- Use a compact gutter-first control, matching the selected "gutter plus" direction.
- Reveal a small chunk on normal click and all available context on Option-click.
- Expand both old and new sides when both snapshots are available.
- Preserve existing hunk actions, review comment placement, inline feedback placement, and stable anchors for original diff rows.
- Keep initial review loading fast by fetching file snapshots lazily.

## Non-Goals

- Do not turn the diff review surface into a full file editor.
- Do not mutate `ParsedDiff.Hunk` to represent expanded context.
- Do not make provider-only sessions fail when repository snapshots are unavailable.
- Do not eagerly load full file contents for every changed file.

## UX

Each expandable hunk boundary shows a small `+` affordance in the line-number gutter. The adjacent row can show subdued text such as `24 unchanged lines above` or `31 unchanged lines below`.

Interaction:

- Click: reveal the next context chunk, defaulting to 10 lines.
- Option-click: reveal all remaining context in that direction.
- Hover/help: describe the active action, for example `Expand 10 lines` or `Expand all`.
- When all context in a direction is visible, remove the boundary control for that direction.

Split view expands both old and new side context when both snapshots exist. If only one side exists, such as an added or deleted file, expansion degrades to the available side. Stacked view projects expanded context through the same row-ordering rules used by the existing stacked diff renderer.

Existing collapsed in-hunk context remains supported. Boundary expansion reveals context outside the parsed hunk; collapsed rows inside the parsed hunk keep their current expansion behavior.

## Data Model

`ParsedDiff.Hunk` remains the immutable source of the actual diff. Expansion state lives alongside display construction.

Add a context layer with these responsibilities:

- `DiffReviewContextProvider`: optional async provider attached to a renderable review file.
- `DiffReviewFileContextSnapshot`: old/new line arrays plus metadata for missing or unavailable sides.
- `DiffContextExpansionState`: per file, hunk, and boundary state tracking how many lines above and below are currently revealed.
- Display-row metadata for expanded context rows so they render as neutral context while remaining distinguishable from original diff rows.

Original diff row anchors stay stable. Expanded context rows receive deterministic anchors from real old/new line numbers. They do not alter `sourceHunk`, hunk staging, hunk discard, commit hunk dropping, inline feedback placement, or draft comment placement for original rows.

## Loading And Providers

Providers are optional and lazy. A review file loads its snapshot on first provider-backed expansion and caches it in view state.

Provider sources:

- Unstaged local changes: old side is the index version; new side is the worktree file.
- Staged local changes: old side is `HEAD` or the empty tree; new side is the index version.
- Commit review: old side is the first parent or empty tree; new side is the commit.
- Draft review request: old side is the selected base ref; new side is the validated head SHA or current HEAD used for the draft.
- Provider/imported sessions without local repository snapshots: provider-backed expansion is unavailable, but already-present collapsed in-hunk context can still expand.

Provider failures are scoped to the file and interaction that triggered them. A failed snapshot load should not break the rest of the review stream. Files known to be binary, missing, or unsupported before rendering should hide expansion controls. If a control was rendered but the lazy snapshot load fails, show a lightweight inline failure for that file.

## Rendering

`DiffReviewFileSection` owns per-file expansion UI state, similar to its existing collapsed-row and draft-composer state. The text renderer stays responsible for drawing rows, line numbers, selection, backgrounds, wrapping, and LSP metadata.

Rendering flow:

1. Build the base `DiffDisplayModel` from `ParsedDiff`.
2. When expansion state or loaded snapshots change, derive display groups that include expanded boundary context rows.
3. Pass the derived groups to `DiffPaneTextDocumentView`.
4. Render the gutter `+` affordance through the least invasive AppKit bridge, either as a row-level gutter control or an extension of the line-number ruler.

Scroll position should remain stable after expansion, especially when revealing lines above the visible viewport.

## Testing

Unit tests should cover:

- Expansion math for above and below hunk boundaries.
- Chunked expansion versus expand-all.
- Added, deleted, renamed, and normal modified files.
- Stable original anchors across expansion.
- Deterministic anchors for expanded context rows.
- Provider selection for unstaged, staged, commit, and draft review request contexts.
- Fallback behavior when no provider exists.
- Display-row generation for split and stacked layouts.

UI-level tests should cover accessibility identifiers or labels for gutter expansion controls where practical.
