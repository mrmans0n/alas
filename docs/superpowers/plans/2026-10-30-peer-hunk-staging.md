# Peer hunk staging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage, unstage and discard single hunks of a paired host's worktree diffs from the Mac.

**Architecture:** A new `HostWorktreeChange.hunk(...)` names a hunk by path, stage, index, header and a lines hash. The host re-diffs, checks the hunk, rebuilds the patch with `HunkPatchBuilder` and applies it. The Mac supplies `DiffPaneHunkActions` to the peer diff view.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, AlasCore SwiftPM package.

**Spec:** docs/superpowers/specs/2026-10-30-peer-hunk-staging-design.md

## Global Constraints

- Swift Testing only. Keep tests minimal and sharp. Git stays real, and nothing uses a fixed `Task.sleep`.
- No xcodebuild locally: the app's first build is CI. `swift test --package-path Packages/AlasCore` is fine.
- No patch text from the Mac. Every patch is built on the host from its own diff.
- Conventional Commits, no attribution trailers.

## Review Focus

1. **The file changed after the Mac read it** (same header, different lines, or a shifted index). The change is refused, and nothing is applied. Tested by Task 1.
2. **Discard on an untracked file, or a deleted tracked one.** It is refused. Tested by Task 1.
3. **Stage on an untracked file.** It stages with the right mode, from the host's own probe. Tested by Task 1.
4. **A hunk past the truncation cap.** It is refused. Tested by Task 1.
5. **An older host.** There are no hunk buttons. Checked in review.

---

### Task 1: Host applies a named hunk

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift` (`HostWorktreeChange.hunk`, `HostHunkAction`, the capability mapping)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift` (`worktreesHunksV1 = "host.worktrees.hunks.v1"` in `headlessOnly`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeGit.swift` (the handler, and the exhaustive switches)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/Git/` (a shared `hunkLinesHash`; `fileMode(at:)` moved from `Alas/Sources/Center/DiffTabView.swift` with DiffTabView calling it; a `stageHunk` beside `unstageHunk` if useful)
- Test: extend `HostProtocolServerTests` beside the `dropHunk` tests (~:1821)

- [ ] **Step 1: Write the failing test** `aMacStagesUnstagesAndDiscardsAHunk`. Use a template repo where a tracked file has two separated edits (two hunks), plus one untracked file. Assert:
  - Staging hunk 1 leaves only hunk 0 unstaged, and the staged diff shows hunk 1.
  - Unstaging it restores both unstaged hunks.
  - Discarding hunk 0 removes it from the working tree.
  - A wrong `linesHash`, a wrong header and an index past the shown hunks are refused, with the file unchanged.
  - Discard on the untracked file is refused. Stage on it stages the file with its mode.
  - The action must fit the stage: unstage on an unstaged diff is refused.
- [ ] **Step 2: Run it.** `swift test --package-path Packages/AlasCore --filter aMacStagesUnstagesAndDiscardsAHunk`. Expected: the build fails.
- [ ] **Step 3: Implement it** per the spec's host decisions.
- [ ] **Step 4: Run it, plus the whole core suite.** Expected: everything passes.
- [ ] **Step 5: Commit.** `feat(alas-host): stage, unstage and discard a hunk for a paired Mac`

### Task 2: Mac hunk buttons

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift` (an `unstage` slot on `DiffPaneHunkActions`, rendered in the header like stage and discard; local callers unchanged)
- Modify: `Alas/Sources/Remote/Native/NativePeerDocumentView.swift` (accept hunk actions, the discard confirmation, a busy state, the note on refusal)
- Modify: `Alas/Sources/App/RootView.swift` (wire the actions for `.diff(path:stage:)` documents to `hosts.mutate(.hunk(...))`, then `client.reloadWorkspace()`; gate on the capability)
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift` (a capability check, if not covered by `mutate`'s gate)

- [ ] **Step 1:** Wire it.
  - The unstaged diff gets stage and discard; the staged diff gets unstage.
  - No other document gets actions, and nothing shows on older hosts.
  - The hash and header sent are computed from the hunk as received.
- [ ] **Step 2:** If the document-to-actions mapping is a plain function, add a parameterized case in an existing peer suite.
- [ ] **Step 3:** Run `swiftformat --lint`. No xcodebuild.
- [ ] **Step 4: Commit.** `feat(remote): stage and discard hunks of a host's diffs from the Mac`
