# Peer Git Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac paired with a headless `alas-host` can stage, unstage, discard, commit/amend, push, pull and fetch on a host worktree from the peer right pane. The peer pane shows the same review pill and behind chip as a local pane.

**Architecture:** The host gains one capability, `host.worktrees.git.v1`, which only the headless host advertises. It covers three requests: `mutateWorktree(worktree:branch:change:)`, `commitMessageInput(worktree:)` and `reviewStatus(worktree:)`. It also covers one opt-in event, `reviewStatus`, published whenever a followed worktree's `ReviewLoopSnapshot` changes. Helpers the local pane already uses move into core so host and app run the same code: rename path expansion, push arguments, and the commit-message input. The peer pane reuses the existing Changes rows, `PendingDiscard`, `ReviewLoopDrawer`, `BehindChip` and `CommitMessageSuggester`.

**Tech Stack:** Swift 6 / SwiftUI app, `Packages/AlasCore` SwiftPM (UI-free), Swift Testing, real git through `GitTemplate`.

**Spec:** `docs/superpowers/specs/2026-10-25-peer-git-actions-design.md`

**PR split:**
- **PR A** (Tasks 1–4): host mutations, capability, never-prompting git, and the moves into core.
- **PR B** (Task 5): sync and review state to the peer.
- **PR C** (Tasks 6–7): the peer UI.

Land them in order. While only A has landed, a host advertises `git.v1` without `reviewStatus`. That is harmless, because no Mac sends git requests before C.

## Global Constraints

