# Issue-Driven Missions

Date: 2026-08-01
Status: Approved design

## Context

Alas organizes repositories, worktrees, terminals, and ACP sessions, but the
unit of work is still implicit. Starting from a GitHub or GitLab issue requires
the user to translate the issue into a branch, create a worktree, start an
agent, provide context, and remember how those pieces belong together.

This design introduces a durable `Mission` as that missing unit of work. The
first release turns one provider issue into one worktree and one ACP session.
The Mission remains visible above the underlying project and worktree, carries
the issue snapshot and activity history, and has an explicit lifecycle.

The persistence model deliberately represents Mission legs as a collection,
although the first release enforces exactly one. That creates a narrow path to
later multi-repository Missions without putting multi-repository orchestration,
schedules, or heartbeats into this implementation.

## Goals

- Create a Mission from a pasted GitHub or GitLab issue URL or a short issue
  reference.
- Let the user confirm the project, base, branch, ACP agent, and initial prompt
  before anything is created.
- Durably connect the issue snapshot, Mission, worktree, ACP session, and
  eventual PR or MR identity.
- Make setup restart-safe and retryable without deleting work that already
  succeeded.
- Give Missions a first-class sidebar section and a dedicated center-pane tab.
- Derive `Ready to complete` from a merged PR or MR or from a worktree archived
  through Alas, while keeping Mission completion an explicit user action.
- Leave the source issue untouched.
- Establish provider-neutral and multi-leg domain boundaries that can support
  later scheduled and cross-repository Missions.

## Non-goals

- An issue inbox, issue search, assignment queue, or provider notification feed.
- More than one repository or worktree leg in a Mission.
- Scheduled Missions, recurring agents, heartbeats, or unattended execution.
- Manual Missions without a provider issue.
- Closing, reopening, labeling, assigning, or commenting on the source issue.
- Automatically creating, publishing, merging, or closing a PR or MR.
- Automatically archiving or deleting a worktree.
- Mission CLI, MCP, remote-device, or mobile controls.
- Supporting terminal-based agents as the Mission's initial agent surface.

## User Experience

### Entry and issue resolution

The Missions section in the left sidebar has a `New Mission` action. Activating
it opens a small entry sheet with one issue reference field.

The field accepts:

- A canonical GitHub or GitLab issue URL.
- `#123`, resolved against the project containing the currently selected
  worktree.

A full URL is matched to a project already added to Alas by comparing the
provider kind, host, and repository path with each project's detected remote.
Alas does not clone or add a project as a side effect. If no project matches,
the sheet explains that the repository must be added first. A short reference
requires a selected project and never guesses across projects.

Resolution fetches the issue title, body, state, labels, assignees, update time,
canonical URL, and provider identity. This produces an in-memory draft only;
no Mission, worktree, branch, or ACP session exists yet.

### Confirmation

After successful resolution, the sheet becomes a confirmation form containing:

- A read-only issue summary and provider identity.
- The matched project.
- The base ref, using the existing new-worktree default.
- An editable branch name generated from the issue number and sanitized title,
  using the project's established branch-prefix policy.
- The default enabled ACP agent, with the existing agent picker available.
- An editable initial prompt.

The Mission title is the issue title in the first release. Worktree destination
derivation follows the existing new-worktree behavior and is not a separate
Mission concept.

The default prompt names the issue and asks the agent to inspect the attached
issue context, keep the change focused, add regression coverage, and verify the
result. The complete structured issue snapshot is included in the prompt in a
stable Markdown section with the canonical URL, rather than relying only on the
short instruction.

If a non-completed Mission already has the same canonical issue identity, the
confirmation flow offers `Open Existing` and `Create Another`. It never merges
or silently reuses Missions.

### Creation feedback

Selecting `Create Mission` closes the confirmation sheet and immediately adds
the durable Mission row with a `Creating` state. The row and Mission tab show
the exact checkpoint, such as `Creating worktree` or `Starting agent`.

Creation is a recoverable sequence, not an all-or-nothing transaction across
Git and ACP processes:

1. Persist the Mission, issue snapshot, initial leg, and a creation event.
2. Run and await the real Git worktree operation.
3. Persist the successful worktree identity and event.
4. Create and persist the ACP session identity for that worktree.
5. Start the ACP session and submit the prepared prompt.
6. Persist the running checkpoint and open the Mission tab.

Alas must not interpret the current optimistic worktree row as completion. The
Mission advances past step 2 only when the underlying Git operation and project
reconciliation have succeeded.

### Sidebar and Mission tab

`Missions` is a first-class section above `Projects` within the active Space.
In the first release, a Mission appears in every Space containing its leg's
project. Active Missions are sorted by most recent Mission activity. Completed
Missions are omitted from the active list and are available in a collapsed
completed subsection.

A Mission row shows provider and issue number, title, and current Mission state.
Selecting it activates the Mission's worktree and opens or focuses a dedicated
Mission tab. The tab contains:

- Provider, repository, issue number, title, state, and an `Open Issue` action.
- The stored issue snapshot with a manual `Refresh` action and captured time.
- A leg card with project, base, branch, worktree, ACP status, diff summary, and
  linked PR or MR state when available.
