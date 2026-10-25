# Peer Reviews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac paired with a headless `alas-host` lists a host worktree's draft reviews and opens them in the same `DiffReviewSurface` as local work. Comments go both ways. The Mac gets a banner when an agent opens a review or replies to a comment.

**Architecture:**
- **Host side.** One headless-only capability, `host.reviews.v1`, covers three requests: `listReviews`, `readReview` and `mutateReview`.
  - The host owns comment identity. Every write goes through `ReviewsAPI`, and both the agent and the Mac validate file identity with the same `fileIDNamespace` function.
  - An opt-in `reviewsChanged(worktreeID:)` event tells the Mac to read again.
  - Notices travel on the existing `worktreeNotice` relay, which gains an optional `reviewSessionID`.
- **Mac side.** A thin `NativePeerReviewView` wraps `DiffReviewSurface`. The existing app loaders (`ReviewChangesLoader`, `CommitReviewLoader`, `RangeReviewLoader`) build its session. They are fed by a `NativePeerReviewGitClient`, which answers their git-client protocols with host-channel reads. The loaders therefore produce the same `DiffReviewFileID`s that the host files comments under.

**Tech Stack:** Swift 6 / SwiftUI app, `Packages/AlasCore` SwiftPM (UI-free), Swift Testing, real git.

**Spec:** `docs/superpowers/specs/2026-10-25-peer-reviews-design.md`. Its "Decisions from the builder check" override its Goals.

**PR split:**
- **PR A** (Tasks 1–4): the host. Wire types, list/read/mutate, the change event, notices, and the headless local-changes review.
- **PR B** (Tasks 5–6): the peer review tab and Reviews list for `localChanges`, `commit` and `trackedCommit`.
- **PR C** (Tasks 7–9): ranges and branches, and a notice click that opens its review.

Land them in order. Until B lands, nothing sends the new requests.

**Deviation from the suggested shape:** the Reviews list moves into B, so that B's tab can be reached. C keeps ranges, branches and the notice click.

## Global Constraints

- AGENTS.md (origin/main):
  - Swift Testing only, with minimal, sharp tests. Don't test views or wiring.
  - Core imports no SwiftUI, AppKit, GhosttyKit, MLX, TreeSitterPack or FffC.
  - Anything the app uses from core is `public`. Public cross-module types are explicitly `Sendable`.
  - Conventional Commits, with no attribution trailers or footers.
- Core tests: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`.
- Tests use real git and temp dirs. **Never the real profile:** every `AlasCoreContext` built in a test passes `reviewDrafts: ReviewDraftCommentStore(url: <tmp>)` and `reviewSessions: ReviewSessionStore(url: <tmp>)`.
- The app can't be built locally, so CI is its first build.
  - Keep `Alas/` and `AlasTests/` edits mechanical.
  - Add **no new files** under `Alas/` or `AlasTests/`, so no xcodegen run is needed.
  - Say in each PR body that the app tests ran on CI only.
- No change to local review behaviour or storage. The host never persists a `ReviewSessionRecord` for the synthesized local-changes entry. The Mac never writes host review files.
- Copy (verbatim):
  - Notices:
    - `"Agent opened a review"` (title).
    - `"<author> replied to review feedback"` (title). This matches `AttentionProducer.reviewReply`.
  - Errors:
    - `"This host does not serve reviews."`
    - `"Not available from this Mac yet."`
    - `"Only file and line comments can be added from a paired Mac."`
  - Truncation:
    - `"The host cut off part of this review; some files or lines are not shown."`

## Review Focus

1. **Partial staging.** When one path is both staged and unstaged, a Mac comment on the staged section must stay on `staged`. The agent default picks unstaged, which would move it.
   - Tested by Task 2, `aMacCommentKeepsTheStageItWasFiledOn`.
   - Tested by Task 5, `hostFiledCommentsLandOnTheFileThePeerLoaderBuilds`.
2. **Stale anchors.** A comment whose file no longer differs must still come back from `readReview` and still count as open. It must not vanish. Tested by Task 1, `aReviewReadsEveryCommentOfItsSession`.
3. **Truncated host replies.** File lists capped at `maxChangedFiles` and hunks capped by `truncateHunks` must surface as a banner, not as a silently partial review. Tested by Task 5, `aTruncatedHostReplyIsReported`.
4. **Trust boundary.** A Mac must not read or write another worktree's or project's session, or a comment that belongs to a different session than the one named. Tested by Task 2, `macMutationsStayInsideTheirReview`.
5. **Old or app hosts.** An app host or a pre-reviews host must not advertise or serve the requests. The Mac then shows no Reviews section. Tested by Task 1, `reviewRequestsAreServedOnlyByAHeadlessHost`, plus the capability assertions in `HostProtocolTests` and `HostSessionsTests`.

---

## PR A — host

### Task 1: Wire types, capability, list and read

**Files:**
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`:
  - Add the requests after `reviewStatus` (`:134`).
  - Add the responses before `failure`.
  - Add the new types after `HostWorktreeRead`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift:1485`: add the capability.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift:36`: change `servedCapabilities`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift`:
  - Dispatch near `:355`.
  - Add a `reviewWorktree(_:)` gate next to `gitWorktree`.
- Create `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+PeerReviews.swift`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift`: add `openedLocalChangesReviews`, which Task 4 populates.
- Test `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`:
  - Change `RepoFixture.init` to pass temp review stores under `root`.
  - Add the new tests.