- AGENTS.md rules (from origin/main's CLAUDE.md):
  - Swift Testing only.
  - Keep tests minimal and sharp. Do not test views or wiring.
  - Core imports nothing from SwiftUI, AppKit, GhosttyKit, MLX, TreeSitterPack or FffC. Anything the app uses from core must be `public`.
  - Use Conventional Commits. Add no agent attribution: no `Co-Authored-By` lines and no generated-by footers.
- Core tests:
  `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`
- The app cannot be built locally, so CI is its first build.
  - Keep `Alas/` and `AlasTests/` edits mechanical.
  - Add **no new files** under `Alas/` or `AlasTests/`, so no xcodegen run is needed.
  - `AlasTests` changes are verified by CI only. Say so in the PR body.
- No behaviour change for local worktrees. The never-prompt git env applies only in `alas-host`.
- Copy pinned by the spec, used verbatim:
  - `"The worktree changed since it was listed."`
  - `"Pull stopped on conflicts; resolve them on the host."`
- Copy chosen here, used verbatim:
  - `"These changes are no longer in the worktree."`
  - `"A checkpoint restore is pending on the host; finish it there first."`
  - `"This host does not serve git actions."`
  - `"A commit needs a subject."`
  - `"The branch's push target could not be read."`
- The checkpoint rule follows the binding Decisions section: refuse when `environment.checkpointRecoveryBlocksRemoval(worktree)` is true, and take **no writer lease**. Goal 4's "checkpoint writer lease" wording is overridden.
- No agent-turn guard. A live session in the worktree does not block an action.

## Review Focus

1. **The host's agent switched branch after the Mac listed the worktree.** The action is refused with "The worktree changed since it was listed." and git is untouched. Covered by a Task 3 refusal-test argument.
2. **The Mac's change list is stale and the file is already gone on the host.** Discarding it is refused with "These changes are no longer in the worktree." It must not report success while doing nothing. Covered by a Task 3 refusal-test argument.
3. **A push needs credentials, or ssh asks for a host key or passphrase on a host run from a terminal.** Git fails at once with its own message instead of waiting out the timeout. Covered by the Task 2 env test.
4. **The pull rebase hits a conflict.** The Mac gets "Pull stopped on conflicts; resolve them on the host." and the host is left mid-rebase. Covered by the Task 4 conflict test.
5. **An older Mac is subscribed to a newer host.** It never receives the `reviewStatus` event, which it cannot decode. Covered by the Task 5 opt-in test.

---

## PR A — host git actions

### Task 1: Move the shared git helpers into core

Pure moves. The local pane must behave exactly as before.

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasModel/Model/GitTypes.swift`. Add an `extension ChangedFile` next to `ChangedFile` (~:86).
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Integrations/CodeHost/CodeHostModels.swift`. Add an `extension ReviewLoopSnapshot` after the struct (~:753).
- Create: `Packages/AlasCore/Sources/AlasPlatform/LocalText/CommitMessageSuggestion.swift`. It takes lines 1–428 of `Alas/Sources/Center/Commit/CommitMessageSuggestion.swift`: `CommitMessageSuggestion`, `CommitMessageSuggestionRecord`, `CommitMessageSuggestionInput` and `CommitMessageSuggestionPolicy`.
- Modify: `Alas/Sources/Center/Commit/CommitMessageSuggestion.swift`. Keep only `CommitMessageSuggester` and `CommitMessageSuggestionState` (from :430 on).
- Modify: `Alas/Sources/Right/RightPaneState.swift`:
  - delete `unstagePaths(for:)` (:3233) and the three `discardPaths` statics (:3699–3727);
  - delete `reviewLoopPushArguments` (:1365–1380);
  - update their callers (:1261, :3736 and the `requestDiscard*` functions).
- Modify tests (call sites only): `AlasTests/RightPaneStateDiscardPathsTests.swift` and `AlasTests/RightPaneStateReviewLoopPushTests.swift` (:259–:278).

**Interfaces:**
- Produces:
  - `extension ChangedFile { public var gitPaths: [String] }`. Returns `[path, renameFrom]` for a staged rename (`status == "R"` with a non-empty `renameFrom`), else `[path]`.
  - `public static func discardPaths(forFileAt path: String, in changes: [ChangedFile]) -> [String]`
  - `public static func discardPaths(forFolderAt folder: String, in changes: [ChangedFile]) -> [String]`
  - `public static func discardPaths(forAllIn changes: [ChangedFile]) -> [String]`
  - The three `discardPaths` statics live on `ChangedFile` and keep today's bodies.
  - `extension ReviewLoopSnapshot { public func pushArguments(forceWithLease: Bool) -> [String] }`. Same body as `reviewLoopPushArguments`.
  - `public struct CommitMessageSuggestionInput: Codable, Equatable, Sendable`:
    - adds a `public init(stat:diff:branch:ticketTitle:recentSubjects:)`;
    - `public static func load(worktreePath: URL, ticketTitle: String?) async throws -> Self`.
  - Everything in `CommitMessageSuggestionPolicy` that the app or `AlasTests` touches becomes `public`: `FilePriority`, `FileDiff`, `priority(forPath:)`, `fileDiffs`, `budgetedDiff`, `droppingPartialTail`, `messageCandidates`, `indexKey`, `usesConventionalCommits`, `parse`, `systemPrompt`, and the limit constants. Private members stay private.
  - `CommitMessageSuggestion` and `CommitMessageSuggestionRecord` become `public` too, with public memberwise inits.

- [ ] **Step 1: Make the moves.** Use `git mv` semantics where possible, add `public`, and point the app call sites at the new API:
  - `file.gitPaths`;
  - `ChangedFile.discardPaths(...)`;
  - `snapshot.pushArguments(forceWithLease:)`.

  The app sees the moved types through `@_exported import AlasCore` (`Alas/Sources/App/AlasCoreExports.swift`).
- [ ] **Step 2: Update the two AlasTests call sites.** `RightPaneState.discardPaths(...)` becomes `ChangedFile.discardPaths(...)`, and `RightPaneState.reviewLoopPushArguments(snapshot: s, forceWithLease: f)` becomes `s.pushArguments(forceWithLease: f)`. `CommitMessageSuggestionTests` needs no edit.
- [ ] **Step 3: Build core.** Run `swift build --package-path Packages/AlasCore`. Expected: `Build complete!`. The app compile and the AlasTests suites (`RightPaneStateDiscardPathsTests`, `RightPaneStateReviewLoopPushTests`, `CommitMessageSuggestionTests`) are verified in CI.
- [ ] **Step 4: Commit.** `refactor(core): move rename paths, push arguments and commit-message input into core`

### Task 2: Never-prompting git on the headless host

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasPlatform/Git/Process+Git.swift` (`gitEnv`, ~:168–:185)
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift`. Set the flag before `HostProtocolServer(host:)` (~:207).
- Test: `AlasTests/ProcessGitTests.swift` (extend the existing suite, next to `gitEnvSetsOptionalLocksToZero`)

**Interfaces:**
- Produces:
  - `extension Process { nonisolated(unsafe) public static var neverPromptsForGit = false }`
  - `public static func gitEnv(base: [String: String] = ProcessInfo.processInfo.environment, neverPrompts: Bool = Process.neverPromptsForGit) -> [String: String]`

- [ ] **Step 1: Write the failing test.**

```swift
@Test(arguments: [
    (false, [String: String](), nil as String?, nil as String?),
    (true, [:], "0", "ssh -o BatchMode=yes"),
    (true, ["GIT_SSH_COMMAND": "ssh -i key"], "0", "ssh -i key"),
])
func gitEnvNeverPromptsOnlyWhereAskedAndKeepsAConfiguredSSHCommand(
    neverPrompts: Bool, base: [String: String], prompt: String?, ssh: String?
) {
    let env = Process.gitEnv(base: base, neverPrompts: neverPrompts)
    #expect(env["GIT_TERMINAL_PROMPT"] == prompt)
    #expect(env["GIT_SSH_COMMAND"] == ssh)
}
```

- [ ] **Step 2: Implement.** With `neverPrompts`, set `GIT_TERMINAL_PROMPT=0`. Also set `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, but only when `base` has neither `GIT_SSH_COMMAND` nor `GIT_SSH`. Add this comment at that line: `// ponytail: overrides a repo's core.sshCommand on the host; append BatchMode to it if a host relies on one.` In `main.swift`, set `Process.neverPromptsForGit = true`. The variable affects git children only, never the host's own environment, so agents and terminals are untouched.
- [ ] **Step 3: Verify.** Run `swift build --package-path Packages/AlasCore`. The test runs in CI (AlasTests).
- [ ] **Step 4: Commit.** `fix(alas-host): never let git prompt for credentials`

### Task 3: `host.worktrees.git.v1` with index changes, commit and the suggestion input

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift`:
  - `RemoteServerIdentity` (~:35–:49);
  - `hello` (~:1428);
  - `HostProtocolCapability` (~:1441–:1471).
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHostEnvironment.swift`:
  - the protocol (~:110);
  - the extension default (~:206);
  - `HeadlessHostEnvironment` (~:269).
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`: `HostRequest`, the new `HostWorktreeChange`, and `HostResponse`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift`:
  - `.capabilities` (:325);
  - the new cases;
  - a shared `visibleWorktree(_:)` helper, which replaces the three copied listed-and-not-hidden checks at :239, :273 and :345.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift`. Add `servedCapabilities` on `AlasHost`, and `WorktreesAPI.mutate` next to `renameBranch` (~:362).
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+BranchRename.swift`. Extract the inline idle switch into `isWorktreeIdle(_:)` and use it in `renameBranchWhileIdle`.
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeGit.swift`
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift`. Pass `hostCapabilities: host.servedCapabilities` in the `RemoteServerIdentity(...)` (~:309).
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`:
  - `RepoFixture` gains `init(environment: (any AlasHostEnvironment)? = nil)`;
  - `RecordingRunEnvironment` gains `var servesWorktreeGit = false` and `var blocksForCheckpoint = false`, the latter returned from `checkpointRecoveryBlocksRemoval`.

**Interfaces:**
- Produces:
  - Capability constants:
    - `HostProtocolCapability.worktreesGitV1 = "host.worktrees.git.v1"`. It is **not** in `served`.
    - `RemoteServerIdentity.init(..., hostCapabilities: [String] = HostProtocolCapability.served)`. `hello` advertises `identity.hostCapabilities` in place of `HostProtocolCapability.served`.
  - Environment flag: `AlasHostEnvironment.servesWorktreeGit: Bool { get }`. It defaults to `false` and is `true` in `HeadlessHostEnvironment`.
  - `AlasHost.servedCapabilities: [String]` returns `served + [worktreesGitV1]` when `core.environment.servesWorktreeGit`. The `.capabilities` response returns it.
  - The change enum:

    ```swift
    public enum HostWorktreeChange: Codable, Equatable, Sendable {
        case stage(paths: [String]), unstage(paths: [String]), discard(paths: [String])
        case commit(subject: String, body: String, amend: Bool)
        case push(forceWithLease: Bool), pull, fetch
    }
    ```

  - New requests:
    - `HostRequest.mutateWorktree(worktree: WorktreeRef, branch: String, change: HostWorktreeChange)`, answered `.done`;
    - `HostRequest.commitMessageInput(worktree: WorktreeRef)`, answered `HostResponse.commitMessageInput(input: CommitMessageSuggestionInput)`.
  - `WorktreesAPI.mutate(_ worktree: Worktree, branch: String, change: HostWorktreeChange, caller: HostCaller) async throws`
  - `AlasCoreContext.mutateListedWorktree(_ worktree: Worktree, branch: String, change: HostWorktreeChange) async throws`
  - `AlasCoreContext.isWorktreeIdle(_ worktree: Worktree) -> Bool`

- [ ] **Step 1: Write the failing tests** in `HostProtocolServerTests`. `RepoFixture`'s project is the template repo on `main`. Its main worktree is `ref`, with branch `"main"`. Each test runs `git config user.name Test` and `user.email test@example.com` in the repo first.

```swift
/// A staged rename is unstaged and discarded as both paths, as locally.
@Test(arguments: [
    (HostWorktreeChange.unstage(paths: ["renamed.sh"]), " D .alas/scripts/hello.sh\n?? renamed.sh\n"),
    (HostWorktreeChange.discard(paths: ["renamed.sh"]), ""),
])
func renamesAreUnstagedAndDiscardedAsBothPaths(change: HostWorktreeChange, porcelain: String) async throws {
    // git mv .alas/scripts/hello.sh renamed.sh
    #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change)) == .done)
    #expect(try await Process.git(["status", "--porcelain"], cwd: repo).stdout == porcelain)
}

@Test func commitThenAmendRewordsTheNewCommit() async throws {
    // write new.txt; .stage(paths: ["new.txt"]) == .done
    // .commit(subject: "Add new", body: "", amend: false) == .done → `git log -1 --format=%s` == "Add new"
    // .commit(subject: "Reword", body: "Why", amend: true) == .done → `%s` == "Reword", `%b` == "Why\n",
    //   `git rev-list --count HEAD` == "2\n"
}

enum Refusal: CaseIterable { case branchChanged, staleDiscard, pendingCheckpoint, appHost, hidden }
@Test(arguments: Refusal.allCases)
func gitActionsAreRefused(_ refusal: Refusal) async throws {
    // branchChanged: branch "other", change .stage(paths: ["x"])
    //   → .failure(.failed(message: "The worktree changed since it was listed."))
    // staleDiscard: .discard(paths: ["missing.txt"])
    //   → .failure(.failed(message: "These changes are no longer in the worktree."))
    // pendingCheckpoint: RecordingRunEnvironment(servesWorktreeGit: true, blocksForCheckpoint: true)
    //   → .failure(.failed(message: "A checkpoint restore is pending on the host; finish it there first."))
    // appHost: RecordingRunEnvironment() → .failure(.invalidRequest(reason: "This host does not serve git actions.")),
    //   and `.capabilities` does not contain HostProtocolCapability.worktreesGitV1
    // hidden: core.projects.setWorktreeHidden(..., hidden: true)
    //   → .failure(.notFound(what: "worktree \(ref.path) in project \(projectID)"))
}
```

- [ ] **Step 2: Run them to verify they fail.** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostProtocolServerTests`. Expected: compile errors for `mutateWorktree` and `HostWorktreeChange`.
- [ ] **Step 3: Implement the server cases.**
  - `visibleWorktree(_ ref:) throws -> Worktree` is `worktree(ref)` plus the hidden check, which throws `notFound`.
  - `gitWorktree(_ ref:)` first checks `host.servedCapabilities.contains(worktreesGitV1)`, else throws `invalidRequest("This host does not serve git actions.")`, then returns `visibleWorktree(ref)`.
  - `.mutateWorktree` goes to `host.worktrees.mutate(...)`.
  - `.commitMessageInput` goes to `CommitMessageSuggestionInput.load(worktreePath:ticketTitle:)`. The ticket title is `projects.issueAttachment(projectId:worktreeId:)?.title`.
- [ ] **Step 4: Implement `mutateListedWorktree`** under `ProjectMutationGate.shared.withMutation(projectID:)`, mirroring `renameListedWorktreeBranch`.
  - Validation, in order:
    1. `refuseIfStopping()`.
    2. Re-find the listed worktree by id; if `listed.branch != branch`, refuse with the changed message.
    3. If `!isWorktreeIdle(listed)`, throw `WorktreeBusyError()`.
    4. If `await environment.checkpointRecoveryBlocksRemoval(listed)`, refuse with the checkpoint message.
  - Mapping, all on `GitService()` against `listed.path`:
    - `stage`: `stageAll(files: paths)`.
    - `unstage`: read `status`, then `unstageAll(files:)` on each path's matching `ChangedFile.gitPaths`. A path not in the status is passed through as is.
    - `discard`: read `status`, then take the union of `ChangedFile.discardPaths(forFileAt:in:)` over the paths, keeping order and removing duplicates. If it is empty, refuse with the stale message; otherwise call `discardPaths(files:)`.
    - `commit`: a subject that is blank after trimming is refused with `invalidRequest("A commit needs a subject.")`; otherwise call `commit(worktreePath:subject:body:amend:)`.
    - `push`, `pull`, `fetch`: implemented in Task 4. Throw `invalidRequest` until then.
- [ ] **Step 5: Run the tests to verify they pass.** Same command. Expected: `✔ Suite "HostProtocolServerTests" passed`, and `renameBranchRenamesALinkedWorktreeOnly` still passes.
- [ ] **Step 6: Commit.** `feat(alas-host): stage, unstage, discard and commit from a paired Mac`

### Task 4: Push, pull and fetch on the host

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext+WorktreeGit.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasCoreContext+ReviewStatus.swift`. Make `refreshFollowedReviewStatus` internal and `@discardableResult`.
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`

**Interfaces:**
- Consumes: `ReviewLoopSnapshot.pushArguments(forceWithLease:)` (Task 1); `ProcessResult.pushFailureMessage` (`AlasPlatform/Git/ProcessResult+PushFailure.swift`).
- Produces: after **every** successful change, `mutateListedWorktree` calls `await refreshFollowedReviewStatus(worktree.id)` outside the gate. Task 5 hooks its event there.

- [ ] **Step 1: Write the failing test.**

```swift
/// The Mac learns why a pull stopped, and the host is left mid-rebase to resolve there.
@Test func pullStoppedOnConflictsSaysToResolveOnTheHost() async throws {
    // origin = GitTemplate copy at root/origin. In repo: remote add origin, fetch, branch --set-upstream-to=origin/main.
    // Commit different contents of .alas/scripts/hello.sh in origin and in repo (-c user.name/-c user.email).
    #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .pull))
        == .failure(error: .failed(message: "Pull stopped on conflicts; resolve them on the host.")))
    #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/rebase-merge").path))
}
```

- [ ] **Step 2: Run it to verify it fails.** `... --filter HostProtocolServerTests/pullStoppedOnConflictsSaysToResolveOnTheHost`. Expected: FAIL (`invalidRequest`).
- [ ] **Step 3: Implement the three cases.**
  - `pull`: call `GitService().pull(worktreePath:)`.
    - `.conflict` refuses with the conflict message.
    - `.error(m)` becomes `HostError.failed(m)`.
    - `PullError.noUpstream` surfaces its own message.
  - `fetch`: what the local "Fetch now" does (`RightPaneState.refreshSyncStatus(force: true)`).
    - For the upstream, use `resolveUpstreamRef` and its remote and branch.
    - For the base, use `resolveBaseRef(worktreePath:baseBranch: environment.configuration().worktrees.baseBranch, preferLocal: false)` when it has a remote.
    - Call `fetchRef` for each one found, and throw the first failure.
  - `push`:
    - `await refreshFollowedReviewStatus(id)` first, inside the gate, then take `reviewLoops[id]?.snapshot`. If it is nil, refuse with the push-target message.
    - Run `Process.git(snapshot.pushArguments(forceWithLease:), cwd: listed.path)`.
    - A non-zero exit becomes `HostError.failed(result.pushFailureMessage)`.
- [ ] **Step 4: Run the suite to verify it passes.** Expected: `✔ Suite "HostProtocolServerTests" passed`.
- [ ] **Step 5: Commit.** `feat(alas-host): push, pull and fetch from a paired Mac`

---

## PR B — sync and review state to the peer

### Task 5: Codable review snapshot, `reviewStatus` read and event, peer channel state

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Integrations/CodeHost/CodeHostModels.swift`. Add same-file `extension X: Codable {}` (synthesized) for `ReviewLoopSnapshot`, `ReviewLoopLocalState`, `CodeHostProviderCapabilities`, `ReviewRequest`, `ReviewCheck`, `ReviewThread` and `ReviewComment`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift` and `HostProtocolServer.swift` (new request and response, gated by `gitWorktree(_:)`).
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Events.swift`:
  - the `HostEvent` case;
  - `key`;
  - `HostEventKey`;
  - `optInKind`;
  - `HostEventSource` publishing.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift`. Add the hook next to `reviewStatusRefresh` (:128).
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasCoreContext+ReviewStatus.swift`. Call the hook at the end of `refreshFollowedReviewStatus`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift`. Update `State`, `apply`, and the accepted kinds (:119).
- Test: `HostProtocolServerTests.swift` and `PeerHostChannelTests.swift`.

**Interfaces:**
- Produces:
  - Request and response:
    - `HostRequest.reviewStatus(worktree: WorktreeRef)`, answered `HostResponse.reviewStatus(snapshot: ReviewLoopSnapshot?)`.
    - The host first awaits `refreshFollowedReviewStatus(id)`, so the answer is fresh, and returns `host.reviews.status(of:)`.
  - The event:
    - `HostEvent.reviewStatus(worktreeID: String, snapshot: ReviewLoopSnapshot?)`, with `optInKind` `"reviewStatus"`.
    - Its key is the new `HostEventKey.reviewStatus(String)`.
    - Add the case to every exhaustive `switch` the compiler flags.
  - The publishing hook:
    - `AlasCoreContext.reviewStatusDidRefresh: (@MainActor (String) -> Void)?`, `@ObservationIgnored`.
    - It is set by `HostEventSource.init` to `publishReviewStatus(_:)`.
    - That function publishes only when `core.reviewLoops[id]?.snapshot` differs from the source's last published value for `id`, kept in `[String: ReviewLoopSnapshot]`.
  - Peer channel state:
    - `PeerHostChannel.State.reviewStatuses: [String: ReviewLoopSnapshot]`, keyed by worktree id, empty from a snapshot.
    - `.reviewStatus` sets or clears its entry; `.worktreeRemoved` drops it.
    - `connect()` accepts `["notice", "worktreeNotice", "reviewStatus"]`.

- [ ] **Step 1: Write the failing tests.**

```swift
// HostProtocolServerTests (in-memory Fixture). The hook sets the loop's snapshot:
// core.reviewStatusRefresh = { _ in core.reviewLoop(for: fixture.worktree, baseBranch: "main").setSnapshotForTests(snapshot) }
// where snapshot = ShepherdFixtures.snapshot(ShepherdFixtures.request()).
/// Only a client that accepts `reviewStatus` hears it, intact over the wire.
@Test func aReviewStatusReachesOnlyClientsThatAcceptIt() async throws {
    // plain: .subscribe(after:); accepting: .subscribeAccepting(after:, events: ["reviewStatus"])
    // accepting sends .reviewStatus(worktree: ref) → response == .reviewStatus(snapshot: snapshot)
    // accepting's next events == [.reviewStatus(worktreeID: fixture.worktree.id, snapshot: snapshot)]
    // decode(encode(that HostServerMessage)) == it
    // then setOperationState(.archiving) and wait for plain's next batch: it contains no .reviewStatus
}

// PeerHostChannelTests
@Test func aReviewStatusIsKeptPerWorktreeUntilTheWorktreeIsRemoved() async {
    let (channel, _) = await connected([feature])
    channel.receive(.events(events: [.reviewStatus(worktreeID: feature.worktree.id, snapshot: s)], cursor: cursor))
    #expect(channel.state?.reviewStatuses[feature.worktree.id] == s)
    channel.receive(.events(events: [.worktreeRemoved(projectID: "p", worktreeID: feature.worktree.id)], cursor: cursor))
    #expect(channel.state?.reviewStatuses[feature.worktree.id] == nil)
}
```

  Also update `connectTakesASnapshotThenSubscribesAfterItsCursor` to expect `events: ["notice", "worktreeNotice", "reviewStatus"]`.
- [ ] **Step 2: Run them to verify they fail.** Use `--filter HostProtocolServerTests` and `--filter PeerHostChannelTests`. Expected: compile errors.
- [ ] **Step 3: Implement.** Add the Codable extensions, the request and response, the event and its key, the hook, and the channel state.
- [ ] **Step 4: Run them to verify they pass.** Run both suites, then `--filter AlasHostTests` (the review-follow tests). Expected: all `✔`.
- [ ] **Step 5: Commit.** `feat(alas-host): send a followed worktree's review status to paired Macs`

---

## PR C — peer UI

### Task 6: The shared pill decision for a peer, and showing a host's snapshot

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Integrations/CodeHost/ReviewReadinessModel.swift`. Change the init (:102) and the private `actions(_:applying:)`, and add the static next to `ReviewReadinessActionKind` (~:409).
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Integrations/CodeHost/ReviewLoopState.swift`. Add the method next to `setSnapshotForTests` (:648).
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewLoopDrawer.swift`. Add the param and pass it to `model`.
- Test: `AlasTests/Integrations/ReviewReadinessModelTests.swift` (extend; CI only).

**Interfaces:**
- Produces:
  - `ReviewReadinessModel.init(snapshot:lastError:canOpenAgentHandoff:inFlightAction:servedActions: Set<ReviewReadinessActionKind>? = nil)`.
    - With a set, it drops actions whose kind is not in it.
    - An emptied list falls back to `[refresh]`.
    - `nil` keeps today's behaviour.
  - `extension ReviewReadinessActionKind { public static let peerServed: Set<Self> = [.refresh, .pushBranch, .forcePushBranch, .openReviewRequest] }`
  - `ReviewLoopState.showHostSnapshot(_ snapshot: ReviewLoopSnapshot?)` sets `snapshot` and clears `lastError`. It is for a pane that never refreshes the loop itself.
  - `ReviewLoopDrawer(..., servedActions: Set<ReviewReadinessActionKind>? = nil)`

- [ ] **Step 1: Write the failing test.** Use the suite's `makeSnapshot`, `makeLocal` and `makeReviewRequest` helpers.

```swift
/// A peer's pill offers the host-served actions exactly when local would, and never PR creation or merge.
@Test(arguments: [
    (Self.makeSnapshot(local: Self.makeLocal(needsPush: true), reviewRequest: nil), [ReviewReadinessActionKind.pushBranch]),
    (Self.makeSnapshot(local: Self.makeLocal(needsPush: false, aheadCommitCount: 1), reviewRequest: nil), [.refresh]),
    (/* approved clean request, as approvedCleanRequestExposesMergeAction */ ..., [.openReviewRequest]),
])
func aPeerPillOffersOnlyWhatTheHostServes(snapshot: ReviewLoopSnapshot, kinds: [ReviewReadinessActionKind]) {
    let model = ReviewReadinessModel(snapshot: snapshot, lastError: nil, canOpenAgentHandoff: false,
                                     servedActions: ReviewReadinessActionKind.peerServed)
    #expect(model.actions.map(\.kind) == kinds)
}
```

- [ ] **Step 2: Implement.** Thread `servedActions` through the init and the private `actions` helper. Add `peerServed`, `showHostSnapshot`, and the drawer param.
- [ ] **Step 3: Verify.** `swift build --package-path Packages/AlasCore`. The test runs in CI.
- [ ] **Step 4: Commit.** `feat(review): limit the review pill to the actions a host serves`

### Task 7: The peer pane runs git actions on the host

App-only and mechanical. It has no tests of its own (view and wiring), and CI is its first build.

**Files:**
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift`. Add the git API next to `renameBranch` (:162–:180), and mirror `reviewStatuses` in the channel `onChange` (:203) where `worktrees[serverId]` is set.
- Modify: `Alas/Sources/Right/NativePeerChangesView.swift`:
  - optional git actions;
  - non-read-only rows;
  - the header context menu;
  - a `NativePeerCommitSheet` struct added at the end of this file. No new file.
- Modify: `Alas/Sources/Right/NativePeerRightPaneView.swift`:
  - `gitTarget`;
  - the follow;
  - the error strip;
  - the discard alert;
  - the commit sheet;
  - the pill, behind chip and Fetch in the toolbar.

**Interfaces:**
- Consumes: Tasks 3–6. That means `HostRequest.mutateWorktree`, `.commitMessageInput`, `.reviewStatus`, `.followWorktree` and `.unfollowWorktree`; `PeerHostChannel.State.reviewStatuses`; `ReviewReadinessActionKind.peerServed`; `ReviewLoopState.showHostSnapshot`; and `PendingDiscard` (`Alas/Sources/Right/PendingDiscard.swift`).
- Produces, in `NativePeerHosts`:
  - `func servesGit(serverId: String) -> Bool`: subscribed and `supports(serverId, HostProtocolCapability.worktreesGitV1)`.
  - `func mutate(_ change: HostWorktreeChange, in worktree: PeerHostWorktree, serverId: String) async -> String?`:
    - returns nil when `.done`;
    - otherwise returns `PeerWorktreeRemoval.message(for:)` or the peer-unavailable message;
    - sends `branch: worktree.snapshot.worktree.branch` with `timeout: .seconds(120)`. A pull is a fetch plus a rebase, each up to 30 s on the host.
  - `func commitMessageInput(in worktree: PeerHostWorktree, serverId: String) async -> CommitMessageSuggestionInput?`
  - `func reviewStatus(in worktree: PeerHostWorktree, serverId: String) async -> ReviewLoopSnapshot?`
  - `private(set) var reviewStatuses: [String: [String: ReviewLoopSnapshot]]`, keyed by server id, then worktree id.
  - `func followGit(_ worktree: PeerHostWorktree?, serverId: String?)`:
    - unfollows the previous target and follows the new one;
    - re-sends `followWorktree` when the channel becomes subscribed again (track a per-channel "sent" flag, reset when `isSubscribed` turns false). Host-side follows end with the subscription.

- [ ] **Step 1: Wire the git API in `NativePeerHosts`.**
- [ ] **Step 2: Rows and header in `NativePeerChangesView`.** Add `var git: Git? = nil`, where `struct Git { let onStage: ([ChangedFile]) -> Void; let onUnstage: ([ChangedFile]) -> Void; let onDiscard: (PendingDiscard) -> Void; let onCommit: () -> Void }`. With `git` set, the working-tree section:
  - passes `readOnly: false`, `onStageAll`, `onUnstageAll`, `onDiscardFile` and `onDiscardFolder` to `WorkingTreeRowActions`;
  - gets the local header context menu: Stage All, Unstage All, Divider, "Discard all working tree changes…";
  - gets a "Commit…" button in the header when anything is staged;
  - builds each `PendingDiscard` exactly as `RightPaneState.requestDiscard*` does (target and file count), with `paths` set to the **unexpanded** `ChangedFile.path`s. The host expands renames itself.

  Commit rows stay read-only.
- [ ] **Step 3: The peer right pane.** Add a `gitTarget` computed like `runTarget`: the selected worktree's `PeerHostWorktree` when `hosts.servesGit`. Then:
  - Follow: on `gitTarget` change, call `hosts.followGit`, then seed a `@State` `ReviewLoopState` with `showHostSnapshot(await hosts.reviewStatus(...))`. Feed it `hosts.reviewStatuses[serverId]?[worktreeID]` on change.
  - Error strip: `@State gitError: String?`, shown as a `NativePeerRailMessage` above the Changes content. Every action clears it before running, sets it from `mutate`'s return, then calls `client.reloadWorkspace()`.
  - Discard: present `PendingDiscard.alertTitle` and `alertMessage` exactly as `RightPaneView.swift:400–:423` does. Confirming sends `.discard(paths: pending.paths)`.
  - Pill: `ReviewLoopDrawer(state: loop, canOpenAgentHandoff: false, onAction:, servedActions: .peerServed)` below the Changes tab content, outside `NativePeerChangesView`, so it shows with no changes too. Actions:
    - `.refresh` re-reads `reviewStatus`;
    - `.pushBranch` and `.forcePushBranch` send `.push(forceWithLease: kind == .forcePushBranch)`, bracketed by `loop.beginAction` and `endAction`;
    - `.openReviewRequest` calls `NSWorkspace.shared.open(url)`.
  - Behind chip: in the toolbar, after the branch name, show `BehindChip(count: local.upstreamAheadCommitCount, role: .upstream, inFlight: pullInFlight, onTap: { .pull }, ref: "\(remote)/\(branch)")`. Show it when the snapshot has an upstream, `upstreamAheadCommitCount > 0` and a non-empty branch, the same rule as `showBehindUpstreamChip`.
  - Fetch: next to the chip, a borderless `Menu` with "Fetch now" that sends `.fetch`.
  - Commit sheet: `.sheet` showing `NativePeerCommitSheet(subject, body, amend, error, onCommit:)`.
    - On appear, if `appState.commitMessageSuggestionAvailable`, it calls `hosts.commitMessageInput`, then `appState.makeCommitMessageSuggester().suggest(for:)`. The result fills only fields that are still blank.
    - Commit sends `.commit(subject:body:amend:)`. It dismisses when the result is nil, and otherwise shows the error line.
  - Hosts without `git.v1` keep today's read-only rail unchanged.
- [ ] **Step 4: Verify.** `swift build --package-path Packages/AlasCore` (unchanged core). Push and let CI build the app. Expected: CI `build-test` green, including `ReviewReadinessModelTests`.
- [ ] **Step 5: Commit.** `feat(remote): stage, commit, push and pull a host worktree from the peer pane`

---

## Self-review notes

- **Spec coverage.**

  | Spec item | Where |
  |---|---|
  | Stage, unstage and discard (file, folder, all) | Tasks 3 and 7 |
  | Rename expansion | Tasks 1 and 3 |
  | Discard confirmed on the Mac | Task 7 |
  | Commit and amend | Tasks 3 and 7 |
  | On-Mac suggestion | Tasks 1, 3 and 7 |
  | Push, pull and fetch | Tasks 4 and 7 |
  | Conflict message | Task 4 |
  | Validation, gate, checkpoint | Task 3 |
  | Never prompts | Task 2 |
  | Reload after a mutation | Task 7 |
  | Capability, headless only | Task 3 |
  | Errors in the strip and sheet | Task 7 |
  | Sync and review state, live | Task 5 |
  | Shared pill model | Task 6 |
  | Behind chip and fetch | Task 7 |
  | `reviewLoopPushArguments` moved to core | Task 1 |

- **Deliberate gaps.**
  - The behind-base chip is not shown on the peer, because it is not actionable.
  - Amend does not prefill HEAD's message.
  - There is no push integration test. Pushing to a non-bare template origin is refused, and the arguments are already pinned by `RightPaneStateReviewLoopPushTests`.
  - The host's review refresh does not fetch, so the behind count is as fresh as the last Fetch or pull. Locally it is refreshed by a throttled fetch.
