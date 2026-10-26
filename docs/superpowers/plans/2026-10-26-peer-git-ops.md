# Peer Git Ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac paired with a headless `alas-host` can stash, cherry-pick, revert, edit commits and use checkpoints on the host's worktrees, see and leave an in-progress operation, and resolve conflicts, with the host running git as it does for stage, commit and push today.

**Architecture:**
- **Host side.** Every new change is a new `HostWorktreeChange` case, so it goes through `mutateListedWorktree` and keeps its gate and refusals. Reads that answer more than a Remote session message are their own `HostRequest` cases.
  - The Mac names only stash refs plus shas, commit shas, literal in-worktree paths and checkpoint ids. The host checks each against git or its store before git sees it.
  - `apply` now returns a `HostResponse`, so an edit or a checkpoint create can answer with its result. Everything else still answers `.done`.
  - The changes reply carries the in-progress `MergeOperation`, so the Mac shows the operation card without another read.
  - A rebase in progress passes the branch gate only for the six changes that leave or resolve it.
- **Checkpoints.** `WorktreeCheckpointService` moves from the app into AlasFeatures unchanged in behaviour (PR 4). The host then owns one instance, takes an automatic checkpoint before each host prompt, and serves list, manifest, diff, create, delete, preview and restore (PR 5).
- **Mac side.** The peer right pane reuses the local rows, sheets and cards (`StashSummaryRow`, `StashChangesSheet`, `OperationCard`, `ConflictsSection`, `CheckpointCard`, `CreateCheckpointSheet`, `RestoreCheckpointSheet`). The local commit editor tab gets a small `CommitEditorGit` seam, so the peer feeds it from host reads.

**Tech Stack:** Swift 6 / SwiftUI app, `Packages/AlasCore` SwiftPM (UI-free), Swift Testing, real git in temp dirs.

**Spec:** `docs/superpowers/specs/2026-10-26-peer-git-ops-design.md`. Its "Decisions" and "Decisions from the builder check" sections bind; where this plan departs because of the code, the Self-review says so.