- Test `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolTests.swift`: round trips and the capability check (`:177`).
- Test `Packages/AlasCore/Tests/AlasCoreTests/HostSessionsTests.swift:495`: the expected capabilities gain `reviewsV1`.

**Interfaces:**
- Produces (all `public`, `Codable, Equatable, Sendable`):
  ```swift
  // HostProtocolCapability
  public static let reviewsV1 = "host.reviews.v1"   // "listReviews, readReview and mutateReview: only a headless host"
  // HostRequest
  case listReviews(worktree: WorktreeRef)
  case readReview(worktree: WorktreeRef, sessionID: String)
  case mutateReview(worktree: WorktreeRef, sessionID: String, mutation: HostReviewMutation)
  // HostResponse
  case reviews(reviews: [HostReviewSummary])
  case review(review: HostReview)
  public struct HostReviewSummary {
      /// Synthesized, never saved, for a local-changes review with no record.
      public var record: ReviewSessionRecord
      public var openCommentCount: Int
      public var sessionID: String { record.target.draftSessionID.rawValue }
  }
  public struct HostReview { public var summary: HostReviewSummary; public var comments: [ReviewDraftComment] }
  public enum HostReviewMutation {
      case add(fileID: DiffReviewFileID, path: String, originalPath: String?, anchor: ReviewDraftCommentAnchor, body: String)
      case edit(commentID: String, body: String)
      case delete(commentID: String)
      case resolve(commentID: String)
      case dismiss(commentID: String)
  }
  // AlasCoreContext
  @ObservationIgnored public var openedLocalChangesReviews: Set<String> = []  // worktree ids; ponytail: in memory, lost on restart; comments still list it
  // ReviewsAPI (AlasHost+PeerReviews.swift)
  public func list(in worktree: Worktree) throws -> [HostReviewSummary]
  public func read(_ sessionID: String, in worktree: Worktree) throws -> HostReview
  ```
- `servedCapabilities` appends `[worktreesGitV1, reviewsV1]` when `servesWorktreeGit`. Don't add a second environment flag.

- [ ] **Step 1: Write the failing tests** in `HostProtocolServerTests`. The repo comes from `RepoFixture`. The agent comments come from `host.reviews.addComment(origin:path:startLine:endLine:side:body:sessionID:projectWorktrees:)`.
  ```swift
  @Test func reviewRequestsAreServedOnlyByAHeadlessHost() async throws
  // RepoFixture(environment: RecordingRunEnvironment()) (servesWorktreeGit false):
  // #expect(try await fixture.request(.listReviews(worktree: ref)) == .failure(error: .invalidRequest(reason: "This host does not serve reviews.")))

  @Test func theListSynthesizesLocalChangesOnceItHasComments() async throws
  // modified a.txt, no comments: #expect(try await fixture.request(.listReviews(worktree: ref)) == .reviews(reviews: []))
  // agent addComment on a.txt line 1, no session id:
  //   reviews.count == 1, reviews[0].record.target.kind == .localChanges, openCommentCount == 1,
  //   reviews[0].sessionID == ReviewDraftSessionID.localChanges(worktreeID:, worktreePath:, scope: .all).rawValue
  //   try core.reviewSessions.list(worktreeID:) == []      // not persisted
  // host.reviews.finish(... sessionID: nil, verdict: .approve, summary: "ok"):
  //   still one entry, now with record.verdict?.verdict == .approve (no duplicate)
  // host.reviews.open("HEAD", ...) adds a commit entry: kinds == [.commit, .localChanges] (updatedAt desc)

  @Test func aReviewReadsEveryCommentOfItsSession() async throws
  // agent comment on a.txt, then `git checkout -- a.txt` (file no longer differs):
  //   read returns that comment and openCommentCount == 1.
  // An unknown or foreign session id gives .failure(.notFound(what: "review <id>")).
  ```
