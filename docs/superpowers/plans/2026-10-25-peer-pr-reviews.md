# Peer Pull Request Reviews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac paired with a headless `alas-host` opens the host's pull/merge request reviews in the same peer review view as draft reviews: the provider's diff, the PR's threads inline, draft comments both ways, thread reply/resolve/unresolve, and publish with a verdict, all run by the host with its own gh/glab login.

**Architecture:**
- **Host side.** One new headless-only capability, `host.reviews.provider.v1`, gates four requests: read a review's PR (with or without its diff), open a PR review, act on a thread, and publish.
  - The Mac names only a session id, a thread id, draft ids and the head SHA it showed. The host derives the remote, the PR and the cwd from the saved session, so a Mac can't reach another worktree's or another PR's provider state.
  - Publishing goes through `ProviderReviewPublisher`, the UI-free half of today's `ProviderReviewMutationController`, moved into AlasIntegrations and used by both the app and the host. The host's draft store stays the only record of what was published, and the host serializes publishes per session.
  - Thread actions and publishes end with `reviewsChanged`. The headless host resolves `providerReviewOriginalPath` through a core default.
- **Mac side.** `ReviewSessionLoader.peer` gains the `.reviewRequest` case. It feeds the host's raw provider diff through the existing `ReviewRequestDiffLoader`, using a stub provider that runs nothing, so file ids and namespaces match the host's by construction. `NativePeerReviewView` adds inline threads, thread actions and the existing publish confirmation, which now names the posting account.

**Tech Stack:** Swift 6 / SwiftUI app, `Packages/AlasCore` SwiftPM (UI-free), Swift Testing, real git, fake `CodeHostProvider`.

**Spec:** `docs/superpowers/specs/2026-10-25-peer-pr-reviews-design.md`. Its "Decisions" sections bind; where this plan departs because of the code, the Self-review says so.

**PR split:**
- **PR 1** (Tasks 1–5): the host. Shared publish logic, wire types, read/open, Mac drafts and original path, thread actions, publish.
- **PR 2** (Tasks 6–8): the Mac. Peer loader, review view with threads and publish, entry points.

Land them in order. Until PR 2 lands, nothing sends the new requests.

## Global Constraints

- AGENTS.md (origin/main):
  - Swift Testing only, with minimal, sharp tests. Don't test views or wiring.
  - Core imports no SwiftUI, AppKit, GhosttyKit, MLX, TreeSitterPack or FffC.
  - Anything the app uses from core is `public`. Public cross-module types are explicitly `Sendable`.
  - Conventional Commits, with no attribution trailers or footers.
- Core tests: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`. Check the `Test run with N tests` line: N > 0.
- **Tests never run gh or glab.** Host tests install a fake `CodeHostProvider` through `core.codeHostProviders` (Task 2), as `ReviewShepherdTests` injects one. Git stays real, in temp dirs.
- **Never the real profile:** every `AlasCoreContext` built in a test passes `reviewDrafts: ReviewDraftCommentStore(url: <tmp>)` and `reviewSessions: ReviewSessionStore(url: <tmp>)`.
- The app can't be built locally, so CI is its first build.
  - Keep `Alas/` and `AlasTests/` edits mechanical.
  - Add no new files there. Task 3 deletes two, so it runs `xcodegen` and commits `Alas.xcodeproj`.
  - Say in each PR body that the app tests ran on CI only.
- No change to local review behaviour or storage. The Mac never publishes, never mutates a provider thread itself, and never holds a copy of the drafts. Nothing creates a provider-side pending review: only `publishReview` and `mutateReviewThread` are called.
- No credential crosses the wire. Only the login name (`account`) does.
- Copy (verbatim):
  - Host errors:
    - `"This host does not serve pull request reviews."`
    - `"This review has no pull or merge request."`
    - `"This review is already being published."`
    - `notFound(what: "review thread <id>")`
  - Publisher errors, kept from today's controller:
    - `"The selected draft is no longer publishable."`
    - `"There are no publishable draft comments for a comment review."`
  - Mac:
    - `"Not available from this Mac yet."` (a host without the capability).
    - `"Posts as <account>, the host's <Provider> login."` (publish confirmation; the line is left out when `account` is nil).
    - `"Review <PR|MR> <#|!><number>"` (Reviews list row), built from `reviewRequestLabel` and `reviewRequestNumberPrefix`.
    - `"The host cut off part of this review; some files or lines are not shown."` (existing note, now also for a capped provider diff).

## Review Focus

1. **Double publish.** Two Macs, or a double click, publish the same session at once. Only one reaches the provider. The other is refused with `"This review is already being published."`, and a retry after it finds nothing left to publish. Tested by Task 5, `aReviewPublishesOnceWhileAPublishIsInFlight`.
2. **The PR moved since the Mac loaded it.** Publish anchors at the head the Mac showed, not the head the host re-reads. Tested by Task 5, `publishPostsTheSessionsDraftsAtTheHeadTheMacShowed`.
3. **Trust boundary.**
   - A draft id from another session is never published.
   - A thread id that isn't in this PR is never mutated.
   - A session of another worktree, or a non-PR session, is refused.

   Tested by Task 4, `threadActionsActOnlyOnTheirPullRequestsThreads`, and Task 5, `publishRefusalsReachNoProvider`.
4. **A huge PR diff.** A diff past the frame budget is cut at the last whole file and flagged, so the Mac shows the truncation note instead of a broken last file. Tested by Task 2, `aProviderDiffOverItsCapEndsAtTheLastWholeFile`.
5. **The host's gh or glab fails or isn't logged in.** The provider's message reaches the Mac as `.failed(message:)`, not a hang or an empty PR. The account is nil, so the confirmation leaves the account line out. Tested by Task 2, `aMacOpensAndReadsAPullRequestReview` (the unauthenticated case).

---

## PR 1 — host

### Task 1: Shared publish logic in AlasIntegrations

**Files:**
- Modify `Packages/AlasCore/Sources/AlasIntegrations/Integrations/CodeHost/ProviderReviewActions.swift`:
  - Append `ProviderReviewPublisher`, `ProviderReviewDraftOutcome`, `ProviderReviewPublishError` and `ProviderReviewPublishPlanner`, moved from the app.
  - Add `Codable` to `ProviderReviewPublishResult` and `ProviderThreadMutationResult`, by extension in this file. Task 2 sends them.
- Modify `Alas/Sources/Center/ReviewWorkspace/ProviderReviewMutationController.swift`:
  - `publishReview` delegates to `ProviderReviewPublisher.publish`.
  - Delete the moved planner and error enum.
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/ProviderReviewPublisherTests.swift`.
- Test: in `AlasTests/ReviewSessionTabViewTests.swift`, delete the seven tests at `:255–:657`: `providerMutationControllerPublishesDraftsAndMarksResults` through `providerMutationControllerKeepsFailedDraftsActiveWithError`, the planner test included. Delete `providerDraftComment(...)` (`:1248`) once it's unused. Keep `providerMutationControllerFactoryRequiresLoadedProviderContext` and the fakes, which other tests use.

