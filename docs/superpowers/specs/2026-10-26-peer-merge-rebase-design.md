# Merging and rebasing a paired host's worktree from the Mac — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. Everything after the start of a merge or rebase already works on a host worktree from the Mac:
- the operation card with Continue, Skip and Abort;
- the conflicts section with Use ours, Use theirs, Keep deleted and Mark resolved;
- since #2236, editing a file on the host.

What's missing is the start. Locally, the Commits header's branch menu offers "Merge branch into this worktree…" and "Rebase this worktree onto…". The host worktree's menu offers only Commit, Create Checkpoint and Fetch now. Bringing a host branch up to date with `main`, or merging a feature into it, means leaving the Mac.

This design adds the start, plus one gap that becomes obvious once conflicts arise: a conflicted row on a host worktree opens a read-only diff, so its markers can't be edited.

## Current state (from recon, origin/main 4bf381510)

- **Local start.**
  - `BranchOpsMenu` offers Merge… and Rebase…. Each opens a single-select `BranchPicker` fed by `GitService.branches(at:)`, which lists local and remote-tracking branches.
  - `GitService.merge(worktreePath:branch:)` runs `git merge <b> --no-edit`; `rebase(worktreePath:onto:)` runs a plain `git rebase <onto>`. Both use zdiff3.
  - There are no options: no ff-only, squash, autostash or `-i`. There's no confirmation and no automatic checkpoint.
  - A `.conflict` result opens the first conflicted file. A `.error` result (a dirty tree, an unknown ref) is only logged.
- **Host.**
  - `HostRequest.mutateWorktree(worktree:branch:change:)` with `HostWorktreeChange` already covers stash, operations (continue, skip, abort), conflict resolution, cherry-pick, revert, edit commit and checkpoints.
  - These run through `mutateListedWorktree`, which applies the mutation gate, branch revalidation (with the mid-rebase exception), idle and checkpoint-recovery checks.
  - `apply` refuses commit, push, pull, cherry-pick and revert while an operation is in progress. `throwIfFailed(MergeResult)` turns `.error` into a refusal, and leaves `.conflict` to the next changes read, which carries `operation` (including the rebase plan).
  - **No merge or rebase case exists.** The git-ops design listed them as a non-goal.
- **Branches.**
  - The Mac can already read a project's branch list (`branchList`, `GitService.branches` at the project path), as the peer new-session sheet does.
  - A worktree shares its repository's refs, so that list is the same one the local picker shows.
- **Mac.**
  - The host worktree's header menu is in `NativePeerRightPaneView`. `runGit` sends a change and shows a refusal in the rail's error strip.
  - `NativePeerChangesView` reuses `OperationCard` and `ConflictsSection`. A conflicted row opens `.diff(path, .unstaged)`, which is read-only.

## Goals

1. **Merge… and Rebase… on a host worktree.**
   - The host worktree's branch menu gets "Merge branch into this worktree…" and "Rebase this worktree onto…".
   - Each opens the same branch picker as local, listing the host repository's branches (local and remote-tracking), with the worktree's own branch left out.
   - Choosing a branch starts the operation on the host.
2. **The outcome shows as it does locally.**
   - A clean merge or rebase refreshes the rail.
   - A conflicted one shows the operation card and the conflicts section, through the existing changes read.
   - A refused one shows git's message in the rail's error strip. This covers a dirty tree, an operation already in progress, or a branch that no longer exists.
3. **Conflicted host files open editable.**
   - When the host serves file editing, selecting a conflicted row opens the file in the editor, markers included, instead of the read-only diff.
   - The user edits, saves, then uses Mark resolved and Continue, all of which already exist.
4. **Gated like other host git changes.**
   - The usual refusals apply: the project gate, the listed branch (no merge or rebase on a stale listing), idle, pending checkpoint recovery, and the checkpoint-restore hold.
   - Starting is refused while a merge, rebase, cherry-pick or revert is already in progress.
5. **Capability-gated and compatible.**
   - A new headless-only capability gates the two new changes.
   - Older hosts keep today's menu, and older Macs are unaffected.

## Non-goals

- Options beyond local's: ff-only, squash, `--no-ff`, autostash, interactive rebase. Local has none.
- A three-way merge view, marker navigation or the merge agent for host files. Locally these live in the MergeConflict tab. For hosts, the plain editor with markers is the parity floor for now.
- An automatic checkpoint before a merge or rebase. Local takes none.
- Fetching before merging. "Fetch now" already exists in the same menu.

## Anti-goals

- **No git command built from a Mac string.** The host resolves the chosen branch against its own branch list, as it does for stashes and commits, and refuses anything else.
- **No change to local merge, rebase or conflict behaviour.**
- **No merge or rebase on a worktree whose HEAD no longer matches the listing.**

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - git stays real in tests (template repos);
  - no UI imports in core; public cross-module types Sendable;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is its first build. Split long SwiftUI chains, avoid name collisions, and no shadowing `if let`.
- The host already runs git with prompts disabled, so merge and rebase need no extra headless handling.
  - Merge passes `--no-edit`.
  - A plain rebase opens no editor.
  - Continue and skip already set `core.editor=true`.

## Decisions (my calls)

- **Two new `HostWorktreeChange` cases**, `merge(branch:)` and `rebase(onto:)`, under a new headless-only capability.
  - A new capability, not `host.worktrees.operations.v1`, because an older host serving operations would fail to decode the new cases.
  - The host:
    - checks that no operation is in progress;
    - resolves the name against `GitService.branches` for the worktree;
    - refuses the worktree's own branch;
    - runs the existing `GitService.merge` or `rebase`.

    `.clean` and `.conflict` both return normally, and `.error` becomes a refusal carrying git's message.
- **The picker reuses the project-level branch list** the Mac already reads, rather than a new worktree read. The refs are the same, and the host validates the choice anyway.
- **No confirmation.** Picking a branch and pressing Merge or Rebase is the confirmation locally too, and Abort undoes a conflicted start.
- **Conflict rows open the file only when the host serves file editing.** Otherwise the read-only diff stays.
- **One PR.** The host part is small: two cases, one capability, a handler branch and a test. The Mac part reuses the picker and `runGit`.

## Left to the builder

- Exact names of the capability and cases.
- Whether the picker filters out the current branch on the Mac, the host, or both. The host must refuse it regardless.
- How a long rebase interacts with git's per-call timeout on the host. Match what the host's cherry-pick does.
