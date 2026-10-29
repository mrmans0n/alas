# Peer image and binary preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preview a paired host worktree's images, image diffs and other binaries from the Mac, as locally.

**Architecture:** A new `HostWorktreeRead.fileBytes(path:revision:)` returns raw bytes, capped at 5 MB, for the working tree or a validated revision. It reuses the text read's path chain. On the Mac, the peer document area gains three new contents: an image preview, an image diff (the existing `ImageDiffView`) and a placeholder card.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, Swift Testing, AlasCore SwiftPM package.

**Spec:** docs/superpowers/specs/2026-10-29-peer-file-preview-design.md

## Global Constraints

- Swift Testing only. Keep tests minimal and sharp. Git stays real (template repos), and nothing uses a fixed `Task.sleep`.
- No xcodebuild locally: the app's first build is CI. `swift test --package-path Packages/AlasCore` is fine.
- No git command is built from a Mac string. A revision is an enum the host maps to refs it already uses for diffs, and a SHA is verified as a commit.
- Byte reads follow exactly the text read's path rules.
- Conventional Commits, no attribution trailers.

## Review Focus

1. **An image just over the cap,** or an old blob over it. The host refuses with `.tooLarge` and `byteSize` before reading past the cap. The Mac shows the card with the size. Tested by Task 1.
2. **A symlink, gitignored or `.git` path asked for as bytes.** It is refused exactly as the text read refuses it. Tested by Task 1.
3. **An added image** (no old side) **and a deleted image** (no new side). The diff shows the missing side as locally, not an error. Tested by Task 1 (`.notFound` for the absent side) and pinned by the resolver Task 3 reuses.
4. **A revision SHA that isn't a commit,** or a rev expression. It is refused without running git. Tested by Task 1.
5. **An older host.** The Mac keeps today's note and never sends `fileBytes`. The reviewer checks the gating.

---

### Task 1: Host serves file bytes (PR 1)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift` (`HostWorktreeRead`, plus a new `HostFileRevision`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift` (capability, and the `.fileBytes` server reply)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasCoreContext+RemoteInspection.swift` (a bytes read beside `remoteFileContents`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteGatewayHostCalls.swift` and `HostProtocolServer.swift` (routing, as `.file` is routed)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/SSH/RemoteWorktreeFileAccess.swift` (a raw capped read reusing `openRegularFileNoFollow` and `readCapped`)
- Test: extend the existing suite that covers `remoteFileContents` / `HostWorktreeRead.file`

