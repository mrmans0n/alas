# Review before push design

## Goal

Ship can already take a branch from a finished session to a merged PR: the
session calls `pr_create`, Alas pushes and opens the PR, the shepherd sends CI
failures, trusted review threads and conflicts back to the session, and
Auto-merge lands it. This design adds a code review by a second agent before
every push Ship makes.

With Review before push, Auto-fix and Auto-merge on, one Ship click still ends
in a merged PR with no input from the user. The difference is that every head
Alas pushes, the first one and every fix after it, was reviewed locally first
and came back clean.

The user picks the reviewer's agent and model and writes what it looks for.
Both work globally, per project and per PR. A repository can add its own
instructions in `.alas/code-review.md`, for example "Watch out for
`// ponytail` comments, remove the ponytail prefix". Findings and verdicts show
in the existing review pane.

## Scope

In scope:

- A Review before push lever on PR and gg stack shepherding, with a global
  default and a per-ship switch, next to Auto-fix and Auto-merge.
- A gate in `pr_create`, `stack_ship` and the shepherd's fix loop: Alas pushes
  only a commit whose review is clean or that the user let through.
- A reviewer that runs as a read-only ephemeral session with the chosen agent
  and model, and returns findings that Alas files into the review pane.
- A reviewer setting (agent, model) in Settings, Project Settings and each
  ship, and a review prompt built from four layers: global, repo file, project,
  local file.
- A verdict banner in the review pane, which the desktop does not render today.
- New stops, phases and notifications for the review loop.
- An updated agent contract for `pr_create`, `stack_ship` and `pr_status`.

Out of scope:

- Blocking pushes Alas doesn't make. A session or the user can still run
  `git push`. Alas notices the unreviewed head afterwards (see "Heads pushed
  outside Alas") but does not install a `pre-push` hook.
- Gating the Changes pane's Push and Commit & publish buttons.
- Posting findings to GitHub or GitLab automatically. The pane's existing
  Publish review still works on a PR review.
- Changing the lever or the reviewer from a paired Mac or the iOS app. They
  see the new phases through the shared `phaseLine`.
- A reviewer key in `.alas/config.json`, and a review button outside Ship.

## Decisions

| Concern | Decision |
| --- | --- |
| When the review runs | Before each push Alas makes for a shipped branch or stack, on the local commits. Never on uncommitted changes. |
| Who reviews | An ephemeral ACP session with the resolved reviewer agent and model. Claude Code and Codex review in place in a read-only mode; other agents review in a throwaway checkout of the commit, deleted afterwards, so their edits never reach the worktree. |
| Who fixes | The owning session, through Auto-fix. Findings reach it as a shepherd prompt with a card. |
| How findings come back | The reviewer ends its turn with a JSON block. Alas parses it and files the findings itself, attributed to the reviewer. The reviewer does not call MCP tools. |
| Clean | Verdict `approve`, or `comment` with no open findings. |
| Push | Alas pushes the exact reviewed SHA through the existing publish path. It never forces. If HEAD moved during the review, the review restarts on the new HEAD. |
| Round cap | `maxReviewRounds` (default 3, range 1...10) reviews with findings per pending push. Reaching it stops and asks the user. |
| Prompt layers | Global prompt, `.alas/code-review.md`, project instructions, `.alas/code-review.local.md`, then a fixed Alas section. Layers add up. Shepherd rules keep their replace semantics. |
| Reviewer resolution | Per-ship choice, else project override, else global. Global defaults to "Same as the session" with the agent's default model. |
| Merge gate | With the lever on, Auto-merge also needs the PR head to be a clean or allowed SHA. Stacks don't auto-merge; "ready to land" gets the same condition. |
| Unreadable repo file | Fails closed: the review stops instead of running without the file, as shepherd rules do. |
| Default | Review before push is off. |

## User experience

### Ship popover, before shipping

The unbound popover in `ACPShepherdButton` (and its stack twin in
`ACPStackShepherdPopover`) gains:

- A step line led by a review symbol when the lever is on: "Codex reviews the
  commits here first. Nothing is pushed until the review is clean."
- A `ShepherdSwitchRow` titled "Review before push". Its detail line holds the
  reviewer menu ("Codex · gpt-5.2 ▾") and "up to 3 rounds". The switch and the
  menu start from the resolved defaults and apply to this ship only.

Ship with agent sends the existing create prompt. The choice travels with the
ship request so `pr_create` knows whether to gate (see "Data model").

### Ship popover, while reviewing

A ship whose push waits on a review has no PR yet. The pill shows a new
`reviewing` badge with the label "Reviewing". The popover lists the steps:

1. Committed `a1b2c3d`
2. Codex review, round 1: 2 findings (Open review)
3. This session is fixing them
4. Codex reviews the fix (round 2 of 3)
5. Push and open the PR

The footer has "Ship without review", which pushes HEAD as it is and records
it as allowed, and "Stop", which ends the review and leaves the branch
unpushed.

### Ship popover, shepherding

The bound popover keeps its layout. Below the open-threads line it shows the
review line for the current head, one of:

- "Codex is reviewing `4f5e6a7`…" (Open session)
- "Codex reviewed `4f5e6a7` before the push" (Open review)
- "Codex review: 2 findings on `4f5e6a7`, sent to this session" (Open review)
- "`9f8e7d6` reached GitHub without a review" (Allow)

A third switch row, "Review before push", sits above Auto-fix and Auto-merge,
with the reviewer menu in its detail line. It writes to the shepherd record
like the other two. The Changes review drawer (`ReviewShepherdBlock`) shows the
same row and line.

### Stops

Each stop sets the pill to `attention`, posts the usual shepherd notification
and pushes nothing until the user acts.

| Stop | Message | Actions |
| --- | --- | --- |
| Rounds spent | "3 review rounds spent, 1 finding still open. Nothing was pushed." | Open review, Ship anyway |
| Auto-fix off | "2 findings. Auto-fix is off, so nothing was pushed." | Open review, Send to session |
| Reviewer failed | "Review didn't finish: <reason>. Nothing was pushed." | Retry, Ship anyway |
| Unreadable file | "Couldn't read .alas/code-review.md: <reason>. Nothing was pushed." | Retry, Ship anyway |

Reasons for a failed reviewer: the agent isn't installed or enabled, it can't
attach (signed out, crashed), it can't run read-only, its review checkout
couldn't be made or the worktree is over SSH, the turn ended without a
parseable result, or it ran past the review timeout (20 minutes).

"Ship anyway" pushes HEAD, records it as allowed and continues as if the
review were clean.

### Settings › Changes

A new "Code review" group above "PR shepherd":

- **Reviewer.** "Agent and model that review shipped branches before Alas
  pushes them. A project can override it, and each ship can change it from the
  Ship button." Two menus: agent ("Same as the session" or any enabled ACP
  agent; those whose read-only mode Alas doesn't enforce read "reviews in a
  separate checkout") and model
  ("Agent default" or the models that agent last advertised, from
  `ACPAgentModelCatalog`).
- **Prompt.** "What every review looks for. Project instructions and
  .alas/code-review.md are added after it." Uses `promptEditorRow` and a new
  `CodeReviewPromptEditorWindow` on `PromptEditorBody`.

The "PR shepherd" group gains two rows:

- **Review before pushing.** "Review each push Ship makes with the reviewer
  above. Findings open in the review pane; with Auto-fix on they go back to the
  session that owns the branch. Each ship can change this from the Ship button
  or the review drawer."
- **Review rounds per push.** "Reviews with findings before the shepherd stops
  and asks for you." A stepper, 1 to 10.

The Auto-merge row's description adds "the current head passed its review" to
its list of conditions.

The agent and model menus are the compact menu that `RunScheduleEditorView`
keeps private as `ScheduleChipMenu`. It moves to a shared `AgentModelPicker`
used by both screens.

### Project Settings › Automation

A "Code review" block under "PR shepherd":

- **Reviewer.** "Use global setting · Codex gpt-5.2", or an agent and model.
  Same picker.
- **Instructions.** A multiline editor (`ProjectStartupScriptEditor`). Caption:
  "Added after the global prompt and .alas/code-review.md, for you alone."
- **Repo file status.** "✓ .alas/code-review.md found in the repo, added too",
  and the same for `.alas/code-review.local.md`. No line when neither exists.

### Review pane

Each review round opens a review session on a commit range pinned to the
reviewed SHA: `base...<sha>`, so later commits don't move the diff under the
findings. The header names the branch and "local, not pushed" until a push
contains the SHA.

A new verdict banner sits under the header in `ReviewSessionTabView`. It
renders `ReviewSessionRecord.verdict`, which is stored today but never shown on
the desktop:

- The verdict chip: "Approved", "Changes requested" or "Commented".
- The reviewer ("Codex · gpt-5.2"), the reviewed SHA, "round N of M" and the
  time.
- The summary as Markdown.
- Actions: a "Sent to <owner> session" status, "Review again", "Ship anyway"
  while the push still waits, and "Open reviewer session" while that session
  exists.

The banner shows for any session with a verdict, so `review_finish` from the
CLI gets it too. Finding cards and the findings rail are the existing ones.
Findings carry the reviewer's name as author, so cards read "Codex draft"
instead of "Agent draft".

### Owning session's transcript

Findings reach the owning session as a shepherd prompt with an
`ACPPromptCard` titled "Review before push · 2 findings": reviewer, round,
SHA, one item per finding with its location, and an Open review action. The
prompt tells the session to fix each finding, commit, resolve the finding with
`review_resolve`, and not push.

## Flow

### First push

1. Ship with agent sends the create prompt. The session commits and calls
   `pr_create(title, body, draft, base)`.
2. `createShepherdedPR` runs every check it runs today (branch, remote,
   provider, adoption). If the lever is on for this ship and HEAD is not a
   clean or allowed SHA, it stores a pending push (title, body, draft, base,
   HEAD) instead of pushing, starts round 1 and returns
   `{"status": "reviewing", ...}` (see "Agent contract"). An open PR adopted
   with nothing to push is bound, and with the lever on its head goes through
   the pushed-head review, so auto-merge waits until it passes.
3. Alas builds the review prompt and sends it to the reviewer session.
4. When the reviewer's turn ends, Alas parses its result and files findings
   and the verdict into the round's review session.
5. Clean: Alas resumes the publish path with the stored request on the
   reviewed SHA: push, open or adopt the PR, bind the shepherd. The bind prompt
   tells the owning session the PR is open.
6. Findings with Auto-fix on: Alas sends them to the owning session. When its
   turn ends with new commits, Alas starts the next round on the new HEAD. The
   session may also call `pr_create` again, which updates the stored title and
   body and starts the next round the same way. A turn that ends with no new
   commits counts as no progress, as fix turns do today.
7. Findings with Auto-fix off, or rounds spent: stop.

### Fixes after the PR is open

The shepherd's fix prompt changes from "Fix what's below, commit, and push" to
"Fix what's below and commit. Don't push: Alas reviews the commits and pushes
them." When the fix turn ends with local commits ahead of the PR's remote head
branch, the ship review for that session runs steps 3 to 7. A clean review
pushes through the same exact-SHA path `pr_create` uses, by re-entering
`pr_create`, which adopts the open PR.

While a review runs or its findings wait for the owner, the shepherd's
`awaitingPush` idle follow-up doesn't fire. Review findings and CI failures
share the existing fix-attempt budget per problem; the round cap is separate
and counts only reviews.

With the lever off, the fix prompt keeps today's wording and nothing changes.

### Stacks

`stack_ship` gates before `gg sync` the same way. The review covers
`base...<top of the entries the ship plan publishes>`. Findings name files and
lines in that range; the stack fix prompt already tells the session to fix
entries bottom-up with gg and publish with `stack_ship`, which now reviews
first. `stack_ship` already answers `in_progress` and reports the end as a new
turn, so a review only lengthens that.

Stacks never auto-merge. The "ready to land" state gains the same condition as
the merge gate: the top entry's head is a clean or allowed SHA.

### Heads pushed outside Alas

On each poll the shepherd compares the PR head with the record's clean and
allowed SHAs. A head that is neither, and that equals local HEAD, gets reviewed
like a fix: findings go to the owning session, a clean review clears it. A
head Alas can't review (not checked out locally) shows "reached GitHub without
a review" with Allow. Either way Auto-merge waits until the head is clean or
allowed.

## Reviewer

### Session

The reviewer is an ephemeral ACP session whose parent is the owning session,
built on the `/btw` side session machinery in `ACPSessionManager`:

- Created with the resolved agent, with the model staged through
  `pendingModel` as run schedules do.
- Any ACP agent can review. One whose read-only mode holds whatever the
  user's own rules allow (`ACPSideQuestionSupportPolicy.enforcesReadOnly`:
  Claude, Codex) reviews in place: it runs in the worktree, put in a
  read-only mode with `enterReadOnlyMode`, and an agent Alas can't move out
  of auto-approving modes fails the review with "<agent> can't run
  read-only".
