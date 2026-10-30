# Peer File History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a paired host file's history on the Mac: the commits that touched it, following renames, with each commit's diff of the file beside the list.

**Architecture:** A new `HostWorktreeRead.fileHistory(path:)` returns up to 200 `CommitInfo`s, each with the file's path at that commit, under a new capability. On the Mac, File History opens a center view (like the commit editor): a list on the left, and the selected row's `.commitDiff(path: pathAtCommit, sha:)` document on the right.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, AlasCore SwiftPM package.

**Spec:** docs/superpowers/specs/2026-10-29-peer-file-history-design.md

## Global Constraints

- Swift Testing only. Keep tests minimal and sharp. Git stays real (template repos), and nothing uses a fixed `Task.sleep`.
- No xcodebuild locally: the app's first build is CI. `swift test --package-path Packages/AlasCore` is fine.
- The path goes through `normalizedRelativePath` and after `--`. No other Mac string reaches git.
- Conventional Commits, no attribution trailers.

## Review Focus

1. **A file renamed partway through its history.** Entries before the rename carry the old `pathAtCommit`, and their commit diff opens under that path. Tested by Task 1; the Mac's use of it is checked by review.
2. **More than 200 commits.** The list stops at 200 and is marked truncated. Tested by Task 1 (with a small cap parameter).
3. **A `.git`, `..` or absolute path.** It is refused. Tested by Task 1.
4. **An untracked file, or one with no history.** The list is empty, not an error, and the view says so. Tested by Task 1.
5. **An older host.** The menu item is disabled. The reviewer checks it.

---

### Task 1: Host serves a file's history (PR 1)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift` (`HostWorktreeRead.fileHistory(path:)`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift` (capability; replies `fileHistory(sessionId:path:entries:truncated:)` and `fileHistoryFailed(sessionId:path:reason:message:)`)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/Git/GitService.swift` (a history call that also returns each commit's path; extend `fileHistory` or add a sibling, keeping local's callers unchanged)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteGatewayHostCalls.swift`, `AlasCoreContext+RemoteInspection.swift`, `HostProtocolServer.swift` (routing, as the commit reads route)
- Test: extend the suite that has `aMacReadsAWorktreeFilesBytes` (`HostProtocolServerTests`)

**Interfaces:**
- Produces:
  - `HostProtocolCapability.worktreesFileHistoryV1 = "host.worktrees.fileHistory.v1"`, served wherever `worktreesReadV1` is.
  - `HostFileHistoryEntry: Codable, Equatable, Sendable { commit: CommitInfo; pathAtCommit: String }`.
  - `RemoteWorktreeFileAccess.maxHistoryEntries = 200`.

- [ ] **Step 1: Write the failing test** `aMacReadsAFilesHistory`. Use a template repo where `a.txt` is committed, edited, renamed to `b.txt` and edited again. Assert:
  - Reading `b.txt` returns 4 entries, newest first. Their `pathAtCommit` values are `b.txt`, `b.txt`, `a.txt`, `a.txt`, and the +/− counts are as committed.
  - With a small cap passed internally (e.g. 2), there are 2 entries and `truncated` is true.
  - An untracked file returns 0 entries and `truncated` is false.
  - `.git/config`, `../x` and `/etc/passwd` are refused.
- [ ] **Step 2: Run it.** `swift test --package-path Packages/AlasCore --filter aMacReadsAFilesHistory`. Expected: the build fails.
- [ ] **Step 3: Implement it.**
  - Run `git log --follow -n <cap+1>`, with local's pretty format plus `--name-status -M` (or the numstat form) to get each commit's path for the followed file, then `-- <path>`.
  - Parse into entries, cap them, and set `truncated`.
  - Local's `fileHistory` stays behaviourally unchanged; check its existing tests still pass.
- [ ] **Step 4: Run it, plus the whole core suite.** Expected: everything passes.
- [ ] **Step 5: Commit.** `feat(alas-host): serve a file's history to a paired Mac`

### Task 2: Mac File History view (PR 2)

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift` (`servesFileHistory(serverId:)`)
- Modify: `Alas/Sources/Remote/Native/NativePeerSessions.swift` (`openedFileHistory` state, cleared and exclusive like `openedCommitEditor`; the read through `hosts.read`, with the epoch guard; the reply applied; the `unserved` switch updated)
- Modify: `Alas/Sources/Remote/Native/NativePeerWorkspace.swift` (a `Load` for history, if that is where reads land)
- Modify: `Alas/Sources/App/RootView.swift` (a center branch for the history view, before the document)
- Modify: `Alas/Sources/Right/NativePeerRightPaneView.swift` (`onFileHistory` for the Files tab and Changes rows, disabled without the capability)
- View: reuse `CommitRow` and the `FileHistoryTabView` header. Prefer adding the view to an existing peer file over a new file (a new file needs `xcodegen` and a commit of the project).

- [ ] **Step 1:** Wire it.
  - The menu item opens history for the path.
  - The view shows a header (basename, "History", directory, close), the list, loading, Retry, "No history" and "Showing the latest 200".
  - The first row is selected.
  - The selected row's diff renders as the existing `.commitDiff(path: pathAtCommit, sha:)` document beside the list, through the existing document plumbing, so text and image diffs work. Make sure the image diff plan works for a commit whose file list isn't loaded, using `pathAtCommit` and its rename status if needed.
- [ ] **Step 2:** If any non-trivial decision is a plain function (e.g. the entry to document mapping), add a parameterized case to an existing peer suite. Otherwise add no test.
- [ ] **Step 3:** Run `swiftformat --lint`. No xcodebuild.
- [ ] **Step 4: Commit.** `feat(remote): show a host file's history on the Mac`
