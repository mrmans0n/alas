# Cross-Repository Mission Legs

Date: 2026-08-03
Status: Approved design

## Context

Issue-driven Missions currently connect one provider issue to one project,
worktree, and ACP session. The persistence schema stores Mission legs as a
collection, but the store, coordinator, navigation, readiness evaluation, and
Mission tab deliberately enforce exactly one leg.

This design turns that prepared collection into a real cross-repository
Mission. A running Mission can gain repository-specific legs one at a time.
Each leg creates and owns its own worktree and agent session, while all legs
share the Mission issue, activity timeline, aggregate status, and explicit
completion action.

The increment establishes the multi-leg foundation required by later scheduled
Mission triggers. It does not add scheduling or general workflow dependencies.

## Goals

- Add a repository leg to an existing running Mission.
- Share the Mission issue and a concise leg manifest with each new agent while
  preserving repository-specific instructions.
- Create, retry, and recover multiple legs independently and in parallel.
- Track setup, attention, review, diff, and readiness state per leg.
- Show all legs together in one global, worktree-independent Mission tab.
- Make the Mission visible in every Space containing one of its projects.
- Derive Mission readiness only after every leg is ready.
- Preserve existing single-leg Missions and their persisted tabs through an
  explicit migration.

## Non-Goals

- Creating all legs during initial Mission creation.
- Adding more than one leg for the same Alas project.
- Linking a different provider issue to each leg.
- Removing, abandoning, reordering, or detaching a leg.
- Attaching existing worktrees or ACP sessions as new legs.
- Sequential execution or dependencies between legs.
- Sharing agent transcripts or full diffs between leg prompts.
- A combined cross-repository diff or review editor.
- Scheduled, recurring, or unattended Mission triggers.
- Automatically stopping agents, merging reviews, archiving worktrees, or
  mutating the provider issue when the Mission is completed.

## User Experience

### Adding a leg

A running Mission tab shows an `Add Leg` action below its ordered leg cards.
The action is unavailable while the initial Mission is creating and after the
Mission becomes ready or completed. This prevents sticky readiness from being
revoked by adding more work after the completion condition has been observed.

`Add Leg` opens a confirmation sheet derived from the existing Mission
confirmation form. The form contains:

- A project picker containing every configured Alas project not already used
  by the Mission, including projects outside the current Space.
- A base ref using the selected project's existing new-worktree default.
- An editable branch generated from the Mission issue number and title through
  the project's established branch-prefix and sanitization rules.
- An enabled ACP agent picker.
- Editable repository-specific instructions.
- A read-only preview of the shared issue and existing-leg manifest that will
  accompany those instructions.

The project picker enforces one leg per project. Branch, destination, and
worktree reservation validation reuse the existing new-worktree and Mission
rules. Confirmation persists the new leg before starting external work, closes
the sheet, and immediately shows a `Creating worktree` leg card.

### Shared prompt context

Each added leg receives a stable Markdown prompt containing:

1. The stored Mission issue snapshot and canonical provider URL.
2. A concise manifest of every existing leg: project, repository, branch, and
   current leg state.
3. The new leg's repository-specific instructions.
4. The existing focused-change, regression-coverage, and verification guidance.

The prompt does not include other agent transcripts or full diffs. A later leg
uses the latest successfully refreshed issue snapshot and the manifest captured
when that leg is confirmed. Restarting or retrying setup reuses the persisted
prepared prompt rather than rebuilding it from newer runtime state.

### Mission tab

The Mission tab becomes a global center tab whose identity is
`mission:<mission-id>`. It is not owned by any worktree and remains open while
the user switches projects, Spaces, and worktrees.

The page uses one scrolling aggregate layout:

- Mission provider, issue, title, state, issue context, and refresh action.
- Aggregate leg counts, diff totals, review status, and completion explanation.
- One leg card per persisted ordinal.
- Mission activity timeline.
- Explicit Mission completion action.

Each leg card shows project, base, branch, worktree, agent status, diff summary,
linked PR or MR, lifecycle state, attention reason, and available recovery
actions. `Open Agent`, `Open Changes`, `Open Review`, and worktree recovery act
on that leg only. An attention summary links to the affected cards.

The Mission tab does not show a worktree-specific right pane. While it is
active, the right pane is temporarily suppressed without changing the user's
stored visibility preference. A leg action selects the target worktree,
activates the requested worktree-specific surface, and restores the prior
right-pane preference.

### Sidebar and Spaces

A Mission appears in the Missions section of every Space containing at least
one of its leg projects. Its global tab always shows all legs, including legs
whose projects are not present in the active Space.

Selecting a Mission row activates the global tab and highlights only the
Mission row. The last selected worktree remains remembered but is not rendered
as simultaneously selected. Selecting a worktree row returns to that
worktree's most recently active tab; any open Mission tabs remain in the center
tab strip.

