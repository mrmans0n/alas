# Stash, commit actions and checkpoints on a paired host's worktrees — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. The Mac can already stage, commit, push, pull and review a host worktree. It can't stash, cherry-pick, revert, edit a commit, or use checkpoints. Locally these are everyday safety nets, especially around agents. This design brings them to host worktrees, with the host running git, as it already does for the other git actions.

## Current state (from recon, origin/main 0d9503575)

- **Host git.**
  - `HostWorktreeChange` has stage, unstage, discard, commit (with amend), push, pull and fetch. It's served headless-only through `AlasCoreContext+WorktreeGit.swift` `mutateListedWorktree`, under `ProjectMutationGate`.
  - Before acting, that checks that the listed branch is HEAD, the lifecycle is idle, there's no checkpoint recovery pending, and pathspecs are literal.
  - `apply` refuses commit, push and pull while `git.mergeState != nil`, with "A rebase, merge, cherry-pick or revert is in progress on the host; finish it there first."
  - The Mac sends the changes through `NativePeerHosts.mutate` (120 s timeout) and `NativePeerRightPaneView.runGit`.
- **Stash** is all in AlasPlatform `GitService+Stash.swift`:
  - list, push(message, includeUntracked), files, diff, apply, pop and drop;
  - apply, pop and drop verify ref plus sha.
  - Locally: a "Stash Changes…" sheet, Apply/Pop/Drop… on each row (Drop confirmed), and a stash diff tab. The list is the repo-wide `refs/stash`.
- **Cherry-pick and revert** are in `GitService`:
  - They return `MergeResult .clean/.conflict(files)/.error`, with `continueOperation`, `abortOperation` and `skipOperation`, and conflict resolution through `useOurs`, `useTheirs` and `markResolved`.
  - `mergeState` reads the in-progress operation (`MergeOperation`).
  - Locally: both are confirmed, and conflicts show the `OperationCard` (Continue/Skip/Abort) and the `ConflictsSection`.
- **Edit commit** is `GitService.editCommit(worktreePath:baseRef:targetSha:action:)`, with actions reword, drop file and drop hunk.
  - It replays from a backup branch with `reset --hard` and restores the backup on failure.
  - It needs a clean tree and no operation in progress. Locally it's a center editor tab.
- **Checkpoints**:
  - Manifests and blobs live in `WorktreeCheckpointStore` (AlasFeatures), and restore is a journaled transaction (AlasFeatures).
  - The orchestrating `WorktreeCheckpointService` is in the app target. It creates manual and automatic checkpoints, previews, diffs, restores, recovers and deletes.
  - The app takes an automatic checkpoint before each agent prompt. The host takes none; it only reads pending recovery journals to refuse git mutations.
  - Restore is refused while sessions or terminals are active, among other blockers (`CheckpointRestoreBlocker`).
- **Peer today.**
  - The changes view has no stash, operation or conflicts section.
  - Conflict kinds are decoded per file but never acted on.
  - The wire has no "operation in progress" field.
  - The only peer confirm is the one for discard.

## Goals

1. **Stash.**
   - From the Mac, stash a host worktree's changes, with a message and include-untracked as locally.
   - List the stashes, open a stash's files and diffs, and apply, pop or drop one. Drop is confirmed as locally.
   - An apply or pop that conflicts leaves the conflicted files visible and resolvable (Goal 3).
2. **Cherry-pick and revert.**
   - From a commit row on the Mac, cherry-pick or revert a commit onto the host worktree, with the same confirmations as locally.
3. **Operations and conflicts.**
   - When a cherry-pick, revert, merge or rebase is in progress on the host, the Mac shows it, as the local `OperationCard` does, with Continue, Skip and Abort.
   - Conflicted files show in a conflicts section with Use ours, Use theirs and Mark resolved.
   - Commit, push and pull stay refused during an operation, as today. The Mac now shows why and offers the way out.
4. **Edit commit.**
   - From a commit row on the Mac, reword a commit, or drop a file or a hunk from it, with the same refusals as locally: dirty tree, operation in progress, merge commit.
   - The Mac uses the existing local editor tab, fed from host reads.
5. **Checkpoints.**
   - The Mac lists a host worktree's checkpoints. It can create one with a label, open its diff, delete one (confirmed) and restore selected groups through the same preview sheet.
   - Restore is refused for the same reasons as locally, computed on the host: active sessions and terminals there, an operation in progress, HEAD changed, and so on.
   - The host also takes an automatic checkpoint before each agent prompt, as the app does. That safety net then exists on a headless host too, and it's what makes restore worth having.
6. **Capability-gated and compatible.**
   - New headless-only capabilities gate the new reads and changes. Older Macs and hosts are unaffected.
   - Each piece hides on the Mac when the host doesn't serve it.

