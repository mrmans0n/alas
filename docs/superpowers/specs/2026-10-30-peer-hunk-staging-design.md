# Staging and discarding hunks in a paired host's worktree from the Mac — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. Locally, a file's unstaged diff has "Stage hunk" and "Discard hunk" buttons on each hunk header, so an agent's change can be committed piece by piece or partly thrown away. On a host worktree, the same diff shows no hunk actions; only whole files can be staged, unstaged or discarded.

The user asked for this phase to run unattended, so the calls below are mine.

## Current state (from recon, origin/main 4b4d3e14f)

- **Local.**
  - Hunk-level only; there is no line staging anywhere.
  - `HunkPatchBuilder.patch(file:hunk:tracked:untrackedMode:)` (pure, tested) rebuilds a one-hunk patch from the parsed hunk. `DiffTabView` applies it:
    - stage: `git apply --cached`;
    - discard: `git apply --reverse`, after a confirm alert.
  - `GitService.unstageHunk` (`git apply --cached --reverse`) is used by the draft commit review.
  - Git's context matching is the validator. Discard is hidden for untracked files and for deleted tracked files.
- **Host.**
  - `HostWorktreeChange` stages, unstages and discards whole paths through `mutateListedWorktree` (gate, listed branch, idle, checkpoint checks, literal pathspecs).
  - `editCommit(.dropHunk(path:index:header:))` already names a hunk safely. The host re-diffs, applies the same truncation the Mac saw, checks the index and header, and builds the patch from its own hunk.
- **The Mac's peer diff view** renders the shared `DiffPaneView` with an empty `DiffPaneHunkActions()`, so no buttons appear. Hunks arrive as `RemoteDiffHunk` from `.fileDiff(path, stage, comparisonMode)`.

## Goals

1. **Stage and discard a hunk of a host file's unstaged diff,** with local's header buttons and local's discard confirmation.
2. **Unstage a hunk of a host file's staged diff.** Local offers this in the draft commit review; on the Mac's host view the staged diff is the only place to do it.
3. **Never apply a hunk the user didn't see.** The Mac names the hunk; the host rebuilds the patch from its own fresh diff and refuses it if the hunk changed since it was shown. The user gets "The file changed since it was shown. Refresh and try again." and the diff reloads.
4. **The diff and Changes refresh after each action,** as they do after other host git actions.
5. **Gated like other host git changes.** The same refusals apply: project gate, listed branch, idle worktree, checkpoint recovery and restore hold.
6. **Capability-gated and compatible.**
   - A new headless-only capability gates the change.
   - Older hosts show no hunk buttons.
   - Older Macs are unaffected.

## Non-goals

- Line-level staging. Local has none.
- Discarding a staged hunk. Local has none.
- Hunk actions on branch-comparison, commit, stash or checkpoint diffs.
- Hunks past the truncation cap. They are never offered.

## Anti-goals

- **No patch text from the Mac.** The host builds every patch from its own diff.
- **No silent apply of a different hunk.** The Mac sends the header and a hash of the hunk's lines as it saw them. The host refuses unless its hunk at that index matches both. Git's context check is the second line of defence.
- **No change to local hunk staging.**

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - git stays real in tests (template repos);
  - no UI imports in core; public cross-module types Sendable;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is its first build.

## Decisions (my calls)

- **One new change: `HostWorktreeChange.hunk(path:stage:index:header:linesHash:action:)`.**
  - `stage` is unstaged or staged; `action` is stage, unstage or discard.
  - It sits under a new headless-only capability.
  - The action must fit the stage: stage and discard need unstaged, unstage needs staged.
- **The host's check mirrors `dropHunk`.**
  1. `refuseOutside`.
  2. Re-run the diff `remoteFileDiff` runs for that stage, including rename identity, and apply the same truncation.
  3. The index must be among the hunks the Mac was shown, with an equal header and an equal lines hash.
  4. Refuse conflicted, binary and empty diffs. Refuse discard of untracked or deleted tracked files.
  5. Build the patch with `HunkPatchBuilder`, probing an untracked file's mode on the host. `fileMode(at:)` moves from `DiffTabView` into the core package.
  6. `git apply --cached`, `--cached --reverse` or `--reverse`. A git failure answers the "changed since it was shown" refusal.
- **The lines hash is SHA-256 over the hunk's lines as the wire carries them,** computed by one shared function on both ends.
- **The Mac passes hunk actions into `NativePeerDocumentView`** from where `client` and `hosts` are in scope.
  - The unstaged document gets stage and discard (discard confirmed as locally).
  - The staged document gets unstage, through a new `unstage` slot on `DiffPaneHunkActions` that the header renders as local's buttons do.
  - Buttons are disabled while a change is in flight. A refusal shows in the document's note area, and the workspace reloads.
- **One PR.** The host change and the Mac wiring are both small.

## Left to the builder

- Exact names of the capability, cases and hash function.
- Where the shared lines hash lives (core, used by both ends).
- The unstage button's icon and help text: follow the draft commit review's unstage hunk.