- Any other agent reviews in a throwaway checkout of the reviewed commit
  (`ReviewScratchCheckouts`): a detached `git worktree add` under
  Application Support's `review-checkouts`, one per ship review, moved to
  each round's head with `checkout --force` and `clean -fdx` so nothing it
  wrote carries over. The session's cwd, terminals and file root are that
  checkout, never the user's worktree. It still tries a read-only mode but
  runs without one. Local worktrees only: on an SSH worktree it fails with
  "<agent> can't review an SSH worktree; pick Claude Code or Codex", and a
  checkout git can't make fails with "couldn't prepare a review checkout:
  <error>". The checkout is removed with the reviewer, and on launch Alas
  removes every checkout no pending review owns.
- Permission requests use a reviewer rule: allow `read`, `search` and
  `think`; reject everything else, `fetch` included. The reviewer never asks,
  so it can't stall an unattended ship.
- Not listed in the sidebar and separate from the `/btw` slot, so a side
  question can run at the same time.
- One per pending push, reused across its rounds so it remembers earlier
  findings. Discarded once that push completes or stops. "Open reviewer
  session" shows its transcript read-only while it exists.

One review runs per worktree at a time. The push after a clean review goes
through `serializedPublish`, so it never overlaps a `pr_create` or
`stack_ship` publish; a `pr_create` that arrives mid-review updates the
pending push instead of starting a second review.