- [ ] **Step 2: Run the tests and confirm they fail.** `... --filter HostProtocolServerTests`. Expected: compile errors for `listReviews`.
- [ ] **Step 3: Implement.**
  - Add the wire cases and types.
  - Add the gate: `reviewWorktree(ref)`. It throws `invalidRequest("This host does not serve reviews.")` unless `servedCapabilities.contains(reviewsV1)`, then returns `visibleWorktree(ref)`.
  - Add the dispatch.
  - `list`:
    - Take the records from `core.reviewSessions.list(worktreeID:)` whose `status != .archived`.
    - When no record has the `.localChanges(scope: .all)` draft id, and either comments exist for it or `openedLocalChangesReviews` contains the worktree, append one synthesized record. Build it with `ReviewSessionTarget.localChanges(worktreeID:repositoryPath:scope: .all)`. Its `createdAt` and `updatedAt` are the earliest and latest comment times, or `Date()` when there are none.
    - `openCommentCount` counts the `.active` comments of that draft id.
    - Sort by `updatedAt`, newest first.
  - `read`:
    - Parse the id with `ReviewDraftSessionID(rawValue:)` and require `isFor(worktreeID: worktree.id)`.
    - Find the summary in `list(in:)`; if it's missing, throw `notFound`.
    - The comments are `core.reviewDrafts.load(sessionID:)`.
- [ ] **Step 4: Add round trips and capability assertions.**
  - Add `listReviews`, `mutateReview(.add(...))`, `.reviews` and `.review` to `clientMessagesRoundTrip` and `serverMessagesRoundTrip`.
  - Extend `helloAdvertisesExactlyTheConsoleCapabilitiesItServes` with `#expect(!caps.contains(HostProtocolCapability.reviewsV1))`.
  - Update `HostSessionsTests:495` to `served + [worktreesGitV1, reviewsV1]`.
- [ ] **Step 5: Run and confirm everything passes.** `--filter HostProtocolServerTests`, `--filter HostProtocolTests`, `--filter HostSessionsTests`. Expected: all pass, and the `Test run with N tests` line shows N > 0.
- [ ] **Step 6: Commit.** `feat(alas-host): list and read a worktree's reviews for paired Macs`.

### Task 2: Mac mutations

**Files:**
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+Reviews.swift`: change `fileIDNamespace` (`:386`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+PeerReviews.swift`.
- Modify `HostProtocolServer.swift`: dispatch `mutateReview`.
- Test `HostProtocolServerTests`.

**Interfaces:**
- Consumes `HostReviewMutation` and `reviewWorktree` from Task 1.
- Produces:
  ```swift
  public func mutate(_ mutation: HostReviewMutation, sessionID: String, in worktree: Worktree, caller: HostCaller) async throws
  // fileIDNamespace gains `requested: String? = nil`; agent callers keep passing nil.
  ```
