# Peer File Edit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac paired with a headless `alas-host` edits a host worktree's text files in its own editor. The host does every write as a compare-and-swap against the version the Mac read, and tells the Mac when an open file changes.

**Architecture:**
- **Host (PR 1).**
  - The file read gains an optional `WorktreeFileVersion`: a SHA-256 of the bytes, which decides, plus the mtime.
  - Three new `HostRequest` cases write a file, create a folder, and follow a file. They go through their own gated entry point in a new `AlasCoreContext+WorktreeFiles.swift`, with no branch check.
  - A refcounted `HostFileWatcher` publishes an opt-in `fileChanged` event.
  - All of it sits behind capability `host.worktrees.files.v1`, appended to `HostProtocolCapability.headlessOnly`.
- **Mac (PR 2).**
  - `EditorBuffer`'s SSH half moves, mechanically, behind a struct of closures, `EditorRemoteBackend`. A second implementation, `.peer`, talks to the host through `NativePeerHosts`.
  - A host text file the host served with a version opens over the peer center in the local `EditorTabView`. Its buffer is adopted into `TabsManager` under a namespaced tab id.
  - The peer Files tab gains New File and New Folder.
  - The right pane's checkpoint restore refuses while host buffers of that worktree are dirty.

**Tech Stack:** Swift 6 / SwiftUI app, `Packages/AlasCore` SwiftPM (UI-free), Swift Testing, real git in temp dirs.

**Spec:** `docs/superpowers/specs/2026-10-26-peer-file-edit-design.md`. Both of its Decisions sections bind. Where this plan rules between them or departs because of the code, the Self-review says so.

**PR split** (land in order):
- **PR 1 — host** (Tasks 1–3). Capability `host.worktrees.files.v1`. No Mac sends a write or follow yet. Task 1's read version reaches every client and is ignored until PR 2.
- **PR 2 — Mac** (Tasks 4–7). Task 4 is a pure move and lands as its own commit, so review can diff it as one.

## Global Constraints

- AGENTS.md (origin/main):
  - Swift Testing only, minimal and sharp. Don't test views or wiring.
  - Core imports no SwiftUI, AppKit, GhosttyKit, MLX, TreeSitterPack or FffC.
  - Anything the app or tests use from core is `public`. Public cross-module types are explicitly `Sendable`.
  - Conventional Commits, with no attribution trailers or footers.