### Prompt

`CodeReviewPromptBuilder` (pure, in AlasCore) joins, in order:

1. The global prompt (`AppConfig.changes.codeReview.prompt`).
2. `.alas/code-review.md` under "## Repository review instructions".
3. Project instructions under "## Project review instructions".
4. `.alas/code-review.local.md` under "## Your review instructions".
5. The Alas section: branch, base, reviewed SHA, the diff, earlier findings
   still open with their ids and the owner's replies, and the output format.

Empty layers are skipped. `CodeReviewInstructionsResolver` reads both files
through the loader `ShepherdRulesResolver` already uses, so SSH worktrees work
the same and a read failure throws.

Alas puts `git diff base...<sha>` in the prompt up to 200,000 characters. A
larger diff is included file by file until the cap. The prompt lists the
remaining paths and tells the reviewer to read them from the worktree, which
is at the reviewed SHA unless the owner committed since, in which case the
round restarts anyway.

The default global prompt asks for correctness bugs, regressions, missing
error handling, security problems and leftover debug code, one finding per
problem, each with a concrete fix, and no style nits the repo's linters
already catch.

### Result

The reviewer ends its turn with one fenced JSON block:

```json
{
  "verdict": "request_changes",
  "summary": "A leftover debug marker and a swallowed error in the reviewer launch.",
  "findings": [
    { "path": "Alas/Sources/App/AppState+Shepherd.swift", "line": 313,
      "end_line": 313, "body": "Leftover `// ponytail` marker. Keep the comment without the prefix." }
  ],
  "resolved": ["<id of an earlier finding that is now fixed>"]
}
```

`CodeReviewResultParser` (pure) takes the last JSON block in the final agent
message. Lines refer to the new side at the reviewed SHA. A finding whose line
falls outside the diff is filed as a file comment; one whose path isn't in the
diff is folded into the summary. A missing or malformed block fails the round
with "Review didn't finish: the reviewer returned no result" and does not count
toward the cap.

Alas files findings with `ReviewDraftCommentAuthor.agent(name:)` set to the
reviewer's display name and model, resolves the `resolved` ids in the earlier
round's session with the reviewer as resolver, and stores the verdict with
`markedReviewed`.

## Data model

| Type | Change |
| --- | --- |
| `AppConfig.Changes` | `codeReview: CodeReviewSettings` with `reviewer: ReviewerChoice` (`sameAsSession` or `agent(id, modelID?)`) and `prompt: String`. |
| `ShepherdDefaults` | `reviewBeforePush: Bool = false`, `maxReviewRounds: Int = 3`, clamped to `1...10`. |
| `ProjectConfig` | `codeReview: ProjectCodeReviewSettings?` with `reviewer: ReviewerChoice?` (nil inherits) and `instructions: String`. Cleared when empty, copied to linked projects like `shepherd`. |
| `ShepherdBadgeState` | New `reviewing`. |
| `ShepherdObservation` | `reviewGate: ShepherdReviewGate?` (passed SHAs, whether a review is running); nil when the lever is off. |
| `ShipReviewRecord` (new) | Keyed by worktree and owning session. Holds the lever, the per-ship reviewer, the pending push (PR request fields or stack plan), the phase (idle, reviewing, awaiting fix, pushing, stopped with a reason), rounds this push, the round history (SHA, review session id, verdict, open findings), `passedSHAs` (clean or allowed), an unreviewed remote head, and the reviewer session id. |

The shepherd records don't change. The lever and reviewer live only on the
`ShipReviewRecord`, which the shepherd finds by worktree and owning session, so
there is one source of truth before and after the PR exists.

`ShipReviewRecord`s persist to `ship-reviews.json` under Application Support
through `PersistenceStoreProtocol`, like `review-shepherds.json`. A record lives
from the first gated push until its shepherd record ends or the user stops it.
On relaunch, a round that was running restarts with a new reviewer session and
does not count toward the cap.

`ShepherdPolicy.headGatePasses` gains one condition: with the lever on, the
request head is in the record's `passedSHAs`. Stacks check the top open entry's
head the same way in `StackShepherdPolicy.isReady`.

The ship request that carries the popover's choice is the existing
`requestShepherdCreatePR` path. Alas stores the choice on a `ShipReviewRecord`
before it sends the create prompt, and `pr_create` from that session reads it.
A `pr_create` with no record uses the resolved defaults.

## Agent contract

- `pr_create` may return `{"status": "reviewing", "round": 1, "max_rounds": 3,
  "reviewer": "codex/gpt-5.2", "head_sha": "..."}`. The tool description and
  `alas skill guide review` say: Alas pushes and opens the PR once the review
  is clean; findings arrive as a new turn; never `git push` yourself.
- `stack_ship` keeps its `in_progress` reply; its status adds the same
  `review` object.
- `pr_status` adds `review: {state, round, max_rounds, reviewer, head_sha,
  open_findings}`, and `PRShepherdWireDTO.Shepherd` adds
  `review_before_push`.
- The fix prompt wording changes as described in "Fixes after the PR is open".

## Testing

Following the repo's testing policy, tests cover pure decision logic and one
integration path:

- `CodeReviewPromptBuilder`: layer order, skipped empty layers, diff cap and
  the omitted-files list. Parameterized over layer combinations.
- `CodeReviewInstructionsResolver`: an unreadable file throws. Added to the
  existing shepherd rules suite.
- `CodeReviewResultParser`: last block wins, fenced and bare JSON, malformed
  input, out-of-diff lines become file comments, unknown paths fold into the
  summary.
- Ship review policy: clean pushes; findings with Auto-fix on go to the owner;
  Auto-fix off stops; the cap stops; HEAD moving mid-review restarts without
  counting; a failed round doesn't count.
- `ShepherdPolicyTests`: the merge gate with clean, allowed and unreviewed
  heads, parameterized; the `awaitingPush` idle follow-up waits while reviewing.
- `ShipReviewer` with fake effects: a clean review pushes the reviewed SHA,
  findings reach the owner and the next commit starts round two, an
  unavailable reviewer or unreadable instructions stop without pushing, and a
  relaunch restarts a running round once. No `pr_create` test harness exists
  (it needs a code host), so the gate is covered at this layer.

## Documentation

- README: a "Code review" subsection under "Repo-local configuration"
  describing `.alas/code-review.md`, `.alas/code-review.local.md` and how they
  stack with the global and project prompts.
- `AlasCLI/crates/alas/src/skills/review.md` and the `pr_create` and
  `stack_ship` tool descriptions in `mcp.rs`: the `reviewing` reply and the
  no-`git push` rule.
