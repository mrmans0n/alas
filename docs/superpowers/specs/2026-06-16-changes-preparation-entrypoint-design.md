# Changes Preparation Entry Point Design

## Context

The Changes tab currently exposes related destinations as separate, similarly
weighted rows: draft commit, review changes, and the review-loop drawer. The
center panes for these workflows are useful and should remain separate, but the
right-pane entry points feel duplicative because they compete for attention
instead of presenting one clear preparation hierarchy.

The goal of this pass is to improve how users get from the Changes tab to the
existing draft commit, local review, and PR/MR review-request workflows. This is
an entry-point and hierarchy change only; it does not redesign the center panes
or provider behavior.

## Goals

- Make the Changes tab read as one coherent preparation surface.
- Keep `DraftCommitTabView`, `ReviewSessionTabView`, and
  `DraftReviewRequestTabView` as separate center-pane destinations.
- Replace the separate draft/review trigger rows with one polished preparation
  card.
- Make `Review current changes` the primary doorway when reviewable changes
  exist.
- Surface one compact PR/MR readiness action using existing review-loop logic.
- Preserve current staging, discard, conflict, commit-list, and review-loop
  behavior.

## Non-Goals

- Redesigning draft commit composition.
- Redesigning the multi-file review tab.
- Redesigning draft PR/MR creation.
- Removing the review-loop drawer.
- Changing provider readiness rules.
- Adding new provider actions.

## Proposed Hierarchy

Add a single preparation card near the top of the Changes tab, below merge
operation and conflict UI and above the working-tree file list.

The card contains one primary action:

- `Review current changes`

This opens the existing multi-file review center pane. It shows the number of
reviewable files and aggregate additions/deletions. It appears only when there
are reviewable non-conflict changes.

The card also contains compact secondary actions:

- `Draft commit` or `Open draft`
- `Create PR/MR`, `Push`, `Open PR/MR`, `Inspect`, or `Refresh`

These are not competing top-level rows. They are destination actions inside the
same preparation card, making the Changes tab hierarchy clearer while preserving
the current workflow separation.

## Behavior Rules

The preparation card appears when any of the following is true:

- there are reviewable non-conflict file changes
- there are staged changes
- there is a live or stashed draft commit
- the review-loop readiness model exposes one of the compact action kinds
  listed below

The primary review action appears only when `ReviewChangesTriggerSummary`
produces a summary for reviewable changes. Conflicts do not count toward this
summary.

The draft commit action appears when staged changes exist or when a live/stashed
draft commit exists. Its label is `Draft commit` for a new draft and `Open
draft` when a draft already exists. If no staged changes exist but a draft
exists, the action remains visible so users can recover or finish the draft.

The PR/MR action reuses `ReviewReadinessModel.actions` and selects one compact
action by priority:

1. `createReviewRequest`
2. `pushBranch`
3. `openReviewRequest`
4. `inspectReviewEvidence`
5. `refresh`

The card must not show multiple PR/MR actions. The existing `ReviewLoopDrawer`
remains the detailed surface for branch state, chips, facts, and secondary
review-loop actions.

Conflicts and merge operations continue to take visual priority above the
preparation card.

## Implementation Shape

Introduce a small pure model named `ChangesPreparationModel`, built from data
already available to `ChangesTabView`:

- changed files and `ReviewChangesTriggerSummary`
- staged file count and staged additions/deletions
- live/stashed draft commit state
- `ReviewReadinessModel`

The model produces:

- optional primary review action metadata
- optional draft commit action metadata
- optional review-request action metadata
- compact stats and status text for the card

`ChangesTabView` renders a new `ChangesPreparationCard` from that model. The
card does not directly know about git, provider clients, or tab construction. It
calls existing handlers supplied by `ChangesTabView`:

- `openReviewChangesTab`
- `openDraftTab`
- `rps.handleReviewReadinessAction(_, appState:)`

This keeps provider and branch-readiness policy inside the existing review-loop
model and state objects.

## Review Loop Drawer

The `ReviewLoopDrawer` stays in place for this pass. It remains the detailed
branch/review status surface with chips, facts, and secondary actions.

If the preparation card later makes the drawer feel redundant, a follow-up can
collapse the drawer by default, move selected chips into the card, or turn the
drawer into an explicit branch review status popover.

## Testing

Focused model tests should cover:

- review action appears only when reviewable non-conflict changes exist
- draft commit action appears for staged changes
- draft commit action appears for existing live/stashed drafts even without
  staged changes
- review-request action selects the highest-priority readiness action
- review-request action does not expose multiple readiness actions
- conflicts are excluded from reviewable change summaries

Hosted UI coverage can stay light. Add a `ChangesPreparationCard` or
`ChangesTabView` test only if the current test harness makes button ordering and
handler invocation practical.

## Fast Follow

- Re-evaluate whether the `ReviewLoopDrawer` should collapse by default after
  the preparation card lands.
- Consider moving the most important readiness chips into the card once the
  compact action proves useful.
- Add keyboard shortcuts for review changes, draft commit, and create/open
  review request.
