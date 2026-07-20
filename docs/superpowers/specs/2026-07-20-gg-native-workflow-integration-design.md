# Native GG Workflow Integration

Date: 2026-07-20
Status: Approved design

## Context

Alas already supports GG project mode, stack-aware commit rows, a stack drawer,
agent context, and an inbox. The current integration is strongest for observing
and publishing a stack, but it does not provide a complete native workflow for
preparing or rewriting stack commits:

- GG mode hides the existing Prepare card instead of adapting it.
- Commit context menus expose only Open PR/MR, Checkout, and Land Through.
- Stack editing operations such as Amend, Absorb, Split, Drop, Unstack,
  Reorder, Restack, and Undo require a terminal.
- Sync is disabled whenever the stack is behind base, even when GG is
  configured to rebase automatically during sync.
- User-facing GG UI uses the internal term "entry" where "commit" is clearer.

This design extends the existing GG integration rather than replacing the
non-GG review loop or introducing a generalized workflow framework.

## Goals

- Restore a GG-aware Prepare surface for reviewing and assigning local changes.
- Add commit-scoped GG operations to a clearly namespaced context submenu.
- Add native Alas flows for Split Commit, Split Stack, and Reorder Stack.
- Make the stack drawer reflect GG's effective sync and rebase configuration.
- Centralize GG mutation safety, progress, conflict recovery, refreshes, and
  Undo eligibility.
- Use "commit" for user-facing stack units and reserve "entry" for internal
  models and GG wire formats.
- Preserve all existing non-GG behavior.

## Non-goals

- Unifying `ReviewLoopState` and GG stack readiness into one workflow engine.
- Reimplementing GG's history rewrite, metadata, or operation-log behavior in
  Alas.
- Exposing GG's `--force` or `--ignore-immutable` options in the GUI.
- Automatically staging, stashing, aborting conflicts, or rolling back remote
  operations.
- Replacing GG's terminal interface for users who prefer it.

## Terminology

Alas-owned visible strings use these terms:

- **Stack**: the ordered collection of local commits and their PRs/MRs.
- **Stack commit**: a local commit belonging to a GG stack.
- **PR/MR**: the remote review object associated with one stack commit.
- **Entry**: internal-only terminology permitted in types such as
  `GGStackEntry` and in decoded GG payloads.

Existing GG UI, including the stack drawer, progress text, confirmations, and
inbox, must replace user-visible "entry" with "commit". Raw, unclassified GG
diagnostics may retain GG's original wording, but all typed Alas messages use
the terminology above.

## Architecture

### Existing-layer extension

The design adds one per-worktree mutation coordinator while retaining the
current service and presentation boundaries:

```text
Prepare card       GG commit submenu       Stack drawer / editors
      \                    |                       /
       +----------- GGMutationCoordinator -------+
                              |
                    GGStackActionState
                              |
                 GGService + GGCommandRunning
                              |
                            gg CLI
```

The three UI surfaces describe typed intent. They do not construct command-line
arguments or start processes.

`GGMutationCoordinator` owns:

- Fresh stack and effective-config preflight.
- One mutation at a time per worktree.
- Immutable, dirty-tree, stale-editor, and paused-operation validation.
- Confirmation models for destructive or remote operations.
- In-flight state, completion summaries, and paused conflicts.
- Targeted refresh and cache invalidation after completion or partial failure.
- Tracking whether the latest GG operation can still be undone.

`GGService` remains the only GG process boundary. It gains typed methods for the
new commands and keeps `GGCommandRunning` injectable for tests.

`GGStackActionState` remains the observable presentation state. It expands its
action kinds and result state rather than creating separate state objects for
each view.

The non-GG `ReviewLoopState`, `ReviewReadinessModel`, and handlers remain
unchanged.

## User Surfaces

### GG-aware Prepare card

`ChangesTabView` no longer suppresses `ChangesPreparationCard` when the GG
drawer is active. In GG mode the card uses a GG-specific presentation model.

The approved hierarchy is:

1. Full-width primary action: `Review current changes`.
2. Three visible secondary destinations:
   - `New stack commit`
   - `Amend current`
   - `Absorb into stack`

`Review current changes` continues to review all current changes through the
existing Alas review-changes flow.

`New stack commit` opens the existing draft-commit editor. It is available when
there are staged changes or a non-empty saved draft and the worktree is checked
out at the actual stack head. On a lower stack commit, only this destination is
disabled; Amend and Absorb remain available. The resulting commit is created
through the existing commit path, after which the GG stack is refreshed.

`Amend current` runs `gg sc --staged-only` for the checked-out stack commit.
That flag is an external prerequisite supplied by the paired git-gud native
client protocol change. Alas probes `gg sc --help` and disables Amend Current
unless the installed GG advertises `--staged-only`; it never falls back to
plain `gg sc`, whose configured unstaged action may stage or stash other work.

`Absorb into stack` runs `gg absorb -s` so GG assigns staged hunks to matching
stack commits.

Amend and Absorb are staged-only operations:

- Alas never stages changes implicitly.
- Each action shows staged file and diff statistics.
- With no staged changes, actions are disabled with `Stage changes first`.
- Unstaged changes remain available to Review and existing staging controls.

The Prepare card and stack drawer may be visible at the same time because they
represent different scopes: local change preparation versus stack lifecycle.

### Commit context menu

Generic Git actions remain at the top level. A commit that maps to a GG stack
commit receives a `GG` submenu. Items are grouped with dividers in this order:

Remote review:

- `Review PR in Alas...` or `Review MR in Alas...`
- `Open PR in Browser` or `Open MR in Browser`

Navigation and editing:

- `Checkout Commit`
- `Split Commit...`

Lifecycle:

- `Drop Commit...`
- `Split Stack Here...`
- `Land Through Here...`

Remote review items appear only when the commit has a mapped PR/MR. Review opens
the provider diff and comment workflow in Alas; Open launches the provider page.
The existing top-level `Review Commit...` remains the local agent review and is
not renamed.

Drop confirmation names the selected commit, states how many descendants GG
must rewrite, and warns when the commit has an open PR/MR. Only the selected
commit is removed; descendants are rewritten and retained.

Checkout is hidden for the current commit. Operations that are meaningful but
temporarily blocked remain disabled and expose a concise reason, including an
immutable commit, paused conflict, stale selection, or another in-flight GG
mutation. If a disabled menu item cannot expose help reliably, the submenu adds
a disabled explanatory row immediately below it.

### Stack drawer

The drawer remains persistent at the bottom of the Changes panel and collapsed
by default. It continues to show stack identity and summary state. Expanding it
shows facts, the current primary action, progress, errors, and an overflow menu.

Primary actions follow this precedence:

1. Paused operation: `Continue` and `Abort`.
2. Manual rebase required by effective GG configuration: `Rebase onto <base>`.
3. Unsynced or publishable commits: `Sync stack`.
4. Fresh stack with landable commits: `Land ready`.
5. Otherwise: status and remote review actions without a forced primary action.

The overflow menu contains:

- `Reorder Stack...`
- `Restack...`
- `Undo Last GG Operation`
- `Clean Merged Commits...`

Sync remains available with unrelated local changes when GG permits it, but the
drawer explicitly states that local changes are not included. It never implies
that uncommitted work was published.

## Effective GG Configuration

Alas extends `GGConfigReader` to resolve the effective local-over-global values
needed for presentation. GG remains responsible for enforcing its own config at
execution time.

The drawer follows these rules:

- With `sync_auto_rebase = true`, `sync_behind_threshold > 0`, and the threshold
  met, Sync stays primary and its detail text says that Sync includes a rebase
  onto the base branch.
- With `sync_auto_rebase = false` and `sync_behind_threshold > 0`, Rebase
  replaces Sync when `behind_base >= sync_behind_threshold`.
- A `sync_behind_threshold` of `0` disables the behind-base replacement, so
  Sync remains available without claiming that it includes a rebase.