## Non-goals

- Merge and rebase started from the Mac (the "Merge branch into…" and "Rebase onto…" menu items). Goal 3 only handles an operation that's already in progress, whoever started it.
- The merge-conflict center tab with the agent proposal (`MergeAgent`). The Mac resolves a file with ours/theirs/mark resolved; editing conflict markers waits for host file editing, which is a later phase.
- Hunk staging and partial stash.
- File History. It's a separate read and could follow alongside.

## Anti-goals

- **No agent's uncommitted work lost to a Mac action** beyond what the same action risks locally. Locally, stash, cherry-pick, revert and edit don't block on running agents; only restore does. Mirror exactly that, and don't add new silent destruction.
- **No change to local behaviour or storage.**
- **No git command built from a Mac string.** The Mac names stash refs plus shas, commit shas, paths and checkpoint ids. The host validates each one (sha shape, ref resolves to sha, path literal and inside the worktree, checkpoint belongs to the worktree's lineage) before git sees it.
- **No operation the Mac starts leaves the worktree in a state the Mac can't see or leave.** That's why Goal 3 ships with or before Goal 2.

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - git stays real in tests: build only the repo the assertions need, and reuse template repos;
  - no UI imports in core; public cross-module types Sendable;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is its first build. Keep `Alas/` edits close to the existing local UI, and reuse local views where they take plain data.
- Every new host change goes through `mutateListedWorktree`, keeping its gate and refusals. Every new read goes through `HostWorktreeRead`'s existing per-worktree path.

## Decisions (my calls)

- **PRs, in order** (checkpoints split in two below):
  1. stash;
  2. operations and conflicts, then cherry-pick and revert;
  3. edit commit;
  4. checkpoints.

  Operations come before cherry-pick and revert, because a conflicting pick otherwise strands the user.
- **The changes reply carries the operation.** `changeList` gains an optional in-progress operation (kind plus the target commit's sha and summary), so the Mac shows the card without a separate read. Older hosts omit it.
- **Checkpoint orchestration moves into core.** The UI-free part of `WorktreeCheckpointService` (create, preview, diff, restore, recover, delete, the blockers) moves into AlasFeatures, and the app and the host share it, as was done for provider publishing. The host computes the coordination snapshot from its own sessions and terminals.
- **The host's automatic checkpoint** uses the same trigger point and limits as the app: 50 automatic, oldest pruned.
- **Confirmations mirror local:**
  - Drop, revert, cherry-pick and checkpoint delete are confirmed.
  - Restore uses the preview sheet and takes a recovery checkpoint first.
  - Apply, pop and edit-commit save aren't confirmed.
- **The repo-wide stash list,** as locally. Other worktrees' stashes show too, and the ref-plus-sha check limits any action to the entry the user saw.

## Decisions from the builder check (my calls)

- **A rebase in progress passes the gate for the way out only.**
  - `mutateListedWorktree` refuses unless git's current branch equals the listed one, and a rebase detaches HEAD, so today Continue, Skip and Abort would be refused.
  - The gate accepts the listed branch when a rebase in progress names it as the branch being rebased (`rebase-merge/head-name` or `rebase-apply/head-name`). This applies only to the operation and conflict changes: continue, skip, abort, use ours, use theirs, mark resolved. Every other change keeps today's refusal.
  - Cherry-pick, revert and merge don't detach HEAD, so they need no exception.
- **Checkpoints split into two PRs.**
  - First a refactor PR: the UI-free part of `WorktreeCheckpointService` moves into AlasFeatures, and the app's callers switch to it with local behaviour identical. The app's own checkpoint tests are the safety net on CI.
  - Then the host wiring PR: automatic checkpoints on the host, plus the Mac's list, create, diff, delete and restore.
  - That makes five PRs in all.
- **Host prompts' checkpoints are restorable from the Mac's transcript.**
  - Locally, a prompt's automatic checkpoint is attached to its user message and offers "Restore files to before this request".
  - Once the host takes automatic checkpoints, the Mac's peer transcript shows that action for host sessions, and it opens the host restore preview for that checkpoint.
  - It's part of the host wiring PR. It only appears when the host serves checkpoints.

## Left to the builder

- Exact request, reply and capability names. Whether stash and checkpoint reads are new `HostWorktreeRead` cases or their own requests.
- The wire shapes for stash entries, checkpoint summaries and the restore preview.
- How the editor tab gets its commit data on the Mac: the existing commit reads plus raw subject and body.
- How the Mac's diff tabs for stash and checkpoint reuse the peer diff reading.
- The exact split inside each PR into tasks.