- Core tests: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`. Check that the `Test run with N tests` line has N > 0.
- **Git stays real** in temp dirs, from `GitTemplate` copies through the existing `RepoFixture`. No git fakes.
- **Never the real profile.** Every `AlasCoreContext` a test builds is `RepoFixture`'s, with temp stores.
- **Never a fixed `Task.sleep`** as synchronization. Core tests use `eventually` and `Client.waitFor`. App tests poll a condition with a deadline, as `remoteLoadNotifiesObserversWhenContentArrives` does.
- **The app can't be built locally**, so CI is its first build:
  - App tasks verify on CI (`-only-testing AlasTests/<Suite>`). Each PR body says which app tests ran on CI only.
  - Split long SwiftUI modifier chains into `let` steps, as `RootView` does.
  - No new property or method whose name collides with an existing one on the same type.
  - No `if let x` that shadows a property a closure then assigns.
  - No new files under `Alas/` or `AlasTests/`, so no `xcodegen`. Core gets two new source files.
- **Local and SSH editing stay behaviourally identical.** Task 4 is a mechanical move. The existing `EditorBufferTests` SSH cases (`remoteLoadNotifiesObserversWhenContentArrives`, `remoteFailedLSPOpenRetriesThroughNormalReopen`, `remoteConflictChecksCoalesceAnOverlappingRequest`) must pass unchanged.
- **A peer buffer never touches this Mac's disk,** even when the host's path exists here. It has no store (no hot-exit), no LSP, and no Save As or move.
- **Headless only.** `worktreesFilesV1` joins `HostProtocolCapability.headlessOnly`, so `servedCapabilities` serves it only where `environment.servesWorktreeGit`.
- **Wire compatibility.**
  - The new `version` key on `fileContents` decodes lossily (`try?` … `?? nil`): absent or unreadable is nil.
  - `fileChanged` is opt-in (`optInKind`), so an older Mac never receives it.
  - An older host sends no version, and the Mac keeps today's read-only view.
- **Trust boundary.** A write path passes all of:
  - `RemoteWorktreeFileAccess.normalizedRelativePath` and `resolve` (no `..`, no absolute path, no `.git` in any case, nothing resolving outside);
  - no symlink at any component: the parent's `realpath` equals the root's `realpath` plus the normalized parent, and an `lstat` of the final component finds it absent or `S_IFREG`;
  - in a git project, `GitService().isPathIgnored` is false. A folder project skips this, as reads do.
- **Writes are capped like reads:** `RemoteWorktreeFileAccess.maxFileBytes` (512 KB), for both the new text and the file it replaces.
- Copy (verbatim):
  - Host refusals:
    - `"The host does not edit <path>."` (`invalidRequest`): every trust-boundary refusal, a directory where a file is named, and `followFile` on such a path.
    - `"The host edits files up to 512 KB."` (`invalidRequest`)
    - `"The host does not edit files of remote projects."` (`invalidRequest`)
    - `"A checkpoint restore is running on the host; save again once it finishes."` (`failed`)
    - `"A checkpoint restore is pending on the host; finish it there first."` (`failed`, today's copy)
    - `"<path> already exists on the host."` (`failed`, `createFolder`)
    - `"The folder holding <path> is no longer on the host."` (`failed`)
    - `"This host does not serve this git action."` (`servedWorktree`'s existing copy)
    - A stale version is `HostError.fileChanged(current:)`, with nil when the file is gone.
  - Mac:
    - New File: `"<path> already exists on the host."` (a `fileChanged` answer to a create). The local titles `"New File"`/`"untitled.txt"`, `"New Folder"`/`"New Folder"`, and the error titles `"New File Failed"`/`"New Folder Failed"`.
    - Restore refusal: `"Save or discard unsaved edits to <path>, <path> before restoring."`
    - Editor errors reuse `EditorConflictBanner` (`"Couldn't save: <message>"`, `"File changed on disk while you have unsaved edits."`, `"File was deleted on disk."`).

## Review Focus

1. **Another tool saves the open file by rename (a new inode), then saves again.** A watch on the old inode would go deaf after the first save. Every later save must still reach the Mac. Tested by Task 3, `aFollowedFileChangeReachesOnlyTheMacsFollowingIt` (two atomic writes in a row).
2. **A Mac drops off while following.** Its follow must not keep the host watching forever, while a second Mac's follow of the same file keeps working. Tested by Task 3, `aFileStaysWatchedWhileAnyMacFollowsIt`.
3. **Saving an executable script or a CRLF file.** The temp-file rename must keep the mode, and the bytes must arrive exactly as the Mac sent them. Tested by Task 2, `aMacSavesAHostFileAgainstTheVersionItRead` (`0755`, `"\r\n"`).
4. **New File or New Folder over a name that exists.** It must be refused, with the existing file untouched. Tested by Task 2, `aMacSavesAHostFileAgainstTheVersionItRead` (second create of each).
5. **Two saves in a row from one buffer.** The second must compare against the version the first returned, not the one first read. Otherwise every second save is a spurious conflict. Tested by Task 5, `aHostFileSaveMeetingANewerVersionKeepsTheEditsAndKeepMineResaves` (final save).

---

## PR 1 — host

### Task 1: Versioned file reads

**Files:**
- Modify `Packages/AlasCore/Sources/AlasPlatform/SSH/RemoteWorktreeFileAccess.swift`:
  - Add `WorktreeFileVersion` and `FileVersionProbe` above `RemoteWorktreeFileAccess`.
  - Add `readVersionedFileContents(at:)`. `readFileContents(at:)` (`:353`) returns its `.outcome`.
  - `openReadCapped` (`:298`) also returns the descriptor's `st_mtimespec`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift`:
  - `.fileContents` (`:901`) gains `version`.
  - Add a `version` coding key (`:915-928`).
  - Decode it lossily (`:1162`) and encode it with `encodeIfPresent` (`:1432`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteMessageWireJSON.swift:905`: `RemoteFileContentsResult.success` gains `version`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasCoreContext+RemoteInspection.swift:770-779`: the local read uses `readVersionedFileContents`. The SSH-project branch (`:741-767`) sends no version.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteGatewayHostCalls.swift:211-213` and `Packages/AlasCore/Sources/AlasHostCore/Remote/Federation/RemoteMessageSessionScope.swift:116,196-197`: pass `version` through.
- Modify the app's positional patterns, `Alas/Sources/Remote/Native/NativePeerWorkspace.swift:278` and `Alas/Sources/Remote/Native/NativePeerSessions.swift:1578`, to the new arity. Task 6 reads the version.
- Modify `AlasTests/Remote/RemoteAppStateAccessTests.swift:1871,1909`. The session path now carries a version, so match `.success("hello\n", false, _)` instead of comparing equal.
- Test `HostProtocolTests`, `HostProtocolServerTests`.

**Interfaces:**
- Produces:
  ```swift
  // AlasPlatform
  public struct WorktreeFileVersion: Codable, Hashable, Sendable {
      /// SHA-256 of the bytes, lowercase hex: two versions differ when this does.
      public var contentHash: String
      /// When the bytes were read; never compared on the host.
      public var modified: Date
      public init(contentHash: String, modified: Date)
      public static func contentHash(of data: Data) -> String          // CryptoKit SHA256
  }
  public enum FileVersionProbe: Equatable, Sendable {
      case missing                                   // absent, a symlink, or not a regular file
      case tooLarge(byteSize: Int)
      case version(WorktreeFileVersion, data: Data)
  }
  // RemoteWorktreeFileAccess
  /// `readFileContents`, plus the version of the bytes read: nil unless `.text`.
  public static func readVersionedFileContents(at url: URL) async -> (outcome: FileReadOutcome, version: WorktreeFileVersion?)
  /// The regular file at `url` as one no-follow open, capped at `maxFileBytes`.
  public static func probeVersion(at url: URL) async -> FileVersionProbe
  // RemoteServerMessage
  case fileContents(sessionId: String, path: String, text: String, truncated: Bool, version: WorktreeFileVersion? = nil)
  // RemoteFileContentsResult
  case success(text: String, truncated: Bool, version: WorktreeFileVersion? = nil)
  ```
- Every host fills the version: it's a read, and a client that doesn't know it ignores it. Phones get it too, harmlessly.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  // HostProtocolTests
  @Test func aFileReadCarriesItsVersion() throws
  // v = WorktreeFileVersion(contentHash: "ab", modified: Date(timeIntervalSince1970: 7))
  // .fileContents(sessionId: "a", path: "p", text: "t", truncated: false, version: v) round-trips through RemoteServerMessage JSON
  // .replacingSessionId("b") keeps v
  // with json["version"] removed, set to "garbage", or set to ["contentHash": 1]: decodes equal to the same message with version nil

  // HostProtocolServerTests, extending worktreeReadsAnswerWithTheSessionReplyKeyedByTheWorktree
  // .readWorktree(.file(path: "notes.txt")) → .worktreeRead(.fileContents(worktree.id, "notes.txt", "hi\n", false, let version?))
  // version.contentHash == WorktreeFileVersion.contentHash(of: Data("hi\n".utf8))
  // version.modified == notes.txt's modificationDate
  ```
- [ ] **Step 2: Run and confirm they fail.** `--filter HostProtocolTests`. Expected: a compile error for `version:`.
- [ ] **Step 3: Implement.** Hash and mtime come from the same descriptor `openReadCapped` already holds, so the version describes exactly the bytes served.
- [ ] **Step 4: Run and confirm they pass.** `--filter HostProtocolTests`, `--filter HostProtocolServerTests`. App: CI runs `-only-testing AlasTests/RemoteAppStateAccessTests -only-testing AlasTests/RemoteMessageSessionScopeTests -only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/NativePeerWorkspaceTests -only-testing AlasTests/RemoteWorktreeFileAccessTests`.
- [ ] **Step 5: Commit.** `feat(remote): send a file's version with its contents`.

### Task 2: Compare-and-swap writes, new files and new folders

**Files:**
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`:
  - `HostRequest` (after `checkpointRestorePreview`, `:174`): `writeFile`, `createFolder`.
  - `HostResponse` (before `failure`, `:542`): `fileWritten`.
  - `HostError` (`:564`): `fileChanged`.
- Modify `RemoteProtocol.swift:1515-1526`: add `worktreesFilesV1`, appended to `headlessOnly`.
- Modify `RemoteWorktreeFileAccess.swift`: add `replaceAtomically`.
- Create `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeFiles.swift`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift`: dispatch after `checkpointRestorePreview` (`:398`), each through `servedWorktree(ref, capability: worktreesFilesV1)` (`:506`), logging `caller.log("worktrees.files", path)`.
- Test `HostProtocolServerTests`, and round trips in `HostProtocolTests`.

**Interfaces:**
- Consumes Task 1's `WorktreeFileVersion`, `probeVersion`, and `checkpointRestoreHolds`/`isHeldByCheckpointRestore` (`AlasCoreContext+Checkpoints.swift:96`).
- Produces:
  ```swift
  public static let worktreesFilesV1 = "host.worktrees.files.v1"   // writeFile, createFolder, followFile, unfollowFile, the fileChanged event
  // HostRequest
  /// Replaces `path`'s text if the file is still at `expected`; nil `expected` creates it, refusing if anything is there.
  case writeFile(worktree: WorktreeRef, path: String, text: String, expected: WorktreeFileVersion?)
  case createFolder(worktree: WorktreeRef, path: String)
  // HostResponse
  case fileWritten(version: WorktreeFileVersion)
  // HostError
  /// The file is no longer at the version the client named: `current`, or nil when it is gone.
  case fileChanged(current: WorktreeFileVersion?)
  // RemoteWorktreeFileAccess
  /// Writes `data` to a temp file beside `url`, fsyncs it, sets the mode `url` had (0644 for a new
  /// file), and renames it over `url`. Returns the version written. The temp file never outlives a failure.
  public static func replaceAtomically(_ url: URL, with data: Data) async throws -> WorktreeFileVersion
  // AlasCoreContext (+WorktreeFiles), internal
  /// A paired Mac's file change in a listed worktree, under the project's gate. Refused while stopping,
  /// unlisted or archived, busy (`isWorktreeIdle`), held by a checkpoint restore, or with a restore
  /// pending. No branch check: the version is the guard.
  func changeListedFiles<T: Sendable>(in worktree: Worktree, _ body: @MainActor (Worktree) async throws -> T) async throws -> T
  func writeListedFile(_ path: String, text: String, expected: WorktreeFileVersion?, in worktree: Worktree) async throws -> WorktreeFileVersion
  func createListedFolder(_ path: String, in worktree: Worktree) async throws
  /// `path` in `worktree` under the trust-boundary rules (Global Constraints), else
  /// invalidRequest("The host does not edit <path>."); the folder holding it must exist.
  func writableURL(_ path: String, in worktree: Worktree) async throws -> URL
  ```
- **`changeListedFiles`** copies the head of `mutateListedWorktree` (`AlasCoreContext+WorktreeGit.swift:16-41`), drops the two branch checks, and adds the restore hold. Leave `mutateListedWorktree` itself alone: `gitActionsAreRefused` pins the order of its refusals.
  - It refuses a worktree whose path `isRemoteAlasPath` with `"The host does not edit files of remote projects."`.
- **`writeListedFile`:**
  1. Refuse text over the cap.
  2. Take `writableURL`.
  3. Run `probeVersion`:
     - over the cap: refuse with the cap copy;
     - `.missing` with a non-nil `expected`: `fileChanged(current: nil)`;
     - `.version(v, _)` whose `contentHash` differs from `expected`'s, or any version when `expected` is nil: `fileChanged(current: v)`.
  4. Then `replaceAtomically`. The hash alone decides, so a touch-only mtime change passes.
- **`createListedFolder`** runs `writableURL`, refuses an existing entry (`failed("<path> already exists on the host.")`), then calls `mkdir`. It creates no parents.
- A missing parent is `failed("The folder holding <path> is no longer on the host.")`.
- `// ponytail:` the probe-then-rename window is the same race local saves have; an `O_EXCL` lock file would close it if it ever bites.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func aMacSavesAHostFileAgainstTheVersionItRead() async throws
  // main worktree; .alas/scripts/hello.sh := "old\r\n", chmod 0o755
  // read .file → version v. .writeFile(path, text: "new\r\n", expected: v) → .fileWritten(w)
  //   w.contentHash == contentHash(of: "new\r\n"); disk bytes == Data("new\r\n".utf8); posixPermissions == 0o755
  //   no ".hello.sh.alas-*" temp file left in .alas/scripts
  // .writeFile(path, text: "newer\n", expected: w) → .fileWritten
  // .writeFile("new.txt", text: "", expected: nil) → .fileWritten; new.txt is empty with mode 0o644
  // again → .failure(.fileChanged(current: e)) with e.contentHash == contentHash(of: Data())
  // .createFolder("docs") == .done, a directory; again → .failure(.failed(message: "docs already exists on the host."))
  // .writeFile("gone/x.txt", text: "", expected: nil) → .failure(.failed(message: "The folder holding gone/x.txt is no longer on the host."))

  enum OutsideChange: CaseIterable { case edited, deleted, touched }
  @Test(arguments: OutsideChange.allCases)
  func aSaveIsCheckedAgainstTheFilesContentNotItsTimestamp(_ change: OutsideChange) async throws
  // notes.txt := "a\n", read v; then edited: "theirs\n"; deleted: removed; touched: modificationDate += 60 s
  // .writeFile("notes.txt", text: "mine\n", expected: v):
  //   edited  → .failure(.fileChanged(current: c)), c?.contentHash == contentHash(of: "theirs\n"); disk "theirs\n"
  //   deleted → .failure(.fileChanged(current: nil)); still absent
  //   touched → .fileWritten; disk "mine\n"

  enum UnwritablePath: CaseIterable { case parentDirectory, dotGit, dotGitCase, symlinkFinal, symlinkParentOutside, symlinkParentInside, directory, ignored }
  @Test(arguments: UnwritablePath.allCases)
  func fileWritesStayOnRegularFilesInsideTheWorktree(_ shape: UnwritablePath) async throws
  // root/outside/inside.txt := "keep\n"
  // parentDirectory "../outside/inside.txt"; dotGit ".git/config"; dotGitCase ".GIT/config";
  // symlinkFinal "alias.txt" (→ outside/inside.txt); symlinkParentOutside "out/inside.txt" (out → root/outside);
  // symlinkParentInside "scripts/hello.sh" (scripts → .alas/scripts); directory ".alas";
  // ignored "debug.log" (.gitignore "*.log\n", debug.log "a\n")
  // .writeFile(path, text: "x", expected: nil) → .failure(.invalidRequest(reason: "The host does not edit \(path)."))
  // outside/inside.txt == "keep\n"; .git/config bytes unchanged; .alas/scripts/hello.sh unchanged; debug.log == "a\n"

  @Test(arguments: [false, true])
  func ignoredFilesAreEditedOnlyInFolderProjects(folder: Bool) async throws
  // git: the fixture repo. folder: root/plain added with kind: .folder. Either way .gitignore "*.log\n" and debug.log "a\n".
  // read .file("debug.log"): git → .fileUnavailable(_, _, .pathRejected, _, _); folder → .fileContents with version v
  // folder: .writeFile(expected: v, text: "b\n") → .fileWritten; disk "b\n"
  // git: .writeFile(expected: nil, text: "b\n") → .failure(.invalidRequest(reason: "The host does not edit debug.log."))

  enum WriteGate: CaseIterable { case restoreHold, pendingRecovery, overCap, appHost }
  @Test(arguments: WriteGate.allCases)
  func fileWritesAreRefusedWhileTheWorktreeIsHeld(_ gate: WriteGate) async throws
  // notes.txt := "a\n", read v
  // restoreHold: core.checkpointRestoreHolds[UUID()] = [SessionOwnerID.worktree(id).storageKey]
  //   → .failed(message: "A checkpoint restore is running on the host; save again once it finishes.")
  // pendingRecovery: RecordingRunEnvironment(servesWorktreeGit: true, blocksForCheckpoint: true)
  //   → .failed(message: "A checkpoint restore is pending on the host; finish it there first.")
  // overCap: text of maxFileBytes + 1 "a"s → .invalidRequest(reason: "The host edits files up to 512 KB.")
  // appHost: RecordingRunEnvironment() → .invalidRequest(reason: "This host does not serve this git action.")
  // notes.txt == "a\n" afterwards

  @Test func aFileIsSavedMidRebaseWhileTheListingLags() async throws
  // (repo, ref) = stopPullOnConflicts(); read .alas/scripts/hello.sh → v (conflict markers)
  // .writeFile(path, text: "resolved\n", expected: v) → .fileWritten; disk "resolved\n"; .git/rebase-merge still exists
  ```
- [ ] **Step 2: Run and confirm they fail.** `--filter HostProtocolServerTests`. Expected: a compile error for `writeFile`.
- [ ] **Step 3: Implement** the wire cases, the capability, `replaceAtomically`, `AlasCoreContext+WorktreeFiles.swift`, and the dispatch.
- [ ] **Step 4: Round trips.** Add `.writeFile(…, expected: v)`, `.writeFile(…, expected: nil)`, `.createFolder`, `.fileWritten` and `.failure(.fileChanged(current: nil))` to `clientMessagesRoundTrip` / `serverMessagesRoundTrip`. `helloAdvertisesExactlyTheConsoleCapabilitiesItServes` and `HostSessionsTests:495` already use `headlessOnly`.
- [ ] **Step 5: Run and confirm everything passes.** `--filter HostProtocolServerTests`, `--filter HostProtocolTests`, `--filter HostSessionsTests`.
- [ ] **Step 6: Commit.** `feat(alas-host): save, create and make folders in a worktree for paired Macs`.

### Task 3: Followed files and the `fileChanged` event

**Files:**
- Modify `HostProtocol.swift`: `HostRequest` gains `followFile`/`unfollowFile`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Events.swift`:
  - `HostEvent` (`:27-64`) gains `fileChanged`, with its `key` (`:74-95`) and `optInKind` (`:592-598`).
  - `HostEventKey` (`:139-152`) gains `.file`.
  - `HostSubscription` gains file follows, released in `cancel` (`:250`) and the `isolated deinit`. `receive` (`:285`) drops `fileChanged` for unfollowed files, and unfollows a removed worktree's files.
  - `HostEventLog` gains `fileFollows`, beside `reviewFollows`.
  - `HostEventSource.init` (`:418-437`) owns a `HostFileWatcher` and wires it.
- Create `Packages/AlasCore/Sources/AlasHostCore/Core/HostFileWatcher.swift`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift:24`: `eventSource` becomes `private(set) var`, so tests can reach the watcher.
- Modify `HostProtocolServer.swift`:
  - `followFile` next to `followWorktree` (`:310`), through `servedWorktree(…, worktreesFilesV1)` and `subscribed()`, with the path normalized or `invalidRequest("The host does not edit <path>.")`.
  - `unfollowFile` needs only the subscription.
- Modify the exhaustive `HostEvent` switches: `PeerHostChannel.State.apply` (`PeerHostChannel.swift:75-77`, ignored) and `RemoteSessionGateway.swift:455-457` (`break`).
- Test `HostProtocolServerTests`, and round trips in `HostProtocolTests`.

**Interfaces:**
- Consumes Task 1's `probeVersion` and Task 2's capability.
- Produces:
  ```swift
  // HostRequest; worktreesFilesV1, on the connection's subscription
  case followFile(worktree: WorktreeRef, path: String)
  case unfollowFile(worktree: WorktreeRef, path: String)
  // HostEvent; optInKind "fileChanged"
  /// A followed file's content changed: its new version, or nil once it is gone (or no longer a regular file within the cap).
  case fileChanged(worktreeID: String, path: String, version: WorktreeFileVersion?)
  // HostSubscription
  public func followFile(_ worktree: Worktree, path: String)
  public func unfollowFile(worktreeID: String, path: String)
  // HostEventLog
  var fileFollows: (follow: (Worktree, String) -> Void, unfollow: (_ worktreeID: String, _ path: String) -> Void)
  // HostFileWatcher, internal, @MainActor
  init(publish: @escaping @MainActor ([HostEvent]) -> Void)
  /// Counted per (worktree, path): the first follow starts the watch, the last unfollow stops it.
  func follow(_ worktree: Worktree, path: String)
  func unfollow(worktreeID: String, path: String)
  /// Followers per "worktreeID/path".
  private(set) var watches: [String: Int]
  ```
- **Watch.** Per followed file, use two `DispatchSource.makeFileSystemObjectSource` (`O_EVTONLY`):
  - one on the file (`.write, .extend, .attrib, .rename, .delete`), absent while the file is missing;
  - one on its directory (`.write`).

  On any event, hop to the main actor, then `probeVersion`:
  - publish only when the hash, or whether a file is there, changed since the last version published or read at follow time;
  - re-open the file source, since a rename save swaps the inode.

  `.missing` and `.tooLarge` publish `version: nil`. A path whose `resolve` fails, or with a symlink parent, watches nothing.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func aFollowedFileChangeReachesOnlyTheMacsFollowingIt() async throws
  // notes.txt := "a\n". Connections A and B (a second HostProtocolServer(host: fixture.host).connect) each
  //   .subscribeAccepting(after: cursor, events: ["fileChanged"]); only A sends .followFile(ref, "notes.txt") == .done
  // write "b\n" atomically → A gets .fileChanged(worktree.id, "notes.txt", v), v?.contentHash == contentHash(of: "b\n")
  // write "c\n" atomically again (a new inode) → A gets contentHash "c\n"
  // delete → A gets .fileChanged(worktree.id, "notes.txt", nil)
  // A .unfollowFile; recreate "d\n"; then a worktreeChanged both receive (setOperationState .archiving)
  //   → A has no event for "d\n"; B has no fileChanged at all
  // decoding a received batch through HostServerMessage JSON gives it back

  @Test func aFileStaysWatchedWhileAnyMacFollowsIt() async throws
  // A and B both follow notes.txt; A's connection closes
  // write "b\n" → B still gets its fileChanged
  // B .unfollowFile → fixture.host.eventSource?.fileWatcher.watches.isEmpty == true

  // extend gitActionsAreRefused(.appHost):
  // .followFile(ref, "notes.txt") → .failure(.invalidRequest(reason: "This host does not serve this git action."))
  ```
- [ ] **Step 2: Run and confirm they fail.** `--filter HostProtocolServerTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm they pass.** Add `.followFile` and an `.events` batch holding `.fileChanged(…, version: nil)` to the round trips. Run `--filter HostProtocolServerTests`, `--filter HostProtocolTests`, `--filter PeerHostChannelTests`, `--filter HostSessionsTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): tell paired Macs when a file they follow changes`.

## PR 2 — Mac

### Task 4: Extract `EditorBuffer`'s remote half behind a backend seam (mechanical move)

**Files:**
- Modify `Alas/Sources/Code/Editor/EditorBuffer.swift` only. Add `EditorRemoteBackend`, `EditorRemoteProbe` and `EditorRemoteWatch` beside `RemoteConflictCheckCoalescer` (`:11`).

**Interfaces:**
- Produces:
  ```swift
  /// How an EditorBuffer reads, saves and watches a file that is not on this Mac's disk.
  struct EditorRemoteBackend {
      /// The SSH host: its status, LSP, Save As and move. Nil for a paired host's file, which has none of them.
      let sshHost: String?
      /// The file's bytes and baseline mtime, checked inside the worktree first.
      let read: @MainActor (_ relativePath: String) async throws -> RemoteReadResult
      /// Whether the file moved on from the buffer's baseline `mtime`.
      let probe: @MainActor (_ relativePath: String, _ baseline: Date) async throws -> EditorRemoteProbe
      /// The file's current mtime, nil once gone: Keep mine's new baseline.
      let currentMtime: @MainActor (_ relativePath: String) async throws -> Date?
      /// Writes `content` if the file is still at `expectedMtime` with `expectedContent`; both nil overwrite.
      /// Returns the new mtime; a moved file throws `RemoteFileAccessError.saveConflict`.
      let write: @MainActor (_ relativePath: String, _ content: String, _ expectedMtime: Date?, _ expectedContent: String?) async throws -> Date
      /// Until the returned watch stops: `observed` runs synchronously on each watcher event,
      /// then `check` (awaited by timed checks).
      let watch: @MainActor (_ relativePath: String, _ observed: @escaping @MainActor () -> Void,
                             _ check: @escaping @MainActor () async -> Void) -> EditorRemoteWatch

      /// Today's SSH behaviour, moved verbatim.
      @MainActor static func ssh(host: String, worktreeRoot: URL) -> Self
  }
  enum EditorRemoteProbe: Equatable { case unchanged, changed, deleted }
  struct EditorRemoteWatch { let stop: @MainActor () -> Void }
  // EditorBuffer
  private let remoteBackend: EditorRemoteBackend?          // replaces `private let remoteHost: String?` (:418)
  private var remoteHost: String? { remoteBackend?.sshHost }
  private var remoteWatch: EditorRemoteWatch?              // replaces remotePollTask and remoteHelperSession (:421-423)
  private init(…, remoteBackend: EditorRemoteBackend? = nil)   // the designated init (:613); nil asks RemoteHostRegistry as today
  ```
- **What moves into `.ssh`, unchanged:**
  - `read`: the `remoteReadResultForTesting` hook, else `verifyRemoteFileContained`, then `RemoteFileAccess.read`. This is `beginRemoteLoad`'s body (`:2303-2308`).
  - `probe`: `RemoteFileAccess.mtime`; nil is `.deleted`, a value `> baseline` is `.changed`, anything else `.unchanged` (`:1065-1070`).
  - `currentMtime`: `RemoteFileAccess.mtime` (`:1260`).
  - `write`: `verifyRemoteFileContained`, then `RemoteFileAccess.write(host:path:content:expectedMtime:expectedContent:)` (`:1435-1449`).
  - `watch`: the helper session, the matcher and the adaptive poll loop with `retryIfNeeded` (`:1010-1053`), plus `remoteConflictPollNanos` and `remoteHelperSafetyNetNanos` (`:427-429`).
    - A helper event calls `observed()` (the `fileWatchGeneration` bump), then `Task { await check() }`.
    - A timed check awaits `check()`, then calls `retryIfNeeded()`, as today.
- **What stays in the buffer:**
  - `RemoteConflictCheckCoalescer`, as `checkRemoteConflict()`.
  - `checkRemoteConflictOnce()`, which now switches on `probe`.
  - Generations, `remoteSaveInFlight`, `remoteOverwriteAfterConflict`, and rollback.
  - `RemoteHostStatusStore` reporting, now `if let host = remoteHost`, at the same points.
  - `saveAsRemote`/`moveToRemote` (`:1588-1677`), still on `remoteHost` and `verifyRemoteFileContained`.
- **The rule for every `remoteHost` reference:**
  - A check that picks remote or local *I/O* reads `remoteBackend`. That covers:
    - `refreshWorkspaceEditDiskMetadata` (`:302`);
    - init's `navigationResolvedRoot`/`localSaveRoot` (`:622-623`);
    - `revert` (`:929`), `startWatching` (`:943`), `startWatchingIfNeeded` (`:988`, now `remoteWatch == nil`);
    - `startMoveLookupForMissingFile` (`:1114`) and `resolveConflictKeepingMine` (`:1254`);
    - `save` (`:1307`), `saveAwaitingRemote` (`:1326`), `saveAs` (`:1514`), `moveTo` (`:1549`) and `renameItem` (`:1710`);
    - `saveConflictKeepingMineAwaitingRemote` (`:1993`), `applySnapshot` (`:2145-2147`), `checkForConflictOnRestore` (`:2253`) and `loadFromDisk` (`:2466`).
  - LSP, workspace-edit identity and status reporting keep `remoteHost`. That covers `:291`, `:378`, `:419`, `:718`, `:737`, `:1967` and `:2400-2446`.
- `beginRemoteLoad(replacingDirty:)`, `checkRemoteConflict()` and `startRemoteWatching()` lose their `host` parameter.

- [ ] **Step 1: Move the code.** No test: the existing SSH tests pin this behaviour. Don't edit them.
- [ ] **Step 2: Verify.** CI's app build plus `-only-testing AlasTests/EditorBufferTests -only-testing AlasTests/WorkspaceEditExecutorTests`. Review the diff as a move: no SSH call, guard or ordering changes.
- [ ] **Step 3: Commit.** `refactor(editor): put an editor buffer's remote file access behind a backend`.