- Below `sync_behind_threshold`, Sync remains available.
- `sync_draft`, `sync_auto_lint`, title/description update settings, and other
  GG sync policy are not duplicated in Alas command construction. Calling
  `gg sync` without conflicting overrides lets GG apply the effective config.

If GG reports a stale-base warning despite the preflight snapshot, Alas refreshes
the stack and presents Rebase rather than repeatedly retrying Sync.

## Native Editors And Sheets

### Split Commit

`Split Commit...` opens a native Alas tab based on the existing commit editor's
diff and hunk-selection components.

The tab provides:

- Hunk selection for the new lower commit.
- Message fields for both resulting commits.
- Separate previews for the new commit and the remainder.
- Validation that both commits are non-empty and messages are valid.
- Apply and Cancel commands that do not resize or shift the diff layout.

Opening the editor records the target GG ID/SHA, stack head, commit tree, and
diff identity. Apply refuses a stale plan without discarding the user's message
text or selection.

Alas does not perform the rewrite itself. Native Split requires a small GG
command contract described under `Structured Split Prerequisite`.

### Split Stack

`Split Stack Here...` opens a confirmation sheet containing:

- A new stack name derived from the selected commit and editable by the user.
- `Create a new worktree`, enabled by default but optional.
- The selected commit and the exact number of commits above it that move to the
  new stack.
- The lower stack name and destination stack name.

Apply runs `gg unstack --target <id> --name <name> --no-tui --json`, adding
`--worktree` when selected and `--keep-current` otherwise. When a new worktree
is created, Alas refreshes the project worktree list and selects that worktree.
Without a new worktree, Alas requires GG's `--keep-current` capability, keeps
the current worktree on the lower stack, refreshes GG Inbox, and reports that
the new stack has no worktree. `--keep-current` is an external prerequisite
supplied by the paired git-gud native client protocol change; Alas probes
`gg unstack --help` and locks the worktree toggle on for older installations.
It does not switch branches implicitly.

### Reorder Stack

`Reorder Stack...` opens a native sheet listing mutable stack commits with drag
handles. It previews the resulting order and submits an explicit identifier
sequence through `gg reorder --order`.

The Reorder sheet does not also drop commits. Destructive removal remains the
explicit `Drop Commit...` action. Immutable commits are fixed in place. Dragging
is limited to contiguous mutable regions, and Apply remains disabled if the
result would require GG to rewrite an immutable commit.

### Restack

`Restack...` first runs `gg restack --dry-run --json` and presents the repair
plan. Apply is available only when the plan contains work and runs the normal
structured restack command without force.

## Structured Split Prerequisite

The installed GG version currently supports interactive hunk selection and
whole-file noninteractive selection, but not a structured hunk plan. A native
Alas Split editor must not reproduce GG's rewrite, metadata, descendant rebase,
immutability, or operation-log behavior.

GG therefore needs a two-step, versioned structured protocol:

```text
gg split --describe --commit <target> --json
gg split --plan-json <path> --json
```

Describe returns GG-owned hunk identities so Alas does not need to reproduce
GG's diff canonicalization:

```json
{
  "version": 1,
  "plan_token": "opaque-token-bound-to-target-and-tree",
  "target": { "gg_id": "...", "sha": "...", "tree": "..." },
  "hunks": [
    {
      "id": "opaque-stable-hunk-id",
      "path": "Alas/Sources/Example.swift",
      "header": "@@ -10,4 +10,8 @@",
      "patch": "..."
    }
  ],
  "first_message": "Suggested first message",
  "remainder_message": "Existing commit message"
}
```

Alas displays the returned patches and submits a private temporary plan:

```json
{
  "version": 1,
  "plan_token": "opaque-token-bound-to-target-and-tree",
  "target": { "gg_id": "...", "sha": "...", "tree": "..." },
  "selected_hunk_ids": ["opaque-stable-hunk-id"],
  "first_message": "New lower commit message",
  "remainder_message": "Remainder commit message"
}
```