**PR split** (land in order; each PR's Mac task is the only sender of its new requests):
- **PR 1 — stash** (Tasks 1–2). Capability `host.worktrees.stash.v1`.
- **PR 2 — operations and conflicts, then cherry-pick and revert** (Tasks 3–6). Capability `host.worktrees.operations.v1`.
- **PR 3 — edit commit** (Tasks 7–8). Capability `host.worktrees.commitEdit.v1`.
- **PR 4 — checkpoint refactor** (Task 9). No wire change.
- **PR 5 — checkpoints on the host** (Tasks 10–13). Capability `host.worktrees.checkpoints.v1`.

## Global Constraints

- AGENTS.md (origin/main):
  - Swift Testing only, with minimal, sharp tests. Don't test views or wiring.
  - Core imports no SwiftUI, AppKit, GhosttyKit, MLX, TreeSitterPack or FffC.
  - Anything the app or tests use from core is `public`. Public cross-module types are explicitly `Sendable`.
  - Conventional Commits, with no attribution trailers or footers.
- Core tests: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`. Check the `Test run with N tests` line: N > 0.
- **Git stays real** in temp dirs, built from `GitTemplate` copies (`repository(at:)`, `repositoryAheadOfOrigin(at:)`). No git fakes.
- **Never the real profile.** Every `AlasCoreContext` a test builds passes temp `reviewDrafts`, `reviewSessions` and, from Task 10, `checkpoints: WorktreeCheckpointService(store: .init(root: <tmp>))`.
- **Never a fixed `Task.sleep`.** Wait with `eventually { … }` (`TestSupport/Eventually.swift`).
- The app can't be built locally, so CI is its first build.
  - Keep `Alas/` edits close to the existing local UI, and add no new files under `Alas/` or `AlasTests/`.
  - Task 9 deletes `Alas/Sources/Checkpoints/WorktreeCheckpointService.swift`, so it runs `xcodegen` and commits `Alas.xcodeproj`.
  - Say in each PR body which app tests ran on CI only.
- **Headless only.** The four capabilities are served only where `environment.servesWorktreeGit`, as `host.worktrees.git.v1` is. They join a new `HostProtocolCapability.headlessOnly` list.
- **Trust boundary.** The host checks everything the Mac names before git sees it:
  - A stash is a `(ref, sha)` pair equal to an entry of `git stash list`.
  - A commit is a hex SHA (`RemoteWorktreeFileAccess.isCommitSHA`) that `rev-parse --verify --quiet <sha>^{commit}` resolves in this repository.
  - A path is literal and inside the worktree (`refuseOutside`, under `Process.$gitLiteralPathspecs`).
  - A checkpoint id is in the catalog of the worktree's own lineage.
- **No change to local behaviour or storage.** The only intended local difference is in PR 4's image decoding, explained in the Self-review.
- Copy (verbatim):
  - Host errors:
    - `"This host does not serve this git action."` (a capability the host lacks)
    - `"This stash changed since it was listed. Refresh and try again."`
    - `"The stash has no file <path>."`
    - `"A commit is named by its SHA."`, and `notFound(what: "commit <sha>")`
    - `"The operation on the host changed; refresh and try again."`
    - `"This commit changed since it was shown. Refresh and try again."`
    - `"A checkpoint needs a name."`
    - `"Checkpoints are not available for this worktree."`
    - `notFound(what: "checkpoint <uuid>")`
    - `"Refresh the restore preview before trying again."` (the local stale-preview copy, now shared)
    - Restore blockers: `CheckpointRestoreBlocker.description`, e.g. `"Stop active terminal and agent sessions before restoring."`
  - Host diff notes: `"Binary files cannot be shown."` and `"Image changes are not shown from a host."`
  - Mac, reused from local:
    - Stash: `"Stash Changes…"`, `PendingStashDrop.alertTitle` / `alertMessage`.
    - Cherry-pick: `"Cherry-pick commit?"`, `"Cherry-pick <sha7>"`, `"Apply this commit to the current branch."`.
    - Revert: `"Revert Commit…"`, `"Revert commit?"`, `"Revert <sha7>"`, `"Create a new commit that reverses this commit."`.
    - `"Edit Commit…"`, `"Create Checkpoint…"`.
    - Checkpoint delete: `"Delete checkpoint <label>?"`, `"This removes the checkpoint only. Your worktree is unchanged."`.
    - Transcript: `"Restore files to before this request"`.

## Review Focus

1. **The listing lags the host's HEAD during a rebase.** The Mac still shows `main` while git is detached mid-rebase. Continue, Skip, Abort and the conflict changes must pass; every other change must still be refused as changed. Tested by Task 4, `aRebaseStoppedOnConflictsIsLeftFromTheMac` and `onlyTheWayOutPassesTheGateDuringARebase`.
2. **The operation moved under the Mac.** The cherry-pick finished, or a rebase started on the host, after the Mac drew the card. A Continue or Abort aimed at the old kind must not act on the new one. Tested by Task 4, `onlyTheWayOutPassesTheGateDuringARebase` (the wrong-kind case).
3. **A session-selected changes read goes through federation.** The operation must survive `replacingSessionId`, or a Mac with a session selected never sees the card. Tested by Task 3, `aChangeListCarriesTheHostsOperation`.
4. **A truncated commit diff on the Mac.** Dropping a hunk the Mac only partly showed would drop more than the user saw. The Mac disables Drop Hunk when the diff was cut. The host refuses a hunk whose header differs from git's. Tested by Task 7, `commitEditsTakeOnlyWhatTheMacSaw`.
5. **A stash list that moved between list and click.** Another worktree pushed a stash, so `stash@{0}` now names a different entry. Apply, pop, drop, files and diff must refuse rather than act on it. Tested by Task 1, `stashActionsActOnlyOnTheStashTheMacSaw`.

---

## PR 1 — stash

### Task 1: Host stash reads and changes

**Files:**
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`:
  - `HostRequest` (`:46-157`): add the three reads after `publishReview`.
  - `HostWorktreeChange` (`:161-165`): add the four stash cases, and a `capability` property.
  - `HostResponse` (`:361-400`): add `.stashes`, `.stashFiles` and `.diff` before `failure`.
  - Add `HostStashRef` and `HostDiff` after `HostProviderReview` (`:248`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift:1463-1508`: add `worktreesStashV1` and `headlessOnly`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift`:
  - `servedCapabilities` (`:36-42`) becomes `served + (servesWorktreeGit ? headlessOnly : [])`.
  - `WorktreesAPI.mutate` (`:378`) returns `HostResponse`, marked `@discardableResult`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeGit.swift`:
  - `mutateListedWorktree` (`:11`) and `apply` (`:39`) return `HostResponse`.
  - Add the stash cases and the stash reads.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasCoreContext+RemoteInspection.swift:230`: `remoteDiffHunk` goes from `private` to internal, for `HostDiff`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift`:
  - Dispatch the reads after `publishReview`.
  - `.mutateWorktree` (`:346`) checks `change.capability` and returns `mutate`'s response.
  - Add `servedWorktree(_:capability:)` next to `gitWorktree` (`:471`).
- Test `HostProtocolServerTests`, `HostProtocolTests`, and `HostSessionsTests:495`.

**Interfaces:**
- Produces (wire types `public`, `Codable, Equatable, Sendable`):
  ```swift
  // HostProtocolCapability
  public static let worktreesStashV1 = "host.worktrees.stash.v1"   // listStashes, stashFiles, stashDiff and the stash changes
  /// What only a headless host serves; Tasks 3, 7 and 10 append theirs.
  public static let headlessOnly = [worktreesGitV1, reviewsV1, reviewsProviderV1, worktreesStashV1]
  // HostRequest
  case listStashes(worktree: WorktreeRef)                                    // the repo-wide list, as locally
  case stashFiles(worktree: WorktreeRef, stash: HostStashRef)
  case stashDiff(worktree: WorktreeRef, stash: HostStashRef, path: String)
  // HostWorktreeChange
  case stash(message: String, includeUntracked: Bool)
  case applyStash(HostStashRef), popStash(HostStashRef), dropStash(HostStashRef)
  /// The capability beyond host.worktrees.git.v1 a change needs; nil for the original seven.
  public var capability: String? { get }
  // HostResponse
  case stashes(stashes: [GitStash])
  case stashFiles(files: [GitStashFile])
  case diff(diff: HostDiff)                                                  // stashDiff; Task 10's checkpointDiff
  public struct HostStashRef { public var ref: String; public var sha: String }   // + init(_ stash: GitStash)
  public struct HostDiff {
      public var hunks: [RemoteDiffHunk]
      public var truncated: Bool
      public var note: String?          // a metadata summary or why there are no hunks
      /// Capped as a commit diff is (`RemoteWorktreeFileAccess.truncateHunks`); a binary diff
      /// has no hunks and the note "Binary files cannot be shown."
      public init(_ diff: ParsedDiff)
      public init(hunks: [RemoteDiffHunk], truncated: Bool, note: String?)
  }
  // AlasCoreContext (+WorktreeGit), internal
  func mutateListedWorktree(_ worktree: Worktree, branch: String, change: HostWorktreeChange) async throws -> HostResponse
  func stashes(in worktree: Worktree) async throws -> [GitStash]
  func stashFiles(_ stash: HostStashRef, in worktree: Worktree) async throws -> [GitStashFile]
  func stashDiff(_ stash: HostStashRef, path: String, in worktree: Worktree) async throws -> HostDiff
  /// The entry of `git stash list` equal to `stash`, else "This stash changed since it was listed. Refresh and try again."
  private static func listedStash(_ stash: HostStashRef, at root: URL) async throws -> GitStash
  ```
- `servedWorktree(ref, capability:)` throws `invalidRequest("This host does not serve this git action.")` unless the capability is served, then returns `visibleWorktree(ref)`.
  - The three reads use it with `worktreesStashV1`.
  - `.mutateWorktree` uses it with `change.capability`, after `gitWorktree`.
- The stash cases in `apply`:
  - `.stash` runs `pushStash`.
  - The others run `applyStash`, `popStash` or `dropStash` on `listedStash(ref)`.
  - A `StashOperationResult` of `.conflict(m)` or `.error(m)` throws `failed(message: m)`, as locally the sidebar shows it. The conflicted files stay in the worktree.
- `stashDiff` finds `path` among `stashFiles` (`.path` equal), else `invalidRequest("The stash has no file <path>.")`. It answers `HostDiff(git.stashDiff(...))`.
- Reads run outside the gate, as `readWorktree` does. They only read.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  // HostProtocolServerTests
  @Test func aMacStashesAndPopsAHostWorktreesChanges() async throws
  // main worktree; write new.txt; .mutateWorktree(.stash(message: "wip", includeUntracked: true)) == .done
  // status --porcelain == ""; .listStashes → .stashes(s) with s.map(\.subject) == ["On main: wip"]
  // .stashFiles(HostStashRef(s[0])) → .stashFiles(f) with f.map(\.path) == ["new.txt"], f[0].isUntracked
  // .stashDiff(…, path: "new.txt") → .diff(d) with d.hunks.count == 1
  // .popStash(HostStashRef(s[0])) == .done; new.txt exists; .listStashes == .stashes(stashes: [])

  enum StaleStash: CaseIterable { case otherSHA, unlistedRef, optionRef, missingFile }
  @Test(arguments: StaleStash.allCases)
  func stashActionsActOnlyOnTheStashTheMacSaw(_ stale: StaleStash) async throws
  // one stash S. otherSHA: ref S.ref, sha of HEAD; unlistedRef: "stash@{3}", S.sha; optionRef: "--index", S.sha
  // → .dropStash, .applyStash and .stashFiles each answer
  //   .failure(.failed(message: "This stash changed since it was listed. Refresh and try again."))
  // missingFile: .stashDiff(S, path: "nope.txt") → .failure(.invalidRequest(reason: "The stash has no file nope.txt."))
  // afterwards `git stash list` is unchanged

  @Test func aConflictingStashPopKeepsTheStashAndShowsTheConflict() async throws
  // stash a change to .alas/scripts/hello.sh, commit a conflicting change to it, .popStash(S)
  //   → .failure(.failed(message:)) whose message contains "CONFLICT"
  // the stash is still listed; remoteRead(.changes) lists hello.sh with conflict != nil

  // extend gitActionsAreRefused(.appHost): .listStashes → .failure(.invalidRequest(reason: "This host does not serve this git action."))
  ```
- [ ] **Step 2: Run and confirm they fail.** `--filter HostProtocolServerTests`. Expected: compile errors for `listStashes`.
- [ ] **Step 3: Implement** the wire types, capability, `apply` returning `HostResponse`, the stash cases, the reads and the dispatch. Log with `caller.log("worktrees.mutate", path)` as today.
- [ ] **Step 4: Update the round trips and capability tests.**
  - Add `listStashes`, `stashDiff`, `mutateWorktree(… .applyStash(…))`, `.stashes` and `.diff` to `clientMessagesRoundTrip` and `serverMessagesRoundTrip`.
  - In `helloAdvertisesExactlyTheConsoleCapabilitiesItServes` (`:224`), replace the three `!caps.contains` lines with `#expect(Set(caps).isDisjoint(with: HostProtocolCapability.headlessOnly))`.
  - `HostSessionsTests:495` expects `HostProtocolCapability.served + HostProtocolCapability.headlessOnly`.
- [ ] **Step 5: Run and confirm everything passes.** `--filter HostProtocolServerTests`, `--filter HostProtocolTests`, `--filter HostSessionsTests`.
- [ ] **Step 6: Commit.** `feat(alas-host): stash a worktree's changes for paired Macs`.

### Task 2: Stashes on the Mac

**Files:**
- Modify `Alas/Sources/Remote/Native/NativePeerHosts.swift`:
  - Add `servesStash` and the reads after `reviewStatus` (`:261`).
  - Add `change` beside `mutate` (`:236`); `mutate` becomes a wrapper over it.
- Modify `Alas/Sources/Remote/Native/NativePeerWorkspace.swift`:
  - `Document` (`:30`) gains `.stashDiff`.
  - Add `finishDocument`.
- Modify `Alas/Sources/Remote/Native/NativePeerSessions.swift`: `open(_:)` (`:1084`) serves `.stashDiff` over the host channel.
- Modify `Alas/Sources/Remote/Native/NativePeerDocumentView.swift`: `badge` (`:28`) shows `"stash"`.
- Modify `Alas/Sources/Right/NativePeerChangesView.swift`:
  - `Git` (`:8`) gains the stash closures.
  - Add the Stashes section after `commitSection`, and the "Stash Changes…" header item.
- Modify `Alas/Sources/Right/NativePeerRightPaneView.swift`:
  - Stash state, reads and actions.
  - The drop alert next to the discard alert (`:91`).
  - The `StashChangesSheet` sheet.

**Interfaces:**
- Consumes Task 1's wire types.
- Produces:
  ```swift
  // NativePeerHosts
  func servesStash(serverId: String) -> Bool        // servesGit && supports(worktreesStashV1)
  /// The reply to `change`, or the error message to show.
  func change(_ change: HostWorktreeChange, in: PeerHostWorktree, serverId: String) async -> Result<HostResponse, String>
  func stashes(in: PeerHostWorktree, serverId: String) async -> [GitStash]?             // nil: refused or no answer
  func stashFiles(_ stash: GitStash, in: PeerHostWorktree, serverId: String) async -> Result<[GitStashFile], String>
  func stashDiff(_ stash: GitStash, path: String, in: PeerHostWorktree, serverId: String) async -> Result<HostDiff, String>
  // NativePeerWorkspace
  case stashDiff(path: String, stash: GitStash)     // Document
  /// Lands a host-served diff for `document` if it is still the open one.
  mutating func finishDocument(_ document: Document, with result: Result<HostDiff, String>)
  // NativePeerChangesView.Git
  let stashes: [GitStash]?                           // nil hides the section and the menu item
  let stashFiles: [String: Load<[GitStashFile]>]     // by ref
  let onStashChanges: () -> Void, onToggleStash: (GitStash) -> Void
  let onApplyStash: (GitStash) -> Void, onPopStash: (GitStash) -> Void, onDropStash: (GitStash) -> Void
  ```
- The Stashes section mirrors the local one (`ChangesTabView.swift:882-915`):
  - A `SectionHeader(role: .stashes, title: "Stashes")`.
  - `StashSummaryRow` per stash; an open stash lists `StashFileRow`s, or `StashEmptyRow`.
  - A file row opens `.stashDiff(path:stash:)`.
- The right pane:
  - Re-reads stashes on `.onChange(of: client.workspace.changes)` and after each stash change. Expanded files are dropped for a ref whose sha changed, as `reconcileStashCaches` does.
  - "Stash Changes…" shows `StashChangesSheet`. Its `onStash` runs `runGit(.stash(message:includeUntracked:))`.
  - Apply and Pop run `runGit` with no confirmation.
  - Drop sets `pendingStashDrop`. The alert uses `PendingStashDrop.alertTitle` and `alertMessage`, with `"Drop"` (destructive) and `"Cancel"`.
- `NativePeerHosts.mutate` keeps its signature, mapping `.success` to nil.

- [ ] **Step 1: Implement.** No new test: this is view wiring over Task 1, and views are excluded by policy.
- [ ] **Step 2: Verify.** CI's app build plus `-only-testing AlasTests/NativePeerWorkspaceTests`. By hand, against a headless host:
  - Stash with a message and untracked files.
  - Open a stash file's diff.
  - Pop it, and drop another (confirmed).
  - An older host shows no Stashes section.
- [ ] **Step 3: Commit.** `feat(remote): stash a host worktree's changes from a paired Mac`.

## PR 2 — operations and conflicts, then cherry-pick and revert

### Task 3: The changes reply carries the in-progress operation

**Files:**
- Modify `Packages/AlasCore/Sources/AlasModel/Model/GitTypes.swift:281-326`: add `Codable` to `MergeOperation`, `RebasePlan`, `RebasePlanCommit` and `RebasePlanCommit.State` (synthesized, in the declarations).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift`:
  - The `.changeList` case (`:881`) gains `operation`.
  - Add an `operation` coding key, and decode (`:1094`) and encode (`:1354`) it with `IfPresent`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteMessageWireJSON.swift:868`: `RemoteChangeListResult.success` gains `operation`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasCoreContext+RemoteInspection.swift:289-337`: `remoteChangeList` reads `git.mergeState`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteGatewayHostCalls.swift:146-155`: pass it through.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Federation/RemoteMessageSessionScope.swift:112,168-173`: keep it when rescoping.
- Modify `Alas/Sources/Remote/Native/NativePeerWorkspace.swift`:
  - `Changes` (`:14`) gains `operation`.
  - `apply` (`:173`) and the review loader's match (`:378`) take the new arity.
- Modify the app tests that build `.changeList` positionally: `AlasTests/Remote/RemoteMessageSessionScopeTests.swift:78` and any `case .changeList(…)` pattern that `xcodebuild` flags.
- Test `HostProtocolTests`.

**Interfaces:**
- Produces:
  ```swift
  // RemoteServerMessage
  case changeList(…, workingTreeTruncated: Bool? = nil, operation: MergeOperation? = nil)   // nil from older hosts and with none
  // RemoteChangeListResult
  case success(…, workingTreeTruncated: Bool? = nil, operation: MergeOperation? = nil)
  // NativePeerWorkspace.Changes
  var operation: MergeOperation?
  ```
- Every host fills it: it's a read, and a client without the operations capability ignores it.
- A folder project and a failed `mergeState` answer nil. A mergeState failure doesn't fail the list.

- [ ] **Step 1: Write the failing test.**
  ```swift
  // HostProtocolTests
  @Test func aChangeListCarriesTheHostsOperation() throws
  // op = .rebase(plan: RebasePlan(ontoBranch: "abc", sourceBranch: "main", commits: [.init(sha: "d1", summary: "s", state: .current)]))
  // a changeList with operation: op round-trips through RemoteServerMessage JSON; .replacingSessionId("b") keeps op
  // the same JSON with the "operation" key removed decodes with operation == nil
  ```
- [ ] **Step 2: Run and confirm it fails.** `--filter HostProtocolTests`. Expected: compile error for `operation:`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm it passes.** `--filter HostProtocolTests`, `--filter HostProtocolServerTests` (`worktreeReadsAnswerWithTheSessionReplyKeyedByTheWorktree` still passes). App: CI runs `-only-testing AlasTests/RemoteMessageSessionScopeTests -only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/NativePeerWorkspaceTests`.
- [ ] **Step 5: Commit.** `feat(remote): send a worktree's in-progress git operation with its changes`.

### Task 4: Continue, skip, abort and resolve conflicts, through the rebase gate

**Files:**
- Modify `HostProtocol.swift`: the operation and conflict cases on `HostWorktreeChange`, and `HostOperationKind`.
- Modify `RemoteProtocol.swift`: `worktreesOperationsV1`, appended to `headlessOnly`.
- Modify `AlasCoreContext+WorktreeGit.swift`:
  - The gate exception at `:29-30`.
  - The new cases in `apply`. Commit, push and pull keep the `mergeState` refusal (`:43-46`).
- Test `HostProtocolServerTests`.

**Interfaces:**
- Produces:
  ```swift
  public static let worktreesOperationsV1 = "host.worktrees.operations.v1"
  public enum HostOperationKind: String, Codable, Sendable {
      case merge, rebase, cherryPick, revert
      public init(_ operation: MergeOperation)
  }
  // HostWorktreeChange; capability worktreesOperationsV1
  case continueOperation(kind: HostOperationKind), skipOperation(kind: HostOperationKind), abortOperation(kind: HostOperationKind)
  case useOurs(path: String), useTheirs(path: String), keepDeleted(path: String), markResolved(path: String)
  /// The changes that leave or resolve an operation: the rebase gate lets only these through.
  public var leavesAnOperation: Bool { get }
  ```
- **The gate.** After `listed.branch == branch`, when git's branch (`"(detached)"` if empty) differs from `branch`, the change still passes when all of these hold:
  - `change.leavesAnOperation`;
  - git's branch is empty (detached);
  - `mergeState` is `.rebase(plan)` with `plan.sourceBranch == branch`.

  Otherwise it throws today's `"The worktree changed since it was listed."`.
- **`apply`:**
  - `continueOperation`, `skipOperation` and `abortOperation` read `mergeState`. Nil, or a `HostOperationKind` other than `kind`, throws `failed("The operation on the host changed; refresh and try again.")`.
  - They then run `continueOperation`, `skipOperation` or `abortOperation`. A `MergeResult` of `.clean` or `.conflict` answers `.done`: the next changes read shows the card and conflicts. `.error(m)` throws `failed(m)`.
  - The four path cases run `refuseOutside([path])`, then git, as `RightPaneState` does (`:4521-4573`):
    - `useOurs` and `useTheirs` stage with `markResolved` afterwards;
    - `keepDeleted` runs `git rm`;
    - `markResolved` runs `git add`.

- [ ] **Step 1: Write the failing tests.** Factor the conflicting-pull setup of `pullStoppedOnConflictsSaysToResolveOnTheHost` (`:753`) into `RepoFixture.stopPullOnConflicts() async throws -> (URL, WorktreeRef)`. The worktree stays listed on `main`; nothing relists it.
  ```swift
  @Test(arguments: [true, false])
  func aRebaseStoppedOnConflictsIsLeftFromTheMac(continues: Bool) async throws
  // listed branch "main", git detached mid-rebase
  // continues: .useTheirs(path: ".alas/scripts/hello.sh") == .done; .continueOperation(kind: .rebase) == .done
  //   → no .git/rebase-merge; `git rev-parse --abbrev-ref HEAD` == "main\n"; hello.sh == "ours\n"
  //     (a rebase's "theirs" is the commit being replayed)
  // !continues: .abortOperation(kind: .rebase) == .done → no .git/rebase-merge; HEAD is the "ours" commit
  // either way remoteRead(.changes) answers operation == nil

  enum DuringRebase: CaseIterable { case stage, commit, wrongKind, outsidePath }
  @Test(arguments: DuringRebase.allCases)
  func onlyTheWayOutPassesTheGateDuringARebase(_ change: DuringRebase) async throws
  // stage: .stage(paths: ["x"]); commit: .commit(subject: "x", body: "", amend: true)
  //   → .failure(.failed(message: "The worktree changed since it was listed."))
  // wrongKind: .continueOperation(kind: .cherryPick)
  //   → .failure(.failed(message: "The operation on the host changed; refresh and try again."))
  // outsidePath: .useOurs(path: "../x") → .failure(.invalidRequest(reason: "The path ../x is outside the worktree."))
  // .git/rebase-merge still exists in every case
  ```
- [ ] **Step 2: Run and confirm they fail.** `--filter HostProtocolServerTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm they pass.** Add `.continueOperation(kind: .rebase)` and `.useOurs(path:)` to `clientMessagesRoundTrip`, then run `--filter HostProtocolServerTests`, `--filter HostProtocolTests` and `--filter HostSessionsTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): continue, skip, abort and resolve a worktree's git operation for paired Macs`.

### Task 5: Cherry-pick and revert

**Files:**
- Modify `HostProtocol.swift`: two `HostWorktreeChange` cases, under `worktreesOperationsV1`.
- Modify `AlasCoreContext+WorktreeGit.swift`: `apply`, and `verifiedCommit`.
- Test `HostProtocolServerTests`.

**Interfaces:**
- Consumes `HostOperationKind` and the abort path (Task 4).
- Produces:
  ```swift
  case cherryPick(sha: String), revert(sha: String)          // HostWorktreeChange
  /// `sha` as a full commit SHA of this repository: hex (`isCommitSHA`), else
  /// invalidRequest("A commit is named by its SHA."); resolving through
  /// `rev-parse --verify --quiet <sha>^{commit}`, else notFound(what: "commit <sha>").
  static func verifiedCommit(_ sha: String, at root: URL) async throws -> String
  ```
- `apply` runs `git.cherryPick` or `git.revert` on the verified SHA.
  - `.clean` and `.conflict` answer `.done`. `.error(m)` throws `failed(m)`.
  - With conflicts the operation stays in place for Task 4's changes, as locally.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func aConflictingCherryPickLeavesAnOperationTheMacCanSeeAndLeave() async throws
  // a branch "other" off main commits "theirs\n" to hello.sh; main commits "ours\n"; head = HEAD sha
  // .cherryPick(sha: <other's sha>) == .done
  // remoteRead(.changes): operation == .cherryPick(sha: <other's sha>, summary: "theirs"), a file with conflict != nil
  // .abortOperation(kind: .cherryPick) == .done → operation == nil, HEAD == head, status --porcelain == ""

  @Test(arguments: [
      ("HEAD", HostError.invalidRequest(reason: "A commit is named by its SHA.")),
      ("--abort", .invalidRequest(reason: "A commit is named by its SHA.")),
      (String(repeating: "a", count: 40), .notFound(what: "commit \(String(repeating: "a", count: 40))")),
  ])
  func cherryPickAndRevertTakeOnlyThisRepositorysCommits(_ sha: String, _ error: HostError) async throws
  // both .cherryPick(sha:) and .revert(sha:) → .failure(error); HEAD unchanged; no operation
  ```
- [ ] **Step 2: Run and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm they pass.** `--filter HostProtocolServerTests`. Add `.cherryPick` to the round trip, then run `--filter HostProtocolTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): cherry-pick and revert a commit for paired Macs`.

### Task 6: Operation card, conflicts and commit actions on the Mac

**Files:**
- Modify `Alas/Sources/Right/NativePeerChangesView.swift`:
  - `Git` gains the operation, conflict and commit closures.
  - The body adds `OperationCard` and `ConflictsSection` above the working tree.
  - `commitSection` (`:172`) adds a context menu to each commit row.
- Modify `Alas/Sources/Right/NativePeerRightPaneView.swift`: the closures, and the two confirmations next to the discard alert.
- Modify `NativePeerHosts.swift`: `servesOperations`.

**Interfaces:**
- Consumes Tasks 3–5.
- Produces:
  ```swift
  func servesOperations(serverId: String) -> Bool    // servesGit && supports(worktreesOperationsV1)
  // NativePeerChangesView.Git
  let servesOperations: Bool
  let onContinue: (MergeOperation) -> Void, onSkip: (MergeOperation) -> Void, onAbort: (MergeOperation) -> Void
  let onUseOurs: (ChangedFile) -> Void, onUseTheirs: (ChangedFile) -> Void
  let onKeepDeleted: (ChangedFile) -> Void, onMarkResolved: (ChangedFile) -> Void
  let onCherryPick: ((RemoteCommit) -> Void)?, onRevert: ((RemoteCommit) -> Void)?, onEditCommit: ((RemoteCommit) -> Void)?   // Task 8 sets the last
  // NativePeerRightPaneView
  @State private var pendingCommitAction: (kind: HostOperationKind, commit: RemoteCommit)?   // .cherryPick or .revert
  ```
- **Operation card.** With `servesOperations` and `changes.operation`, show `OperationCard(operation:hasUnresolvedConflicts:…)`. Its buttons run `runGit(.continueOperation(kind: HostOperationKind(op)))`, and the skip and abort equivalents.
- **Conflicts.** `conflicts` is the staged and unstaged files with `conflict != nil`, one per path. They show in `ConflictsSection`:
  - `bulkInFlight: false`, `hasAgent: false`, and a no-op bulk resolve;
  - `onSelect` opens `.diff(path:stage: .unstaged)`;
  - the four actions run their changes.

  Conflicted files are left out of the working-tree rows, as locally (`nonConflictChanges`).
- **Commit rows.** Each gets a context menu when `commit.sha != nil`:
  - `"Edit Commit…"` (Task 8);
  - `"Cherry-pick…"`, which sets `pendingCommitAction`;
  - a divider and `"Revert Commit…"` (destructive), which sets `pendingCommitAction`.

  The alerts use the local copy (Global Constraints). Confirming runs `runGit(.cherryPick(sha:))` or `runGit(.revert(sha:))`.
- `runGit` already reloads changes, so the card appears after a conflicting pick.

- [ ] **Step 1: Implement.** No new test (views; the decisions are Tasks 3–5's).
- [ ] **Step 2: Verify.** CI's app build. By hand, against a headless host:
  - Cherry-pick a conflicting commit. The card and conflicts show.
  - Use theirs, then Continue.
  - Pull into a conflict while the sidebar still says the branch, then Abort.
- [ ] **Step 3: Commit.** `feat(remote): resolve, continue or abort a host worktree's git operation, and cherry-pick or revert from a paired Mac`.