**Interfaces:**
- Produces (all `public`):
  ```swift
  public enum ProviderReviewDraftOutcome: Equatable, Sendable {
      case published(ReviewDraftProviderPublish)
      case failed(ReviewDraftProviderError)
  }
  public enum ProviderReviewPublishError: LocalizedError, Equatable, Sendable {
      case noPublishableSelectedDrafts           // "The selected draft is no longer publishable."
      case noPublishableDraftsForCommentReview   // "There are no publishable draft comments for a comment review."
  }
  public enum ProviderReviewPublishPlanner {     // moved verbatim, now public
      public static func publishableDrafts(_ drafts: [ReviewDraftComment]) -> [ReviewDraftComment]
      public static func unpublishableMessages(_ drafts: [ReviewDraftComment]) -> [String]
  }
  @MainActor public enum ProviderReviewPublisher {
      /// Publishes the publishable `drafts` (only `localDraftIDs` when set), then
      /// hands `record` each draft's outcome, stamped with `now()` taken after the provider answers.
      public static func publish(
          _ drafts: [ReviewDraftComment], selecting localDraftIDs: Set<String>?,
          to reviewRequest: ReviewRequest, remote: CodeHostRemote,
          decision: ProviderReviewDecision, summaryBody: String, cwd: URL,
          provider: any CodeHostProvider, now: () -> Date,
          record: (_ draftID: String, _ outcome: ProviderReviewDraftOutcome) throws -> Void
      ) async throws -> ProviderReviewPublishResult
  }
  ```
- The body is today's `ProviderReviewMutationController.publishReview`. Its two refusals throw before the provider is called. `markPublished` and `recordProviderError` become `record(id, .published(...))` and `record(id, .failed(...))`.
- The app controller keeps its signature. Its `record` switches onto `draftController.markPublished` and `recordProviderError`. `ReviewSessionTabView` is untouched; it now uses the public planner.

- [ ] **Step 1: Write the failing tests.** Drafts are in-memory `ReviewDraftComment`s of one `.reviewRequest` session. The provider is a private `RecordingPublisher: CodeHostProvider` that records each `ProviderReviewPublishRequest` and returns a set result.
  ```swift
  @Test func publishRecordsEachDraftsOutcome() async throws
  // drafts a, b; provider result published [a (thread "t1", comment "c1")], failed [b "line is not commentable"]
  // record calls == [("a", .published(p)), ("b", .failed(e))] with p.threadID == "t1", p.commentID == "c1",
  //   p.reviewNumber == request.number, p.publishedAt == now; e.message == "line is not commentable", e.provider == remote.kind

  @Test(arguments: [
      (["a"], ProviderReviewDecision.comment, ["a"], nil),
      (["missing"], .comment, nil, ProviderReviewPublishError.noPublishableSelectedDrafts),
      (nil, .comment, nil, .noPublishableDraftsForCommentReview),   // with no drafts
      (nil, .approve, [], nil),                                      // decision-only approve, no drafts
  ] as [([String]?, ProviderReviewDecision, [String]?, ProviderReviewPublishError?)])
  func whatAPublishSends(ids: [String]?, decision: ProviderReviewDecision, sent: [String]?, refusal: ProviderReviewPublishError?) async throws
  // sent != nil → the one recorded request's comments.map(\.localDraftID) == sent, decision == decision
  // refusal != nil → #expect(throws: refusal) and no recorded request

  @Test func publishPlannerIgnoresAlreadyPublishedAndInvalidDrafts()   // moved verbatim from the app suite
  ```
- [ ] **Step 2: Run the tests and confirm they fail.** `--filter ProviderReviewPublisherTests`. Expected: compile errors for `ProviderReviewPublisher`.
- [ ] **Step 3: Implement.** Move the planner and error, add the publisher, and make the app controller delegate.
- [ ] **Step 4: Run the tests and confirm they pass.** `--filter ProviderReviewPublisherTests`. App: CI runs `-only-testing AlasTests/ReviewSessionTabViewTests`.
- [ ] **Step 5: Commit.** `refactor(review): share provider publishing between the app and the host`.

### Task 2: Wire types, capability, provider read and open

