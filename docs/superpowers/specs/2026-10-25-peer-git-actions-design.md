# Git actions on a paired host's worktrees — design

## Intent

A Mac paired with a headless `alas-host` (the Mac mini) can see a host worktree's Changes, Files and diffs, but it can't act on them. The rail is read-only: `NativePeerRightPaneView` passes `readOnly: true`, and the peer protocol has no git write endpoints. Committing or pushing an agent's work on the mini means asking the agent or opening a host shell. The user wants parity with local worktrees wherever possible. This design brings the everyday git actions of the local Changes tab to host worktrees, executed on the host.

## Current state (from recon, origin/main)

- **Local Changes actions.** Each goes through `RightPaneState` (app) onto `GitService` (core, `Packages/AlasCore/Sources/AlasPlatform/Git/`, UI-free):
  - stage/unstage files (`GitService+Staging`);
  - discard files/folders/all (`GitService+Discard`, behind a client-side confirmation);
  - commit/amend (`commit(subject:body:amend:)`) from the Draft Commit tab;
  - pull with rebase (`GitService+Pull`);
  - fetch (`fetchRef`);
  - push and force-with-lease, from the review pill, built from `reviewLoopPushArguments` on `RightPaneState` and run with `Process.git`;
  - stash, ignore, merge/rebase onto, cherry-pick, revert, conflict continue/skip/abort;
  - hunk staging, in the diff tab;
  - commit & publish, via `CommitPublishWorkflow`.
- **The draft commit message.** It is suggested on-device (Apple Intelligence or MLX) from plain git output (`CommitMessageSuggestionInput.load`). The Commit Editor's "Generate" uses an ACP agent.
- **What the host already serves.** It serves reads through `HostRequest.readWorktree(worktree:read:)` (`host.worktrees.read.v1`), which covers changes, file diffs, files, commit files and commit diffs. The peer refreshes on host snapshot changes and on the refresh button.
- **The established mutation pattern.**
  - Example: `renameBranch(worktree:from:to:)`.
  - Gating: a dedicated `HostProtocolCapability` added to `served`.
  - Lookup: the server resolves the listed worktree and refuses hidden ones.
  - Concurrency: it runs under `ProjectMutationGate` and revalidates the branch the client saw, failing with "The worktree changed since it was listed.".
  - Client: `NativePeerHosts.canX`/`x`, which maps failures to a message.
- **Git on the host.** Git runs with inherited stdin and no `GIT_TERMINAL_PROMPT=0`. Under launchd, a push that needs credentials fails rather than prompts. Every git call has a 30 s default timeout, which also applies locally.

## Goals

1. **Stage, unstage and discard files** from the peer Changes rail, for one file, a folder or everything, with the same entry points and context menus as local.
   - Discard keeps the local confirmation alert, shown on the Mac.
   - Renames stage and unstage both paths, as locally (`unstagePaths`/`discardPaths` helpers).
2. **Commit and amend** from the peer pane: a commit sheet with subject, body and an Amend toggle.
   - The **suggested commit message** is generated on the Mac, by the same on-device suggester the Draft Commit tab uses, from git output the host returns. The headless host needs no model.
3. **Push, pull and fetch** for the worktree's branch, from the same places the local pane offers them:
   - push from the PR/review pill, including force-with-lease where local offers it;
   - pull (rebase) from the behind chip;
   - fetch from the branch menu.
   - A pull that stops on conflicts reports a clear message ("Pull stopped on conflicts; resolve them on the host"). Conflict resolution is not in this step.
4. **Executed on the host, safely.**
   - **Validation:** every action resolves the listed worktree, refuses hidden or archived ones, and revalidates the branch the Mac saw ("The worktree changed since it was listed.").
   - **Serialization:** actions run under the project mutation gate, and are refused during a checkpoint restore or pending recovery, like local actions.
   - **Never prompts:** git runs with `GIT_TERMINAL_PROMPT=0` and an SSH `BatchMode=yes`, so a push needing credentials fails with git's message instead of hanging.
   - **After a mutation:** the Mac reloads the worktree's changes.