- `Open Agent`, `Open Changes`, and `Open Issue` actions.
- A durable activity and failure timeline.
- Readiness explanation and the explicit completion action.

The first release stores `MissionTabState(missionID, worktreeID)` in the
primary worktree's existing tab set. Selecting a Mission always resolves its
current primary leg before switching worktrees and focusing that stable tab ID.
This avoids adding a second global tab host. A future multi-repository Mission
may require a global Mission surface, but that is outside this design.

## Domain Model and Persistence

Mission data lives in a global `missions.sqlite` under Alas application
support. A global store is required because Mission identity is above a single
worktree and later Missions may contain multiple legs. SQLite provides durable
checkpoints, ordered events, migrations, and atomic updates within the Mission
store. It avoids putting task lifecycle data in project JSON or in a
per-worktree ACP database.

The store is owned off the main actor behind a narrow `MissionStore` API. Views
and provider adapters never write tables directly.

### Mission

A Mission record contains:

- Stable UUID-based Mission ID.
- Title.
- Source kind. `issue` is the only valid source kind in the first release.
- Lifecycle state and setup checkpoint.
- Primary leg ID.
- Created, updated, and optional completed timestamps.
- Optional current attention reason.

### Issue source

The one-to-one issue source contains:

- Provider kind and normalized host.
- Normalized repository identity and issue number.
- Canonical URL.
- Title, body, state, labels, assignees, and provider update timestamp.
- Snapshot capture timestamp and last refresh error, if any.

Provider kind, normalized host, normalized repository identity, and issue
number form the canonical duplicate key. Completed Missions do not block reuse
of that key.

### Mission leg

A Mission owns an ordered collection of legs. Each leg contains:

- Stable leg ID and Mission ID.
- Project ID and ordinal position.
- Base ref, branch, and planned worktree destination.
- Optional worktree ID after Git creation succeeds.
- Chosen ACP agent ID and optional local ACP session ID.
- Optional linked review identity: provider, host, repository, number, and URL.

The first release validates that a Mission has exactly one leg. Using a
collection now makes later cross-repository work additive instead of requiring
the Mission identity and persistence boundaries to be replaced.

### Mission event

Mission events are append-only user-facing timeline entries with a stable ID,
Mission ID, timestamp, event kind, concise display text, and optional leg ID.
Events cover creation checkpoints, retries, refreshes, readiness changes, and
completion. Provider output and process errors are sanitized before storage and
display.

## Provider Boundary

Issue loading uses a focused `CodeHostIssueProviding` interface rather than
putting URL parsing or CLI details in the Mission coordinator. `GitHubCLIProvider`
and `GitLabCLIProvider` conform to this interface and continue using the
existing `CodeHostCommandRunning` abstraction. The live registry exposes an
issue provider for each supported `CodeHostKind`.

The issue resolver has three separate responsibilities:

1. Parse and canonicalize the user reference.
2. Match it to a configured project and detected `CodeHostRemote`.
3. Ask the matched provider for an `IssueSnapshot`.

Provider adapters use structured CLI output and are host-aware, including
GitHub Enterprise, self-hosted GitLab, and GitLab repository subgroups. They
map missing optional fields to empty or unknown values. CLI absence,
authentication failure, issue-not-found responses, permission errors, and
malformed required output remain distinct user-facing failures.

Issue refresh replaces the stored snapshot only after a complete new snapshot
is available. If refresh fails, Alas keeps the previous snapshot, marks it
stale, records the error, and keeps the provider URL usable.

No interface in this release permits issue mutation.

## Mission Coordination

`MissionCoordinator` owns the setup state machine and delegates provider, Git,
ACP, and persistence work to narrow collaborators. It does not embed Git or ACP
process logic.

The existing worktree creation path requires one targeted extraction. Its
current public behavior inserts an optimistic row and completes Git work in a
background task. Introduce a completion-aware worktree creation operation that
returns the reconciled `Worktree` only after Git succeeds. The existing New
Worktree UI may retain optimistic presentation while using that operation;
Mission creation awaits its result.

ACP creation likewise needs a worktree-addressed operation that does not depend
on the currently selected worktree. It creates and persists the local session
ID before connection and prompt submission, allowing the Mission leg to record
that ID before the fallible startup step. The existing ACP tab-opening path can
delegate to the same operation.

Each checkpoint write is idempotent. On app launch, the coordinator inspects
Missions left in `Creating` or `Needs attention`, reconciles their planned and
persisted artifact IDs, and resumes only the first incomplete checkpoint. A
known worktree path or local ACP session ID is reused rather than recreated.

## Lifecycle

The persisted Mission states are:

- `Creating`: initial setup is actively advancing through a named checkpoint.
- `Running`: setup succeeded and the Mission remains active. The ACP session
  may itself be working, idle, stopped, or awaiting input without changing the
  Mission to completed.
- `Needs attention`: an operation failed or a required artifact is missing.
  The attention reason and retry checkpoint are persisted.
- `Ready to complete`: Alas observed an advisory completion condition.
- `Completed`: the user explicitly completed the Mission.