### Task 5: The peer backend and host file access on the Mac

**Files:**
- Modify `EditorBuffer.swift`: add `EditorRemoteBackend.peer(…)` and a convenience init.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift`:
  - accept `"fileChanged"` in `connect` (`:134`);
  - add `onFileChanged` beside `onNotice` (`:100`), called from `receive` (`:162`).
- Modify `Alas/Sources/Remote/Native/NativePeerHosts.swift`:
  - `servesFiles`, `writeFile`, `createFolder` and `followFile`, after `servesCheckpoints`;
  - file follows re-sent and nudged in `makeChannel`'s `onChange` (`:582-602`), as `sendGitFollow` is;
  - cleared in `stop` (`:94`).
- Test `AlasTests/EditorBufferTests.swift`.

**Interfaces:**
- Consumes Tasks 1–4.
- Produces:
  ```swift
  // EditorRemoteBackend
  /// A paired host's file. Its closures share the version last read or written (the baseline); the host
  /// compares content hashes, so a touch is no change.
  @MainActor static func peer(
      read: @escaping @MainActor (_ path: String) async -> RemoteServerMessage?,   // the `.file` read; nil: no answer
      write: @escaping @MainActor (_ path: String, _ text: String, _ expected: WorktreeFileVersion?) async throws -> WorktreeFileVersion,
      follow: @escaping @MainActor (_ path: String, _ onChange: @escaping @MainActor (WorktreeFileVersion?) -> Void) -> () -> Void
  ) -> Self
  // EditorBuffer
  /// A paired host's file: no store, no LSP; `backend` reads, saves and watches it.
  convenience init(hostWorktreeRoot: URL, relativePath: String, backend: EditorRemoteBackend)
  // PeerHostChannel
  public var onFileChanged: (@MainActor (_ worktreeID: String, _ path: String, _ version: WorktreeFileVersion?) -> Void)?
  // NativePeerHosts
  func servesFiles(serverId: String) -> Bool    // worktrees[serverId] != nil, subscribed, supports(worktreesFilesV1)
  /// The version written. A stale version throws RemoteFileAccessError.saveConflict(current == nil ? .deleted : .changed);
  /// any other refusal throws NativePeerReviewGitClientError with the host's message.
  func writeFile(_ path: String, text: String, expected: WorktreeFileVersion?, in worktree: PeerHostWorktree, serverId: String) async throws -> WorktreeFileVersion
  func createFolder(_ path: String, in worktree: PeerHostWorktree, serverId: String) async -> String?   // the error message; nil once done
  /// Calls `onChange` with each version of `path` the host sends, and with nil after a resubscription
  /// (look again), until the returned stop runs. The first follow of a file sends followFile, the last stop unfollowFile.
  func followFile(_ path: String, in worktree: PeerHostWorktree, serverId: String,
                  onChange: @escaping @MainActor (WorktreeFileVersion?) -> Void) -> () -> Void
  /// `.peer` over the three above.
  func hostFileBackend(in worktree: PeerHostWorktree, serverId: String) -> EditorRemoteBackend
  ```
- **The `.peer` closures** share one baseline box, `sshHost: nil`:
  - **`read`:**
    - `.fileContents` with a version sets the baseline and returns `.file(data: Data(text.utf8), mtime: version.modified)`;
    - with no version, `.unreadable("The host sent no version of this file.")`;
    - `.fileUnavailable(.notFound)` is `.missing`, and any other reason is `.unreadable(<NativePeerWorkspace.describe>)`;
    - nil throws `RemoteFileAccessError.connectionFailed(FederatedSessionsProvider.peerUnavailableMessage)`.
  - **`probe`:** `read` again, then:
    - the same `contentHash` refreshes the baseline and is `.unchanged`;
    - missing is `.deleted`;
    - anything else is `.changed`.
  - **`currentMtime`:** `read`'s version `modified`, nil when missing.
  - **`write`:**
    - with `expectedMtime` non-nil, it writes against the baseline;
    - with both nil (Keep mine, Save anyway), it reads the current version (nil when missing) and writes against that;
    - success sets the baseline.
  - **`watch`:** `follow`. A version whose hash equals the baseline's only refreshes the baseline. Anything else calls `observed()`, then `Task { await check() }`. `stop` calls `follow`'s stop.

- [ ] **Step 1: Write the failing tests.** Use an in-memory `FakeHostFile` (text, version, `reads`, `writes: [WorktreeFileVersion?]`, and the follow handler) whose closures feed `.peer`. Use `hostWorktreeRoot: URL(fileURLWithPath: "/srv/repo")`.
  ```swift
  @Test func aHostFileSaveMeetingANewerVersionKeepsTheEditsAndKeepMineResaves() async throws
  // host "a\n" (v1); load; edit to "mine\n"; host becomes "theirs\n" (v2)
  // saveRecordingErrorAwaitingRemote() throws; conflict == .changedOnDisk; storage "mine\n"; host "theirs\n"
  // resolveConflictKeepingMine(); poll until the probe lands; saveRecordingErrorAwaitingRemote()
  //   → host "mine\n", writes.last == v2, dirty == false, conflict == nil
  // edit to "mine 2\n"; save → writes.last == the version the previous save returned

  @Test func aHostChangeWithTheSameContentNeitherReloadsNorConflicts() async throws
  // host "a\n" (v1); load; reads == 1
  // follow handler(v1 with a later modified): reads == 1, conflict == nil
  // edit to "mine\n"; handler(same hash) → conflict == nil
  // handler(hash of "theirs\n") with the host now "theirs\n" → poll until conflict == .changedOnDisk; storage "mine\n"
  ```
- [ ] **Step 2: Implement** the backend, the init, the channel callback and the `NativePeerHosts` API.
- [ ] **Step 3: Verify.** CI: `-only-testing AlasTests/EditorBufferTests`. Local core: `--filter PeerHostChannelTests` still passes.
- [ ] **Step 4: Commit.** `feat(remote): read, save and follow a host's files from a paired Mac`.