- Semantics mirror the local `ReviewDraftCommentController` and `ReviewDraftWorkspaceActions`:
  - **add.** The author is `.user`. The anchor must be `.file` or `.line`, else `invalidRequest("Only file and line comments can be added from a paired Mac.")`.
    - The session kind must be `localChanges`, `commit`, `trackedCommit`, `commitRange` or `branch`. Otherwise refuse with `invalidRequest("Not available from this Mac yet.")`.
    - The path goes through `worktreeRelativePath`.
    - The namespace is `fileIDNamespace(..., requested: fileID.namespace)`. For local changes, the requested stage must exist for the path and be allowed by the scope. For other kinds, it must equal the resolved namespace. A `.failed(message)` becomes `invalidRequest(message)`.
    - The comment is stored with `fileID` exactly as validated.
  - **edit.** Allowed only while the comment is active. Sets `bodyMarkdown` and `updatedAt`.
  - **delete.** Allowed in any state: `store.delete(commentID:sessionID:)`.
  - **resolve.** Allowed while active. Sets `state = .resolved`, `resolvedBy = .user`, then `ReviewHandoffProgress.recomputeAndPersist`, the same call `resolve` uses.
  - **dismiss.** Allowed while active. Sets `state = .dismissed`.
  - **Every comment mutation:** the comment must exist, and `comment.sessionID.rawValue == sessionID`. Otherwise `notFound(what: "review comment <id>")`. A state that doesn't allow the action gives `invalidRequest`.
  - Each successful mutation ends with `core.reviewCommentsDidChange()`. Task 3 replaces this with `didChange(worktreeID:)`.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test(arguments: [("staged", true), ("unstaged", true), ("commit", false)])
  func aMacCommentKeepsTheStageItWasFiledOn(namespace: String, accepted: Bool) async throws
  // a.txt staged, then modified again (both stages). mutate(.add(fileID: .init(namespace:, path: "a.txt"), ... .line(side: .new, startLine: 1, ...)))
  // accepted → the stored comment's fileID.namespace == namespace and author == .user
  // rejected → .failure(.invalidRequest(...)) and nothing stored

  @Test func macMutationsStayInsideTheirReview() async throws
  // A comment in the local-changes session. mutate(.edit) naming a commit session id → notFound.
  // A session id of another worktree (another RepoFixture project) → notFound. An unknown comment id → notFound.

  @Test func macMutationsActAsTheUser() async throws
  // edit → body changed. resolve → state .resolved, resolvedBy == .user. edit after resolve → invalidRequest.
  // dismiss of an active one → .dismissed. delete → gone from read(...).comments.
  ```
- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement** `mutate` and the `requested:` branch of `fileIDNamespace`. Log each mutation with `caller.log("reviews.mutate", sessionID)`.
- [ ] **Step 4: Run and confirm the tests pass.** `--filter HostProtocolServerTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): let a paired Mac add, edit, resolve, dismiss and delete review comments`.

### Task 3: `reviewsChanged` event

**Files:**
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Events.swift`: the event case, `key` (`:72`), `HostEventKey` (`:132`), and `optInKind` (`:582`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+Reviews.swift`:
  - `ReviewsAPI` gains `changed`. `AlasHost.reviews` passes `noteAttention`, as `attention` does.
  - Replace the four `core.reviewCommentsDidChange()` calls with `didChange(worktreeID:)`. `open` (in `AlasHost+ReviewOpen.swift`) also calls it on success.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift`:
  - `State.apply` (`:36`).
  - The subscribed kinds (`:128`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift:456`: the exhaustive list.
- Test `PeerHostChannelTests`.
- Test `HostProtocolServerTests`.

**Interfaces:**
- Produces:
  ```swift
  case reviewsChanged(worktreeID: String)          // HostEvent; optInKind "reviewsChanged"; key .reviews(worktreeID)
  // ReviewsAPI
  var changed: @MainActor ([HostEvent]) -> Void = { _ in }
  func didChange(worktreeID: String)   // core.reviewCommentsDidChange(); changed([.reviewsChanged(worktreeID:)])
  // PeerHostChannel.State
  public var reviewRevisions: [String: Int] = [:]  // bumped per reviewsChanged; dropped with the worktree, like reviewStatuses
  ```
- Keep `reviewCommentChanges` as `ChangeSignal<Void>`. An app test observes it (`AlasCLICommandRouterTests:1465`), and it carries no worktree id.
- The channel subscribes with `["notice", "worktreeNotice", "reviewStatus", "reviewsChanged"]`.

- [ ] **Step 1: Write the failing tests.**
  - Extend `connectTakesASnapshotThenSubscribesAfterItsCursor`: the expected events list gains `"reviewsChanged"`.
  - Add to `PeerHostChannelTests`:
    ```swift
    @Test func reviewChangesCountPerWorktreeUntilTheWorktreeIsRemoved() async
    // two .reviewsChanged(feature) batches → state?.reviewRevisions[feature.id] == 2; worktreeRemoved → nil
    ```
  - Add to `HostProtocolServerTests`:
    ```swift
    @Test func aReviewChangeReachesOnlyClientsThatAcceptIt() async throws
    // Two connections, one subscribeAccepting ["reviewsChanged"]. An agent addComment → the accepting client gets
    // .reviewsChanged(worktreeID: worktree.id); the plain one gets none (follow aReviewStatusReachesOnlyClientsThatAcceptIt's pattern).
    ```
- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm the tests pass.** `--filter PeerHostChannelTests`, `--filter HostProtocolServerTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): tell subscribers when a worktree's reviews change`.

### Task 4: Notices and the headless local-changes review

**Files:**
- Modify `AlasHost+Events.swift`: `HostWorktreeNotice` (`:118`).
- Modify `AlasHost+Reviews.swift`: the `reviewReplyAdded` helper (`:59`).
- Modify `AlasHost+ReviewOpen.swift`: `open` (`:26`).
- Modify `AlasHost+PeerReviews.swift`: add `openLocalChanges`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter+Headless.swift`: `isScreenBound` and `openReviewChanges`.
- Test `Packages/AlasCore/Tests/AlasCoreTests/HeadlessCLIRouterTests.swift`.
- Test `HostProtocolServerTests`.

**Interfaces:**
- Consumes `ReviewsAPI.changed` and `didChange` from Task 3.
- Produces:
  ```swift
  // HostWorktreeNotice
  public var reviewSessionID: String?   // init param `reviewSessionID: String? = nil`; an older Mac ignores it
  // ReviewsAPI
  public func openLocalChanges(in worktree: Worktree)   // inserts into openedLocalChangesReviews, didChange, opened-notice
  ```
- When `core.environment.relaysNotices` is set:
  - `reviewReplyAdded` also sends `changed([.worktreeNotice(.init(id: UUID(), worktreeID: <comment's worktree>.id, title: "\(reply.author.displayName) replied to review feedback", body: reply.bodyMarkdown, reviewSessionID: comment.sessionID.rawValue))])`.
  - `open` and `openLocalChanges` send a notice titled `"Agent opened a review"`, with body `opened.label` or `"local changes"`, and with `reviewSessionID` set.
- `isScreenBound` drops `.review(.localChanges)`, and the nil-session `commentAdd` and `finish` cases. Now that the Mac shows that review, they're no longer screen-bound. Update the doc comment to match.
- `headless(host:)` passes `openReviewChanges: { host.reviews.openLocalChanges(in: $0) }`.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  // HeadlessCLIRouterTests: remove the three review commands from `screenBound`, then add:
  @Test func reviewingLocalChangesOnAHeadlessHostListsIt() async
  // handle(.review(.localChanges(worktree: nil))) for a listed worktree → not the refusal;
  // core.openedLocalChangesReviews contains the worktree id
  // HostProtocolServerTests:
  @Test(arguments: [ReplyPath.reply, .resolveWithReply, .bareResolve])
  func agentRepliesNoticeTheMacWithTheirReview(_ path: ReplyPath) async throws
  // with RepoFixture's worktreeNotices(of:) helper: .reply and .resolveWithReply → one notice with
  // reviewSessionID == the comment's session id and title "Agent replied to review feedback"; .bareResolve → []
  @Test func anAgentOpeningAReviewNoticesTheMac() async throws
  // host.reviews.open("HEAD", in:, caller:) → one notice titled "Agent opened a review" with reviewSessionID == opened draft id
  ```
- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm the tests pass.** `--filter HeadlessCLIRouterTests`, `--filter HostProtocolServerTests`. Also run `--filter HostProtocolTests`. Add one `.worktreeNotice` with a `reviewSessionID` to `serverMessagesRoundTrip`.
- [ ] **Step 5: Commit.** `feat(alas-host): notice paired Macs when an agent opens or answers a review`.

## PR B — peer review tab

### Task 5: Peer git client and loader path

**Files:**
- Modify `Alas/Sources/Remote/Native/NativePeerWorkspace.swift`:
  - Make `hunk(_:)` and `changedFile(_:stage:)` internal.
  - Add `NativePeerReviewGitClient` below `NativePeerWorkspace`.
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`: add `static func peer(git:)`. It sits beside `production`, so it can use the private `filterLocalChanges` and `filteringFileList` helpers.
- Modify `Alas/Sources/Remote/Native/NativePeerHosts.swift`:
  - Add the review calls.
  - Mirror `reviewRevisions` in `makeChannel`'s `onChange`.
- Modify `AlasCoreContext+RemoteInspection.swift:706`: mark `remoteRead(_:in:replyingAs:)` `@_spi(Testing) public`.
- Test `AlasTests/Remote/NativePeerWorkspaceTests.swift`, which runs on CI only.

**Interfaces:**
- Consumes `HostReview`, `HostReviewSummary`, `HostReviewMutation` and `reviewsV1` from Tasks 1 and 2, and `reviewRevisions` from Task 3.
- Produces:
  ```swift
  /// The host's reads behind the review loaders. Per-file read failures become an empty diff, which the loaders show
  /// as their "No text diff" placeholder; a failed file list throws. No context expansion or images from a peer.
  struct NativePeerReviewGitClient: ReviewChangesGitClient, CommitReviewGitClient, RangeReviewGitClient {
      let read: @Sendable (HostWorktreeRead) async -> RemoteServerMessage?
      /// Set when any reply was cut off by the host's caps.
      let notes: Notes                          // final class Notes: @unchecked Sendable { @MainActor var truncated = false }
      var threeDot = false                      // rangeDiff has no threeDot argument (used from Task 8)
      func commitFiles(sha: String) async throws -> [CommitChangedFile]
  }
  struct NativePeerReviewGitClientError: Error { let message: String }
  // ReviewSessionLoader
  static func peer(git: NativePeerReviewGitClient) -> ReviewSessionLoader   // localChanges (all scopes), commit, trackedCommit; rest unsupportedTarget
  // NativePeerHosts
  private(set) var reviewRevisions: [String: [String: Int]] = [:]
  func servesReviews(serverId: String) -> Bool   // subscribed && supports(reviewsV1)
  func reviews(in worktree: PeerHostWorktree, serverId: String) async -> [HostReviewSummary]?
  func review(_ sessionID: String, in worktree: PeerHostWorktree, serverId: String) async -> HostReview?
  func mutateReview(_ mutation: HostReviewMutation, sessionID: String, in worktree: PeerHostWorktree, serverId: String) async -> String?  // error message; nil once done
  ```
- Client method mapping:
  - `status`: reads `.changes(comparisonMode: nil)` and returns `staged + unstaged` as `ChangedFile`s.
  - `imageStatus`: returns `[]`.
  - `diff(... staged:)`: reads `.fileDiff(path:, stage: "staged"/"unstaged", comparisonMode: nil)`.
  - `diff(sha:file:)`: reads `.commitDiff(sha:path:)`.
  - `commitFiles`: reads `.commitFiles(sha:)` and maps each entry to `CommitChangedFile(path:status:add:del:originalPath: renameFrom)`.
  - The `*ContextSnapshot` methods throw `NativePeerReviewGitClientError(message: "Not available from this Mac yet.")`.
  - The image providers have a `load` whose sides are failed.
  - `resolvedRangeTrees` returns `(base, head)`.
  - Every reply with `truncated: true` sets `notes.truncated`.
  - The batch `*DiffsByFile` methods keep their `[:]` defaults.
- `peer(git:)`'s `commit` closure takes the SHA from `.commit(sha)` or `.trackedCommit(revision).resolvedSHA`. It lists files with `git.commitFiles`. It calls `CommitReviewLoader(git:).load(worktreePath: target.repositoryPath, ...)` with `openFileForPath: { _ in nil }`.

- [ ] **Step 1: Write the failing tests** in `NativePeerWorkspaceTests`.
  - **Setup:** a temp repo (`git init -b main`, one commit of `a.txt`), and `AlasCoreContext(projects:runHistoryStore:environment: HeadlessHostEnvironment(), reviewDrafts:, reviewSessions:)` with temp stores. The worktree goes in through `insertOptimisticWorktree`, as `GatewayHostFixture` does.
  - **Client:** `read: { await core.remoteRead($0, in: worktree, replyingAs: worktree.id) }`.
  ```swift
  enum Kind: Sendable, CaseIterable { case localChanges, commit }   // Task 8 adds .commitRange, .branch
  @Test(arguments: Kind.allCases)
  func hostFiledCommentsLandOnTheFileThePeerLoaderBuilds(_ kind: Kind) async throws
  // localChanges: a.txt line 1 staged, then line 2 edited unstaged. Agent addComment (session nil) on line 2 →
  //   unstaged; Mac mutate(.add(fileID: "staged:a.txt", line 1)). commit: commit the edit, open("HEAD"), agent addComment line 1.
  // session = try await ReviewSessionLoader.peer(git: client).load(target: summary.record.target).session
  // for each comment in host.reviews.read(id, in:).comments:
  //   let file = try #require(session.files.first { $0.summary.id == comment.fileID })
  //   #expect(file.parsedDiff.hunks.flatMap(\.lines).contains { $0.newNumber == comment.startLine })
  @Test func aTruncatedHostReplyIsReported() async throws
  // fake read returning .fileDiffResult(..., truncated: true) for any fileDiff and a one-file changeList →
  //   after ReviewChangesLoader(git: client).load(...), #expect(client.notes.truncated)
  ```
- [ ] **Step 2: Commit the failing tests together with the implementation.** The app can't build locally, so CI is the first run.
- [ ] **Step 3: Implement** the client, `peer(git:)`, and the `NativePeerHosts` calls. The calls follow `runScripts` and `mutate`: guard on `servesReviews`, then `channel.request(...)`, and map `.failure(let e)` through `PeerWorktreeRemoval.message(for:)`.
- [ ] **Step 4: Verify.** Core: `--filter HostProtocolServerTests` still passes after the SPI change. App: CI runs `-only-testing AlasTests/NativePeerWorkspaceTests`. Check that its `Test run with N tests` count includes the new tests.
- [ ] **Step 5: Commit.** `feat(remote): load a host review's diff through the review loaders`.

### Task 6: Review tab and Reviews list

**Files:**
- Modify `Alas/Sources/Remote/Native/NativePeerDocumentView.swift`: add `NativePeerReviewView` below `NativePeerDocumentView`.
- Modify `Alas/Sources/Remote/Native/NativePeerSessions.swift`:
  - Add `openedReview`, `openReview` and `closeReview`.
  - Clear `openedReview` in `selectWorktree`.
- Modify `Alas/Sources/App/RootView.swift:408`: in `peerCenterContent`, check the review first.
- Modify `Alas/Sources/Right/NativePeerRightPaneView.swift:189`: add a Reviews section in the Changes tab, above `ReviewLoopDrawer`.

**Interfaces:**
- Consumes everything from Task 5.
- Produces:
  ```swift
  struct NativePeerReviewSelection: Equatable { let serverId: String; let worktree: PeerHostWorktree; let sessionID: String }
  // NativePeerSessions
  private(set) var openedReview: NativePeerReviewSelection?
  func openReview(_ sessionID: String, serverId: String, worktree: PeerHostWorktree)
  func closeReview()
  // NativePeerReviewView(hosts: NativePeerHosts, selection: NativePeerReviewSelection, codeFontFamily: String, codeFontSize: CGFloat, onClose: () -> Void)
  ```
- **Review view.**
  - On `.task(id: hosts.reviewRevisions[serverId]?[worktreeID])`, re-read `review(...)` and replace the comments.
  - Load the diff once on appear, and again from a refresh `ToolbarBtn`. ponytail: local changes don't live-refresh from the Mac; add a host diff event if that bites.
  - Feed `DiffReviewSurface` with `draftCommentsByFileID: ReviewDraftCommentGrouping.commentsByFileID(comments)`, `onSaveDraftComment` mapped to `.add`, and `ReviewDraftCommentActions(availability:edit:delete:resolve:dismiss:)` mapped to the matching mutations.
  - `availability` mirrors `ReviewDraftWorkspaceActions`: `canEdit`, `canResolve` and `canDismiss` follow `comment.isActive`; `canDelete` is `true`; the rest are `false`.
  - A mutation's error shows as a note in the header.
  - The header shows `record.target.title` and the verdict read-only (`record.verdict`).
  - Show the truncation note when `notes.truncated` is set.
  - When the loader throws `unsupportedTarget`, show `"Not available from this Mac yet."`.
- **Reviews section.** Shown when `gitTarget != nil && hosts.servesReviews(serverId:)`.
  - Rows come from `reviews(in:)`, re-read on `.task(id: "\(gitTargetKey)#\(revision)")`.
  - Each row shows `record.target.title`, `record.target.sourceDescription`, the open count, and the verdict.
  - Tapping a row calls `client.openReview(...)`.
  - Empty means no section.

- [ ] **Step 1: Implement.** There's no test, because views are excluded by policy; the decisions live in Task 5's client and the host.
- [ ] **Step 2: Verify.** Run CI's app build and the `NativePeerWorkspaceTests` and `NativePeerSessionsTests` suites. Smoke-test by hand against a headless host: comment from the Mac, then an agent `review_comments` shows it on the same path and line.
- [ ] **Step 3: Commit.** `feat(remote): open and comment on a host worktree's reviews`.

## PR C — ranges, branches, notice click

### Task 7: Range reads on the host

**Files:**
- Modify `HostProtocol.swift`: `HostWorktreeRead` (`:147`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteGatewayHostCalls.swift`:
  - The `RemoteWorktreeInspecting` requirements, with default failure implementations in an extension, so test fakes are untouched.
  - The `remoteRead` mapping (`:128`).
- Modify `AlasCoreContext+RemoteInspection.swift`: add the core implementations and their `WorktreeInspection` forwards.
- Test `HostProtocolServerTests`.

**Interfaces:**
- Produces:
  ```swift
  case rangeFiles(base: String, head: String, threeDot: Bool)
  case rangeDiff(base: String, head: String, threeDot: Bool, path: String, originalPath: String?)
  func remoteRangeFiles(sessionId: String, base: String, head: String, threeDot: Bool) async -> RemoteCommitFilesResult
  func remoteRangeDiff(sessionId: String, base: String, head: String, threeDot: Bool, path: String, originalPath: String?) async -> RemoteFileDiffResult
  static func rangeSpec(base: String, head: String, threeDot: Bool) -> String   // "a..b" / "a...b"
  ```
- Replies reuse `.commitFiles` / `.commitFilesFailed` and `.commitDiffResult` / `.commitDiffFailed`, with `sha: rangeSpec(...)`. Document this on the cases; it avoids four new Remote messages.
- Both refs must pass `RemoteWorktreeFileAccess.isCommitSHA`, because stored review targets pin SHAs. Paths must pass `normalizedRelativePath`. Otherwise reply `.pathRejected`.
- Use `GitService.rangeChangedFiles(at:base:head:threeDot:)` and `rangeDiff(worktreePath:base:head:threeDot:file:originalPath:)`, capped like the commit reads.

- [ ] **Step 1: Write the failing test.**
  ```swift
  @Test(arguments: [false, true])
  func rangeReadsAnswerAsCommitRepliesNamedByTheirRange(threeDot: Bool) async throws
  // RepoFixture: a commit changing a.txt on top of base. rangeFiles(base:, head:) →
  //   .worktreeRead(.commitFiles(worktree.id, rangeSpec, files.map(\.path) == ["a.txt"], false));
  // rangeDiff for a.txt → .commitDiffResult with non-empty hunks; base "main" (not a SHA) → .commitFilesFailed(.pathRejected)
  ```
- [ ] **Step 2: Run and confirm the test fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm the tests pass.** `--filter HostProtocolServerTests`. Also add `rangeDiff` to `clientMessagesRoundTrip` and run `--filter HostProtocolTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): read commit-range and branch diffs for paired Macs`.

### Task 8: Peer ranges and branches

**Files:**
- Modify `NativePeerWorkspace.swift`: the client.
- Modify `ReviewSessionLoader.swift`: `peer(git:)`.
- Modify `Alas/Sources/Remote/Native/NativePeerSessions.swift:1241`: `unserved(_:)` gains the two new cases. Map both onto the commit failure replies with the range spec as the SHA.
- Test `NativePeerWorkspaceTests`.

**Interfaces:**
- Consumes `rangeFiles`, `rangeDiff` and `rangeSpec` from Task 7.
- Produces:
  ```swift
  func rangeFiles(base: String, head: String, threeDot: Bool) async throws -> [CommitChangedFile]
  // rangeDiff(worktreePath:revisions:file:originalPath:) reads .rangeDiff(base: revisions.before, head: revisions.after, threeDot: self.threeDot, ...)
  ```
- `peer(git:)` adds `commitRange` (with `threeDot = false`) and `branch` (with `threeDot = true`). Each builds `RangeReviewLoader(git: <copy with threeDot set>)` with files from `git.rangeFiles`.
- `branchWithLocalChanges`, `sinceSnapshot` and `draftCommit` stay `unsupportedTarget`. Task 6's view already shows `"Not available from this Mac yet."` for them.

- [ ] **Step 1: Extend the test.** Add `case commitRange, branch` to `Kind`. Setup: `open("<base>..HEAD")` and `open("<base>...HEAD")` with the SHAs of a two-commit history, plus an agent comment on the changed line. The assertions are unchanged.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify.** CI runs `-only-testing AlasTests/NativePeerWorkspaceTests`. Expected: 4 arguments of `hostFiledCommentsLandOnTheFileThePeerLoaderBuilds` pass.
- [ ] **Step 4: Commit.** `feat(remote): review host commit ranges and branches from a paired Mac`.

### Task 9: A notice click opens its review

**Files:**
- Modify `Packages/AlasCore/Sources/AlasAgentKit/Harness/NotificationService.swift:217`: `notifyPeerNotice`.
- Modify `Packages/AlasCore/Sources/AlasAgentKit/Harness/NotificationDelegate.swift:62`: the context.
- Modify `Alas/Sources/App/AppState+PeerHosts.swift:22`: `worktreeNotice`.
- Modify `Alas/Sources/App/AppState.swift:6929`: `onContextClickThrough`.
- Modify `NativePeerSessions.swift`: add `openHostReview`.

**Interfaces:**
- Consumes `HostWorktreeNotice.reviewSessionID` from Task 4, and `openReview` from Task 6.
- Produces:
  ```swift
  public func notifyPeerNotice(..., peerWorktreeId: String? = nil, peerReviewSessionId: String? = nil)  // userInfo["peerReviewSessionId"]
  public var peerReviewSessionId: String?   // notification context, read from userInfo
  func openHostReview(serverId: String, worktreeID: String, sessionID: String)  // selectHostWorktree, then openReview on that worktree's host entry
  ```
- When the context carries both `peerWorktreeId` and `peerReviewSessionId`, the click calls `openHostReview`. Otherwise it keeps today's `selectHostWorktree`.

- [ ] **Step 1: Implement.** There's no new test: it's wiring, and parsing one optional userInfo key is a trivial getter.
- [ ] **Step 2: Verify.** Run `swift build --package-path Packages/AlasCore`; no core notification suite exists. Then the CI app build. By hand: an agent `review_reply` on the host shows a banner, and clicking it opens that review.
- [ ] **Step 3: Commit.** `feat(remote): open the review a host notice is about`.

---

## Self-review

- **Spec coverage.** Each goal maps to tasks:
  - Goal 1 (the list, live): Tasks 1, 3 and 6.
  - Goal 2 (the review tab and all four kinds): Tasks 5, 6, 7 and 8.
  - Goal 3 (both ways, host identity): Tasks 2 and 5.
  - Goal 4: dropped.
  - Goal 5 (banners, click): Tasks 4 and 9.
  - Goal 6 (capability, opt-in event, older Macs): Tasks 1, 3 and 4.
  - Builder decisions: headless-only (Task 1), synthesized local entry (Task 1), router open path (Task 4), replies-only banners (Task 4), kinds (Tasks 2, 6 and 8), verdict read-only (Task 6).
- **Where the plan departs from the spec, because of the code:**
  - The Mac offers no reply or reopen. The local draft UI (`ReviewDraftCommentActions`) has neither, so `.user` applies to add and resolve (`resolvedBy`).
  - Edit and delete mirror local availability, not "their own only".
  - "Review tab" is an overlay in the peer center, like peer documents, because `NativePeerTab` has no review kind.
- **Type consistency.** These names are used the same way in every task: `HostReviewSummary.record`, `sessionID`, `HostReviewMutation` cases, `reviewRevisions` (on both the channel and the hosts), `NativePeerReviewGitClient.notes`, `threeDot`, and `rangeSpec`.
