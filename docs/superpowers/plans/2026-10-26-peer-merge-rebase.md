# Peer merge and rebase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start a merge or rebase on a paired headless host's worktree from the Mac, and edit its conflicted files there.

**Architecture:** Two new `HostWorktreeChange` cases under a new headless-only capability, handled in `AlasCoreContext.apply` with the existing `GitService.merge`/`rebase`. The Mac adds two items to the host worktree's branch menu, using the local `BranchPicker` over the project branch list it already reads, and sends them through `runGit`. Conflicted rows open the host file when the host serves file editing.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, AlasCore SwiftPM package.

**Spec:** docs/superpowers/specs/2026-10-26-peer-merge-rebase-design.md

## Global Constraints

- Swift Testing only. Keep tests minimal and sharp per AGENTS.md. Git stays real (template repos).
- No xcodebuild locally: the app's first build is CI. `swift test --package-path Packages/AlasCore` is fine.
- Split long SwiftUI modifier chains. Avoid name collisions and `if let` shadowing.
- Conventional Commits, no attribution trailers.
- No git command is built from a Mac string: the branch must be in the host's `GitService.branches` list for the worktree.

## Review Focus

1. **Merging the worktree's own branch, or a name not in the list** (`main; rm -rf`, `--abort`, `HEAD~1`). The host refuses it and runs no git. Tested by Task 1.
2. **Starting while a cherry-pick, revert, merge or rebase is in progress.** It is refused with the existing "in progress" message. Tested by Task 1.
3. **A dirty tree git refuses to merge over.** git's message reaches the Mac as a refusal and is not swallowed. Tested by Task 1 (`.error` → `HostError.failed`).
4. **A conflicting rebase.** It returns `.done`, and the next changes read shows the rebase operation, so the existing card appears. Tested by Task 1.
5. **A host without the new capability.** The Mac menu doesn't show the items. Not unit-tested (view gating). The reviewer checks it.

---

### Task 1: Host merges and rebases a listed worktree

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift` (`HostWorktreeChange`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift` (`HostProtocolCapability`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeGit.swift` (`apply`, and the exhaustive switches in that file)
- Test: extend the existing host suite that covers `cherryPick` through `mutateWorktree` (in `Packages/AlasCore/Tests/AlasCoreTests/`, `HostProtocolServerTests.swift` or the git-ops suite it lives in)

**Interfaces:**
- Produces:
  - `case merge(branch: String)` and `case rebase(onto: String)` on `HostWorktreeChange`.
  - `HostProtocolCapability.worktreesIntegrateV1 = "host.worktrees.integrate.v1"`, added to `headlessOnly` and advertised wherever the other headless capabilities are.
  - `capability` maps both new cases to it. `leavesAnOperation` stays false for both.

- [ ] **Step 1: Write the failing test** `aMacMergesAndRebasesAListedWorktree`. Use the suite's template-repo helper with a worktree on `feature` and a `main` that diverges. Assert, in order:
  - `.merge(branch: "feature")` (its own branch) is refused, and so are `.rebase(onto: "--abort")` and `.merge(branch: "nope")`.
  - With a dirty tracked file that `main` changes, `.merge(branch: "main")` is refused, the refusal message is non-empty, and HEAD is unchanged.
  - After cleaning, `.rebase(onto: "main")` with a conflicting change answers `.done`, and the worktree's `mergeState` is a rebase.
  - While it's in progress, `.merge(branch: "main")` is refused with "A rebase, merge, cherry-pick or revert is in progress; finish or abort it first."
  - After `.abortOperation(kind: .rebase)`, a non-conflicting `.merge(branch: "main")` answers `.done` and HEAD has `main`'s commit as an ancestor.
- [ ] **Step 2: Run it.** `swift test --package-path Packages/AlasCore --filter aMacMergesAndRebasesAListedWorktree`. Expected: it fails to compile, because the cases don't exist yet.
- [ ] **Step 3: Implement.**
  - Add the cases and the capability.
  - In `apply`, add both to the "refuse while in progress" group.
  - Add a `listedBranch(_:of:)` helper beside `verifiedCommit`/`listedStash`. It returns the name only if it's in `GitService().branches(at: root)` and isn't the worktree's current branch; otherwise it throws `HostError.failed(message: "<name> isn't a branch of this repository.")`, or "A worktree can't merge or rebase onto its own branch." for its own branch.
  - Then call `try Self.throwIfFailed(await git.merge(worktreePath: root, branch:))` and `rebase(worktreePath:onto:)`.
  - After a rebase that finished cleanly, re-sync the worktree's branch name the same way the continue/abort path does. Share that code rather than copying it.
- [ ] **Step 4: Run it, plus the whole core suite.** `swift test --package-path Packages/AlasCore`. Expected: everything passes.
- [ ] **Step 5: Commit.** `feat(alas-host): merge and rebase a listed worktree for a paired Mac`

### Task 2: Mac starts merge and rebase, and edits conflicted host files

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift` (a `servesIntegrate(serverId:)` beside `servesOperations`)
- Modify: `Alas/Sources/Right/NativePeerRightPaneView.swift` (header branch menu at ~:272, picker popover state, `runGit`)
- Modify: `Alas/Sources/Right/NativePeerChangesView.swift` (the conflicts `onSelect` at ~:88)
- Read for reuse: `Alas/Sources/Right/BranchOpsMenu.swift` (`BranchPicker`, its copy) and `Alas/Sources/Remote/Native/NativePeerNewSession.swift` (how the project `branchList` is fetched)

**Interfaces:**
- Consumes: Task 1's cases and capability.

- [ ] **Step 1: Menu items.**
  - When `servesIntegrate` is true for the selected host worktree (the `gitTarget`), the header menu gets "Merge branch into this worktree…" and "Rebase this worktree onto…", with local's exact copy.
  - Each opens a popover with `BranchPicker`, listing the project's branches from the existing `branchList` read minus the worktree's branch, and with local's Merge/Rebase button.
  - Confirming sends `.merge(branch:)` or `.rebase(onto:)` through `runGit`, which already shows a refusal in `gitError` and reloads.
  - No confirmation step.
- [ ] **Step 2: Conflicted rows open the file.** In `NativePeerChangesView`, when the host serves file editing (`client.hostFileTarget != nil`, or whatever the view already has for it), a conflicts-row selection opens `.file(path:)`. Otherwise it keeps `.diff(path:stage: .unstaged)`. Pass a flag or closure in rather than reaching into the client from the view.
- [ ] **Step 3: Check.** Run `swiftformat --lint` on the changed files. Review the gating by reading it: an older host shows neither item.
- [ ] **Step 4: Commit.** `feat(remote): merge and rebase a host worktree from the Mac`