## PR 3 — edit commit

### Task 7: Host commit details and commit edits

**Files:**
- Modify `Packages/AlasCore/Sources/AlasPlatform/Git/CommitInfo.swift:5`, `CommitDetails.swift:5,261` and `GitService+CommitEditing.swift:5`: add `Codable` to `CommitInfo`, `CommitDetails`, `CommitChangedFile` and `CommitEditResult` (synthesized, in the declarations).
- Modify `HostProtocol.swift`: the read, the change, `HostCommitEdit`, and the responses.
- Modify `RemoteProtocol.swift`: `worktreesCommitEditV1`, appended to `headlessOnly`.
- Modify `AlasCoreContext+WorktreeGit.swift`: the edit case, and `commitDetails`.
- Modify `HostProtocolServer.swift`: dispatch `commitDetails`.
- Modify the `RepoFixture` in `HostProtocolServerTests`: add `init(environment:aheadOfOrigin: Bool = false)`, which uses `GitTemplate.repositoryAheadOfOrigin`, and stores `aheadSHAs`.

**Interfaces:**
- Consumes `verifiedCommit` (Task 5) and `refuseOutside`.
- Produces:
  ```swift
  public static let worktreesCommitEditV1 = "host.worktrees.commitEdit.v1"
  case commitDetails(worktree: WorktreeRef, sha: String)          // HostRequest
  case commitDetails(details: CommitDetails)                      // HostResponse; files filtered and capped as remoteCommitFiles does
  case commitEdited(result: CommitEditResult)                     // HostResponse, to editCommit
  // HostWorktreeChange; capability worktreesCommitEditV1
  case editCommit(sha: String, edit: HostCommitEdit, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
  public enum HostCommitEdit: Codable, Equatable, Sendable {
      case message(subject: String, body: String)
      case dropFile(path: String)
      /// The `index`th hunk of the commit's diff of `path`, which must have `header`.
      case dropHunk(path: String, index: Int, header: String)
  }
  func commitDetails(_ sha: String, in worktree: Worktree) async throws -> CommitDetails   // AlasCoreContext
  ```