### Task 6: Host files open in the editor over the peer center

**Files:**
- Modify `Alas/Sources/Remote/Native/NativePeerSidebarSnapshot.swift` (beside `NativePeerCommitEditorSelection`, `:218`): add `NativePeerHostFile`.
- Modify `Alas/Sources/Remote/Native/NativePeerWorkspace.swift`: add `documentVersion`, set at `:278` and cleared in `beginDocument` (`:140`) and `closeDocument` (`:155`).
- Modify `Alas/Sources/Remote/Native/NativePeerSessions.swift`: host buffers, `openedHostFile`, `hostFileTarget` (beside `hostGitTarget`, `:371`), and save and revert.
- Modify `Alas/Sources/Remote/Native/NativePeerDocumentView.swift`: add `NativePeerHostFileView`.
- Modify `Alas/Sources/App/RootView.swift`:
  - `peerCenterContent` (`:445`) shows `NativePeerHostFileView` ahead of `NativePeerDocumentView` when `client.openedHostFile` is set.
  - The `.alasSaveActiveTab` (`:1313`) and `.alasRevertActiveTab` (`:1329`) handlers act on it first.
- Modify `Alas/Sources/App/AlasApp.swift:150-172`: Save and Revert stay enabled while a host file is open.
- Modify `Alas/Sources/App/AppState.swift:9890`: add `hasOpenPeerHostFile`.
- Modify `Alas/Sources/Center/TabsManager.swift` (after `buffer(…)`, `:2427`): add `adoptBuffer`/`releaseAdoptedBuffer`.
- Modify `Alas/Sources/Center/EditorTabView.swift`: add `peerHostFile`.