The normal transition is:

`Creating → Running → Ready to complete → Completed`

A fallible checkpoint may transition `Creating` or `Running` to
`Needs attention`. A successful retry returns to the appropriate setup
checkpoint and then to `Running`. After initial setup has settled, the user may
complete a `Running`, `Needs attention`, or `Ready to complete` Mission through
a confirmation action. Completion is unavailable while a setup operation is
actively in flight and does not cancel that operation.

Completing a Mission changes only Mission state and list placement. It does not
stop an ACP process, mutate the issue, merge code, archive or delete a
worktree, or delete persisted sessions. Those remain separate explicit actions.

## Readiness

`MissionReadinessEvaluator` observes existing Alas state and code-host review
data. A non-completed Mission becomes `Ready to complete` when either:

- Its linked PR or MR is merged.
- Its worktree is archived through Alas.

Review identity is captured on the Mission leg when existing review discovery
finds a request for the leg's branch. Readiness is reevaluated when the Mission
tab refreshes, existing review data refreshes, a worktree archive completes,
and during startup reconciliation. This design does not add an independent
provider polling loop.

A PR or MR closed without merge does not make a Mission ready. A worktree
missing from disk without an Alas archive action becomes `Needs attention`, not
ready. Source issue state does not determine Mission readiness.

Readiness is advisory but sticky. Once Alas has observed a merged review or an
explicit Alas archive event, a later provider refresh failure must not make the
Mission look unfinished again. `Ready to complete` remains until the user acts,
and `Completed` is terminal for this release.

## Failure and Recovery Behavior

- **Worktree creation failure:** retain the Mission and planned leg, store the
  error, and offer `Retry Worktree`. No ACP session is created.
- **ACP creation or startup failure:** retain the successful worktree and any
  persisted local ACP session ID. Offer `Retry Agent` and `Open Worktree`.
  Never repeat Git creation.
- **Restart during setup:** reconcile stable planned paths and local IDs, then
  continue from the first incomplete checkpoint without duplicating artifacts.
- **Provider refresh failure:** retain and show the last successful issue
  snapshot with stale metadata and a retry action.
- **Externally missing worktree:** move to `Needs attention` and offer existing
  worktree recovery or Mission completion actions. Do not infer archival.
- **Agent unavailable after confirmation:** fail at the agent checkpoint while
  keeping the worktree and allow another enabled ACP agent to be selected for
  retry.
- **Project removed:** retain Mission history and provider context, mark the leg
  unavailable, and avoid destructive cleanup.

Errors are attached to the checkpoint that produced them. Retrying a later
checkpoint never reruns an earlier successful one.

## Testing

Focused Swift Testing coverage should include:

- GitHub and GitLab URL parsing, short-reference resolution, enterprise hosts,
  GitLab subgroups, canonical duplicate identities, and invalid inputs.
- Provider command construction and fixture parsing for complete and partial
  issue responses, missing CLI, authentication failure, not-found responses,
  and malformed output.
- Branch default generation and sanitization through existing project prefix
  rules.
- Mission store migration, round trips, ordered legs and events, canonical
  duplicate lookup, and active/completed queries.
- Coordinator checkpoint transitions with fake issue, worktree, ACP, and store
  collaborators.
- Worktree failure before ACP creation, ACP failure after worktree success,
  retry behavior, and app-restart reconciliation without duplicate artifacts.
- Readiness for merged, closed-unmerged, archived, and externally missing
  worktrees, plus confirmation that issue state is ignored.
- Mission completion side effects: only Mission state and events change.
- Active Space filtering and Mission-row navigation to the primary worktree.
- `MissionTabState` Codable round trips and stable tab identity.
- Mission tab presentation for creating, running, needs-attention,
  ready-to-complete, stale-source, and completed records.

Provider tests use recorded JSON fixtures and fake command runners; they do not
require live GitHub or GitLab access. Coordinator integration tests use fake
artifact services rather than creating real worktrees or agent processes.

Before completion, run the focused Mission, code-host, worktree, ACP, sidebar,
and tab tests; regenerate the Xcode project after adding source files; run
SwiftFormat lint; then run the repository's required macOS build and test
commands.

## Acceptance Criteria

- A GitHub or GitLab issue reference can be resolved and confirmed without
  mutating local Git state.
- Confirming creates one durable Mission, one linked worktree, and one linked
  ACP session with the issue context submitted as the initial prompt.
- Closing and reopening Alas at every creation checkpoint resumes safely and
  does not create duplicate worktrees or ACP sessions.
- A setup failure preserves every artifact that already succeeded and exposes
  a retry for only the failed checkpoint.
- The Mission is visible in the active Space, opens a dedicated Mission tab,
  and retains its issue snapshot and activity across restarts.
- A merged PR or MR or an Alas worktree archive makes the Mission ready; a
  closed-unmerged review or externally missing worktree does not.
- Completing a Mission is explicit and has no provider, Git, worktree, or ACP
  side effects.
- GitHub and GitLab behavior is provider-neutral at the Mission layer.
- The stored leg collection is multi-leg-capable while all first-release UI and
  coordinator validation enforce exactly one leg.