**Files:**
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift`:
  - Requests after `mutateReview` (`:141`).
  - Responses after `review` (`:321`).
  - Types after `HostReviewMutation` (`:207`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift:1495`: the capability.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift:38`: `servedCapabilities`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift`:
  - Dispatch after `:363`.
  - `providerReviewWorktree(_:)` next to `reviewWorktree` (`:463`).
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift:139`: `codeHostProviders`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+ReviewOpen.swift:70`: use `core.codeHostProviders` in place of `CodeHostProviderRegistry.live()`.
- Create `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+ProviderReviews.swift`.
- Modify `Packages/AlasCore/Sources/AlasIntegrations/Integrations/CodeHost/CodeHostModels.swift`: `ReviewSessionTarget.providerRemote` and `ReviewRequest.pinned(headSHA:)`.
- Modify `CodeHostProvider.swift`: `viewerLogin` requirement, with a nil default.
- Modify `GitHubCLIProvider.swift`, `GitLabCLIProvider.swift`: implement `viewerLogin`. GitLab renames its private `currentUserUsername` (`:1081`) to it.
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift:231-249`: `production.reviewRequest` builds its remote with `target.providerRemote`.
- Test `HostProtocolServerTests`: a fake provider and fixture helper, and the new tests.
- Test `HostProtocolTests`: the cap test, round trips, and the capability check (`:211`).
- Test `HostSessionsTests:495`: expected capabilities gain `reviewsProviderV1`.

**Interfaces:**
- Produces (wire types `public`, `Codable, Equatable, Sendable`):
  ```swift
  // HostProtocolCapability
  public static let reviewsProviderV1 = "host.reviews.provider.v1"  // "readProviderReview, openProviderReview, mutateReviewThread and publishReview: only a headless host"
  // HostRequest
  case readProviderReview(worktree: WorktreeRef, sessionID: String, withDiff: Bool)
  case openProviderReview(worktree: WorktreeRef, number: Int)
  case mutateReviewThread(worktree: WorktreeRef, sessionID: String, threadID: String, kind: ProviderThreadMutationKind, body: String?)  // Task 4
  case publishReview(worktree: WorktreeRef, sessionID: String, publish: HostReviewPublish)                                          // Task 5
  // HostResponse
  case providerReview(review: HostProviderReview)
  case reviewThreadMutated(result: ProviderThreadMutationResult)   // Task 4
  case reviewPublished(result: ProviderReviewPublishResult)        // Task 5
  public struct HostProviderReview {
      public var remote: CodeHostRemote
      public var request: ReviewRequest                  // with its threads
      public var capabilities: CodeHostProviderCapabilities
      public var account: String?                        // the host's login; nil when it can't tell
      public var diff: String?                           // the provider's raw unified diff; nil unless asked
      public var diffTruncated: Bool
      public static let maxDiffBytes = 4 * 1024 * 1024   // RemoteTranscriptSync.maxMessageBytes; well under WebSocketFrame.maxPayloadLength
      /// Within `maxBytes`, or cut just before the last "diff --git " header that starts within it.
      public static func capped(_ diff: String, maxBytes: Int = maxDiffBytes) -> (diff: String, truncated: Bool)
  }
  public struct HostReviewPublish {                      // Task 5
      public var decision: ProviderReviewDecision
      public var body: String
      public var draftIDs: [String]?                     // nil: every unpublished draft
      public var headSHA: String?                        // the head of the diff the Mac showed
  }
  // AlasCoreContext
  @_spi(Testing) @ObservationIgnored public var codeHostProviders = CodeHostProviderRegistry.live()
  // CodeHostProvider
  func viewerLogin(remote: CodeHostRemote, cwd: URL) async -> String?   // default nil
  // GitHub: `gh api user --hostname <host> --jq .login`, trimmed, nil on failure or empty. GitLab: the renamed currentUserUsername.
  // CodeHostModels.swift
  extension ReviewSessionTarget { public var providerRemote: CodeHostRemote? }  // the remote ReviewSessionLoader.production builds today; nil for other kinds
  extension ReviewRequest { public func pinned(headSHA: String?) -> ReviewRequest }  // self when nil
  // ReviewsAPI (AlasHost+ProviderReviews.swift)
  public func providerReview(_ sessionID: String, in worktree: Worktree, withDiff: Bool) async throws -> HostProviderReview
  public func openProviderReview(number: Int, in worktree: Worktree, caller: HostCaller) async throws -> HostReview
  /// The saved PR session `sessionID` of `worktree`, its remote and provider.
  private func providerSession(_ sessionID: String, in worktree: Worktree) throws -> (record: ReviewSessionRecord, remote: CodeHostRemote, provider: any CodeHostProvider)
  ```
- `servedCapabilities` appends `reviewsProviderV1` alongside `reviewsV1` when `servesWorktreeGit`.
- `providerReviewWorktree(ref)` throws `invalidRequest("This host does not serve pull request reviews.")` unless the capability is served, then returns `visibleWorktree(ref)`.
- `providerSession`:
  - The id must parse and be `isFor(worktreeID:)`. Its record must be in `list(in:)`. Otherwise `notFound(what: "review <id>")`.
  - The record's target kind must be `.reviewRequest` with a `providerRemote`. Otherwise `invalidRequest("This review has no pull or merge request.")`.
  - With no provider in `core.codeHostProviders` for the kind, throw `failed(CodeHostProviderError.unsupportedProvider(kind).localizedDescription)`.
- `providerReview`:
  - Runs `provider.reviewRequest(remote:number:cwd: worktree.path)`. With `withDiff`, also `capped(provider.reviewDiff(...))`.
  - Adds `viewerLogin` and `capabilities`.
  - Any provider error becomes `HostError.failed(message: localizedDescription)`.
- `openProviderReview`:
  - `number > 0`, else `invalidRequest`.
  - Runs `open("\(number)", in:, caller:)`. A `.failure(f)` becomes `failed(message: f.message)`. On success, returns `read(saved.record.target.draftSessionID.rawValue, in:)`.
  - `open` already reuses an active session and emits `didChange`.
- Test fake, private to `HostProtocolServerTests`:
  ```swift
  final class FakeReviewProvider: CodeHostProvider, @unchecked Sendable {   // @MainActor-confined use
      var kind: CodeHostKind; var headSHA = "bbb"; var threads: [ReviewThread] = []; var diff = ""; var login: String? = "octocat"
      var readError: (any Error)?                                   // thrown by reviewRequest
      var publishResult: ((ProviderReviewPublishRequest) -> ProviderReviewPublishResult)?  // Task 5
      var holdsPublish = false; var releasePublish: CheckedContinuation<Void, Never>?        // Task 5
      private(set) var publishes: [ProviderReviewPublishRequest] = []; private(set) var threadMutations: [ProviderThreadMutation] = []
      // reviewRequest returns a minimal open request on `remote`/`number` with headSHA and threads; capabilities .githubCLI
  }
  // RepoFixture
  /// Adds an `origin` of `kind` (https://github.com/acme/app.git or https://gitlab.com/acme/app.git), installs
  /// `provider` for it, and opens PR/MR 7 as an agent would; returns the session id.
  func openPullRequestReview(_ provider: FakeReviewProvider) async throws -> String
  ```

- [ ] **Step 1: Write the failing tests.**
  ```swift
  // HostProtocolServerTests: extend reviewRequestsAreServedOnlyByAHeadlessHost:
  // #expect(try await fixture.request(.readProviderReview(worktree: ref, sessionID: "x", withDiff: false))
  //     == .failure(error: .invalidRequest(reason: "This host does not serve pull request reviews.")))

  @Test func aMacOpensAndReadsAPullRequestReview() async throws
  // provider: threads [thread "t1" on a.txt], diff "diff --git a/a.txt b/a.txt\n…", login "octocat"
  // .openProviderReview(worktree: ref, number: 7) twice → both .review(r) with the same r.summary.sessionID,
  //   r.summary.record.target.kind == .reviewRequest; core.reviewSessions.list(worktreeID:).count == 1
  // .readProviderReview(sessionID, withDiff: true) → request.number == 7, request.threads.map(\.id) == ["t1"],
  //   account == "octocat", diff == provider.diff, diffTruncated == false; withDiff: false → diff == nil
  // a local-changes session id → .failure(.invalidRequest(reason: "This review has no pull or merge request."))
  // provider.readError = CodeHostProviderError.unauthenticated("github.com") →
  //   .failure(.failed(message: "Authentication is required for github.com."))

  // HostProtocolTests
  @Test func aProviderDiffOverItsCapEndsAtTheLastWholeFile()
  // two sections A (100 bytes) + B (100 bytes): capped(maxBytes: 150) == (A, true); capped(maxBytes: 400) == (A+B, false);
  // one 300-byte section: capped(maxBytes: 150) == ("", true)
  ```
- [ ] **Step 2: Run the tests and confirm they fail.** `--filter HostProtocolServerTests`, `--filter HostProtocolTests`. Expected: compile errors for `readProviderReview`.
- [ ] **Step 3: Implement.** Add the wire types, gate, dispatch, seam, `viewerLogin`, `providerRemote`, `pinned`, and the two `ReviewsAPI` functions. Log with `caller.log("reviews.openProvider", "\(number)")`.
- [ ] **Step 4: Add round trips and capability assertions.**
  - Add `readProviderReview`, `publishReview`, `.providerReview` and `.reviewPublished` to `clientMessagesRoundTrip` and `serverMessagesRoundTrip`.
  - Add `#expect(!caps.contains(HostProtocolCapability.reviewsProviderV1))` to `helloAdvertisesExactlyTheConsoleCapabilitiesItServes`.
  - Change `HostSessionsTests:495` to `served + [worktreesGitV1, reviewsV1, reviewsProviderV1]`.
