# PR shepherd design

## Goal

An ACP session that finishes a change can open the PR/MR itself, and Alas then
looks after that PR until it merges. When CI fails, a trusted reviewer leaves a
thread, or the branch conflicts with base, Alas sends the problem back to the
same session as a new turn. When everything is green and the merge gate passes,
Alas can merge it. This matches the PR monitoring, auto-fix and auto-merge that
Claude Desktop ships (see "Monitor pull request status" in
https://code.claude.com/docs/en/desktop), on GitHub and GitLab, for every
project.

The repository's `lassie` skill already does this for `mrmans0n/alas` as an
agent prompt. This design moves the loop into the app and keeps the
repo-specific parts (the Codex gate, CI timing) as project configuration.

## Scope

- New `alas` MCP tools `pr_create` and `pr_status`.
- A `ReviewShepherd` service in AlasCore that watches every bound PR/MR while
  Alas runs, decides what to do with a pure policy, prompts the owning session,
  merges when allowed and escalates when stuck.
- Trusted-reviewer metadata on review comments for GitHub and GitLab.
- Project shepherd rules: free-text instructions plus required reviewers, from
  a repo file or project settings.
- A PR button with a status badge in the ACP toolbar, a shepherd block in the
  Changes review drawer, global defaults in Settings, and per-project rules in
  Project Settings.
- Notifications and sidebar attention for escalations and outcomes.
- Optional auto-archive of the worktree after merge.

Out of scope for v1: remote/SSH worktrees, multi-repo Workspace checkouts,
running while Alas is quit, GitLab merge trains (the provider doesn't detect
them today), reviewers/labels/assignees on create, and replacing the `lassie`
skill.

## Decisions

| Concern | Decision |
| --- | --- |
| Who fixes | The session bound to the PR. Prompts queue behind any running turn. |
| Who runs the loop | Alas. The agent only runs fix turns. |
| Binding | `pr_create` binds to the calling session through `ALAS_SESSION_ID`. Other PRs are bound explicitly from the Changes drawer. Alas never guesses an owner. |
| Providers | GitHub (`gh`) and GitLab (`glab`) through the existing `CodeHostProvider`. |
| Fix triggers | Failed checks, unresolved threads from trusted reviewers, merge conflicts with base. |
| Merge | The existing readiness gate and `ReviewLoopState.merge(snapshot:)` (squash, head-pinned, merge-queue aware), plus required reviewers and a two-poll head stability rule. |
| Storage | `review-shepherds.json` under Application Support via `PersistenceStoreProtocol`, like `run-schedules.json`. |
| Lifecycle | Owned by `AlasCoreContext`, started by AppState after topology loads, stopped at app termination. Independent of pane or window visibility. |
| Polling | Adaptive per record (30 s / 2 min / 5 min), at most 2 provider fetches in flight, immediate evaluation on wake. |
| Project rules | `.alas/shepherd.local.md`, then `.alas/shepherd.md`, then project settings. |
| Toolbar UI | State pill (symbol plus `#N`/`!N`, or "Ship"), in the right-hand group directly left of the minimap toggle. |

## Architecture

```text
AppState ──start/stop──▶ ReviewShepherd (AlasCore, @MainActor @Observable)
                           ├─ records ⇄ review-shepherds.json
                           ├─ per record: headless ReviewLoopState ──▶ gh / glab
                           ├─ ShepherdPolicy.decide(...)          (pure)
                           ├─ ShepherdPromptBuilder.build(...)    (pure)
                           └─ effects via injected closures:
                                deliverPrompt(sessionID, owner, text) → ACP manager (hydrate + queue)
                                sessionState(sessionID, owner)        → busy / idle / archived / missing
                                escalate / notify                     → NotificationService + harness attention
                                refreshPaneIfCached(worktreeID)       → RightPaneStore
                                archiveWorktree(worktreeID)           → existing archive path
                                localState(worktreePath)              → ReviewLoopLocalProbe (AlasCore)
ACPSessionManager.onTurnCompleted ──▶ ReviewShepherd.turnCompleted(sessionID:)
MCP pr_create / pr_status ──▶ AlasCLICommandRouter ──▶ AppState ──▶ ReviewShepherd
```

`ReviewShepherd` follows the `RunScheduler` pattern: AlasCore owns state and
timing, AppState installs the app-specific closures. No AppKit or SwiftUI in
the package.

Each record owns a headless `ReviewLoopState`, so the shepherd reuses the
existing snapshot model, `ReviewReadinessModel.canMergeReviewRequest` and the
final merge revalidation in `ReviewLoopState.merge(snapshot:)`. A new
`ReviewLoopLocalProbe` in AlasCore reads the same local facts `RightPaneState`
uses (clean tree, local HEAD, ahead/behind against upstream). `RightPaneState`
keeps its own assembly, because it shares those git calls with the file tree
refresh and switching would double them.

After each shepherd poll, if `RightPaneStore` has a cached `RightPaneState` for
that worktree, the shepherd calls `refresh(forceReviewLoopRemote: true)` on it.
The Changes drawer stays current without a second polling loop. The drawer's
own 45 s throttle is unchanged.

## Model

```swift
public struct ShepherdRecordID: Hashable, Codable, Sendable {
    public let worktreeID: String          // owner is always .worktree(worktreeID) in v1
    public let providerKind: CodeHostKind
    public let host: String
    public let repositorySlug: String
    public let requestNumber: Int
}

public enum ShepherdPhase: Codable, Equatable, Sendable {
    case watching
    case fixing(dispatchedAt: Date)        // prompt delivered, turn queued or running
    case awaitingPush(turnEndedAt: Date, pollsWithoutProgress: Int)
    case merging
    case queued                            // in a merge queue
    case escalated(ShepherdEscalation)
    case paused                            // provider auth failed; resumes on the next successful fetch
    case merged
    case closed
}

public enum ShepherdEscalation: String, Codable, Sendable {
    case attemptsExhausted, noProgress, deliveryFailed, ownerGone, authFailed
}

public struct ShepherdRecord: Codable, Equatable, Sendable {
    public let id: ShepherdRecordID
    public var sessionID: ACPSession.ID
    public var branch: String
    public var baseBranch: String
    public var autoFix: Bool
    public var autoMerge: Bool
    public var phase: ShepherdPhase
    public var lastDispatchedFingerprint: ShepherdFingerprint?
    public var fixAttempts: Int
    public var lastSeenHeadSHA: String?
    public var stableHeadPolls: Int        // consecutive polls with the same head and complete checks
    public var headFirstSeenAt: Date?      // when the policy first saw lastSeenHeadSHA; nil in older records
    public var notifiedReadyHeadSHA: String?
    public var finishedAt: Date?           // set on merged/closed; drives 7-day retention
    public var createdAt: Date
    public var updatedAt: Date
}

public struct ShepherdFingerprint: Codable, Equatable, Sendable {
    public let headSHA: String
    public let hasConflict: Bool
    public let failingCheckIDs: [String]   // sorted
    public let threadIDs: [String]         // sorted, actionable + trusted only
}
```

Records live in `Paths.reviewShepherdsFile` (`review-shepherds.json`). Records
in `merged` or `closed` are kept for 7 days so the toolbar button and drawer can
show the outcome, then dropped on the next load.

## Policy

`ShepherdPolicy.decide(record:snapshot:threads:rules:session:now:) -> ShepherdDecision`
is pure. `ShepherdDecision` carries the record's next `phase` and one action:
`wait`, `dispatchFix(ShepherdFixRequest)`, `merge`, `notifyReady`,
`finish(.merged | .closed)` or `escalate(ShepherdEscalation)`. The policy runs
only on a successful fetch; fetch errors are handled by the poller (see
Polling).

Rules run in order. The first one that produces an action wins.

1. Terminal. Merged on the provider gives `finish(.merged)`. Closed without
   merge gives `finish(.closed)`.
2. Escalated or paused.
   - `paused`: a successful fetch means auth works again, so the phase becomes
     `watching` and evaluation continues.
   - `escalated`: if the PR has no problems (rule 7's collection is empty),
     the user or someone else fixed it, so the phase becomes `watching` and
     evaluation continues. Otherwise `wait`. Escalated records never dispatch
     or merge until the user presses Resume.
3. Auto-fix off. Skip to rule 8. Auto-merge and the ready notification still
   apply.
4. Owner archived or missing gives `escalate(.ownerGone)`.
5. Owner busy (`transcript.streamingState != .idle` for a live session,
   `directTurnInFlight` for an unloaded one) gives `wait`.
6. Fix turn settled.
   - `fixing` with an idle owner moves to `awaitingPush`. This covers both a
     normal `turnCompleted` and a turn lost to an app restart.
   - In `awaitingPush`, progress means the provider head differs from
     `lastDispatchedFingerprint.headSHA`, or the trusted thread ids differ
     from `lastDispatchedFingerprint.threadIDs` (the agent replied or
     resolved). Progress moves the phase to `watching` and evaluation
     continues. No progress increments `pollsWithoutProgress`; the third such
     poll gives `escalate(.noProgress)`, earlier ones give `wait`.
7. Collect problems:
   - conflict when `mergeState == .dirty`;
   - failed checks (failing bucket), only when no check is pending, so partial
     results never trigger a fix;
   - review threads where `!isResolved && !isOutdated` and the head comment's
     `authorTrust == .trusted`.

   Threads do not wait for checks. A trusted thread on a head with running CI
   dispatches right away, which is lassie's "feedback before CI" rule.

   No problems and no pending check: reset `fixAttempts` to 0, except while a
   head that reports no checks is inside the no-checks grace period (rule 8).
   No problems: continue to rule 8. Problems
   whose fingerprint equals `lastDispatchedFingerprint`: `wait`. Otherwise:
   - if `fixAttempts >= 3`: `escalate(.attemptsExhausted)`;
   - else `dispatchFix` with all current problems, ordered conflict, checks,
     threads. The phase becomes `fixing`, `fixAttempts` increments, and
     `lastDispatchedFingerprint` is set.
8. Merge. Requires `autoMerge`, the existing readiness gate
   (`canMergeReviewRequest`, which includes a clean local tree and local HEAD
   equal to the provider head), every login in `rules.requiredReviewers`
   having reviewed the current head, and `stableHeadPolls >= 2`. A head that
   reports no checks at all also needs `noChecksGracePeriod` (15 minutes)
   since `headFirstSeenAt`, because its CI may not have registered yet; a
   new head restarts that clock. Gives
   `merge` and phase `merging`. A merge-queue outcome moves the record to
   `queued`, and polling continues until the provider reports merged.
9. Ready without auto-merge. Same gate as rule 8 minus `autoMerge`. Gives
   `notifyReady` once per head (`notifiedReadyHeadSHA`).
10. Otherwise `wait`.

Rule 8's gate fails while you have uncommitted changes in the worktree or
local HEAD differs from the provider head, so the shepherd never merges code
you haven't pushed or a head you've moved past locally. Merge failures from
changed state (head moved, gate no longer passes) return the record to
`watching`. The policy never bypasses the gate.

### Trusted reviewers

`ReviewComment` gains `authorTrust: ReviewAuthorTrust` with cases `trusted`,
`untrusted`, `unknown`. The policy acts only on `trusted`.

- GitHub. The review-thread GraphQL query adds `authorAssociation` and the
  author's `__typename`. Trusted when `viewerDidAuthor == false` and the
  association is `OWNER`, `MEMBER` or `COLLABORATOR`, or the author is a `Bot`.
- GitLab. Note authors carry no `bot` flag (notes use GitLab's `UserBasic`
  entity), so the provider resolves each thread-head author's access level
  with `glab api projects/:id/members/all/:user_id`, and calls
  `glab api users/:id` for the `bot` flag only when that returns 404 or a level
  below 30. Results are cached in the provider for one hour. Trusted when the
  author is not the authenticated user and the access level is at least 30
  (Developer), or the author is a bot.
- Anything the provider can't classify is `unknown`.

### Required reviewers

`rules.requiredReviewers` is a list of logins. A login counts as having
reviewed the current head when any of these holds:

- GitHub: a submitted review whose `commit.oid` is the head; a top-level
  comment, or a THUMBS_UP reaction on the PR, created after the head commit's
  `committedDate` (only while the PR's last commit is still the head).
- GitLab: an approval not older than the head commit, or a note created after
  it.

Logins are lowercased and a trailing `[bot]` is stripped, so
`chatgpt-codex-connector` matches `chatgpt-codex-connector[bot]`. Checked
against `mrmans0n/alas` PRs #1966, #1969 and #1970: Codex leaves a formal
review only when it has findings; on a clean head it adds a THUMBS_UP reaction
(EYES while it is still reviewing, which does not count).

## Polling

| Record state | Interval |
| --- | --- |
| Checks pending, `fixing`, `awaitingPush`, `merging`, `queued` | 30 s |
| Watching, checks complete | 2 min |
| `escalated`, `paused` | 5 min |
| `merged`, `closed` | not polled |

One 30 s timer evaluates which records are due. At most 2 provider fetches run
at once. `NSWorkspace.didWakeNotification` (installed through
`PlatformServices`, like `RunScheduler.wakeNotification`) and app launch
evaluate every non-terminal record immediately. Provider errors back off
exponentially per record up to 10 min. An authentication failure moves the
record to `paused` and escalates once with `.authFailed`.

`turnCompleted(sessionID:)` moves any `fixing` record owned by that session to
`awaitingPush` and makes it due immediately.

## Session integration

AppState gets `deliverShepherdPrompt(sessionID:worktreeID:text:) async -> Bool`,
modeled on `ACPSessionOrchestrationCoordinator.resolveDeliveryTarget`:

1. Load the persisted row. Archived or missing returns `false`.
2. `placeholderSession(id:)`, then `hydrateIfNeeded(id:)`.
3. `ACPSessionManager.enqueueDelegatedPrompt(text:source:into:)` with a
   shepherd `ACPDelegatedPromptSource`, then `reattach(to:)` when the agent is
   idle, disconnected or failed.

`sendPrompt` cannot be used here: it requires a writer lease that only an
attached session holds. The enqueue-then-reattach route is the one the
orchestration coordinator uses for a child's first prompt, so the session does
not need an open tab. A `false` result escalates with `.deliveryFailed`.

AppState adds `reviewShepherd.turnCompleted(sessionID:)` to its existing
`onTurnCompleted` fan-out next to scheduled turns and orchestration.
`ACPTurnCompletion` carries no commit identity, so progress is measured from
the provider head on the next polls (rule 6).

Shepherd prompts start with an `Alas PR shepherd` header line, and the
shepherd source makes the transcript render them through the existing
`DelegatedPromptRow` with the caption "Alas PR shepherd".

### Fix prompt

`ShepherdPromptBuilder.build(request:fixRequest:rules:)` is pure. Shape:

```text
Alas PR shepherd · GitHub #2041 "fix(auth): retry token refresh"
Branch fix-login → main · head a3f9c1e

The PR needs attention. Fix what's below, commit, and push to fix-login.
Never force-push or rewrite published history. When done, call pr_status to confirm.

## Merge conflict with main
Merge origin/main into fix-login, resolve each conflict from the intended
behavior, commit, push.

## Failing checks (2)
### unit-tests (CI / build.yml)
<tail of failed log, at most 8,000 characters>
Full log: https://…

## Review threads (1)
### Auth/TokenRefresher.swift:88 · @maintainer (MEMBER)
> This retry should back off; we hammer the endpoint.
Thread: https://… (id: PRRT_…)

## How to work
- Classify each finding: fix it, show it is already fixed, or reply with
  evidence that it is wrong. Never change code only to silence wrong feedback.
- Batch every fix you can make now into one push.
- Run the tests your repository instructions require for the files you touch.
- If a check failure is unrelated to your change and the log shows a flake or
  infrastructure error, rerun it with gh/glab and say why.
- Reply on threads you decline. Resolve threads you fixed.
- If you can't make progress, say so plainly. Alas will notify the user.

## Project rules
<contents of the resolved project instructions>
```

Limits. At most 3 failed-check logs, fetched with `checkEvidenceDetail` (which
already keeps the last 8,000 characters). Further failing checks are listed by
name, workflow and link. Threads include the full comment chain from
`ReviewThread.comments`, not only the head comment. The "Project rules" section
is omitted when there are none.

### Rebinding

The Changes drawer can bind an unowned PR or move a record to another session.
The new owner gets a context prompt with the PR, branch and current problems,
and `fixAttempts` resets to 0.

## Project rules

`ShepherdRulesResolver.resolve(worktreePath:project:) -> ShepherdRules`, pure
over file contents and `ProjectConfig`:

```swift
public struct ShepherdRules: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case localFile, repoFile, projectSettings, none }
    public let source: Source
    public let instructions: String
    public let requiredReviewers: [String]
}
```

Order: `.alas/shepherd.local.md`, then `.alas/shepherd.md` in the worktree,
then `ProjectConfig.shepherd` (`instructions: String`,
`requiredReviewers: [String]`), else `none`. The first source found wins
completely; sources are not merged. Repo files take optional YAML frontmatter
with one key:

```markdown
---
required_reviewers: [chatgpt-codex-connector]
---
Codex reviews every push within 5 to 10 minutes. Act on its findings without
waiting for CI. CI takes about 50 minutes and a push cancels the run in flight,
so batch fixes into one push.
```

Rules are re-resolved on every dispatch and merge decision, so editing the
file takes effect on the next poll.

## MCP tools

Both follow the existing path: tool definition in `AlasCLI/crates/alas/src/mcp.rs`,
a `Command` variant and `build_request` case in `alas-client`, `AlasCLIRequest`
decoding, an `AlasCLICommandRouter` case, and an AppState service backed by
`ReviewShepherd`. The calling session comes from `ALAS_SESSION_ID`.

### `pr_create`

Arguments: `title` (required), `body` (required), `draft` (default false),
`base` (default: the worktree's base branch).

Description shown to agents: "Open a pull/merge request for this worktree's
branch and have Alas watch it. Offer this when you've finished a change the
user will want reviewed, and call it only after the user agrees or asks."

Behavior:

1. Reject with a plain message when the worktree is not local, is a Workspace
   checkout, has a detached HEAD, is on the base branch, tracks the base
   branch as its upstream (the push would land on base), has no commits ahead
   of base, or `gh`/`glab` is missing or unauthenticated (the message names
   the install or `auth login` command).
2. If an open PR/MR already exists for the branch, bind it and return
   `created: false`.
3. Push the exact HEAD with `git push -u <remote> <sha>:refs/heads/<branch>`,
   reusing the push step and destination checks from `CommitPublishWorkflow`.
   Never force.
4. `createReviewRequest`, then bind the result to the calling session with the
   default toggles from Settings.

Result:

```json
{
  "number": 2041,
  "url": "https://github.com/…/pull/2041",
  "provider": "github",
  "head_sha": "a3f9c1e…",
  "created": true,
  "uncommitted_changes": false,
  "shepherd": { "auto_fix": true, "auto_merge": false }
}
```

Uncommitted changes don't block creation. `uncommitted_changes: true` lets the
agent mention them.

### `pr_status`

No arguments. Returns the PR bound to the calling session, else the PR for the
worktree's current branch, else `{"pull_request": null}`. Always a fresh
provider fetch that bypasses the 45 s throttle.

```json
{
  "pull_request": {
    "number": 2041, "url": "…", "state": "open", "draft": false,
    "head_sha": "a3f9c1e…", "merge_state": "blocked",
    "checks": { "passed": 10, "failed": 1, "pending": 1, "skipped": 0,
                "failing": [{ "name": "unit-tests", "workflow": "CI", "url": "…" }] },
    "threads": [{ "id": "PRRT_…", "path": "Auth/TokenRefresher.swift", "line": 88,
                  "author": "maintainer", "trust": "trusted", "body": "…", "url": "…" }],
    "missing_required_reviewers": ["chatgpt-codex-connector"]
  },
  "shepherd": { "phase": "fixing", "auto_fix": true, "auto_merge": false,
                "fix_attempts": 1, "rules_source": "repo_file" }
}
```

`threads` lists actionable threads from trusted reviewers only. `shepherd` is
null when the PR is not bound.

No `alas pr` terminal command. The Rust CLI parser is handwritten, so the
subcommand would not come for free, and agents reach these tools through MCP.

## UI

### ACP toolbar button

`ACPShepherdButton` in `Alas/Sources/ACP/UI/`, placed in `ACPToolbar`'s
right-hand group directly left of the minimap `ToolbarBtn`. A 22 pt pill with
a 5 pt corner radius, `bg-3` fill and a 0.5 pt `line` border, lit on hover or
while the popover is open. It holds a state symbol and the request number
(`#N` on GitHub, `!N` on GitLab) in 11 pt semibold monospaced. With neither a
record nor a PR it shows `arrow.up.circle` and "Ship", with the tooltip "Ship
with agent". `ShepherdPresentation.badge` (`ShepherdBadgeState`) picks the state:

| State | Symbol, color |
| --- | --- |
| PR exists, not shepherded by this session | `arrow.triangle.pull`, `fg-muted` |
| Checks pending, `watching`, `awaitingPush`, waiting on reviewers | `clock.fill`, `warn` |
| `fixing` | `sparkles`, `accent`, with the AI beam |
| Ready (gate passes) | `arrow.triangle.merge`, `add` |
| `merging` | `arrow.triangle.merge`, `add`, with the AI beam |
| `queued` | `list.bullet.rectangle`, `add` |
| Failing with auto-fix off, `escalated`, `paused` | `exclamationmark.triangle.fill`, `del` |
| `merged` | `checkmark.circle.fill`, `.systemPurple` |
| `closed` | `xmark.circle`, `fg-muted` |

The tooltip states the PR number and phase, for example "#2041 · fixing
unit-tests".

Popover, 340 pt wide and sized to its content. Past 8 checks the check list
scrolls at 8 rows so a large PR doesn't make a giant popover:

- Header: PR number and title with an open-in-browser link, then
  `branch → base · short SHA · provider`.
- Checks through the existing `CIStatusStrip`.
- Thread count, and required reviewers still missing on this head.
- Shepherd line: phase, attempt count, and the rules source ("Rules:
  .alas/shepherd.md").
- Switch rows (`ShepherdSwitchRow`): a 12 pt medium title over a 10.5 pt
  `fg-muted` description, with a mini native switch trailing and vertically
  centered. "Auto-fix": "CI failures, conflicts and reviewer threads go back to
  this session". "Auto-merge": "Squash-merge once checks, reviewers and the
  head are settled". Both are disabled once the record is terminal.
- Footer actions: "Open in Changes", "Stop shepherding". Stop deletes the
  record and leaves the PR untouched. Escalated records also show "Resume",
  which returns them to `watching` and resets `fixAttempts`.

With no bound PR, the popover shows the branch, its ahead count and a "Ship
with agent" button (`sparkles`) captioned "The agent writes, opens and
shepherds the PR" (MR on GitLab). The button is disabled while the session is
busy or the provider is unavailable, with the reason in place of the caption.
It sends the session:

```text
Open a PR/MR for the work on this branch. If there are uncommitted changes that
belong to this work, commit them first. Write the title and description from
the actual diff and this conversation, then call pr_create.
```

If the branch already has an unowned PR, the popover offers "Shepherd #N from
this session" in place of Ship with agent. Every other surface keeps "Create
PR" for the direct, non-agent action.

### Changes review drawer

When the drawer's PR has a record, `ChangesTabView` shows
`ReviewShepherdBanner` directly above `ReviewLoopDrawer`: a full-width strip
with an accent tint and an accent top hairline, the owner's agent logo, "<agent>
· <session title> is shepherding #N · <phase line>" (truncated in the middle)
and a Jump action that focuses the owner's tab. While the record is fixing or
merging the strip runs the AI beam. With the owner archived or missing it
reads "Owner session archived or missing" in `warn` with a "Shepherd with…"
menu.

In `ReviewLoopDrawer`:

- Expanded body, above the actions: a shepherd block with the phase line, the
  same two switch rows (the auto-fix description names "the shepherding
  session"), Resume/Stop, and "Move to…".
- Unbound PR: a "Shepherd with…" menu listing the worktree's non-archived
  sessions sorted by `updatedAt` (the history list sorts by `lastOpenedAt`,
  so this sort is explicit), plus "New session" which launches the default
  agent through `PreparedWorktreeACPPrompt` with the rebinding context prompt.

All surfaces read and write the same `ReviewShepherd` record.

### Changes tab create flows

The Draft PR tab and the Draft commit tab's Commit & PR action can hand the
request they create to a session. `ChangesShepherdLine` sits under the
editor's header row, which holds the create and commit buttons: a "Shepherd
with" checkbox and a menu of the worktree's non-archived sessions, newest
`updatedAt` first, plus "None". It defaults to the newest session. It is
hidden when the worktree isn't shepherd-eligible or has no sessions, and in
the Draft commit tab whenever publishing would not create a PR (one already
exists, or gg mode).

The pick is stored as `shepherdChoice` (`ChangesShepherdChoice`, nil until
picked) in `DraftReviewRequestTabState` and `DraftCommitTabState`. Commit & PR
also copies the resolved session into its `CommitPublishReviewTarget`, so the
checkpoint carries it and a resumed publish binds the same session.

After the create succeeds and the Changes pane has refreshed, the tab looks
the request up in the refreshed snapshot by its URL, the same match it uses
to open the created request, and calls `shepherdWithSession`, which sends the
session the context prompt. A failed bind never fails the create: a missing
request posts an in-app error pointing at the drawer's "Shepherd with…", and
a delivery failure escalates the record as usual.

### Settings

Settings > Changes gains a "PR shepherd" group in `AppConfig.Changes`:

| Setting | Default |
| --- | --- |
| Auto-fix new PRs | on |
| Auto-merge new PRs | off |
| Archive worktree after its PR merges | off |

Auto-archive runs only after `finish(.merged)` and once the owning session is
idle, through the existing archive path, which hides the worktree and stops its
tabs without touching disk.

Project Settings > Automation gains "PR shepherd": an instructions text area
and a required-reviewers list, stored in `ProjectConfig.shepherd`. When the
worktree has a shepherd file, the section shows "Overridden by
.alas/shepherd.md" (or `.local.md`).

## Notifications and attention

| Event | macOS notification | Sidebar attention |
| --- | --- | --- |
| Escalation (any reason) | yes | yes: `harness.setExternalActivity(..., state: .awaitingInput, requiresUserInput: true)` on the owning session, same as MCP `notify` at attention level |
| Ready to merge with auto-merge off, once per head | yes | no |
| Merged or queued by the shepherd | yes | no |
| Closed without merge | yes | no |
| Fix dispatched | no | no |

No new `AttentionKind`. When the owner is gone there is no session to flag, so
the escalation goes to the worktree's attention history through
`AttentionProducer.review` (`actionableFeedback`, which does not count as
unresolved) with a body naming the PR. The notification, the red badge and the
drawer block carry the signal in that case.

## Error handling

- Provider CLI missing: `pr_create` and the Ship with agent button say so and name
  the install command. Existing records go to `paused` with `.authFailed`.
- Push rejected (non-fast-forward, protected branch): `pr_create` returns the
  git error. The shepherd never pushes.
- Delivery failure: escalate `.deliveryFailed`, poll at the escalated
  interval, and retry delivery only after the user presses Resume.
- Head moved during merge: `merge` returns no outcome or throws; the record
  returns to `watching`.
- Worktree deleted or archived by the user: the record is dropped on the next
  evaluation.
- Persistence decode failure: the existing `PersistenceStore` recovery moves
  the unreadable file to `review-shepherds.json.broken-<timestamp>`; the
  shepherd logs it and starts with no records. Records decode one by one, so a
  single bad record does not drop the rest.

## Testing

Following AGENTS.md: fewer, sharper tests, extending existing suites first.

- `ShepherdPolicyTests` (AlasCore, new suite for a new type), parameterized
  with `@Test(arguments:)`:
  - terminal states, auto-fix off, archived owner, busy owner;
  - escalated record returns to `watching` when its problems clear; paused
    record resumes on a successful fetch;
  - `fixing` with an idle owner (restart mid-turn) moves to `awaitingPush`;
  - fingerprint dedupe; threads dispatch while checks are pending; failed
    checks wait for pending checks;
  - attempt cap, no-progress escalation, reset on green;
  - merge gate: required reviewer missing on current head, stability below 2
    polls, dirty local tree, merge queue moves to `queued`, a head with no
    checks inside and after the grace period;
  - ready notification fires once per head.
- `ShepherdPromptBuilderTests`: section order, three-log cap with the rest
  listed, full thread chains, project rules appended or omitted.
- `ShepherdRulesResolverTests`: `.local.md` over `.md` over settings,
  frontmatter parsing including a missing or malformed block.
- Existing GitHub and GitLab provider parsing suites: `authorAssociation`
  and bot mapping to `authorTrust`; GitLab access-level mapping.
- Rust: `command_for_tool` cases for `pr_create` and `pr_status` if the crate
  has tests in that style.

Not tested: views, `deliverShepherdPrompt` (it forwards to the orchestration
hydrate-and-send path), defaults, and persistence round trips.

Smoke runs before shipping:

1. Throwaway PR on this repo created through `pr_create` from a session.
2. Break a test; confirm the shepherd dispatches a fix, the session pushes,
   and the record returns to `watching`.
3. With `.alas/shepherd.md` requiring `chatgpt-codex-connector`, confirm
   auto-merge waits for Codex on the current head.
4. GitLab test project: `pr_create`, `pr_status`, and one fix cycle from a
   failing pipeline.
