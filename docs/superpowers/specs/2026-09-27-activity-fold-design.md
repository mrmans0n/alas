# Activity fold redesign

## Goal

Tool-heavy transcripts should read calmly: tool activity recedes, narration and
answers stay foreground, and nothing jumps when a call moves from running to
finished. Reference: Claude desktop / Codex desktop activity groups
("Exploring the project" → one-line `Find …`, `Read …` members).

## Current problems

- A running call is never collapsible, so it renders as a full `ACPToolCallCard`
  ("RAN" + chips + preview + spinner) and is then absorbed into a fold when it
  finishes — the layout jumps.
- Folds have no minimum size and narration splits them, so a
  `cmd → text → cmd → text` stretch becomes a stack of one-member folds, each
  labelled with the raw command title.
- Fold labels are mechanical (latest tool title or "Worked for …"); the grouping
  never uses `ACPToolCallPresentation`.

## Decisions

| Question | Decision |
|---|---|
| What a group contains | Consecutive tool calls and thoughts. Narration, file edits, subagents, compaction, and the fork boundary split groups. |
| Header label | Deterministic verb counts from `ACPToolCallPresentation`. |
| Auto expand/collapse | The live tail group is expanded while running; it collapses once it is no longer the tail. An explicit user toggle wins. |
| Clicking a member | Expands inline into today's `ACPToolCallCard` body. |
| File edits | Unchanged: full diff card, splits groups. |
| Completed-turn fold | Kept; only its label changes. |

Mockup: `.superpowers/brainstorm/*/content/activity-fold.html` (approved).

## Design

Approach: evolve the existing fold pipeline (`ACPToolCallGrouping.fold` →
header + per-member render rows → scroller tiling). Do not render a group as a
single nested row; the header + member tiling is required for scroll-anchor
precision.

### 1. Grouping rules — `ACPToolCallGrouping`

- `isCollapsible` accepts tool calls in any status (running and pending
  included), still excluding context compaction and subagents. `.fileEdit`
  remains non-collapsible.
- `flushRun`: a run containing exactly one tool call and nothing else is
  emitted as a plain `.message` row (drawn as a bare line). Runs with two or
  more members, or with a thought, still form a group. A run containing only a
  thought keeps today's behavior.
- `completedTurnKinds` is unchanged.
- Consequence: absorb-on-finish no longer happens.

### 2. Header label — `ACPToolCallGroupSummary`

- Count members by verb resolved through `ACPToolCallPresentation.resolve`
  (Read, Searched, Ran, Edit, Web Search, MCP, other → "used N tools"). Render
  in first-appearance order as a comma list with pluralization:
  "Read 2 files, searched 1 time, ran 3 commands". Thoughts are not counted.
- Suffix `· N failed` when any member failed.
- Live group (contains a non-final member while the turn runs): "Exploring" if
  every tool member is read/search, else "Running"; followed by
  `· N so far`, drawn with the existing narration shimmer.
- `.completedTurn(duration)`: "Worked for 3m 12s · <counts>" (existing duration
  formatting).
- Expanded headers show the same label; "Hide activity" / "Hide work" are
  removed. The chevron conveys state.
- Header icon: magnifier when read/search dominates, terminal otherwise; a
  clock for completed turns.

### 3. Expansion — `ACPToolCallGroupExpansionSeeds`

- Effective state = explicit user choice if present, otherwise automatic.
- Automatic = expanded iff the group is the live tail (last render row of the
  current turn while the session is running).
- The store gains an explicit-collapsed override alongside the existing
  expanded lineage, so collapsing a live group sticks. Same lineage rules as
  today (keyed by member stable ids).
- `fold` needs to know which group is the live tail; pass it through
  `Options`. Because tail status changes the row list, it must be part of
  `ACPVisibleRowsCache`'s key.

### 4. Rendering

- `ACPToolCallCard` collapsed state becomes the light line:
  icon · verb · monospace target chip · duration / spinner / ✕ · chevron.
  Expanded state keeps today's body (output, input). Used for group members and
  lone calls alike.
- `ACPToolCallGroupHeaderRow` draws the new label, icon, and shimmer; the lane
  bar stays for members.
- Delete `ACPToolCallGroupHeaderAnimation` (absorb pulse) and the collapsed
  header's live narration preview; the shimmering live label replaces both.

### 5. Tests

Extend existing suites; no new files.

- `ACPToolCallGroupingTests` (grouping): running call joins a group; a single
  call is not grouped; a thought counts as a member and keeps a run together.
- `ACPToolCallGroupingTests` (summary): parameterized verb counts and
  pluralization, failed suffix, live "Exploring"/"Running" labels,
  completed-turn label.
- `ACPToolCallGroupingTests` (seeds): automatic expansion of the live tail;
  explicit collapse overrides it; tail loss collapses an untouched group.
- Delete `ACPToolCallGroupHeaderAnimationTests` and update expectations that
  assumed "Hide activity" or single-member groups.

## Out of scope

- Folding file edits into groups.
- Intent-phrase or local-model group titles.
- Subagent and compaction rows.