**Interfaces:**
- Consumes Task 5.
- Produces:
  ```swift
  /// Equal and hashed by server, worktree id and path only (by hand: `PeerHostWorktree` is only
  /// Equatable), so a refreshed host snapshot neither re-keys the buffer nor re-ids the view.
  struct NativePeerHostFile: Hashable {
      let serverId: String
      let worktree: PeerHostWorktree
      let path: String
      /// Namespaced so a host path that also exists on this Mac never shares a local worktree's stores.
      var editorWorktreeID: String { "peer:\(serverId):\(worktree.snapshot.worktree.id)" }
      var tabID: TabID { "peer-file:\(serverId):\(worktree.snapshot.worktree.id):\(path)" }
  }
  // NativePeerWorkspace
  private(set) var documentVersion: WorktreeFileVersion?
  // NativePeerSessions
  /// The selected worktree on a host that edits its files: folder projects included, archived ones not.
  var hostFileTarget: (serverId: String, worktree: PeerHostWorktree)? { get }
  /// The open `.file` document, once the host served it as text with a version, on `hostFileTarget`.
  var openedHostFile: NativePeerHostFile? { get }
  /// Created on first use, watching; kept while dirty after its view closes.
  func hostFileBuffer(for file: NativePeerHostFile) -> EditorBuffer      // @ObservationIgnored storage
  /// Closes and forgets `file`'s buffer unless it is dirty.
  func releaseHostFileBuffer(_ file: NativePeerHostFile)
  func saveOpenedHostFile()       // Task { try? await buffer.saveRecordingErrorAwaitingRemote() }
  func revertOpenedHostFile()     // buffer.revert()
  // AppState
  var hasOpenPeerHostFile: Bool { get }   // nativePeerSessions?.openedHostFile != nil
  // TabsManager
  /// Serves `buffer` for `tabId` from `buffer(worktreeId:tabId:…)`, as the editor views ask; no key, store or LSP.
  func adoptBuffer(_ buffer: EditorBuffer, tabId: TabID)
  func releaseAdoptedBuffer(tabId: TabID)
  // EditorTabView
  var peerHostFile: Bool = false
  ```