GG must validate the plan against a freshly computed target diff before moving
refs. A mismatch returns a structured stale-plan error without mutation. A
successful result returns `version`, `operation_id`, the original SHA, both
resulting SHAs and GG IDs, and the rewritten descendant identities. GG retains
ownership of immutability checks, metadata, descendant rebasing, conflict pause
state, and Undo recording.

Alas writes the plan to a private temporary file, deletes it after completion,
and never logs its patch content.

Capability detection follows the existing GG sync JSONL precedent by probing
the split command's supported options once per GG version. Both `--describe`
and `--plan-json` are required. When the installed version lacks the structured
split contract, `Split Commit...` is disabled with an update-GG explanation.
Other GG actions remain available.

## Mutation Data Flow

Every mutation follows the same sequence:

1. A surface submits a typed `GGMutationRequest` with stable commit identifiers,
   never display positions alone.
2. The coordinator refreshes the current stack and effective config.
3. Preflight validates the target, working tree, immutability, current operation,
   and any editor snapshot.
4. Destructive or remote requests create a typed confirmation model.
5. After confirmation, the coordinator starts the matching typed `GGService`
   method and updates `GGStackActionState`.
6. Structured progress is rendered when GG provides it. Other operations show
   deterministic in-flight state and infer completion only from exit status plus
   a successful refresh.
7. Completion, pause, or failure triggers the appropriate refresh set.
8. The coordinator queries the GG operation log and exposes Undo only when the
   latest operation is local, complete, and undoable.

Refresh scope includes:

- GG stack and effective config.
- Git changes and commit rows.
- Review state for affected PRs/MRs.
- GG inbox cache for any mutation that changes stack or remote state.
- Project worktrees after Unstack or Clean.

Refresh also runs after partial failure. The UI reports observed state rather
than claiming a rollback that did not occur.

## Operation Semantics

- **Amend current**: capability-gated `gg sc --staged-only` from the paired
  git-gud native client protocol, with no fallback to plain `gg sc`.
- **Absorb into stack**: `gg absorb -s`, staged changes only.
- **Checkout Commit**: `gg mv <stable-id>`.
- **Split Commit**: structured plan contract, never TUI automation.
- **Drop Commit**: `gg drop <stable-id> --yes`, after Alas confirmation.
- **Split Stack Here**: noninteractive `gg unstack` with JSON output.
- **Land Through Here**: existing `gg land --until` flow with fresh readiness
  validation and explicit confirmation.
- **Reorder Stack**: direct identifier order, no TUI or text-editor automation.
- **Restack**: structured dry-run preview followed by structured execution.
- **Rebase**: normal GG rebase without force.
- **Sync**: existing streaming GG sync path and effective GG config.
- **Clean**: explicit confirmation and existing project-path recovery behavior.
- **Undo**: target the latest operation ID only after validating the newest
  operation-log record.

## Safety And Recovery

### Serialization and freshness

Only one GG mutation may run per worktree. Native editors and confirmations
capture stable identities, but every Apply performs a fresh preflight because
the stack may change in another terminal, worktree, or agent session.

### Immutable commits

Alas never supplies `--force` or `--ignore-immutable`. Known immutable commits
disable rewrite actions with their reason. GG remains the final authority and
may still reject a race discovered after preflight. Alas parses and presents the
affected commits and reasons without offering a GUI override.

### Dirty working tree

There is no implicit stage or stash behavior. Each request declares its dirty
tree requirements. A blocked operation explains which local state must be
resolved. Editor input is retained after a preflight failure.

### Conflicts

If a rewrite pauses on conflicts, Alas does not abort automatically. It keeps the
GG action associated with the paused state, exposes conflicts through the
existing Conflicts section, and makes Continue/Abort the drawer actions. A full
refresh follows either outcome.

### Undo

After a successful local mutation, the drawer shows its result and an Undo
action without a timer. Undo remains available until another GG mutation begins.
On refresh or relaunch, Alas may restore it only when the newest GG operation-log
record is the same completed, local, undoable operation.