- **`editCommit` in `apply`:**
  1. `verifiedCommit(sha)`.
  2. The base ref is `git.commitsAhead(... resolution: .forCommits(mode: comparisonMode ?? config, userOverrodeBaseBranch: false)).comparisonRef`, as `remoteChangeList` computes it. Nil throws `failed(CommitEditError.targetNotAboveFold.errorDescription)`.
  3. Map the edit:
     - `message` maps as is;
     - `dropFile` runs `refuseOutside` first;
     - `dropHunk` runs `refuseOutside`, then reads `git.diff(worktreePath:sha:file:originalPath:)`, with `originalPath` from `commitDetails`. It takes `hunks[index]` when its `header == header`, else throws `failed("This commit changed since it was shown. Refresh and try again.")`.
  4. Answer `.commitEdited(result: git.editCommit(...))`. `CommitEditError`s pass through as their `errorDescription`.
- `commitDetails` is `verifiedCommit` then `git.commitDetails`. It's served through `servedWorktree(ref, capability: worktreesCommitEditV1)`.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func aMacRewordsAHostCommit() async throws
  // RepoFixture(aheadOfOrigin: true); shas = fixture.aheadSHAs
  // .commitDetails(sha: shas[1]) → .commitDetails(d) with d.info.rawSubject == "entry 2"
  // .editCommit(sha: shas[1], edit: .message(subject: "Reworded", body: ""), comparisonMode: nil)
  //   → .commitEdited(r) with r.currentSha != shas[1]
  // `git log --format=%s origin/main..HEAD` == "entry 3\nReworded\nentry 1\n"

  enum StaleEdit: CaseIterable { case notASHA, belowTheFold, otherHunk, outsidePath, dirtyTree }
  @Test(arguments: StaleEdit.allCases)
  func commitEditsTakeOnlyWhatTheMacSaw(_ stale: StaleEdit) async throws
  // RepoFixture(aheadOfOrigin: true)
  // notASHA: sha "HEAD~1" → .invalidRequest(reason: "A commit is named by its SHA.")
  // belowTheFold: sha `git rev-parse origin/main` → .failed(message: CommitEditError.targetNotAboveFold.errorDescription!)
  // otherHunk: a fourth commit appending a line to hello.sh; .dropHunk(path: ".alas/scripts/hello.sh", index: 0, header: "@@ -9 +9 @@")
  //   → .failed(message: "This commit changed since it was shown. Refresh and try again.")
  // outsidePath: .dropFile(path: "../x") → .invalidRequest(reason: "The path ../x is outside the worktree.")
  // dirtyTree: an untracked file, then the reword → .failed(message: CommitEditError.dirtyWorktree.errorDescription!)
  // HEAD is unchanged in every case
  ```
- [ ] **Step 2: Run and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm they pass.** `--filter HostProtocolServerTests`. Add `commitDetails`, `.editCommit(.dropHunk…)` and `.commitEdited` to the round trips, then run `--filter HostProtocolTests` and `--filter HostSessionsTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): reword a commit or drop a file or hunk from it for paired Macs`.

### Task 8: The commit editor tab, fed by the host

**Files:**
- Modify `Alas/Sources/Center/Commit/CommitEditorTabView.swift`:
  - Add `CommitEditorGit` at the end of the file.
  - The view reads through `source` (`:286-287`, `:324`, `:410-465`), and hides message generation when `!source.generatesMessages`.
- Modify `Alas/Sources/Remote/Native/NativePeerSidebarSnapshot.swift:210`: add `NativePeerCommitEditorSelection`.
- Modify `Alas/Sources/Remote/Native/NativePeerSessions.swift`:
  - Add `openedCommitEditor`, `openCommitEditor` and `closeCommitEditor`.
  - Wherever `openedReview` is cleared (`:271`, `:451`, `:560`, `:593`, `:1086`), clear it too.
- Modify `NativePeerHosts.swift`: `servesCommitEdit`, `commitDetails` and `editCommit`.
- Modify `Alas/Sources/App/RootView.swift:407`: show the editor for `client.openedCommitEditor`.
- Modify `NativePeerRightPaneView.swift`: set `onEditCommit` when `servesCommitEdit`.

**Interfaces:**
- Consumes Task 7.
- Produces:
  ```swift
  /// What the commit editor reads and changes: this Mac's git, or a paired host's.
  struct CommitEditorGit {
      var details: (_ sha: String) async throws -> (details: CommitDetails, rawSubject: String)
      var diff: (_ sha: String, _ file: CommitChangedFile) async throws -> (diff: ParsedDiff, truncated: Bool)
      var edit: (_ targetSha: String, _ action: CommitEditAction) async throws -> CommitEditResult
      /// After an edit lands: the local tab and right-pane bookkeeping (`:455-462`), or the peer selection's new sha.
      var didEdit: (_ result: CommitEditResult, _ title: String) async -> Void
      var generatesMessages: Bool
      /// Today's behaviour, moved verbatim: GitService, the checkpoint-lease guards, the center git mutation, the comparison ref.
      @MainActor static func local(worktreePath: URL, worktreeId: String, tabId: TabID, appState: AppState) -> Self
      @MainActor static func peer(_ selection: NativePeerCommitEditorSelection, hosts: NativePeerHosts,
                                  onEdited: @escaping (CommitEditResult) -> Void) -> Self
  }
  // CommitEditorTabView
  var source: CommitEditorGit? = nil        // nil: .local(...)
  // NativePeerSidebarSnapshot.swift
  struct NativePeerCommitEditorSelection: Equatable {
      let serverId: String; let worktree: PeerHostWorktree; var sha: String
      let comparisonMode: AppConfig.Changes.ChangesComparisonMode
  }
  // NativePeerHosts
  func servesCommitEdit(serverId: String) -> Bool
  func commitDetails(_ sha: String, in: PeerHostWorktree, serverId: String) async -> Result<CommitDetails, String>
  func editCommit(_ sha: String, _ edit: HostCommitEdit, comparisonMode: AppConfig.Changes.ChangesComparisonMode,
                  in: PeerHostWorktree, serverId: String) async -> Result<CommitEditResult, String>
  ```
- **The peer source:**
  - `details` is `commitDetails`, with `rawSubject = details.info.rawSubject`.
  - `diff` reads `.commitDiff(sha:path:)` through `hosts.read` and maps the hunks with `NativePeerWorkspace.hunk`. It returns the reply's `truncated`.
  - `edit` maps `CommitEditAction`:
    - `.message` and `.dropFile` as they are;
    - `.dropHunk(path, hunk)` re-reads the diff, takes `index = hunks.firstIndex(of: hunk)`, and sends `.dropHunk(path:index:header: hunk.header)`. If the hunk is missing, it throws "This commit changed since it was shown. Refresh and try again.".
  - `didEdit` sets `selection.sha = result.currentSha` and reloads the workspace.
  - `generatesMessages` is false.
- The view's `canDropHunk` (`:375`) also needs `!diffTruncated`.
- The editor's `tabState` for the peer is `CommitEditorTabState(worktreeId:, baseRef: "", originalSha:, currentSha: selection.sha, title:)`. `baseRef` is unused, because the host computes it.

- [ ] **Step 1: Implement.** No new test: the decisions are the host's (Task 7). The local path is a verbatim move, so the existing tests pin it.
- [ ] **Step 2: Verify.** CI's app build plus `-only-testing AlasTests/CommitEditorTabViewTests` (if CI lists none, the app build alone). By hand, against a headless host:
  - Reword a commit.
  - Drop a file and a hunk.
  - A dirty host tree shows the local refusal copy.
- [ ] **Step 3: Commit.** `feat(remote): edit a host worktree's commit in the commit editor on a paired Mac`.