- **`NativePeerHostFileView(file:client:state:)`:**
  - On appear, it takes `client.hostFileBuffer(for:)` into `@State`, then calls `state.tabs.adoptBuffer(_, tabId: file.tabID)` and shows `EditorTabView`, with:
    - `worktree: file.worktree.snapshot.worktree`;
    - `worktreePath: URL(fileURLWithPath: file.worktree.snapshot.worktree.path.path)`;
    - `worktreeId: file.editorWorktreeID`, `tabId: file.tabID`;
    - `peerHostFile: true`, with no reveal and nil external.
  - On disappear, it calls `releaseAdoptedBuffer` and `client.releaseHostFileBuffer`.
  - Its header's close button calls `client.closeDocument()`.
  - It's keyed `.id(file)`.
- **`peerHostFile`** turns off whatever reads or writes this Mac's disk, or needs LSP:
  - the breadcrumb's View at HEAD, Compare, File History, Reveal in Finder and Open With;
  - `statusBadge`, `runScriptScope` (nil), and the install and blocked nudges;
  - `WorkspaceEditRecoveryView` and `EditorNavigationResultsView`.

  `handleFindRequest`'s active-tab guard passes, since only one editor shows in the peer center. The conflict banner, find/replace, minimap and `CodeEditorView` stay.