5. **Capability-gated.** The host advertises a new capability (e.g. `host.worktrees.git.v1`). Without it, the Mac keeps today's read-only rail. Older Macs never send the new request.
6. **Errors** show where local shows them: the rail's inline error strip, and the commit sheet's error line.

## Non-goals (this step)

- Hunk and line staging. This needs parsed hunks on the wire.
- Commit & publish (commit, push and create a PR in one go). Host agents' `pr_create` already works on the host. A peer "publish" can follow once the shepherd PR flow has a peer surface.
- Stash, ignore, merge/rebase onto, cherry-pick, revert, and conflict continue/skip/abort. They fit the same request shape and can follow, but conflicts need their own UI.
- The Commit Editor's agent-based "Generate".
- Credential setup on the host. If the host's git can't push, the user fixes it there; the error says so.

## Anti-goals

- No behaviour change for local worktrees.
- The host never prompts and never blocks on stdin.
- A Mac never mutates a worktree whose branch changed since it last listed it.
- No regression for older hosts or Macs.

## Constraints

- AGENTS.md:
  - Swift Testing;
  - testing policy: test the host handler's validation and refusals, path expansion for renames, and the action-to-git mapping, with real git via template repos; don't test view wiring;
  - no UI imports in core;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is the first build. Keep app edits small: reuse the existing Changes views by turning off `readOnly` and passing closures. The commit sheet is one small new view.
- `reviewLoopPushArguments` moves from `RightPaneState` into core so the host builds the same push. The app keeps using it.

## Decisions (my calls)

- **One request with an enum of changes.** Use `mutateWorktree(worktree:branch:change:)` with `HostWorktreeChange` (`stage`, `unstage`, `discard`, `commit(subject:body:amend:)`, `push(forceWithLease:)`, `pull`, `fetch`) behind one capability. Later actions add cases under a new capability flag.
- **The suggestion input is a new read.** A new `HostWorktreeRead` case returns the commit-message suggestion input, and the Mac runs its local suggester on it. It is gated by the same new capability.
- **Discard is confirmed on the Mac.** The host trusts the request, like the other peer mutations.

## Sync state and the review pill (user's decision: full parity)

The peer pane gets the same push/pull surface as local, driven by the same state:

- **The host sends the branch's sync and review state for a followed worktree.** This is the data behind the local review pill and the behind chip: the `ReviewLoopSnapshot` / review-readiness inputs, ahead/behind, upstream, diverged, and push state. It travels as a capability-gated read and/or `HostEvent`, kept live while the Mac follows the worktree, like the existing review-status follow.
- **The peer pane shows the local review pill and the behind chip.** Both are driven by that state, so Push, Force Push (with lease) and Pull appear exactly when they would locally, and their actions map to the new mutations. The branch menu's Fetch is offered as locally.
- **The model is shared.** The pill's decision logic (`ReviewReadinessModel`, `pushState`) is reused or moved to core, not re-implemented, so the local and peer pills can't drift.

## Decisions from the builder check (my calls)

- **Only the headless host serves it.** The new capability goes on a headless-only served list. It is not in the shared `HostProtocolCapability.served` that app hosts also advertise.
  - Why: on a Mac running the app, local git actions are serialized by `RightPaneState` state (`stageMutationWorker`, `pullInFlight`, `discardOperationInFlight` and others) that a core handler can't see.
  - So a Mac paired with another Mac running the app keeps a read-only rail.
  - Cost if wrong: app-host coordination later.
- **The checkpoint rule matches local.** A peer action is refused while a checkpoint restore is in flight, or while one is pending recovery. The host's existing `hasPendingCheckpointRecovery` check already does this for delete. No writer lease is taken.
- **No agent-turn guard.** A live agent session in the worktree, even mid-turn, does not block an action, just as local doesn't.

## Left to the builder

- Exact names, and where the host handler lives (e.g. `AlasCoreContext+RemoteGit.swift`).
- How the commit sheet is presented in the peer pane (sheet vs inline), as long as it mirrors the local commit fields.
- How the sync/review state is carried: a read, an event, or both, extending the existing review-status follow.