## PR 4 — checkpoint refactor

### Task 9: Move the checkpoint service into AlasFeatures

**Files:**
- Create `Packages/AlasCore/Sources/AlasFeatures/Checkpoints/WorktreeCheckpointService.swift`: the whole of `Alas/Sources/Checkpoints/WorktreeCheckpointService.swift`, with:
  - `import AppKit` removed;
  - the protocol, `CheckpointCaptureHooks`, the actor, `init`, and every member the app or `AlasTests` call made `public`;
  - the image side (`:159-165`) decoding through `ImageDiffDecoding.shared.decode(data, target.path)` in place of `NSImage`.
- Delete `Alas/Sources/Checkpoints/WorktreeCheckpointService.swift`.
- Move `CheckpointRestoreErrorPresentation` (`Alas/Sources/Right/Checkpoints/RestoreCheckpointSheet.swift:4-31`) and `CheckpointRecoveryPresentation` (`CheckpointRecoveryCard.swift:3-…`, pure strings) to the end of `Packages/AlasCore/Sources/AlasFeatures/Checkpoints/CheckpointModels.swift`, `public`. The host's restore refusals (Task 10) use the same copy.
- Regenerate `Alas.xcodeproj` with `xcodegen`.

**Interfaces:**
- Produces, unchanged in name and signature, now `public`:
  ```swift
  public protocol WorktreeCheckpointServicing: Sendable { /* today's 11 requirements */ }
  public struct CheckpointCaptureHooks: Sendable
  public actor WorktreeCheckpointService: WorktreeCheckpointServicing {
      public init(store: WorktreeCheckpointStore = .init(), snapshotter: WorktreeStateSnapshotter = .live,
                  hooks: CheckpointCaptureHooks = .none, restoreFaultInjector: CheckpointRestoreFaultInjector = .none)
      public func createRecovery(...); public func prepareRestore(...)   // used by AlasTests
  }
  public enum CheckpointRestoreErrorPresentation { public static func message(_ error: Error) -> String }
  public enum CheckpointRecoveryPresentation { /* today's statics */ }
  ```