- **Buffers** are keyed by `NativePeerHostFile` and built from `hosts.hostFileBackend(in:serverId:)` with `startWatching()`.
  - A clean buffer is closed on release, which stops its follow.
  - A dirty one stays, still following, and reopening the file shows its edits.
  - `// ponytail:` dirty host buffers live until the app quits, with no hot-exit (a spec non-goal).
- **Save and Revert.** `RootView`'s handlers act on `client.openedHostFile` first, and otherwise do today's local save or revert.

- [ ] **Step 1: Implement.** No new test: these are views and wiring over Task 5, which pins the buffer's decisions.
- [ ] **Step 2: Verify.** CI's app build plus `-only-testing AlasTests/NativePeerWorkspaceTests -only-testing AlasTests/NativePeerSessionsTests -only-testing AlasTests/EditorBufferTests`. By hand, against a headless host:
  - Open a text file, edit, and press ⌘S: the host file changes.
  - Edit on the host while the file is clean: it reloads.
  - Edit on the host while dirty: the banner shows. Keep mine, then save.
  - `touch` the file on the host: no banner.
  - A binary or 600 KB file stays in the read-only document view.
  - An older host keeps the read-only view.
- [ ] **Step 3: Commit.** `feat(remote): edit a host worktree's files in the editor from a paired Mac`.

### Task 7: New File and New Folder in the peer tree; refuse a restore over unsaved host edits

**Files:**
- Modify `Alas/Sources/Right/FileContextMenuActions.swift:59`: `readOnlyFile` gains `createsItems`.
- Modify `Alas/Sources/Right/FilesTabView.swift` (`:41`, `:106`, `:115-133`) and `Alas/Sources/Right/FileTreeListView.swift` (`:25`, `:268`, and its `FileTreeContext`): add `createsOnPeer`.
- Modify `Alas/Sources/Right/NativePeerRightPaneView.swift`:
  - `filesTab` (`:1016-1025`) wires creation;
  - `restoreCheckpoint` (`:937`) refuses over dirty host buffers.
- Modify `Alas/Sources/App/AppState.swift:8692`: `promptForChildName` goes from `private` to internal.
- Modify `NativePeerSessions.swift`: add `unsavedHostFilePaths` and `restoreRefusal`.
- Test `AlasTests/FileContextMenuActionsTests.swift:112`.

**Interfaces:**
- Consumes Tasks 5–6.
- Produces:
  ```swift
  // FileContextMenuConfiguration
  /// With `createsItems`, a directory also offers New File and New Folder, still with no local actions.
  static func readOnlyFile(kind: FileTreeNode.Kind, createsItems: Bool = false) -> Self
  // FilesTabView, FileTreeContext
  var createsOnPeer: Bool = false     // read-only menus plus creation; the root menu offers only New File and New Folder
  // NativePeerSessions
  /// Dirty host buffers of `worktreeID` on `serverId`, by path, sorted.
  func unsavedHostFilePaths(serverId: String, worktreeID: String) -> [String]
  /// "Save or discard unsaved edits to <paths> before restoring.", or nil when `paths` is empty.
  static func restoreRefusal(unsavedPaths paths: [String]) -> String?
  ```
- **The Files tab** sets `createsOnPeer` when `client.hostFileTarget` is set.
  - `onCreateFile(dir)` asks `state.promptForChildName(title: "New File", defaultValue: "untitled.txt")` and builds the path with `AppState.childPath`.
    - `hosts.writeFile(path, text: "", expected: nil, …)` creates the file.
    - On success, it calls `client.loadFileTreeChildren(path: dir)` (or `reloadWorkspace()` for the root), then `client.open(.file(path:))`.
    - A `saveConflict` shows `"<path> already exists on the host."`. Any other error shows its message. Both use `state.showFileActionError(title: "New File Failed", …)`.
  - `onCreateFolder` works the same way with `"New Folder"`/`"New Folder"`, `hosts.createFolder`, and `"New Folder Failed"`.