- [ ] **Step 5: Run and confirm everything passes.** `--filter HostProtocolServerTests`, `--filter HostProtocolTests`, `--filter HostSessionsTests`.
- [ ] **Step 6: Commit.** `feat(alas-host): read and open a worktree's pull request reviews for paired Macs`.

### Task 3: Mac drafts on PR reviews and the host's original path

**Files:**
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+PeerReviews.swift:139`: allow `.reviewRequest`.
- Modify `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHostEnvironment.swift`:
  - The requirement at `:101` gains `in core:`, with a core default in the extension at `:116`.
  - Delete the stub at `:203`.
- Modify `AlasHost+ProviderReviews.swift`: add `AlasCoreContext.providerReviewOriginalPath`.
- Modify `AlasCoreContext.swift`: add `providerReviewFiles`.
- Modify `AlasHost+Reviews.swift:214`: pass `in: core`.
- Modify `Alas/Sources/App/AppState.swift`: delete the cache (`:7206`), `reviewRequestOriginalPath` (`:11520-11566`) and the environment forwarder (`:14740-14742`).
- Delete `Alas/Sources/Center/DiffReview/ProviderReviewOriginalPathResolver.swift` and `AlasTests/ProviderReviewOriginalPathResolverTests.swift`. The lookup is one line, inlined in core.
- Modify `AlasTests/AlasCLICommandRouterTests.swift:1492`: `RouterTerminals` takes the new signature, `in core: AlasCoreContext`.
- Regenerate `Alas.xcodeproj` with `xcodegen`.
- Test `HostProtocolServerTests`.

**Interfaces:**
- Consumes `FakeReviewProvider`, `openPullRequestReview`, `codeHostProviders` and `providerRemote` from Task 2.
- Produces:
  ```swift
  // AlasHostEnvironment
  func providerReviewOriginalPath(_ session: ReviewDraftSessionID, path: String, in core: AlasCoreContext) async -> String?
  // default: await core.providerReviewOriginalPath(session, path: path)
  // AlasCoreContext
  @ObservationIgnored var providerReviewFiles: [ReviewDraftSessionID: [DiffReviewFileSummary]] = [:]  // ponytail: kept until the host stops, as the app's cache was
  public func providerReviewOriginalPath(_ session: ReviewDraftSessionID, path: String) async -> String?
  ```
- `providerReviewOriginalPath` is the deleted `AppState.reviewRequestOriginalPath`, with these changes:
  - It finds the record in every project's worktrees, hidden ones included.
  - The remote is `record.target.providerRemote`, the session's own, so no other repository's PR can stamp a path.
  - The provider comes from `codeHostProviders`.
  - The cached file list is `ReviewRequestDiffLoader(provider:).load(...).summary.files`.
  - It returns `files.first { $0.path == path }?.originalPath`, and nil on any failure.
- The app's environment then has no override, and the default runs the same code.

- [ ] **Step 1: Write the failing test.**
  ```swift
  @Test(arguments: [CodeHostKind.github, .gitlab])
  func commentsOnAPullRequestReviewKeepTheirOriginalPath(_ kind: CodeHostKind) async throws
  // a.txt exists in the repo; provider diff renames old.txt → a.txt ("rename from old.txt\nrename to a.txt" + one hunk)
  // agent addComment(path: "a.txt", sessionID: <PR session>) → stored originalPath == (kind == .gitlab ? "old.txt" : nil)
  //   (the existing GitLab-only gate at AlasHost+Reviews.swift:210)
  // Mac .mutateReview(.add(fileID: <"github-pr"|"gitlab-mr">:a.txt, originalPath: "old.txt", .line(new, 1))) == .done,
  //   stored fileID.namespace == "github-pr"/"gitlab-mr", author .user
  // Mac .add with namespace "commit" → .failure(.invalidRequest("this review has no commit files")), nothing stored
  ```
- [ ] **Step 2: Run and confirm the test fails.** `--filter HostProtocolServerTests`. Expected: the GitLab case stores nil, and the Mac add is refused with `"Not available from this Mac yet."`.
- [ ] **Step 3: Implement.** Move the lookup into core, change the requirement, delete the app copies, and allow `.reviewRequest` in `comment(...)`.
- [ ] **Step 4: Regenerate and verify.**
  - Run `xcodegen`, then `git status` to confirm that only the two deleted files' entries leave `Alas.xcodeproj/project.pbxproj`.
  - Core: `--filter HostProtocolServerTests`.
  - App: CI runs `-only-testing AlasTests/AlasCLICommandRouterTests`. Its two `commentAdd…OriginalPath…` tests keep passing through the new signature.
- [ ] **Step 5: Commit** the source, the deletions and `Alas.xcodeproj`. Message: `feat(alas-host): keep a renamed file's original path on a headless host's merge request comments`.

### Task 4: Thread actions

**Files:**
- Modify `AlasHost+ProviderReviews.swift`.
- Modify `HostProtocolServer.swift`: dispatch `mutateReviewThread`.
- Modify `HostProtocolServerTests`: generalize `worktreeNotices(of:)` (`:1312`) into `events(of:)`. `worktreeNotices` filters it, and Tasks 4 and 5 read `.reviewsChanged` from it.

**Interfaces:**
- Consumes `providerSession` from Task 2.
- Produces:
  ```swift
  public func mutateThread(
      _ threadID: String, kind: ProviderThreadMutationKind, body: String?,
      sessionID: String, in worktree: Worktree, caller: HostCaller
  ) async throws -> ProviderThreadMutationResult
  // RepoFixture
  func events(of subscription: HostSubscription) async -> [HostEvent]   // up to a marker notice, as worktreeNotices did
  ```
- `mutateThread`:
  1. `providerSession`. Bound `body` with `checkSize`.
  2. Re-read the PR, and find `request.threads.first { $0.id == threadID }`. If it's missing, throw `notFound(what: "review thread \(threadID)")` before any provider write.
  3. Call `provider.mutateReviewThread(ProviderThreadMutation(remote:, reviewRequest: request, thread: summary, kind:, bodyMarkdown: body, cwd: worktree.path))`.
     - `summary` is `ReviewThreadSummary(id: thread.id, author:, body:, url:, isResolved:, isActionable:, providerThreadID: thread.id)`. Both providers read only `providerThreadID`.
  4. Then `didChange(worktreeID:)` and return the result. A provider error becomes `failed(message:)`.
- Log with `caller.log("reviews.thread", "\(sessionID) \(threadID) \(kind.rawValue)")`.

- [ ] **Step 1: Write the failing test.**
  ```swift
  @Test func threadActionsActOnlyOnTheirPullRequestsThreads() async throws
  // threads ["t1"]. .mutateReviewThread(sessionID, "t1", .resolve, nil) → .reviewThreadMutated(_);
  //   provider.threadMutations.map { [$0.thread.providerThreadID, $0.kind.rawValue, $0.cwd.path] } == [["t1", "resolve", worktree.path.path]];
  //   events(of:) contains .reviewsChanged(worktreeID: worktree.id)
  // "t9" → .failure(.notFound(what: "review thread t9")); a commit session (open("HEAD")) → invalidRequest("This review has no pull or merge request.");
  // a session id for worktree "other" → notFound("review <id>"); provider.threadMutations.count stays 1
  ```
- [ ] **Step 2: Run and confirm the test fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm the tests pass.** `--filter HostProtocolServerTests`. Add `mutateReviewThread` and `.reviewThreadMutated` to the round trips, then run `--filter HostProtocolTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): reply to and resolve pull request threads for paired Macs`.

### Task 5: Publish

**Files:**
- Modify `AlasHost+ProviderReviews.swift`.
- Modify `AlasCoreContext.swift`: add `publishingReviews`.
- Modify `HostProtocolServer.swift`: dispatch `publishReview`.
- Test `HostProtocolServerTests`.

**Interfaces:**
- Consumes `ProviderReviewPublisher` (Task 1), and `HostReviewPublish`, `pinned`, `providerSession` and the fake (Task 2).
- Produces:
  ```swift
  // AlasCoreContext
  @ObservationIgnored var publishingReviews: Set<String> = []   // session ids with a publish running
  // ReviewsAPI
  public func publish(_ publish: HostReviewPublish, sessionID: String, in worktree: Worktree, caller: HostCaller) async throws -> ProviderReviewPublishResult
  ```
- `publish`, in order:
  1. Run `providerSession`, and bound `publish.body` with `checkSize`.
  2. `guard core.publishingReviews.insert(sessionID).inserted`, else throw `invalidRequest("This review is already being published.")`. `defer` removes it.
  3. Re-read the PR and `pinned(headSHA: publish.headSHA)`.
  4. `drafts = core.reviewDrafts.load(sessionID:)`, so another session's ids can't be selected.
  5. Call `ProviderReviewPublisher.publish(drafts, selecting: publish.draftIDs.map(Set.init), ..., cwd: worktree.path, now: Date.init)`. Its `record` re-finds the comment and sets `providerPublish` (clearing `providerError`) or `providerError`, sets `updatedAt`, and saves.
  6. A `ProviderReviewPublishError` becomes `invalidRequest(reason: localizedDescription)`. A provider error becomes `failed(message:)`.
  7. On success, `didChange(worktreeID:)`. The result, warnings included, goes back as-is.
- Log with `caller.log("reviews.publish", "\(sessionID) \(publish.decision.rawValue)")`.
- Agents get nothing new: no CLI verb, no MCP tool.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func publishPostsTheSessionsDraftsAtTheHeadTheMacShowed() async throws
  // provider.headSHA "bbb"; Mac adds drafts a (line 1) and b (line 2) in the PR session; a draft "theirs" in a commit session.
  // publishResult: published [a], failed [b "outdated"], warnings ["GitHub dropped the approval."]
  // .publishReview(sessionID, HostReviewPublish(decision: .comment, body: "", draftIDs: nil, headSHA: "aaa")) →
  //   .reviewPublished(result) with result.warnings == ["GitHub dropped the approval."];
  //   provider.publishes.count == 1, its reviewRequest.headSHA == "aaa", comments ids == [a, b];
  //   stored a.providerPublish != nil, b.providerError?.message == "outdated" and b.state == .active,
  //   "theirs" untouched; events(of:) contains .reviewsChanged(worktreeID:)

  @Test(arguments: [(["theirs"], "The selected draft is no longer publishable."),
                    (nil, "There are no publishable draft comments for a comment review.")])
  func publishRefusalsReachNoProvider(draftIDs: [String]?, reason: String) async throws
  // PR session with no drafts of its own; "theirs" in a commit session → .failure(.invalidRequest(reason: reason)); provider.publishes.isEmpty

  @Test func aReviewPublishesOnceWhileAPublishIsInFlight() async throws
  // provider.holdsPublish = true. Draft a. Task { try await host.reviews.publish(.init(.comment, "", nil, "aaa"), ...) }
  // try await eventually { await MainActor.run { provider.releasePublish != nil } }
  // second publish(draftIDs: ["a"]) throws HostError.invalidRequest(reason: "This review is already being published.")
  // resume releasePublish; first succeeds; a third publish(draftIDs: ["a"]) throws invalidRequest("The selected draft is no longer publishable.")
  // provider.publishes.count == 1
  ```
- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm the tests pass.** `--filter HostProtocolServerTests`, `--filter HostProtocolTests`.
- [ ] **Step 5: Commit.** `feat(alas-host): publish a pull request review for a paired Mac`.

## PR 2 — Mac

### Task 6: Peer loader for PR reviews

**Files:**
- Modify `Alas/Sources/Remote/Native/NativePeerHosts.swift`: add the provider calls after `mutateReview` (`:265`).
- Modify `Alas/Sources/Remote/Native/NativePeerWorkspace.swift`: add `NativePeerProviderDiff` after `NativePeerReviewGitClientError` (`:507`).
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift:319`: `peer(git:providerReview:)`.
- Test `AlasTests/Remote/NativePeerWorkspaceTests.swift`, which runs on CI only.

**Interfaces:**
- Consumes the Task 2–5 wire types, `providerRemote` and `codeHostProviders`.
- Produces:
  ```swift
  // NativePeerHosts
  func servesProviderReviews(serverId: String) -> Bool   // servesReviews && supports(reviewsProviderV1)
  func providerReview(_ sessionID: String, in: PeerHostWorktree, serverId: String, withDiff: Bool) async -> Result<HostProviderReview, NativePeerReviewGitClientError>
  func openProviderReview(number: Int, in: PeerHostWorktree, serverId: String) async -> Result<HostReview, NativePeerReviewGitClientError>
  func mutateReviewThread(_ threadID: String, kind: ProviderThreadMutationKind, body: String?, sessionID: String,
                          in: PeerHostWorktree, serverId: String) async -> Result<ProviderThreadMutationResult, NativePeerReviewGitClientError>
  func publishReview(_ publish: HostReviewPublish, sessionID: String, in: PeerHostWorktree, serverId: String) async -> Result<ProviderReviewPublishResult, NativePeerReviewGitClientError>
  // Each one guards servesProviderReviews (else .unavailable), maps .failure(e) through PeerWorktreeRemoval.message(for:),
  // and any other reply to "The host sent an unexpected reply."
  /// The host's provider diff, for ReviewRequestDiffLoader. Runs no gh or glab: everything else is unsupported,
  /// so image sides fail, as for the peer's draft reviews.
  struct NativePeerProviderDiff: CodeHostProvider { let kind: CodeHostKind; let diff: String }
  // ReviewSessionLoader
  static func peer(git: NativePeerReviewGitClient, providerReview: HostProviderReview? = nil) -> ReviewSessionLoader
  // reviewRequest: nil → unsupportedTarget; else ReviewRequestDiffLoader(provider: NativePeerProviderDiff(kind:, diff: diff ?? ""))
  //   .load(remote: providerReview.remote, request: providerReview.request, cwd: target.repositoryPath), with providerContext from the same pair
  ```

- [ ] **Step 1: Extend the test.**
  - Add `case reviewRequest` to `Kind`.
  - Setup: `git remote add origin https://github.com/acme/app.git`, and `core.codeHostProviders` holds a private fake. Its diff is the real `git diff HEAD~1 HEAD` of the edit commit, and it returns a minimal request for any number. The fake mirrors `ReviewSessionLoaderTests:545`.
  - Open with `reviews.openProviderReview(number: 7, in:, caller: .app)`, then add an agent comment on `a.txt` line 1 in that session.
  - Load with `ReviewSessionLoader.peer(git: client, providerReview: try await reviews.providerReview(id, in: worktree, withDiff: true)).load(target:)`.
  - The assertions are unchanged: every comment's `fileID` names a file the loader built (`github-pr:a.txt`), with an added line at `startLine`.