**Interfaces:**
- Produces:
  - `HostFileRevision`: `.index`, `.base(comparisonMode: AppConfig.Changes.ChangesComparisonMode?)` (HEAD, or the comparison ref the host's changes use), `.commit(sha: String)` and `.parent(sha: String)`.
  - `HostWorktreeRead.fileBytes(path: String, revision: HostFileRevision?)`, where nil means the working tree.
  - The reply is `RemoteServerMessage.fileBytes(sessionId:path:data:byteSize:)`, or the existing `.fileUnavailable` (`.tooLarge` carries `byteSize`, `.notFound` covers a missing side).
  - The capability is `HostProtocolCapability.worktreesFileBytesV1 = "host.worktrees.fileBytes.v1"`, served wherever `worktreesReadV1` is served.
  - The cap is `RemoteWorktreeFileAccess.maxPreviewBytes = 5 * 1024 * 1024`.

- [ ] **Step 1: Write the failing test** `aMacReadsAWorktreeFilesBytes`. Use a template repo with a committed PNG, then change the working-tree copy. Assert, in order:
  - The working tree returns its exact bytes and `byteSize`.
  - `.index` and `.base(nil)` return the committed bytes.
  - `.commit(sha)` returns the bytes at that commit, and `.parent(sha)` the bytes before it.
  - A path added only in the working tree, read at `.base(nil)`, gives `.notFound`.
  - A file over the cap (use a smaller cap via an internal parameter so the test stays cheap) gives `.tooLarge` with its size.
  - A symlink, a gitignored path and `.git/config` are refused as the text read refuses them.
  - `.commit("HEAD~1")` and a SHA that isn't a commit are refused.
- [ ] **Step 2: Run it.** `swift test --package-path Packages/AlasCore --filter aMacReadsAWorktreeFilesBytes`. Expected: the build fails.
- [ ] **Step 3: Implement it.**
  - The working tree uses the text read's chain, with the raw capped read and no binary or UTF-8 gate.
  - A revision uses the same path checks (with the ignore check exempting deleted paths, as diffs do). It runs `git cat-file -s` first to refuse anything over the cap, then `git show <rev>:<path>` via `Process.gitData`.
  - SHAs are validated as the commit reads validate them.
- [ ] **Step 4: Run it, plus the whole core suite.** Expected: everything passes.
- [ ] **Step 5: Commit.** `feat(alas-host): serve a worktree file's bytes to a paired Mac`

### Task 2: Mac previews images and shows the binary card (PR 2)

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerWorkspace.swift` (`DocumentContent` gains `.image(Data, byteSize:)` and `.binary(byteSize: Int?, tooLarge: Bool)`; `.fileUnavailable` `.binary` and `.tooLarge` keep `byteSize`)
- Modify: `Alas/Sources/Remote/Native/NativePeerSessions.swift` (opening `.file(path)` of an `ImageFileType` path sends `fileBytes` when the host serves it)
- Modify: `Alas/Sources/Remote/Native/NativePeerDocumentView.swift` (render the image with local's footer, and the card)
- Read for reuse: `Alas/Sources/Center/ImagePreviewTabView.swift` and `BinaryPreviewTabView.swift`. Extract the shared content views if that keeps the change small; prefer no new files.

- [ ] **Step 1:** Route image paths to a bytes read, gated on `worktreesFileBytesV1`. Any other `BinaryFileType` path, or a text read answered `.binary`, shows the card with the size. Older hosts keep today's note.
- [ ] **Step 2:** Render it.
  - The image comes from `NSImage(data:)`, with a footer showing pixel size and byte count; a decode failure shows local's message.
  - The card shows icon, name, kind and size, with no Open with System or Reveal.
  - "Too large to preview" shows the size.
- [ ] **Step 3:** If the routing is a plain function (path, capability and reply to content), extend an existing NativePeerWorkspace or Sessions test with a parameterized case. Otherwise add no test.
- [ ] **Step 4:** Run `swiftformat --lint`. No xcodebuild.
- [ ] **Step 5: Commit.** `feat(remote): preview a host's images and binary files on the Mac`

### Task 3: Mac image diffs for Changes and commits (PR 2)

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerWorkspace.swift` / `NativePeerSessions.swift` (for an image path's `.diff` or commit-diff document, fetch both sides with `fileBytes` instead of the text diff)
- Modify: `Alas/Sources/Remote/Native/NativePeerDocumentView.swift` (render `ImageDiffView(pair:)`)
- Read: `Packages/AlasCore/Sources/AlasFeatures/Center/ImageDiff/ImageDiffPair.swift`, `ImageDiffPairResolver`, `GitService.imageSide(fromRawData:)`, and the local `DiffTabView` image branch.

- [ ] **Step 1:** Map each peer diff document to its two sides.
  - Unstaged: `.index` against the working tree.
  - Staged: `.base(mode)` against `.index`.
  - Changes against a comparison mode: `.base(mode)` against the working tree.
  - A commit diff: `.parent(sha)` against `.commit(sha)`.
  - A rename's old side uses `renameFrom`.

  Make this a plain function and test it, parameterized, in the existing workspace suite.
- [ ] **Step 2:** Fetch both sides, then build the pair:
  - map `.notFound` to a missing side;
  - decode each side with `GitService.imageSide(fromRawData:)`;
  - get the kind from `ImageDiffPairResolver` with the change's status.

  Render it with `ImageDiffView`. A side that's too large shows local's failed side.
- [ ] **Step 3:** Run `swiftformat --lint`. No xcodebuild.
- [ ] **Step 4: Commit.** `feat(remote): show image diffs for a host's changes and commits`