Mission rows summarize aggregate leg state with concise labels such as:

- `2 working`
- `1 working · 1 needs attention`
- `2 of 3 ready`
- `Ready to complete`

## Domain Model

### Mission

The Mission remains the durable shared task and owns:

- Its stable ID, title, and one provider issue snapshot.
- An ordered collection of one or more legs.
- A primary-leg ID used only as the default focus and compatibility anchor.
- A single ordered activity timeline.
- Mission-level lifecycle and explicit completion timestamps.

Mission-level lifecycle remains deliberately small:

- `Creating`: the initial primary leg is being established.
- `Running`: the Mission is active, regardless of secondary-leg setup or
  attention states.
- `Ready to complete`: every persisted leg has sticky readiness evidence.
- `Completed`: the user explicitly completed the Mission.

`Needs attention` is no longer a Mission-level runtime state. Existing records
in that state migrate their attention and checkpoint data to their sole leg and
become `Running` at the Mission level.

### Mission leg

Each leg becomes an independently executable record with:

- Stable leg ID, Mission ID, project ID, and ordinal.
- Base remote/ref, branch, destination, worktree ID, and worktree lineage.
- Agent ID, ACP session ID, initial prompt identity, and persisted pending
  prompt.
- Optional provider review identity.
- Leg lifecycle: `creating`, `running`, `needsAttention`, or `ready`.
- Setup checkpoint, optional attention reason, and created/updated timestamps.
- Optional sticky readiness evidence describing merged-review or Alas-archive
  completion and when it was observed.

`MissionAggregate.primaryLeg` finds the leg whose ID equals `primaryLegID`; it
does not require the aggregate to contain exactly one leg.

### Invariants

The store validates that:

- A Mission contains at least one leg.
- Exactly one leg matches `primaryLegID`.
- Every leg belongs to the Mission.
- Leg ordinals are unique and contiguous from zero.
- Project IDs are unique within the Mission.
- Events with a leg ID reference a leg belonging to the Mission.

Completed Missions reject new legs, retries, and readiness transitions. An
external operation already in flight may persist its result and final leg
event, but it must not start the next external checkpoint or change the
Mission's completed state. Provider snapshot refresh metadata retains the
existing completed-Mission behavior.

## Persistence and Migration

The SQLite schema gains leg lifecycle, checkpoint, attention, timestamp, and
readiness-evidence columns. Store operations address mutable setup and review
state by Mission ID plus leg ID. Multi-record changes that affect aggregate
readiness and an event occur in one immediate transaction.

The migration converts each existing single-leg aggregate as follows:

- Mission `Creating`: copy its checkpoint and attention to the leg; retain the
  Mission's `Creating` state until the primary leg settles.
- Mission `Running`: create a `running` leg.
- Mission `Needs attention`: create a `needsAttention` leg with the stored
  checkpoint and reason; change the Mission to `Running`.
- Mission `Ready to complete`: create a `ready` leg with sticky legacy
  readiness evidence; retain Mission readiness.
- Mission `Completed`: retain Mission completion and create a leg state from
  its last durable checkpoint; leg readiness no longer affects the terminal
  Mission.

Existing event leg IDs, review identities, worktree identities, and ACP session
IDs remain unchanged.

## Global Tab Persistence

A narrow global tab store persists worktree-independent tabs under application
support. It initially supports only `MissionTabState(missionID, title)` but has
a boundary suitable for future global surfaces.

The center tab strip composes global Mission tabs with the currently selected
worktree's tabs. Active selection distinguishes a global tab from a worktree
tab rather than overloading `selectedWorktreeId`.

On first launch after migration, Alas scans persisted worktree tab files,
extracts Mission tabs, deduplicates them by Mission ID, writes them to the
global store, and removes them from their former worktree files. Missing
Missions are retained as recoverable unavailable tabs using the existing
missing-Mission presentation. The migration is idempotent and records its
version only after all touched tab files and the global file are durable.

## Coordination

`MissionCoordinator` advances work by `MissionLegID`. It maintains independent
in-flight guards and waiters for each leg, allowing legs to create worktrees
and start ACP sessions concurrently.

Adding a leg follows this restart-safe sequence:

1. Persist the complete planned leg, prepared prompt, and `legAdded` event.
2. Reserve and persist its deterministic worktree identity.
3. Create and reconcile the real worktree.
4. Persist worktree identity and durable lineage.
5. Reserve and persist an ACP session identity.
6. Start the ACP session and deliver the persisted prompt.
7. Mark the leg `running` and append an `agentStarted` event.

The existing primary-leg setup path delegates to the same leg coordinator.
Only initial-primary setup controls the Mission's `Creating` to `Running`
transition. Secondary-leg creation and failures do not change Mission state.