- [ ] **Step 2: Implement** the hosts calls, `NativePeerProviderDiff` and `peer(git:providerReview:)`.
- [ ] **Step 3: Verify.** CI runs `-only-testing AlasTests/NativePeerWorkspaceTests`. Expected: 5 arguments of `hostFiledCommentsLandOnTheFileThePeerLoaderBuilds` pass.
- [ ] **Step 4: Commit.** `feat(remote): load a host pull request review's diff on a paired Mac`.

### Task 7: Threads, thread actions and publish in the peer review view

**Files:**
- Modify `Alas/Sources/Remote/Native/NativePeerDocumentView.swift`: `NativePeerReviewView` (`:133-410`).
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`:
  - Make `allowedProviderDecisions` and `defaultProviderDecision` (`:946`, `:963`) internal.
  - Extract `publishRefusal` from `confirmProviderPublish` (`:1027-1035`).
- Modify `Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift`: add the `account` line.

**Interfaces:**
- Consumes everything from Task 6, and `ProviderReviewPublishPlanner` from Task 1.
- Produces:
  ```swift
  // ReviewSessionTabView
  /// The confirmation's refusal before publishing, nil when it may go: "<Decision> is not supported by this provider."
  /// or "<Decision> requires a review summary." (today's copy, now shared).
  static func publishRefusal(decision: ProviderReviewDecision, allowed: [ProviderReviewDecision], summaryBody: String) -> String?
  // ProviderReviewPublishConfirmationView
  var account: String? = nil   // "Posts as \(account), the host's \(providerName) login." under the identity line
  // NativePeerReviewView
  @State private var providerReview: HostProviderReview?   // threads, capabilities, account; diff kept only for the load
  @State private var providerConfirmation: ProviderReviewPublishConfirmationState?
  @State private var providerError: String?                 // thread/publish errors and warnings, shown as a note
  ```
- **Load.**
  - For a `.reviewRequest` target, `loadDiff` reads `providerReview(..., withDiff: true)` first. When the host lacks the capability, `peer(git:)` runs with nil, which throws `unsupportedTarget`, so the view shows `"Not available from this Mac yet."`.
  - Set `.loaded(_, truncated: git.notes.truncated || pr.diffTruncated)`.
  - The `ReadKey` task also re-reads `providerReview(..., withDiff: false)` for a `.reviewRequest` target and replaces `providerReview`. ponytail: this costs one provider read per `reviewsChanged`; cache on the host if gh latency bites.
- **Threads.**
  - Pass `inlineFeedbackByFileID: ReviewSessionTabView.inlineFeedbackByFileID(threads: pr.request.threads, files: loaded.session.summary.files, providerName: pr.remote.kind.displayName)`.
  - Pass `inlineFeedbackActions`, whose availability is the local one (`:1136-1150`) over `pr.capabilities`.
  - Reply, resolve and unresolve call `hosts.mutateReviewThread(item.id, ...)`.
    - On success, set `providerReview.request = result.refreshedRequest`. `providerError` is the joined warnings, or nil.
    - On failure, `providerError = error.message`.
  - Open and copy behave as locally.
- **Drafts.** `commentActions` gains the following, only for a `.reviewRequest` target with `providerReview`:
  - `availability.canPublishProvider = !ProviderReviewPublishPlanner.publishableDrafts([comment]).isEmpty`.
  - `canPublishReview` is `canComment || canSubmitReview`.
  - `publishProvider(comment)` and `publishReview()` open the confirmation, built as `openProviderPublishConfirmation` (`:914-944`) builds it, from `review.comments`.
- **Publish.**
  - Show `ProviderReviewPublishConfirmationView` as an overlay, with `account: pr.account`.
  - Confirm runs `publishRefusal`, then `hosts.publishReview(HostReviewPublish(decision:, body: trimmed, draftIDs: confirmation.commentID.map { [$0] }, headSHA: pr.request.headSHA), ...)`.
  - On success: replace the request with `refreshedRequest`, close the confirmation, and set `providerError` to the joined warnings. Per-draft results arrive with the comments re-read on `reviewsChanged`; `providerError` on a draft shows as locally.
  - On failure: the confirmation shows the message.
  - The button is disabled while a publish is in flight.

- [ ] **Step 1: Implement.** There's no new test, since views are excluded by policy. The decisions live in the host (Tasks 4–5) and in the existing local helpers this reuses.
- [ ] **Step 2: Verify.**
  - Run CI's app build plus `-only-testing AlasTests/ReviewSessionTabViewTests`, which covers the `publishRefusal` extraction through the existing publish-confirmation tests.
  - Smoke-test by hand against a headless host on a throwaway PR:
    - Reply to and resolve a thread.
    - Publish one comment, then the review with Approve.
    - On the PR page, check the comment's head and the posting account.
- [ ] **Step 3: Commit.** `feat(remote): show threads and publish a host pull request review from a paired Mac`.

### Task 8: Entry points

**Files:**
- Modify `Alas/Sources/Right/NativePeerRightPaneView.swift`:
  - `reviewRows` (`:305`) and `reviewsKey` (`:357`).
  - `ReviewLoopDrawer`'s `servedActions` (`:215`).
  - `handleReviewAction` (`:259`).

**Interfaces:**
- Consumes `servesProviderReviews` and `openProviderReview` from Task 6, and `client.openReview` (`NativePeerSessions.swift:1118`).
- Produces:
  ```swift
  /// Opens or reuses the host's review of `number` and shows it; an error lands in `gitError`.
  private func startProviderReview(_ number: Int, on target: (serverId: String, worktree: PeerHostWorktree))
  ```
- **Reviews list.** Add one row first, before the local-changes row, when all of these hold:
  - `hosts.servesProviderReviews(serverId:)`;
  - `reviewLoop.snapshot?.reviewRequest` is a request;
  - no listed review's `record.target.payload` is `.reviewRequest` with that number.

  Its title is `"Review \(r.provider.reviewRequestLabel) \(r.provider.reviewRequestNumberPrefix)\(r.number)"`. A tap calls `startProviderReview(r.number, ...)`. Listed PR reviews open as rows already do.
- **PR drawer.**
  - `servedActions` is `peerServed.union([.inspectReviewEvidence])` when the host serves provider reviews.
  - `.inspectReviewEvidence` calls `startProviderReview(snapshot.reviewRequest.number, ...)`. The model offers it as "Review diff" or "Inspect" when the PR is mergeable, failing or has feedback.
- `startProviderReview` runs `openProviderReview`. On success it calls `client.openReview(review.summary.sessionID, ...)`, guarded by `gitTargetKey` as `runGit` is.

- [ ] **Step 1: Implement.** There's no test: this is view wiring over the host's open (Task 2).
- [ ] **Step 2: Verify.** Run CI's app build. By hand, against a headless host whose worktree has a PR:
  - The row and the drawer action open the same session.
  - A second tap reuses it.
  - An older host shows neither.
- [ ] **Step 3: Commit.** `feat(remote): start a host pull request review from the Reviews list and PR drawer`.

---

## Self-review

- **Spec coverage.** Each goal maps to tasks:
  - Goal 1 (open, provider diff, threads inline, drafts): Tasks 2, 6 and 7.
  - Goal 2 (start from the drawer and the list): Tasks 2 and 8.
  - Goal 3 (draft comments in the host's store): Task 3, with the existing #2218–#2220 mutations.
  - Goal 4 (thread actions): Tasks 4 and 7.
  - Goal 5 (publish, per-draft results, warnings): Tasks 1, 5 and 7.
  - Goal 6 (`providerReviewOriginalPath` on a headless host): Task 3.
  - Goal 7 (capability-gated; older Macs and hosts): Tasks 2 and 6.
  - Builder decisions:
    - publish at the shown head (Task 5);
    - all or a selection, with the two refusals (Tasks 1 and 5);
    - Mac-only publish and threads, serialized (Task 5);
    - the posting account (Tasks 2 and 7);
    - `reviewsChanged` after actions (Tasks 4 and 5);
    - headless only (Task 2).
- **Where the plan departs from the spec, because of the code:**
  - **The shared publish logic lives in AlasIntegrations, not AlasFeatures.** `CodeHostProvider`, `ProviderReviewPublishRequest` and `ReviewRequest` live in AlasIntegrations, which depends on AlasFeatures, so AlasFeatures can't name them.
  - **The host serves the provider's raw diff,** capped at a whole file, rather than a parsed-diff wire type. The Mac parses it with the same `ReviewRequestDiffLoader`, so file ids, namespaces and `originalPath` match the host's and the local flow's by construction, with no new hunk types.
  - **No image previews for a host PR review.** There's no host read of a blob at a revision, and the loader's image path would run gh. Image sides fail, as in the peer's draft reviews. The spec's "otherwise left out" case.
  - **Thread actions and publish are their own requests,** not `HostReviewMutation` cases. They answer with results rather than `.done`. The Mac sends only ids, never a `ProviderThreadMutation` with a remote or cwd. An exhaustive app switch over `HostReviewMutation` (`NativePeerDocumentView.swift:314`) stays untouched.
  - **Host tests inject a fake `CodeHostProvider` rather than a fake command runner.** A runner fake would only re-test gh/glab parsing, which the existing app provider tests own. The one new CLI call, `viewerLogin`, is a one-line `gh api user --jq .login` and gets no test.
  - **`providerReviewOriginalPath` moves into core,** behind a defaulted environment requirement. The app's copy and its resolver file are deleted, so Task 3 runs `xcodegen`.
  - **The drawer reuses `.inspectReviewEvidence`** only when the readiness model offers it. The Reviews-list row is the entry that's always there.
- **Type consistency.** These names are used the same way in every task:
  - `HostProviderReview` (`remote`, `request`, `capabilities`, `account`, `diff`, `diffTruncated`) and `HostReviewPublish` (`decision`, `body`, `draftIDs`, `headSHA`);
  - `reviewsProviderV1` and `servesProviderReviews`;
  - `ProviderReviewPublisher.publish(_:selecting:to:remote:...)` and `ProviderReviewDraftOutcome`;
  - `codeHostProviders`, `providerRemote` and `pinned(headSHA:)`;
  - `FakeReviewProvider` and `openPullRequestReview`;
  - `peer(git:providerReview:)`.