- **`restoreCheckpoint`**, before sending, checks `NativePeerSessions.restoreRefusal(unsavedPaths: client.unsavedHostFilePaths(serverId:worktreeID:))`. When that's non-nil, it becomes `checkpointRestoreError` and nothing is sent. This covers the card and the transcript's "Restore files to before this request", which both end there.

- [ ] **Step 1: Extend the test.**
  ```swift
  @Test(arguments: [FileTreeNode.Kind.file, .dir], [false, true])
  func readOnlyTargetsOfferNoLocalOrWriteActions(kind: FileTreeNode.Kind, createsItems: Bool)
  // localURL == nil
  // file: [.openInAlas, .copyRelativePath, .copyFullPath]
  // dir: createsItems ? [.newFile, .newFolder, .copyRelativePath, .copyFullPath] : [.copyRelativePath, .copyFullPath]
  ```
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify.** CI: `-only-testing AlasTests/FileContextMenuActionsTests` plus the app build. By hand:
  - New File in a subfolder opens it in the editor.
  - New Folder shows in the tree.
  - A name that exists is refused.
  - With a dirty host file, Restore is refused, naming it. After saving, the restore goes ahead.
- [ ] **Step 4: Commit.** `feat(remote): create files and folders on a host, and keep a restore off unsaved host edits`.

## Self-review

- **Spec coverage.**
  - Goal 1 (the local editor for host text files; binary, non-UTF-8, symlinked and over-cap stay read-only): Tasks 1, 5 and 6. The editor opens only for a host-served text read with a version. Everything else stays in today's read-only document view, and the host already refuses symlinked and over-cap reads.
  - Goal 2 (CAS on every save, the banner, Keep mine re-saves against the new version): Tasks 2 and 5.
  - Goal 3 (outside changes, deletes): Tasks 3 and 5.
  - Goal 4 (New File and New Folder; a new file opens): Task 7.
  - Goal 5 (gated saves, shown in the editor): Task 2's entry point. Refusals land in `lastSaveError`, which `EditorConflictBanner` shows.
  - Goal 6 (capability, older peers): `worktreesFilesV1` in `headlessOnly`, opt-in `fileChanged`, the lossy `version`, and `servesFiles`.
  - Non-goals: no LSP (no `lsp`, so no badge), no Save As, move or delete (`remoteBackend != nil` throws, as for SSH), no hot-exit (no store).
  - Anti-goals: no silent overwrite (hash CAS); no write outside, under `.git` or through a symlink (Task 2's rules and tests); local and SSH unchanged (Task 4); capped payloads (Task 2).
  - Builder decisions: no branch check, folder projects, hash over mtime (Tasks 2, 3 and 5), and the own-restore refusal (Task 7).
- **Spec conflicts, ruled:**
  - **Goal 5 says a save is refused when the listed branch no longer matches.** The builder-check decision drops the branch check, so saves work mid-rebase. The later, explicit decision wins: there's no branch check, and `aFileIsSavedMidRebaseWhileTheListingLags` pins it.
  - **Decisions says writes run through `mutateListedWorktree`.** The builder check gives them their own entry point (`changeListedFiles`) with the same checks minus the branch, plus the restore hold. The later decision wins.
  - **New File and New Folder are "host changes through the same gate".** They use `changeListedFiles`, not `HostWorktreeChange`, which carries a branch. New File is `writeFile(text: "", expected: nil)`, with no separate create request.
  - **"The read reply gains an optional version".** It's added to `fileContents` itself, so session reads and phones get it too. That's harmless, and it keeps one read path. The version is a struct (`WorktreeFileVersion`) in AlasPlatform, beside the read that computes it.
  - **"The usual unsaved-changes prompt on close".** A local editor tab closes without a prompt and relies on hot-exit, so there is no usual prompt to reuse. Instead, closing a dirty host file's view keeps its buffer (still following), and reopening shows the edits. The restore refusal names such files. Quitting loses them, which is the spec's no-hot-exit non-goal.
  - **The host sends `fileChanged` only when the hash or the file's existence changes.** The Mac also ignores equal hashes. So a touch never reaches the editor, matching "a fileChanged for an unchanged hash doesn't reload or conflict".
- **Where the plan departs because of the code:**
  - **The seam speaks SSH's vocabulary** (`RemoteReadResult`, mtime `Date`s, `RemoteFileAccessError.saveConflict`). The peer backend keeps the hash baseline in its own closures. That way Task 4 is a pure move, and the buffer's save, rollback and conflict code serves both unchanged.
  - **The peer editor is the local `EditorTabView`,** fed by adopting the buffer into `TabsManager`, because `CodeEditorView` and its coordinator look buffers up there. `peerHostFile` hides what assumes a local disk or LSP. A namespaced `editorWorktreeID` keeps a coincident local path's stores apart.
  - **The own-restore refusal covers any dirty host buffer in the worktree,** not only those overlapping the selected groups as locally. The Mac doesn't map preview groups to paths, and the stricter rule is the safe one.
  - **The capability refusal reuses `servedWorktree`'s "This host does not serve this git action."** It needs no new helper, and only an outdated client sees it.
  - **SSH remote projects on a host get no version and refuse writes.** The host can't write their disk atomically from here, and the spec doesn't cover them.
- **Type consistency.** These names are used the same way in every task:
  - `WorktreeFileVersion(contentHash:modified:)`, `.contentHash(of:)`, `FileVersionProbe`, `probeVersion`, `readVersionedFileContents` and `replaceAtomically`;
  - `worktreesFilesV1`, `writeFile`, `createFolder`, `followFile`, `unfollowFile`, `fileWritten`, `HostError.fileChanged(current:)` and `HostEvent.fileChanged(worktreeID:path:version:)`;
  - `changeListedFiles`, `writeListedFile`, `createListedFolder`, `writableURL` and `HostFileWatcher.watches`;
  - `EditorRemoteBackend` (`.ssh`, `.peer`, `sshHost`), `EditorRemoteProbe`, `EditorRemoteWatch` and `remoteBackend`/`remoteHost`/`remoteWatch`;
  - `NativePeerHostFile` (`editorWorktreeID`, `tabID`), `openedHostFile`, `hostFileTarget`, `hostFileBuffer(for:)`, `releaseHostFileBuffer`, `adoptBuffer`/`releaseAdoptedBuffer`, `peerHostFile` and `createsOnPeer`;
  - `servesFiles`, `hostFileBackend(in:serverId:)`, `unsavedHostFilePaths` and `restoreRefusal(unsavedPaths:)`.