On launch, reconciliation enumerates unsettled legs rather than unsettled
Missions. Each leg resumes from its first incomplete checkpoint using its own
planned path, worktree lineage, ACP session reservation, and persisted prompt.
One leg's persistence or external-operation failure does not cancel another
leg's advancement.

## Review, Readiness, and Completion

Review discovery operates independently for every leg using its provider,
repository, branch, remote, and durable worktree lineage. A linked review is
stored on that leg only.

A leg becomes sticky-ready when either:

- Its linked PR or MR is merged.
- Its worktree is archived through Alas.

A closed-unmerged review does not make a leg ready. An externally missing
worktree makes that leg need attention. Provider refresh failure retains the
last successful leg review snapshot.

After any leg readiness transition, the same transaction reevaluates the
Mission. A running Mission becomes `Ready to complete` only when every leg is
ready. New legs cannot be added after that transition, so Mission readiness
never regresses.

Manual completion remains available while the Mission is running, including
while legs are creating or need attention. The confirmation lists unfinished
legs. Completion changes only Mission state and timeline placement; it does not
force-cancel an external operation already in flight, stop agents, mutate
reviews or issues, or archive worktrees. When an in-flight operation returns,
the coordinator records its outcome but does not begin that leg's next external
checkpoint.

## Failure and Recovery Behavior

- **Secondary worktree failure:** retain the leg at its worktree checkpoint,
  show its sanitized error, and offer `Retry Worktree`. Other legs continue.
- **Secondary ACP failure:** retain the worktree and session reservation, show
  `Retry Agent`, and never repeat Git creation.
- **Restart during setup:** reconcile each unsettled leg independently without
  duplicating worktrees, sessions, or prompts.
- **Project removed:** retain the leg and Mission history, mark only that leg
  unavailable, and keep the global Mission tab usable.
- **Worktree missing externally:** mark only that leg as needing attention;
  never infer readiness or archival.
- **Agent unavailable:** keep the leg worktree and allow a different enabled
  ACP agent to be selected for retry.
- **Issue refresh failure:** retain the shared issue snapshot and mark it stale;
  existing legs and prompts remain unchanged.
- **One-leg persistence failure:** report and retry the affected transaction;
  do not mutate in-memory aggregate state ahead of durable storage.

## Testing

Focused Swift Testing coverage includes:

- Schema migration from every v1 Mission state and interrupted checkpoint.
- Multi-leg store round trips, ordering, primary-leg lookup, event ownership,
  contiguous ordinals, and project uniqueness.
- Adding a leg from a project in the current and another Space.
- Branch and destination defaults using the selected project's policies.
- Prompt generation from issue snapshot, existing-leg manifest, and focused
  instructions without transcript content.
- Parallel setup, isolated worktree/ACP failures, per-leg retries, and restart
  recovery without duplicate artifacts.
- Initial-primary versus secondary-leg Mission-state transitions.
- Independent review discovery and sticky archive/merge readiness.
- All-legs Mission readiness and the prohibition on adding a leg to a ready
  Mission.
- Manual completion while legs are running, creating, and needing attention,
  including settlement of an already in-flight operation without advancing to
  its next external checkpoint.
- Global tab persistence, active selection, unavailable Missions, and
  idempotent migration from worktree tab files.
- Mission visibility in every Space containing a leg and complete global-tab
  rendering from each Space.
- Stacked-card presentation for homogeneous and mixed leg states, aggregate
  counts, diff totals, attention links, and per-leg actions.
- Existing single-leg issue resolution, setup, sidebar, tab, readiness, and
  completion behavior after migration.

Provider tests remain fixture-based. Coordinator tests use fake worktree, ACP,
review, and persistence collaborators rather than live repositories or agents.

Before completion, regenerate the Xcode project after adding source files, run
SwiftFormat lint, run focused Mission/tab/sidebar/code-host/worktree/ACP tests,
and run the repository's required macOS build and test commands.

## Acceptance Criteria

- A running Mission can add a leg for any configured project not already in
  that Mission without changing another leg's artifacts or state.
- Confirming a leg durably creates one planned leg, one worktree, and one ACP
  session with shared Mission context and focused instructions.
- Two or more legs can advance concurrently, fail independently, and resume
  after restart without duplicate artifacts or prompts.
- Every leg exposes its own setup, attention, diff, review, and readiness state
  in one stacked Mission page.
- The Mission tab persists globally and remains usable while switching Spaces,
  projects, and worktrees.
- The Mission appears in every Space containing one of its projects and shows
  all legs from each of those Spaces.
- A Mission becomes ready only after every leg has merged-review or Alas-archive
  evidence; manual completion remains explicit and non-destructive.
- Existing single-leg Missions and Mission tabs migrate without losing issue,
  event, worktree, ACP, review, or readiness identity.
- Scheduling, dependency graphs, leg removal, per-leg issues, and combined
  cross-repository diffs remain outside this increment.