- App callers keep compiling unchanged through `@_exported import AlasCore`: `AppState.swift:645`, `RightPaneState.swift:137,610`, `CheckpointDiffTabView.swift:114` and the checkpoint tests.

- [ ] **Step 1: Move the code.** Make public only what the compiler asks for.
- [ ] **Step 2: Verify the core.** `swift build --package-path Packages/AlasCore`, then `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostProtocolServerTests`. Expected: builds, N > 0 passing. There's no new core test: the app's checkpoint suites pin this behaviour.
- [ ] **Step 3: Regenerate.** Run `xcodegen`, then `git status` to confirm that only the deleted file's entries leave `Alas.xcodeproj/project.pbxproj`.
- [ ] **Step 4: Verify the app on CI.** Run CI's app build plus `-only-testing` for `AlasTests/CheckpointDiffLoaderTests`, `AlasTests/CheckpointRestorePreviewTests`, `AlasTests/CheckpointRestoreIntegrationTests`, `AlasTests/CheckpointRestoreInterruptionTests`, `AlasTests/WorktreeCheckpointCaptureTests` and `AlasTests/RightPaneCheckpointStateTests`. `imagesKeepBothSidesAndFrameCounts` passes through the installed decoder.
- [ ] **Step 5: Commit** the source, the deletion and `Alas.xcodeproj`. Message: `refactor(checkpoints): move the checkpoint service into AlasFeatures`.

## PR 5 — checkpoints on the host

### Task 10: Host checkpoint reads and changes