Any later local or remote GG mutation clears the prior Undo affordance. Sync and
Land never offer Undo. When `gg undo --json` refuses because an operation touched
remote state, was interrupted, or became stale, Alas displays GG's recovery hint
and does not attempt a silent alternative rollback.

### Land

Land retains the existing fresh-readiness validation and explicit confirmation.
The coordinator distinguishes merged from queued PRs/MRs and never reports a
queued review as landed.

## Error Presentation

Typed error categories drive stable Alas messages:

- CLI missing or incompatible capability.
- Immutable targets.
- Dirty working tree or index.
- Stale commit, stack, editor, or split plan.
- Authentication, provider, or network failure.
- Paused conflict.
- Partial stack or worktree change.
- Undo refusal.
- Malformed structured output.

Errors appear on the initiating editor or sheet when user input can be corrected
there. Operational errors and paused states also appear in the stack drawer so
they survive dismissal of transient UI. Malformed output after a zero-exit remote
operation never causes Alas to claim the remote operation failed; Alas refreshes
and reports the observed result.

## Testing

All tests use Swift Testing.

### Presentation models

- GG submenu ordering, grouping, and provider-specific PR/MR labels.
- Hidden versus disabled action rules.
- User-visible terminology contains no Alas-owned "entry" strings.
- Prepare card hierarchy, staged counts, and staged-only enablement.
- Drawer primary-action precedence.
- Effective `sync_auto_rebase` and `sync_behind_threshold` behavior.
- Local-changes-not-included Sync messaging.

### GG service

- Exact arguments for every typed operation.
- Effective-config decoding and local-over-global precedence.
- Structured split-plan encoding and result decoding.
- JSON error, immutable-target, stale-plan, partial-result, and Undo parsing.
- Capability probing for structured Split.

### Mutation coordinator

- One-operation serialization.
- Fresh preflight before confirmation and again before Apply where needed.
- Stale native editor preservation.
- Success refresh sets for local, remote, worktree-changing, and clean actions.
- Conflict pause, Continue, and Abort transitions.
- Latest-operation Undo restoration and invalidation by any later mutation.
- No Undo for Sync, Land, or other remote-touching records.

### Native editor and sheet models

- Split hunk partition and two-message validation.
- Split preview identities and stale-plan behavior.
- Unstack naming, moved-commit summary, and worktree default.
- Reorder validation and immutable constraints.
- Restack dry-run plan presentation.

### Regression and acceptance

- Non-GG Prepare and review-loop behavior is unchanged.
- New stack commit, Amend, and Absorb work with mixed staged/unstaged changes.
- Review PR/MR in Alas opens the selected stack commit's provider review.
- Drop then Undo restores the stack.
- Native Split rewrites through GG and refreshes descendants.
- Split Stack works with and without a new managed worktree.
- Auto-rebase enabled, disabled-above-threshold, and disabled-below-threshold
  states select the correct primary action.
- Conflicted rewrites remain recoverable through Continue and Abort.
- Immutable commits cannot be rewritten from Alas.
- Sync, review status, and Land form an honest end-to-end progression.

The implementation must regenerate the Xcode project if project inputs change,
run focused tests throughout development, and finish with the repository's full
`xcodegen`, build, and test commands.

## Implementation Scope

The structured Split protocol is an external prerequisite implemented and
verified in the GG repository under its own plan. The Alas change feature-gates
native Split until that protocol is installed; it does not carry GG source code.

The Alas work should be delivered as a reviewable GG stack:

1. GG capability model, typed service operations, and effective config.
2. Shared mutation coordinator, refresh rules, conflict state, and Undo.
3. GG-aware Prepare card and terminology cleanup.
4. GG commit submenu, confirmations, and remote review routing.
5. Native Split, Split Stack, Reorder, and Restack interfaces.
6. State-driven drawer actions, conflict recovery, refresh integration, and
   end-to-end hardening.

Each stack commit must be independently testable and keep non-GG behavior green.