**Files:**
- Modify `CheckpointModels.swift`: add `Codable` to `CheckpointRestoreBlocker` (`:69`), `CheckpointRestoreEffect` and its `Layer` (`:104`), `CheckpointRestoreGroup` (`:138`) and `CheckpointRestorePreview` (`:157`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift:187`: an init parameter and property `checkpoints`.
- Create `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+Checkpoints.swift`: target, coordination, reads, and the change helpers.
- Modify `AlasCoreContext+WorktreeGit.swift`:
  - The three checkpoint cases in `apply`.
  - `refuseOutside` goes from `private` to internal.
- Modify `HostProtocol.swift`, `RemoteProtocol.swift` (`worktreesCheckpointsV1` into `headlessOnly`) and `HostProtocolServer.swift`.
- Modify the `RepoFixture` in `HostProtocolServerTests`: pass `checkpoints: WorktreeCheckpointService(store: .init(root: root.appendingPathComponent("checkpoints")))`.

**Interfaces:**
- Consumes Task 9's public service and `CheckpointRestoreErrorPresentation`, and `HostDiff` (Task 1).
- Produces:
  ```swift
  public static let worktreesCheckpointsV1 = "host.worktrees.checkpoints.v1"
  // HostRequest
  case listCheckpoints(worktree: WorktreeRef)
  case checkpointManifest(worktree: WorktreeRef, id: CheckpointID)
  case checkpointDiff(worktree: WorktreeRef, id: CheckpointID, path: String)
  case checkpointRestorePreview(worktree: WorktreeRef, id: CheckpointID, groupIDs: Set<UUID>?)
  // HostWorktreeChange; capability worktreesCheckpointsV1
  case createCheckpoint(label: String)                                        // answers .checkpointManifest
  case deleteCheckpoint(id: CheckpointID)
  case restoreCheckpoint(id: CheckpointID, groupIDs: Set<UUID>, fingerprint: String)
  // HostResponse
  case checkpoints(catalog: CheckpointCatalogSnapshot)
  case checkpointManifest(manifest: WorktreeCheckpointManifest)
  case checkpointRestorePreview(preview: CheckpointRestorePreview)
  // AlasCoreContext
  @ObservationIgnored public let checkpoints: WorktreeCheckpointService      // init(..., checkpoints: WorktreeCheckpointService = .init())
  /// Nil for a remote path, a folder project or no lineage; repository name from the project, no workspace.
  func checkpointTarget(for worktree: Worktree) -> CheckpointWorktreeTarget?
  /// Sessions: the worktree manager's runners plus a starting one. Terminals: its runs, pending
  /// run launches, and host consoles (`hasHostConsoles`). No dirty editors, no other git mutation.
  func checkpointCoordination(for worktree: Worktree) -> CheckpointCoordinationSnapshot
  /// `id` if the worktree's catalog lists it, else notFound(what: "checkpoint <id>").
  func listedCheckpoint(_ id: CheckpointID, in target: CheckpointWorktreeTarget) async throws -> CheckpointID
  ```
- **Reads** go through `servedWorktree(ref, capability: worktreesCheckpointsV1)`. A nil target throws `failed("Checkpoints are not available for this worktree.")`.
  - `listCheckpoints` answers `summaries(target:)`.
  - `checkpointManifest` answers `manifest(target:id:)` after `listedCheckpoint`.
  - `checkpointDiff` runs `refuseOutside([path])` and `listedCheckpoint`, then maps `diffContent`:
    - `.text(d)` becomes `HostDiff(d)`;
    - `.image` becomes no hunks with the note `"Image changes are not shown from a host."`;
    - `.binary` becomes no hunks with the note `"Binary files cannot be shown."`;
    - `.unavailable(m)` throws `failed(m)`.
  - `checkpointRestorePreview` answers `restorePreview(target:id:coordination:selectedGroupIDs:)` after `listedCheckpoint`.
- **Changes** in `apply`:
  - `createCheckpoint`: a label empty after trimming throws `invalidRequest("A checkpoint needs a name.")`. Otherwise answer `.checkpointManifest(manifest(target, createManual(target, label).id))`.
  - `deleteCheckpoint`: `listedCheckpoint`, then `delete`, answering `.done`.
  - `restoreCheckpoint`, in order:
    1. `listedCheckpoint`.
    2. `preview = restorePreview(…, selectedGroupIDs: groupIDs)`. A `blocker` throws `failed(blocker.description)`.
    3. `preview.currentFingerprint != fingerprint` throws `failed("Refresh the restore preview before trying again.")`.
    4. `restore(target:preview:selectedGroupIDs:coordination:)`. Errors become `failed(CheckpointRestoreErrorPresentation.message(error))`. The service takes the recovery checkpoint first.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func aMacCreatesInspectsAndDeletesAHostCheckpoint() async throws
  // write a.txt "one\n"; .createCheckpoint(label: "  Before  ") → .checkpointManifest(m) with m.label == "Before"
  // .listCheckpoints → .checkpoints(c) with c.summaries.map(\.label) == ["Before"]
  // write a.txt "two\n"; .checkpointDiff(id: m.id, path: "a.txt") → .diff(d) with d.hunks.count == 1
  // .deleteCheckpoint(id: m.id) == .done; .listCheckpoints → summaries empty
  // .createCheckpoint(label: " ") → .failure(.invalidRequest(reason: "A checkpoint needs a name."))

  @Test func aCheckpointRestoreWaitsForTheWorktreesSessions() async throws
  // checkpoint m with a.txt "one\n"; write "two\n"; create a session in the worktree (agent "gemini");
  //   eventually the manager has a runner
  // .checkpointRestorePreview(id: m.id, groupIDs: nil) → preview p with p.blocker == .activeSession
  // .restoreCheckpoint(id: m.id, groupIDs: p.selectedGroupIDs, fingerprint: p.currentFingerprint)
  //   → .failure(.failed(message: "Stop active terminal and agent sessions before restoring.")); a.txt == "two\n"
  // archive the session; eventually no runner; preview again → p2.blocker == nil
  // restore with "stale" → .failure(.failed(message: "Refresh the restore preview before trying again."))
  // restore with p2.currentFingerprint == .done; a.txt == "one\n";
  //   the catalog lists a .recovery summary labelled "Before checkpoint restore"

  @Test func checkpointRequestsNameOnlyThisWorktreesCheckpoints() async throws
  // a second project from GitTemplate with checkpoint o; on the first worktree:
  // .checkpointManifest(id: o.id), .checkpointDiff(id: o.id, path: "a.txt") and .deleteCheckpoint(id: o.id)
  //   → .failure(.notFound(what: "checkpoint \(o.id)")); o is still listed in its own worktree
  // .checkpointDiff(id: m.id, path: "../x") → .failure(.invalidRequest(reason: "The path ../x is outside the worktree."))
  ```
- [ ] **Step 2: Run and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm they pass.** `--filter HostProtocolServerTests`. Add `checkpointRestorePreview`, `.restoreCheckpoint` and `.checkpointRestorePreview(preview:)` to the round trips, then run `--filter HostProtocolTests` and `--filter HostSessionsTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): list, create, inspect, delete and restore a worktree's checkpoints for paired Macs`.

### Task 11: The host takes an automatic checkpoint before each prompt

**Files:**
- Modify `Packages/AlasCore/Sources/AlasAgents/ACP/Session/ACPSessionManager.swift:110`: `onCheckpointCapture` becomes `@ObservationIgnored public var`. It's read when each runner is made (`:7490`).
- Modify `AlasCoreContext.swift:467` (`sessionManager(for:)`): on a host that `servesWorktreeGit`, install the capture when the manager has none.
- Modify `AlasCoreContext+Checkpoints.swift`: add `captureAutomaticCheckpoint`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteMessageWireJSON.swift:13`: `RemoteWireMessage` gains `checkpointId`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift:1345-1356`: a user row carries it.
- Modify the `RepoFixture`: script `session/prompt` to answer `null`.

**Interfaces:**
- Produces:
  ```swift
  // ACPSessionManager
  @ObservationIgnored public var onCheckpointCapture: (@MainActor (_ prompt: String, _ hasAttachments: Bool) async -> CheckpointID?)?
  // AlasCoreContext
  /// The app's `onCheckpointCapture` (AppState.swift:12418-12431) for a headless host: `createAutomatic` with
  /// `AutomaticCheckpointLabel.make(prompt:hasAttachments:)`; nil without a target or on any failure. The store keeps
  /// at most 50 automatic checkpoints (`Limits.automaticCount`), oldest pruned, as the app's.
  func captureAutomaticCheckpoint(_ worktree: Worktree, prompt: String, hasAttachments: Bool) async -> CheckpointID?
  // RemoteWireMessage
  public var checkpointId: String? = nil   // a user row's automatic checkpoint; the key is left out when nil
  ```
- `RemoteWireMessage.init` gains `checkpointId: String? = nil`. `transportByteCount` adds `16 + 36` when it's set.
- `toWire`'s `.user` sets it to `attachments.first(where: \.isCheckpointReference)?.checkpointID?.uuidString`. The row's text still leaves the reference out.

- [ ] **Step 1: Write the failing test.**
  ```swift
  @Test func aHostPromptTakesAnAutomaticCheckpointFirst() async throws
  // write a.txt; create a session in the main worktree (agent "gemini"); host.sessions.send(id, prompt: "fix it", caller: .app)
  // eventually the agent received "session/prompt"
  // fixture.core.checkpoints.summaries(target:) has one .automatic summary labelled "Before: fix it"
  // the session's transcript user message carries that id as a checkpoint reference, and
  //   RemoteSessionGateway.toWire(<that message>, index: 0).checkpointId == id.uuidString
  ```
- [ ] **Step 2: Run and confirm it fails.** `--filter HostProtocolServerTests`. Expected: no checkpoint.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm it passes.** `--filter HostProtocolServerTests`, `--filter HostSessionsTests`, `--filter HostProtocolTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): take an automatic checkpoint before each host prompt`.

### Task 12: Checkpoints on the Mac

**Files:**
- Modify `Alas/Sources/Right/Checkpoints/RestoreCheckpointSheet.swift:94-190` and `CreateCheckpointSheet.swift:32-90`: take closures. Today's `init(rps:…)` becomes a convenience initializer over them.
- Modify `NativePeerHosts.swift`: `servesCheckpoints` and the five calls.
- Modify `NativePeerWorkspace.swift`: `Document.checkpointDiff`.
- Modify `NativePeerSessions.swift`: `open` serves `.checkpointDiff` through `finishDocument` (Task 2).
- Modify `NativePeerDocumentView.swift`: `badge` shows `"checkpoint"`.
- Modify `NativePeerRightPaneView.swift`:
  - A Checkpoints section after the reviews.
  - The create sheet, the restore sheet and the delete alert.
  - `"Create Checkpoint…"` in the branch menu (`:139-154`).

**Interfaces:**
- Consumes Task 10.
- Produces:
  ```swift
  // RestoreCheckpointSheet
  init(preview: CheckpointRestorePreview, error: String?, inFlight: Bool,
       refresh: @escaping (Set<UUID>) async -> Void, restore: @escaping (Set<UUID>) async -> Bool,   // true: dismiss
       cancel: @escaping () -> Void)
  init(rps: RightPaneState, preview: CheckpointRestorePreview)                                      // today's behaviour
  // CreateCheckpointSheet
  init(error: String?, disabled: Bool, create: @escaping (String) async -> WorktreeCheckpointManifest?)
  init(rps: RightPaneState)
  // NativePeerHosts
  func servesCheckpoints(serverId: String) -> Bool
  func checkpoints(in: PeerHostWorktree, serverId: String) async -> CheckpointCatalogSnapshot?
  func checkpointManifest(_ id: CheckpointID, in: PeerHostWorktree, serverId: String) async -> Result<WorktreeCheckpointManifest, String>
  func checkpointDiff(_ id: CheckpointID, path: String, in: PeerHostWorktree, serverId: String) async -> Result<HostDiff, String>
  func checkpointRestorePreview(_ id: CheckpointID, groupIDs: Set<UUID>?, in: PeerHostWorktree, serverId: String) async -> Result<CheckpointRestorePreview, String>
  // NativePeerWorkspace.Document
  case checkpointDiff(path: String, checkpointID: CheckpointID)
  ```
- **List.** It's read with stashes, on `client.workspace.changes` changes. A prompt's automatic checkpoint then shows once the agent's edits reload the changes.
- **Cards.** One `CheckpointCard` per summary.
  - Expanding one reads its manifest.
  - `onInspect(group)` opens `.checkpointDiff(path: group.primaryPath, checkpointID:)`.
  - `onRestore` reads the preview and presents the sheet.
  - `onDelete` sets the pending deletion. The alert uses the local copy, and `"Delete"` runs `.deleteCheckpoint`.
- **Sheets.** Create runs `.createCheckpoint(label:)` through `hosts.change` and returns the manifest. Restore's closures:
  - `refresh` re-reads the preview;
  - `restore` runs `.restoreCheckpoint(id:groupIDs:fingerprint: preview.currentFingerprint)` and reloads the workspace;
  - the error shows in the sheet.
- The local sheets' behaviour is unchanged. `RightPaneView.swift:490,497` keep calling the `rps` initializers.

- [ ] **Step 1: Implement.** No new test: views, and Task 10 pins the decisions.
- [ ] **Step 2: Verify.** CI's app build plus `-only-testing AlasTests/RightPaneCheckpointStateTests`. By hand, against a headless host:
  - Create a checkpoint, inspect a file, delete it.
  - Restore while a host session runs: the blocker shows. Restore after stopping it.
- [ ] **Step 3: Commit.** `feat(remote): manage a host worktree's checkpoints from a paired Mac`.

### Task 13: "Restore files to before this request" for host sessions

**Files:**
- Modify `Alas/Sources/Remote/Native/NativePeerTranscriptPresentation.swift:6-19`: `.user` carries its checkpoint.
- Modify `Alas/Sources/Remote/Native/NativePeerTranscriptScroller.swift:494-540`: `NativePeerRowView`'s user menu gains the item. The scroller and row take `onRestoreCheckpoint`.
- Modify `NativePeerSessionView.swift`: pass it when `hosts.servesCheckpoints` for the selected peer.
- Modify `NativePeerSessions.swift`: add `pendingCheckpointRestore`.
- Modify `NativePeerRightPaneView.swift`: present Task 12's restore preview for it.

**Interfaces:**
- Consumes `checkpointId` (Task 11) and the restore flow (Task 12).
- Produces:
  ```swift
  case user(String, checkpointID: CheckpointID?)                 // NativePeerRow; from message.checkpointId via UUID(uuidString:)
  var onRestoreCheckpoint: ((CheckpointID) -> Void)? = nil       // NativePeerRowView; nil hides the item
  private(set) var pendingCheckpointRestore: CheckpointID?       // NativePeerSessions
  func requestCheckpointRestore(_ id: CheckpointID)              // sets it; the right pane takes it
  func takeCheckpointRestore() -> CheckpointID?                  // clears it
  ```
- The user row's menu starts with `"Restore files to before this request"` and a divider when `checkpointID != nil` and `onRestoreCheckpoint != nil`, as `ACPMessageActionsMenu.make` (`:50-55`) orders it.
- The right pane's `.onChange(of: client.pendingCheckpointRestore)` takes the id. With a git target that serves checkpoints, it reads the preview and presents the restore sheet. A refusal lands in `gitError`.

- [ ] **Step 1: Implement.** No new test: the row decoding is one line over Task 11's pinned wire field, and the rest is view wiring.
- [ ] **Step 2: Verify.** CI's app build plus `-only-testing AlasTests/NativePeerSessionsTests`. By hand, against a headless host:
  - Prompt a host session that edits a file.
  - Right-click the prompt, choose "Restore files to before this request", and restore once the session is stopped.
- [ ] **Step 3: Commit.** `feat(remote): restore a host session's files to before a request from a paired Mac`.

---

## Self-review

- **Spec coverage.** Each goal maps to tasks:
  - Goal 1 (stash, with message and untracked; list, files, diffs; apply, pop, drop confirmed; conflicts visible): Tasks 1–2. Conflicts become resolvable with Tasks 4 and 6.
  - Goal 2 (cherry-pick and revert, confirmed): Tasks 5–6.
  - Goal 3 (operation card, conflicts section; commit, push and pull still refused): Tasks 3, 4 and 6. The refusal is unchanged at `:43-46`.
  - Goal 4 (edit commit, the local editor tab fed from the host, the local refusals): Tasks 7–8. The dirty-tree, operation and merge-commit refusals are `editCommit`'s own.
  - Goal 5 (list, create, diff, delete, restore with host blockers; automatic checkpoint before host prompts): Tasks 9–12.
  - Goal 6 (capability-gated, headless only, hidden on older hosts): Tasks 1, 3, 7, 10, and each Mac task's `serves…`.
  - Builder decisions:
    - the rebase gate exception, for the way out only (Task 4);
    - checkpoints as refactor then wiring (Tasks 9 and 10–13);
    - the transcript restore for host sessions (Task 13).
  - Anti-goals:
    - Nothing new blocks on running agents except restore (Task 10), as locally.
    - Every Mac-named value is checked first (Global Constraints, with tests in Tasks 1, 4, 5, 7 and 10).
    - Operations ship in PR 2, before or with cherry-pick.
- **Where the plan departs from the spec, because of the code:**
  - **The changes reply carries the whole `MergeOperation`,** not only kind, sha and summary. `OperationCard` renders a rebase from its plan and a merge from its source branch. Sending the model as-is lets the Mac reuse the card with no wire shape of its own. Every host fills it; the actions stay gated.
  - **Keep deleted joins Use ours, Use theirs and Mark resolved.** `ConflictsSection` offers it for delete-side conflicts, where "use ours" isn't possible. Without it, a Mac's only way out of such a conflict would be Abort.
  - **Continue, Skip and Abort name the operation kind the Mac saw.** The host refuses when it differs, so a stale card can't act on another operation.
  - **Stash and checkpoint diffs are their own requests answering a new `HostDiff`,** not `HostWorktreeRead` cases. Those map one-to-one onto Remote session messages, which phones decode.
  - **Checkpoint create, delete and restore are `HostWorktreeChange` cases.** They take the same gate, so a pending restore journal or a busy worktree refuses them too. The spec's "every new host change goes through `mutateListedWorktree`" covers them.
  - **`apply` returns a `HostResponse`.** An edit's new SHAs and a created checkpoint's manifest go back without new requests that bypass the gate.
  - **Drop hunk names the hunk by index and header** rather than sending hunk content. The host uses git's own hunk. The Mac disables the drop when its diff was truncated.
  - **The moved checkpoint service decodes images through the existing `ImageDiffDecoding` seam,** which the app installs. Locally an image checkpoint diff renders as before. The one difference: an LFS pointer now reports the LFS failure instead of "Image could not be decoded.". On the host, image diffs answer a note.
  - **The checkpoint id reaches the Mac transcript as a new optional `checkpointId` key on `RemoteWireMessage`.** The phone wire still filters the reference from the row's text, and older or phone decoders ignore an unknown key.
  - **The host installs its capture in `sessionManager(for:)`** rather than in `boot`'s factory. Tests then exercise the real path, and an app-built core (no `servesWorktreeGit`) never installs it.
  - **Recovering an interrupted restore isn't offered from the Mac.** The spec doesn't list it. The gate keeps refusing git and checkpoint changes with today's message until it's recovered on the host.
  - **The host's coordination snapshot** counts the worktree manager's runners (plus a starting session) as agents, and its runs, pending launches and host consoles as terminals. A headless host has no editor buffers.
- **Type consistency.** These names are used the same way in every task:
  - `HostStashRef(ref:sha:)` and `HostDiff(hunks:truncated:note:)`;
  - `HostOperationKind`, `leavesAnOperation`, `HostCommitEdit` and `verifiedCommit`;
  - `servedWorktree(_:capability:)` and `HostProtocolCapability.headlessOnly`;
  - `worktreesStashV1`, `worktreesOperationsV1`, `worktreesCommitEditV1` and `worktreesCheckpointsV1`;
  - `listedStash`, `listedCheckpoint`, `checkpointTarget(for:)`, `checkpointCoordination(for:)` and `captureAutomaticCheckpoint`;
  - `CommitEditorGit` and `NativePeerCommitEditorSelection`;
  - `finishDocument`, `.stashDiff` and `.checkpointDiff`;
  - `checkpointId` on the wire, and `checkpointID` in Swift models.
