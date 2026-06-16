# Provider Review Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Alas publish local draft review comments and mutate GitHub/GitLab review threads directly from the existing review workspace.

**Architecture:** Add a provider-neutral write contract beside the existing `CodeHostProvider` read contract, implement it for both `gh` and `glab`, then wire provider publishing through the existing review-session/draft-comment controller. Keep `DiffReviewSurface` provider-neutral; it should render capability-driven actions and delegate all mutations to review-session owned controllers.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, existing `gh`/`glab` CLI provider infrastructure, existing JSON persistence stores.

---

## Scope Boundaries

This plan implements the approved spec at `docs/superpowers/specs/2026-06-15-provider-review-actions-design.md`.

V1 includes both GitHub and GitLab:

- publish local draft comments to provider PR/MR
- GitHub comment/approve/request-changes review decisions
- GitLab discussions, approval endpoint, and request-changes status note
- reply to provider threads/discussions
- resolve/unresolve provider threads/discussions
- refresh provider state after writes
- persist provider publish metadata and provider errors on local drafts
- confirmation UI before remote writes

Out of scope:

- editing/deleting remote comments
- suggestion blocks/apply suggestion
- pending GitHub reviews created outside Alas
- offline mutation queue
- automatic line-comment-to-file-comment fallback

---

## File Map

### Provider Models and Contracts

- Modify `Alas/Sources/Integrations/CodeHost/CodeHostModels.swift`
  - extend `CodeHostProviderCapabilities`
  - add `providerThreadID` and `providerCommentID` directly to `ReviewThreadSummary`; keep `ReviewThreadLocation` focused on path/line/side data
- Create `Alas/Sources/Integrations/CodeHost/ProviderReviewActions.swift`
  - provider-neutral publish/reply/resolve models
  - provider action validators and small payload helpers
- Modify `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift`
  - add async write methods with default unsupported implementations
  - add stdin-capable command runner support for `gh api --input -` and `glab api --input -`

### Provider Implementations

- Modify `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
  - implement publish/reply/resolve/unresolve/review-decision methods
  - add payload builders as `internal static` helpers for tests
- Modify `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
  - implement publish/reply/resolve/unresolve/approve/request-changes-note methods
  - add diff-ref and position payload builders as `internal static` helpers for tests

### Review Workspace State and Controller

- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift`
  - add publish metadata and provider error fields to `ReviewDraftComment`
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift`
  - keep round-trip persistence backward compatible
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentController.swift`
  - add `markPublished`, `recordProviderError`, and active publish filtering
- Create `Alas/Sources/Center/ReviewWorkspace/ProviderReviewMutationController.swift`
  - owns publish/reply/resolve orchestration, refresh-after-write, and draft-store updates

### UI Actions

- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentActions.swift`
  - add publish availability/action
- Modify `Alas/Sources/Center/DiffReview/DiffReviewInlineFeedbackActions.swift`
  - add reply/resolve/unresolve availability/actions
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - render provider thread actions on feedback cards
  - render per-draft publish on local draft cards
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift`
  - render `Publish review`
  - show published/error state in summary rows
- Create `Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift`
  - confirmation UI for decision/comment count/unpublishable drafts
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
  - wire controller, confirmation state, publish results, provider-thread actions

### Tests

- Modify `AlasTests/Integrations/CodeHostModelsTests.swift`
- Create `AlasTests/Integrations/ProviderReviewActionsTests.swift`
- Modify `AlasTests/Integrations/GitHubCLIProviderTests.swift`
- Modify `AlasTests/Integrations/GitLabCLIProviderTests.swift`
- Modify `AlasTests/ReviewDraftModelsTests.swift`
- Modify `AlasTests/ReviewDraftCommentStoreTests.swift`
- Modify `AlasTests/ReviewSessionTabViewTests.swift`
- Modify `AlasTests/DiffReviewSurfaceTests.swift`

Run `xcodegen` after adding new Swift files so `Alas.xcodeproj` references them.

---

## Task 1: Provider Write Models and Capabilities

**Files:**

- Create: `Alas/Sources/Integrations/CodeHost/ProviderReviewActions.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostModels.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift`
- Test: `AlasTests/Integrations/CodeHostModelsTests.swift`
- Test: `AlasTests/Integrations/ProviderReviewActionsTests.swift`

- [ ] **Step 1: Write failing model/capability tests**

Add `AlasTests/Integrations/ProviderReviewActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct ProviderReviewActionsTests {
    @Test func providerDraftCommentBuildsFromActiveLocalDraft() throws {
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        let draft = ReviewDraftComment(
            id: "draft-1",
            sessionID: session,
            fileID: DiffReviewFileID(namespace: "github", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 12,
            endLine: 14,
            selectedText: "let value = 1",
            bodyMarkdown: "Please simplify this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )

        let providerDraft = try #require(ProviderReviewDraftComment(localDraft: draft))

        #expect(providerDraft.localDraftID == "draft-1")
        #expect(providerDraft.path == "Sources/App.swift")
        #expect(providerDraft.side == .new)
        #expect(providerDraft.lineRange == 12...14)
        #expect(providerDraft.bodyMarkdown == "Please simplify this.")
    }

    @Test func providerDraftCommentRejectsNonActiveOrPublishedDrafts() {
        var draft = ReviewDraftComment(
            id: "draft-1",
            sessionID: .reviewRequest(worktreeID: "wt", provider: .github, host: "github.com", repositorySlug: "mrmans0n/alas", number: 527),
            fileID: DiffReviewFileID(namespace: "github", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 12,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Comment",
            state: .resolved,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )
        #expect(ProviderReviewDraftComment(localDraft: draft) == nil)

        draft.state = .active
        draft.providerPublish = ReviewDraftProviderPublish(
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            reviewNumber: 527,
            threadID: "thread-1",
            commentID: "comment-1",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            publishedAt: Date(timeIntervalSince1970: 20)
        )
        #expect(ProviderReviewDraftComment(localDraft: draft) == nil)
    }

    @Test func providerCapabilitiesExposeWriteActions() {
        #expect(CodeHostProviderCapabilities.githubCLI.canPublishReviewComments)
        #expect(CodeHostProviderCapabilities.githubCLI.canReplyToReviewThreads)
        #expect(CodeHostProviderCapabilities.githubCLI.canResolveReviewThreads)
        #expect(CodeHostProviderCapabilities.githubCLI.canUnresolveReviewThreads)
        #expect(CodeHostProviderCapabilities.githubCLI.canApproveReview)
        #expect(CodeHostProviderCapabilities.githubCLI.canRequestChanges)

        #expect(CodeHostProviderCapabilities.gitlabCLI.canPublishReviewComments)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canReplyToReviewThreads)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canResolveReviewThreads)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canUnresolveReviewThreads)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canApproveReview)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canRequestChanges)

        #expect(!CodeHostProviderCapabilities.readOnly.canPublishReviewComments)
    }
}
```

Extend `AlasTests/Integrations/CodeHostModelsTests.swift` with:

```swift
@Test func reviewThreadSummaryCarriesProviderThreadIdentity() {
    let thread = ReviewThreadSummary(
        id: "thread-1",
        author: "reviewer",
        body: "Please fix this.",
        url: URL(string: "https://provider/thread"),
        isResolved: false,
        isActionable: true,
        location: ReviewThreadLocation(
            path: "Sources/App.swift",
            originalPath: nil,
            line: 42,
            side: .new,
            providerPosition: "42"
        ),
        providerThreadID: "thread-provider-id",
        providerCommentID: "comment-provider-id"
    )

    #expect(thread.providerThreadID == "thread-provider-id")
    #expect(thread.providerCommentID == "comment-provider-id")
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProviderReviewActionsTests -only-testing:AlasTests/CodeHostModelsTests -quiet test
```

Expected: compile failure for missing `ProviderReviewDraftComment`, `ReviewDraftProviderPublish`, provider capability fields, and `ReviewThreadSummary` identity fields.

- [ ] **Step 3: Add provider write models**

Create `Alas/Sources/Integrations/CodeHost/ProviderReviewActions.swift`:

```swift
import Foundation

enum ProviderReviewDecision: String, Codable, Equatable, Sendable {
    case comment
    case approve
    case requestChanges
}

struct ProviderReviewDraftComment: Codable, Equatable, Identifiable, Sendable {
    var id: String { localDraftID }
    let localDraftID: String
    let path: String
    let originalPath: String?
    let side: DiffReviewInlineFeedbackSide
    let lineRange: ClosedRange<Int>
    let selectedText: String?
    let bodyMarkdown: String

    init?(localDraft: ReviewDraftComment) {
        guard localDraft.state == .active, localDraft.providerPublish == nil else { return nil }
        self.localDraftID = localDraft.id
        self.path = localDraft.path
        self.originalPath = localDraft.originalPath
        self.side = localDraft.side
        self.lineRange = localDraft.normalizedLineRange
        self.selectedText = localDraft.selectedText
        self.bodyMarkdown = localDraft.bodyMarkdown
    }
}

struct ProviderReviewPublishRequest: Equatable, Sendable {
    let remote: CodeHostRemote
    let reviewRequest: ReviewRequest
    let comments: [ProviderReviewDraftComment]
    let decision: ProviderReviewDecision
    let summaryBody: String
    let cwd: URL
}

struct ProviderReviewPublishedComment: Codable, Equatable, Sendable {
    let localDraftID: String
    let providerThreadID: String?
    let providerCommentID: String?
    let providerURL: URL?
}

struct ProviderReviewFailedComment: Codable, Equatable, Sendable {
    let localDraftID: String
    let message: String
}

struct ProviderReviewPublishResult: Equatable, Sendable {
    let published: [ProviderReviewPublishedComment]
    let failed: [ProviderReviewFailedComment]
    let refreshedRequest: ReviewRequest
    let warnings: [String]
}

enum ProviderThreadMutationKind: String, Codable, Equatable, Sendable {
    case reply
    case resolve
    case unresolve
}

struct ProviderThreadMutation: Equatable, Sendable {
    let remote: CodeHostRemote
    let reviewRequest: ReviewRequest
    let thread: ReviewThreadSummary
    let kind: ProviderThreadMutationKind
    let bodyMarkdown: String?
    let cwd: URL
}

struct ProviderThreadMutationResult: Equatable, Sendable {
    let refreshedRequest: ReviewRequest
    let providerURL: URL?
}
```

- [ ] **Step 4: Extend existing models and provider protocol**

In `ReviewDraftModels.swift`, extend `ReviewDraftComment`:

```swift
struct ReviewDraftProviderPublish: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
    let reviewNumber: Int
    let threadID: String?
    let commentID: String?
    let url: URL?
    let publishedAt: Date
}

struct ReviewDraftProviderError: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let message: String
    let occurredAt: Date
}
```

Add fields to `ReviewDraftComment`:

```swift
var providerPublish: ReviewDraftProviderPublish?
var providerError: ReviewDraftProviderError?
```

Update its initializer to default both fields to `nil` so existing call sites keep compiling:

```swift
providerPublish: ReviewDraftProviderPublish? = nil,
providerError: ReviewDraftProviderError? = nil
```

In `CodeHostModels.swift`, extend `CodeHostProviderCapabilities` with booleans:

```swift
let canPublishReviewComments: Bool
let canReplyToReviewThreads: Bool
let canResolveReviewThreads: Bool
let canUnresolveReviewThreads: Bool
let canApproveReview: Bool
let canRequestChanges: Bool
```

Set `readOnly` to all false. Set `githubCLI` and `gitlabCLI` to all true for those six fields.

Extend `ReviewThreadSummary`:

```swift
let providerThreadID: String?
let providerCommentID: String?
```

Default both to `nil` in the initializer. Keep `id` unchanged for UI identity.

In `CodeHostProvider.swift`, add default unsupported write methods:

```swift
func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult
func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult
```

Default implementations:

```swift
func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
    throw CodeHostProviderError.unsupportedProvider(request.remote.kind)
}

func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
    throw CodeHostProviderError.unsupportedProvider(mutation.remote.kind)
}
```

Extend `CodeHostCommandRunning` so providers can pass JSON to provider CLIs without shell-encoding it into arguments:

```swift
protocol CodeHostCommandRunning: Sendable {
    func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult
}

extension CodeHostCommandRunning {
    func run(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResult {
        try await run(executable, args: args, cwd: cwd, stdin: nil)
    }
}

struct ProcessCodeHostCommandRunner: CodeHostCommandRunning {
    func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult {
        try await Process.run(
            "/usr/bin/env",
            args: [executable] + args,
            cwd: cwd,
            env: Process.gitEnv(),
            stdin: stdin
        )
    }
}
```

Update fake runners in provider tests when those tests first need stdin recording:

```swift
struct Command: Equatable {
    let executable: String
    let args: [String]
    let cwd: URL?
    let stdin: String?

    init(executable: String, args: [String], cwd: URL?, stdin: String? = nil) {
        self.executable = executable
        self.args = args
        self.cwd = cwd
        self.stdin = stdin
    }
}
```

and:

```swift
func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult {
    commands.append(Command(executable: executable, args: args, cwd: cwd, stdin: stdin))
    guard !results.isEmpty else {
        throw CodeHostProviderError.commandFailed(command: executable, stderr: "missing fake result")
    }
    return results.removeFirst()
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProviderReviewActionsTests -only-testing:AlasTests/CodeHostModelsTests -only-testing:AlasTests/ReviewDraftModelsTests -quiet test
```

Expected: PASS.

- [ ] **Step 6: Regenerate project and commit**

Run:

```bash
xcodegen
git status --short
git add Alas/Sources/Integrations/CodeHost/ProviderReviewActions.swift Alas/Sources/Integrations/CodeHost/CodeHostModels.swift Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift AlasTests/Integrations/ProviderReviewActionsTests.swift AlasTests/Integrations/CodeHostModelsTests.swift AlasTests/ReviewDraftModelsTests.swift Alas.xcodeproj
git commit -m "feat(review): add provider review action models"
```

Expected: commit contains only provider model/protocol changes and focused tests.

---

## Task 2: Draft Publish Metadata Persistence

**Files:**

- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentController.swift`
- Test: `AlasTests/ReviewDraftCommentStoreTests.swift`

- [ ] **Step 1: Write failing persistence/controller tests**

Add to `ReviewDraftCommentStoreTests`:

```swift
@Test @MainActor func controllerMarksDraftPublishedAndRecordsProviderErrors() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("review-draft-comments.json")
    let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
    let session = ReviewDraftSessionID.reviewRequest(
        worktreeID: "wt",
        provider: .github,
        host: "github.com",
        repositorySlug: "mrmans0n/alas",
        number: 527
    )
    let controller = ReviewDraftCommentController(
        sessionID: session,
        store: store,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let anchor = DiffReviewLineAnchor(
        path: "Sources/App.swift",
        side: .new,
        line: 42,
        rowIndex: 0,
        selectedText: "let value = 1"
    )
    let fileID = DiffReviewFileID(namespace: "github", path: "Sources/App.swift")

    try controller.load()
    try controller.add(anchor: anchor, fileID: fileID, bodyMarkdown: "Please fix this.")
    let added = try #require(controller.comments.single)

    let publish = ReviewDraftProviderPublish(
        provider: .github,
        host: "github.com",
        repositorySlug: "mrmans0n/alas",
        reviewNumber: 527,
        threadID: "thread-1",
        commentID: "comment-1",
        url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
        publishedAt: Date(timeIntervalSince1970: 120)
    )
    try controller.markPublished(commentID: added.id, publish: publish)

    let published = try #require(controller.comments.single)
    #expect(published.providerPublish == publish)
    #expect(published.providerError == nil)
    #expect(try store.load(sessionID: session).single?.providerPublish == publish)

    try controller.recordProviderError(
        commentID: added.id,
        error: ReviewDraftProviderError(provider: .github, message: "line is outdated", occurredAt: Date(timeIntervalSince1970: 130))
    )

    let errored = try #require(controller.comments.single)
    #expect(errored.providerPublish == publish)
    #expect(errored.providerError?.message == "line is outdated")
}

@Test func publishedMetadataSurvivesStoreRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("review-draft-comments.json")
    let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
    let session = ReviewDraftSessionID.reviewRequest(
        worktreeID: "wt",
        provider: .gitlab,
        host: "gitlab.example.com",
        repositorySlug: "platform/alas",
        number: 42
    )
    let comment = makeComment(id: "published", session: session, startLine: 8, endLine: nil, createdAt: Date(timeIntervalSince1970: 10))
        .withProviderPublishForTest(
            ReviewDraftProviderPublish(
                provider: .gitlab,
                host: "gitlab.example.com",
                repositorySlug: "platform/alas",
                reviewNumber: 42,
                threadID: "discussion-1",
                commentID: "501",
                url: URL(string: "https://gitlab.example.com/platform/alas/-/merge_requests/42#note_501"),
                publishedAt: Date(timeIntervalSince1970: 20)
            )
        )

    try store.save(comment)

    #expect(try store.load(sessionID: session).single == comment)
}
```

Add a private test helper:

```swift
private extension ReviewDraftComment {
    func withProviderPublishForTest(_ publish: ReviewDraftProviderPublish) -> ReviewDraftComment {
        var copy = self
        copy.providerPublish = publish
        return copy
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewDraftCommentStoreTests -quiet test
```

Expected: compile failure for missing controller methods.

- [ ] **Step 3: Implement controller methods**

In `ReviewDraftCommentController.swift`, add:

```swift
func markPublished(commentID: String, publish: ReviewDraftProviderPublish) throws {
    guard let index = comments.firstIndex(where: { $0.id == commentID }) else { return }
    var updated = comments[index]
    updated.providerPublish = publish
    updated.providerError = nil
    updated.updatedAt = now()
    try store.save(updated)
    comments[index] = updated
    errorMessage = nil
}

func recordProviderError(commentID: String, error: ReviewDraftProviderError) throws {
    guard let index = comments.firstIndex(where: { $0.id == commentID }) else { return }
    var updated = comments[index]
    updated.providerError = error
    updated.updatedAt = now()
    try store.save(updated)
    comments[index] = updated
    errorMessage = nil
}

var activeUnpublishedComments: [ReviewDraftComment] {
    comments.filter { $0.state == .active && $0.providerPublish == nil }
}
```

Use the existing private `now` closure already injected into `ReviewDraftCommentController` for both publish and provider-error timestamps.

- [ ] **Step 4: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewDraftCommentStoreTests -quiet test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentController.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift AlasTests/ReviewDraftCommentStoreTests.swift
git commit -m "feat(review): persist provider publish metadata"
```

Expected: commit contains only draft metadata persistence/controller changes and tests.

---

## Task 3: GitHub Provider Mutations

**Files:**

- Modify: `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
- Test: `AlasTests/Integrations/GitHubCLIProviderTests.swift`

- [ ] **Step 1: Write failing GitHub publish/reply/resolve tests**

Add to `GitHubCLIProviderTests`:

```swift
@Test func githubPublishReviewUsesGraphQLPayloadAndRefreshesPR() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.publishReviewMutationOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
    ])
    let provider = GitHubCLIProvider(runner: runner)
    let request = ProviderReviewPublishRequest(
        remote: Self.remote,
        reviewRequest: Self.reviewRequest,
        comments: [
            ProviderReviewDraftComment(
                localDraftID: "draft-1",
                path: "Sources/App.swift",
                originalPath: nil,
                side: .new,
                lineRange: 42...42,
                selectedText: "let value = 1",
                bodyMarkdown: "Please fix this."
            )
        ],
        decision: .requestChanges,
        summaryBody: "Requesting changes from Alas.",
        cwd: Self.cwd
    )

    let result = try await provider.publishReview(request)

    #expect(result.published.map(\.localDraftID) == ["draft-1"])
    #expect(result.failed.isEmpty)
    #expect(result.refreshedRequest.number == 42)
    let commands = await runner.commands
    #expect(commands[0].executable == "gh")
    #expect(commands[0].args == ["api", "graphql", "--input", "-"])
    #expect(commands[0].stdin?.contains("pullRequest(number:$number){id}") == true)
    #expect(commands[1].args == ["api", "graphql", "--input", "-"])
    #expect(commands[1].stdin?.contains("\"event\":\"REQUEST_CHANGES\"") == true)
    #expect(commands[1].stdin?.contains("\"path\":\"Sources/App.swift\"") == true)
}

@Test func githubThreadMutationsUseGraphQLAndRefreshPR() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 0, stdout: Self.replyMutationOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.resolveThreadMutationOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
    ])
    let provider = GitHubCLIProvider(runner: runner)
    let thread = ReviewThreadSummary(
        id: "thread-1",
        author: "reviewer",
        body: "Please fix this.",
        url: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"),
        isResolved: false,
        isActionable: true,
        location: nil,
        providerThreadID: "PRRT_thread_1",
        providerCommentID: "PRRC_comment_1"
    )

    _ = try await provider.mutateReviewThread(ProviderThreadMutation(
        remote: Self.remote,
        reviewRequest: Self.reviewRequest,
        thread: thread,
        kind: .reply,
        bodyMarkdown: "Fixed locally.",
        cwd: Self.cwd
    ))
    _ = try await provider.mutateReviewThread(ProviderThreadMutation(
        remote: Self.remote,
        reviewRequest: Self.reviewRequest,
        thread: thread,
        kind: .resolve,
        bodyMarkdown: nil,
        cwd: Self.cwd
    ))

    let commands = await runner.commands
    #expect(commands[0].args.contains(where: { $0.contains("addPullRequestReviewThreadReply") }))
    #expect(commands[3].args.contains(where: { $0.contains("resolveReviewThread") }))
}
```

Add fixtures near existing test fixture constants:

```swift
static let publishReviewMutationOutput = """
{"data":{"addPullRequestReview":{"pullRequestReview":{"comments":{"nodes":[{"id":"PRRC_comment_1","url":"https://github.com/mrmans0n/alas/pull/42#discussion_r1","pullRequestReviewThread":{"id":"PRRT_thread_1"}}]}}}}}
"""
static let replyMutationOutput = """
{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"PRRC_reply_1","url":"https://github.com/mrmans0n/alas/pull/42#discussion_r2"}}}}
"""
static let resolveThreadMutationOutput = """
{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_thread_1","isResolved":true}}}}
"""
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitHubCLIProviderTests -quiet test
```

Expected: compile failure for missing provider write implementation or initializer access.

- [ ] **Step 3: Implement GitHub mutations**

In `GitHubCLIProvider.swift`, add:

```swift
func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
    let stdin = try Self.githubReviewInputPayload(
        pullRequestID: try await pullRequestNodeID(
            remote: request.remote,
            number: request.reviewRequest.number,
            cwd: request.cwd
        ),
        decision: request.decision,
        summaryBody: request.summaryBody,
        comments: request.comments
    )
    let result = try await runner.run(
        "gh",
        args: ["api", "graphql", "--input", "-"],
        cwd: request.cwd,
        stdin: stdin
    )
    guard result.exitCode == 0 else {
        throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
    }
    let published = try Self.parsePublishedReviewComments(result.stdout, originalDrafts: request.comments)
    let refreshed = try await refreshedReviewRequest(remote: request.remote, request: request.reviewRequest, cwd: request.cwd)
    return ProviderReviewPublishResult(published: published, failed: [], refreshedRequest: refreshed, warnings: [])
}

func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
    switch mutation.kind {
    case .reply:
        guard let threadID = mutation.thread.providerThreadID, let body = mutation.bodyMarkdown, !body.isEmpty else {
            throw CodeHostProviderError.malformedOutput("GitHub reply requires a provider thread id and non-empty body.")
        }
        try await runThreadReply(threadID: threadID, body: body, cwd: mutation.cwd)
    case .resolve:
        guard let threadID = mutation.thread.providerThreadID else {
            throw CodeHostProviderError.malformedOutput("GitHub resolve requires a provider thread id.")
        }
        try await runThreadResolution(threadID: threadID, resolve: true, cwd: mutation.cwd)
    case .unresolve:
        guard let threadID = mutation.thread.providerThreadID else {
            throw CodeHostProviderError.malformedOutput("GitHub unresolve requires a provider thread id.")
        }
        try await runThreadResolution(threadID: threadID, resolve: false, cwd: mutation.cwd)
    }
    let refreshed = try await refreshedReviewRequest(remote: mutation.remote, request: mutation.reviewRequest, cwd: mutation.cwd)
    return ProviderThreadMutationResult(refreshedRequest: refreshed, providerURL: mutation.thread.url)
}
```

Add helper static functions:

```swift
static func githubReviewEvent(for decision: ProviderReviewDecision) -> String {
    switch decision {
    case .comment: "COMMENT"
    case .approve: "APPROVE"
    case .requestChanges: "REQUEST_CHANGES"
    }
}

static func githubReviewInputPayload(
    pullRequestID: String,
    decision: ProviderReviewDecision,
    summaryBody: String,
    comments: [ProviderReviewDraftComment]
) throws -> String {
    struct Comment: Encodable {
        let path: String
        let body: String
        let line: Int
        let side: String
        let startLine: Int?
    }
    struct Variables: Encodable {
        let pullRequestID: String
        let event: String
        let body: String
        let comments: [Comment]
    }
    struct Payload: Encodable {
        let query: String
        let variables: Variables
    }
    let commentPayload = comments.map { comment in
        Comment(
            path: comment.path,
            body: comment.bodyMarkdown,
            line: comment.lineRange.upperBound,
            side: comment.side == .old ? "LEFT" : "RIGHT",
            startLine: comment.lineRange.lowerBound == comment.lineRange.upperBound ? nil : comment.lineRange.lowerBound
        )
    }
    let payload = Payload(
        query: publishReviewMutation,
        variables: Variables(
            pullRequestID: pullRequestID,
            event: githubReviewEvent(for: decision),
            body: summaryBody,
            comments: commentPayload
        )
    )
    let data = try JSONEncoder().encode(payload)
    return String(decoding: data, as: UTF8.self)
}
```

Keep parser/helpers internal static so tests can exercise payload mapping. Use the existing `currentReviewRequest` path to refresh:

```swift
private func refreshedReviewRequest(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> ReviewRequest {
    let refreshed = try await currentReviewRequest(
        remote: remote,
        branch: request.headRefName,
        headOwner: nil,
        baseBranch: request.baseRefName,
        cwd: cwd
    )
    return refreshed ?? request
}
```

Use this explicit GraphQL flow: first query the PR node id by owner/repo/number, then submit the review with `addPullRequestReview(input:)`. Add this helper in the same task:

```swift
private func pullRequestNodeID(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> String {
    let stdin = """
    {"query":"query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id}}}","variables":{"owner":"\(remote.owner)","repo":"\(remote.repository)","number":\(number)}}
    """
    let result = try await runner.run("gh", args: ["api", "graphql", "--input", "-"], cwd: cwd, stdin: stdin)
    guard result.exitCode == 0 else {
        throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
    }
    return try Self.parsePullRequestNodeID(result.stdout)
}
```

Update `githubPublishReviewUsesGraphQLPayloadAndRefreshesPR` so `FakeRunner` returns the PR node-id query result before `publishReviewMutationOutput`, and assert the first two commands are:

```swift
#expect(commands[0].args == ["api", "graphql", "--input", "-"])
#expect(commands[0].stdin?.contains("pullRequest(number:$number){id}") == true)
#expect(commands[1].args == ["api", "graphql", "--input", "-"])
#expect(commands[1].stdin?.contains("\"pullRequestId\":\"PR_node_42\"") == true)
```

Add fixture:

```swift
static let pullRequestNodeOutput = """
{"data":{"repository":{"pullRequest":{"id":"PR_node_42"}}}}
"""
```

- [ ] **Step 4: Preserve thread provider IDs during parsing**

When parsing GitHub review threads, set:

```swift
providerThreadID: node.id
providerCommentID: firstComment.id
```

Keep existing `ReviewThreadSummary.id` stable as the same provider thread id or existing id.

- [ ] **Step 5: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitHubCLIProviderTests -quiet test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift AlasTests/Integrations/GitHubCLIProviderTests.swift
git commit -m "feat(review): add github review mutations"
```

Expected: commit contains only GitHub provider mutation work and tests.

---

## Task 4: GitLab Provider Mutations

**Files:**

- Modify: `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
- Test: `AlasTests/Integrations/GitLabCLIProviderTests.swift`

- [ ] **Step 1: Write failing GitLab publish/reply/resolve tests**

Add to `GitLabCLIProviderTests`:

```swift
@Test func gitlabPublishReviewCreatesDiscussionsApprovesAndRefreshesMR() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.approveOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
    ])
    let provider = GitLabCLIProvider(runner: runner)
    let request = ProviderReviewPublishRequest(
        remote: Self.remote,
        reviewRequest: Self.reviewRequest,
        comments: [
            ProviderReviewDraftComment(
                localDraftID: "draft-1",
                path: "Sources/App.swift",
                originalPath: nil,
                side: .new,
                lineRange: 24...24,
                selectedText: nil,
                bodyMarkdown: "Please fix this."
            )
        ],
        decision: .approve,
        summaryBody: "Looks good after this note.",
        cwd: Self.cwd
    )

    let result = try await provider.publishReview(request)

    #expect(result.published.map(\.localDraftID) == ["draft-1"])
    let commands = await runner.commands
    #expect(commands.contains {
        $0.executable == "glab" && $0.args.prefix(2) == ["api", "projects/:id/merge_requests/42/discussions"]
    })
    #expect(commands.contains {
        $0.executable == "glab" && $0.args.prefix(2) == ["api", "projects/:id/merge_requests/42/approve"]
    })
}

@Test func gitlabThreadMutationsUseDiscussionEndpointsAndRefreshMR() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 0, stdout: Self.createNoteOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.resolveDiscussionOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
        ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
    ])
    let provider = GitLabCLIProvider(runner: runner)
    let thread = ReviewThreadSummary(
        id: "discussion-1",
        author: "reviewer",
        body: "Please fix this.",
        url: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_501"),
        isResolved: false,
        isActionable: true,
        location: nil,
        providerThreadID: "discussion-1",
        providerCommentID: "501"
    )

    _ = try await provider.mutateReviewThread(ProviderThreadMutation(
        remote: Self.remote,
        reviewRequest: Self.reviewRequest,
        thread: thread,
        kind: .reply,
        bodyMarkdown: "Fixed locally.",
        cwd: Self.cwd
    ))
    _ = try await provider.mutateReviewThread(ProviderThreadMutation(
        remote: Self.remote,
        reviewRequest: Self.reviewRequest,
        thread: thread,
        kind: .resolve,
        bodyMarkdown: nil,
        cwd: Self.cwd
    ))

    let commands = await runner.commands
    #expect(commands.contains { $0.args.contains("projects/:id/merge_requests/42/discussions/discussion-1/notes") })
    #expect(commands.contains { $0.args.contains("projects/:id/merge_requests/42/discussions/discussion-1") })
}
```

Add fixtures:

```swift
static let versionsOutput = """
{"diff_refs":{"base_sha":"base123","start_sha":"start123","head_sha":"head123"}}
"""
static let createDiscussionOutput = """
{"id":"discussion-1","notes":[{"id":501,"web_url":"https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_501"}]}
"""
static let createNoteOutput = """
{"id":502,"web_url":"https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_502"}
"""
static let resolveDiscussionOutput = """
{"id":"discussion-1","resolved":true}
"""
static let approveOutput = """
{"id":42,"approved":true}
"""
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitLabCLIProviderTests -quiet test
```

Expected: compile failure for missing GitLab mutation implementation.

- [ ] **Step 3: Implement GitLab mutations**

In `GitLabCLIProvider.swift`, add:

```swift
func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
    let diffRefs = try await mergeRequestDiffRefs(remote: request.remote, request: request.reviewRequest, cwd: request.cwd)
    var published: [ProviderReviewPublishedComment] = []
    var failed: [ProviderReviewFailedComment] = []

    for comment in request.comments {
        do {
            let mapping = try await createDiscussion(remote: request.remote, request: request.reviewRequest, comment: comment, diffRefs: diffRefs, cwd: request.cwd)
            published.append(mapping)
        } catch {
            failed.append(ProviderReviewFailedComment(localDraftID: comment.localDraftID, message: error.localizedDescription))
        }
    }

    if request.decision == .approve {
        try await approveMergeRequest(remote: request.remote, request: request.reviewRequest, cwd: request.cwd)
    } else if request.decision == .requestChanges {
        try await createRequestChangesNote(remote: request.remote, request: request.reviewRequest, body: request.summaryBody, cwd: request.cwd)
    }

    let refreshed = try await reviewRequestDetails(remote: request.remote, request: request.reviewRequest, cwd: request.cwd)
    let threads = (try? await unresolvedDiscussions(remote: request.remote, request: refreshed, cwd: request.cwd)) ?? []
    let checks = (try? await checks(remote: request.remote, request: refreshed, cwd: request.cwd)) ?? []
    return ProviderReviewPublishResult(
        published: published,
        failed: failed,
        refreshedRequest: Self.withEnrichment(threads: threads, checks: checks, on: refreshed),
        warnings: []
    )
}

func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
    guard let discussionID = mutation.thread.providerThreadID else {
        throw CodeHostProviderError.malformedOutput("GitLab thread mutation requires a discussion id.")
    }
    switch mutation.kind {
    case .reply:
        guard let body = mutation.bodyMarkdown, !body.isEmpty else {
            throw CodeHostProviderError.malformedOutput("GitLab reply requires a non-empty body.")
        }
        try await createDiscussionNote(remote: mutation.remote, request: mutation.reviewRequest, discussionID: discussionID, body: body, cwd: mutation.cwd)
    case .resolve:
        try await setDiscussionResolved(remote: mutation.remote, request: mutation.reviewRequest, discussionID: discussionID, resolved: true, cwd: mutation.cwd)
    case .unresolve:
        try await setDiscussionResolved(remote: mutation.remote, request: mutation.reviewRequest, discussionID: discussionID, resolved: false, cwd: mutation.cwd)
    }

    let refreshed = try await reviewRequestDetails(remote: mutation.remote, request: mutation.reviewRequest, cwd: mutation.cwd)
    let threads = (try? await unresolvedDiscussions(remote: mutation.remote, request: refreshed, cwd: mutation.cwd)) ?? []
    let checks = (try? await checks(remote: mutation.remote, request: refreshed, cwd: mutation.cwd)) ?? []
    return ProviderThreadMutationResult(
        refreshedRequest: Self.withEnrichment(threads: threads, checks: checks, on: refreshed),
        providerURL: mutation.thread.url
    )
}
```

Add helpers:

```swift
struct GitLabDiffRefs: Equatable {
    let baseSHA: String
    let startSHA: String
    let headSHA: String
}

static func gitLabPositionPayload(comment: ProviderReviewDraftComment, diffRefs: GitLabDiffRefs) -> [String: String] {
    var payload = [
        "position[position_type]": "text",
        "position[base_sha]": diffRefs.baseSHA,
        "position[start_sha]": diffRefs.startSHA,
        "position[head_sha]": diffRefs.headSHA,
        "position[new_path]": comment.path,
        "position[old_path]": comment.originalPath ?? comment.path,
    ]
    if comment.side == .old {
        payload["position[old_line]"] = "\(comment.lineRange.upperBound)"
    } else {
        payload["position[new_line]"] = "\(comment.lineRange.upperBound)"
    }
    return payload
}
```

Use `glab api` endpoint strings exactly:

- `projects/:id/merge_requests/<number>/versions`
- `projects/:id/merge_requests/<number>/discussions`
- `projects/:id/merge_requests/<number>/discussions/<discussionID>/notes`
- `projects/:id/merge_requests/<number>/discussions/<discussionID>`
- `projects/:id/merge_requests/<number>/approve`
- `projects/:id/merge_requests/<number>/notes`

- [ ] **Step 4: Preserve provider IDs during discussion parsing**

When parsing GitLab discussions, set:

```swift
providerThreadID: discussion.id
providerCommentID: firstNonSystemNote.id.map(String.init)
```

Keep `ReviewThreadSummary.id` as the discussion id.

- [ ] **Step 5: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitLabCLIProviderTests -quiet test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift AlasTests/Integrations/GitLabCLIProviderTests.swift
git commit -m "feat(review): add gitlab review mutations"
```

Expected: commit contains only GitLab provider mutation work and tests.

---

## Task 5: Provider Review Mutation Controller

**Files:**

- Create: `Alas/Sources/Center/ReviewWorkspace/ProviderReviewMutationController.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
- Test: `AlasTests/ReviewSessionTabViewTests.swift`

- [ ] **Step 1: Write failing controller tests**

Add to `ReviewSessionTabViewTests`:

```swift
@Test @MainActor func providerMutationControllerPublishesDraftsAndMarksResults() async throws {
    let sessionID = ReviewDraftSessionID.reviewRequest(
        worktreeID: "wt",
        provider: .github,
        host: "github.com",
        repositorySlug: "mrmans0n/alas",
        number: 527
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ReviewDraftCommentStore(store: PersistenceStore(), url: directory.appendingPathComponent("drafts.json"))
    let draftController = ReviewDraftCommentController(sessionID: sessionID, store: store, now: { Date(timeIntervalSince1970: 200) })
    try draftController.load()
    try draftController.add(
        anchor: DiffReviewLineAnchor(path: "Sources/App.swift", side: .new, line: 12, rowIndex: 0, selectedText: "let value = 1"),
        fileID: DiffReviewFileID(namespace: "github", path: "Sources/App.swift"),
        bodyMarkdown: "Please fix this."
    )
    let added = try #require(draftController.comments.single)

    let provider = FakeProviderReviewMutator(
        result: ProviderReviewPublishResult(
            published: [
                ProviderReviewPublishedComment(
                    localDraftID: added.id,
                    providerThreadID: "thread-1",
                    providerCommentID: "comment-1",
                    providerURL: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1")
                )
            ],
            failed: [],
            refreshedRequest: Self.reviewRequest(provider: .github),
            warnings: []
        )
    )
    let controller = ProviderReviewMutationController(
        provider: provider,
        draftController: draftController,
        now: { Date(timeIntervalSince1970: 300) }
    )

    let outcome = try await controller.publishReview(
        remote: Self.remote(kind: .github),
        reviewRequest: Self.reviewRequest(provider: .github),
        decision: .comment,
        summaryBody: "Review from Alas",
        cwd: URL(fileURLWithPath: "/repo")
    )

    #expect(outcome.refreshedRequest.number == 527)
    let updated = try #require(draftController.comments.single)
    #expect(updated.providerPublish?.threadID == "thread-1")
    #expect(updated.providerPublish?.publishedAt == Date(timeIntervalSince1970: 300))
}

@Test @MainActor func providerMutationControllerKeepsFailedDraftsActiveWithError() async throws {
    let sessionID = ReviewDraftSessionID.reviewRequest(
        worktreeID: "wt",
        provider: .gitlab,
        host: "gitlab.example.com",
        repositorySlug: "platform/alas",
        number: 42
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ReviewDraftCommentStore(store: PersistenceStore(), url: directory.appendingPathComponent("drafts.json"))
    let draftController = ReviewDraftCommentController(sessionID: sessionID, store: store, now: { Date(timeIntervalSince1970: 200) })
    try draftController.load()
    try draftController.add(
        anchor: DiffReviewLineAnchor(path: "Sources/App.swift", side: .new, line: 12, rowIndex: 0, selectedText: nil),
        fileID: DiffReviewFileID(namespace: "gitlab", path: "Sources/App.swift"),
        bodyMarkdown: "Please fix this."
    )
    let added = try #require(draftController.comments.single)

    let provider = FakeProviderReviewMutator(
        result: ProviderReviewPublishResult(
            published: [],
            failed: [ProviderReviewFailedComment(localDraftID: added.id, message: "line is not commentable")],
            refreshedRequest: Self.reviewRequest(provider: .gitlab),
            warnings: []
        )
    )
    let controller = ProviderReviewMutationController(
        provider: provider,
        draftController: draftController,
        now: { Date(timeIntervalSince1970: 300) }
    )

    _ = try await controller.publishReview(
        remote: Self.remote(kind: .gitlab),
        reviewRequest: Self.reviewRequest(provider: .gitlab),
        decision: .comment,
        summaryBody: "Review from Alas",
        cwd: URL(fileURLWithPath: "/repo")
    )

    let updated = try #require(draftController.comments.single)
    #expect(updated.providerPublish == nil)
    #expect(updated.providerError?.message == "line is not commentable")
    #expect(updated.state == .active)
}
```

Add a local fake:

```swift
private struct FakeProviderReviewMutator: CodeHostProvider {
    let kind: CodeHostKind = .github
    let result: ProviderReviewPublishResult

    func isAvailable() async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? { result.refreshedRequest }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL { result.refreshedRequest.url }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { "" }
    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] { [] }
    func checkEvidenceDetail(remote: CodeHostRemote, request: ReviewRequest, item: ReviewEvidenceItem, cwd: URL) async throws -> ReviewEvidenceDetail {
        throw CodeHostProviderError.malformedOutput("FakeProviderReviewMutator does not provide check evidence details.")
    }
    func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] { [] }
    func feedbackEvidenceDetail(remote: CodeHostRemote, request: ReviewRequest, item: ReviewEvidenceItem, cwd: URL) async throws -> ReviewEvidenceDetail {
        throw CodeHostProviderError.malformedOutput("FakeProviderReviewMutator does not provide feedback evidence details.")
    }
    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}
    func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult { result }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests -quiet test
```

Expected: compile failure for missing `ProviderReviewMutationController`.

- [ ] **Step 3: Implement controller**

Create `ProviderReviewMutationController.swift`:

```swift
import Foundation

@MainActor
struct ProviderReviewMutationController {
    let provider: any CodeHostProvider
    let draftController: ReviewDraftCommentController
    let now: () -> Date

    func publishReview(
        remote: CodeHostRemote,
        reviewRequest: ReviewRequest,
        decision: ProviderReviewDecision,
        summaryBody: String,
        cwd: URL
    ) async throws -> ProviderReviewPublishResult {
        let comments = draftController.activeUnpublishedComments.compactMap(ProviderReviewDraftComment.init(localDraft:))
        let request = ProviderReviewPublishRequest(
            remote: remote,
            reviewRequest: reviewRequest,
            comments: comments,
            decision: decision,
            summaryBody: summaryBody,
            cwd: cwd
        )

        let result = try await provider.publishReview(request)
        for published in result.published {
            try draftController.markPublished(
                commentID: published.localDraftID,
                publish: ReviewDraftProviderPublish(
                    provider: remote.kind,
                    host: remote.host,
                    repositorySlug: remote.repositorySlug,
                    reviewNumber: reviewRequest.number,
                    threadID: published.providerThreadID,
                    commentID: published.providerCommentID,
                    url: published.providerURL,
                    publishedAt: now()
                )
            )
        }
        for failed in result.failed {
            try draftController.recordProviderError(
                commentID: failed.localDraftID,
                error: ReviewDraftProviderError(
                    provider: remote.kind,
                    message: failed.message,
                    occurredAt: now()
                )
            )
        }
        return result
    }

    func mutateThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
        try await provider.mutateReviewThread(mutation)
    }
}
```

- [ ] **Step 4: Wire controller factory in `ReviewSessionTabView` without UI yet**

Add private helper methods in `ReviewSessionTabView`:

```swift
private func providerForLoadedReviewSession(_ loaded: ReviewSessionLoadedContext) -> (any CodeHostProvider)? {
    guard let appState else { return nil }
    guard let request = loaded.session.reviewRequest else { return nil }
    return appState.codeHostProviders.provider(for: request.provider)
}

private func makeProviderMutationController(for loaded: ReviewSessionLoadedContext) -> ProviderReviewMutationController? {
    guard let provider = providerForLoadedReviewSession(loaded),
          let draftCommentController
    else { return nil }
    return ProviderReviewMutationController(
        provider: provider,
        draftController: draftCommentController,
        now: now
    )
}
```

Add explicit provider context to the loaded review-session context in this task. Modify `ReviewSessionLoadedContext`:

```swift
struct ReviewSessionProviderContext: Equatable, Sendable {
    let remote: CodeHostRemote
    let reviewRequest: ReviewRequest
}

struct ReviewSessionLoadedContext {
    let session: DiffReviewLoadedSession
    let feedbackTarget: ReviewFeedbackTarget
    let providerContext: ReviewSessionProviderContext?
}
```

Update `ReviewSessionLoader.load(target:)` so local changes, commits, ranges, branches, and draft PR/MR sessions pass `providerContext: nil`. For `.reviewRequest`, populate `providerContext` from the target payload and the loaded `ReviewRequest` returned by `ReviewRequestDiffLoader`; if the existing loader closure returns only `DiffReviewLoadedSession`, change that closure type to return:

```swift
struct ReviewSessionProviderLoadedSession {
    let loadedSession: DiffReviewLoadedSession
    let providerContext: ReviewSessionProviderContext
}
```

and adapt only the `.reviewRequest` production/test loaders.

- [ ] **Step 5: Run focused tests and regenerate project**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests -quiet test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Alas/Sources/Center/ReviewWorkspace/ProviderReviewMutationController.swift Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift AlasTests/ReviewSessionTabViewTests.swift Alas.xcodeproj
git commit -m "feat(review): add provider mutation controller"
```

Expected: commit contains controller and minimal wiring only.

---

## Task 6: Provider Publish Confirmation UI

**Files:**

- Create: `Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentActions.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`
- Test: `AlasTests/ReviewSessionTabViewTests.swift`

- [ ] **Step 1: Write failing UI action tests**

Add to `DiffReviewSurfaceTests`:

```swift
@Test @MainActor func localDraftCardShowsPublishActionWhenAvailable() throws {
    let comment = draftComment(
        id: "draft-publish",
        fileID: DiffReviewFileID(namespace: "github", path: "Sources/App.swift"),
        path: "Sources/App.swift",
        side: .new,
        startLine: 2
    )
    var publishedID: String?
    var layout = DiffLayoutMode.stacked
    var wrap = false
    var whitespace = false
    var actions = ReviewDraftCommentActions()
    actions.availability = { _ in
        ReviewDraftCommentActionAvailability(
            canEdit: false,
            canDelete: false,
            canResolve: false,
            canDismiss: false,
            canCopyPrompt: false,
            canShowSendToAgent: false,
            canSendToAgent: false,
            canPublishProvider: true
        )
    }
    actions.publishProvider = { comment in
        publishedID = comment.id
    }

    let view = DiffReviewFileSection(
        file: DiffReviewFileSectionModel(summary: summary(path: "Sources/App.swift"), parsedDiff: parsedDiff(), displayModel: displayModel(), placeholderMessage: nil, openFile: nil),
        draftComments: [comment],
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsSourceBadge: false,
        draftCommentActions: actions
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 900, height: 500)
    #expect(pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-draft-comment-publish-draft-publish", in: controller.view))
    #expect(publishedID == "draft-publish")
}
```

Add to `ReviewSessionTabViewTests`:

```swift
@Test @MainActor func publishConfirmationListsProviderDecisionAndCommentCount() {
    let view = ProviderReviewPublishConfirmationView(
        providerName: "GitHub",
        reviewIdentity: "PR #527",
        commentCount: 2,
        unpublishableMessages: ["Sources/Old.swift: line is outdated"],
        selectedDecision: .constant(.comment),
        isPublishing: false,
        errorMessage: nil,
        onCancel: {},
        onConfirm: {}
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 420, height: 260)

    #expect(text(in: controller.view, contains: "GitHub"))
    #expect(text(in: controller.view, contains: "PR #527"))
    #expect(text(in: controller.view, contains: "2 comments"))
    #expect(text(in: controller.view, contains: "line is outdated"))
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/ReviewSessionTabViewTests -quiet test
```

Expected: compile failures for new action availability and confirmation view.

- [ ] **Step 3: Extend draft action API**

In `ReviewDraftCommentActions.swift`, add:

```swift
var canPublishProvider: Bool
```

to `ReviewDraftCommentActionAvailability`, defaulting false.

Add action:

```swift
var publishProvider: (ReviewDraftComment) -> Void = { _ in }
```

Update all availability construction sites with `canPublishProvider`.

- [ ] **Step 4: Render per-comment publish**

In `ReviewDraftCommentCard.actionRow` inside `DiffReviewFileSection.swift`, add:

```swift
if availability.canPublishProvider {
    actionButton(id: "publish", title: "Publish") {
        actions.publishProvider(comment)
    }
}
```

Ensure the action button accessibility id becomes:

```swift
"diff-review-draft-comment-publish-\(comment.id)"
```

by following the existing action button id naming pattern.

- [ ] **Step 5: Create confirmation view**

Create `ProviderReviewPublishConfirmationView.swift`:

```swift
import SwiftUI

struct ProviderReviewPublishConfirmationView: View {
    let providerName: String
    let reviewIdentity: String
    let commentCount: Int
    let unpublishableMessages: [String]
    @Binding var selectedDecision: ProviderReviewDecision
    let isPublishing: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish review")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("\(providerName) \(reviewIdentity)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Picker("Decision", selection: $selectedDecision) {
                Text("Comment").tag(ProviderReviewDecision.comment)
                Text("Approve").tag(ProviderReviewDecision.approve)
                Text("Request changes").tag(ProviderReviewDecision.requestChanges)
            }
            .pickerStyle(.segmented)
            Text("\(commentCount) \(commentCount == 1 ? "comment" : "comments")")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
            if !unpublishableMessages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(unpublishableMessages, id: \.self) { message in
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("warn"))
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isPublishing)
                Button(isPublishing ? "Publishing..." : "Publish", action: onConfirm)
                    .disabled(isPublishing)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(theme.color("bg-1"))
        .accessibilityIdentifier("provider-review-publish-confirmation")
    }
}
```

- [ ] **Step 6: Add summary rail publish affordance**

In `ReviewDraftSummaryRail.swift`, add a `Publish review` button near copy/send actions when an injected availability flag is true. If a new action container is needed, add it to `ReviewDraftCommentActions`:

```swift
var publishReview: () -> Void = {}
var canPublishReview: () -> Bool = { false }
```

Render with accessibility id:

```swift
"review-draft-summary-publish-review"
```

- [ ] **Step 7: Run focused UI tests**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/ReviewSessionTabViewTests -quiet test
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run:

```bash
git add Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentActions.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift AlasTests/DiffReviewSurfaceTests.swift AlasTests/ReviewSessionTabViewTests.swift Alas.xcodeproj
git commit -m "feat(review): add provider publish actions"
```

Expected: commit contains UI action surfaces and confirmation view only.

---

## Task 7: Review Session Provider Wiring

**Files:**

- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewInlineFeedbackActions.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Test: `AlasTests/ReviewSessionTabViewTests.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Write failing session wiring tests**

Add to `ReviewSessionTabViewTests`:

```swift
@Test @MainActor func reviewSessionShowsPublishReviewForProviderContextWithDrafts() throws {
    let record = reviewRequestRecord(provider: .github)
    let loaded = loadedReviewRequestContext(provider: .github)
    let draft = draftComment(id: "draft-1", sessionID: record.target.draftSessionID, fileID: loaded.session.files[0].id)
    let draftStore = seededDraftStore(comments: [draft])

    let view = ReviewSessionTabView.testView(
        record: record,
        loaded: loaded,
        draftCommentStore: draftStore,
        provider: FakeProviderReviewMutator(result: ProviderReviewPublishResult(
            published: [],
            failed: [],
            refreshedRequest: reviewRequest(provider: .github),
            warnings: []
        ))
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 1200, height: 720)

    #expect(subview(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: controller.view) != nil)
}
```

Add to `DiffReviewSurfaceTests`:

```swift
@Test @MainActor func providerFeedbackCardShowsReplyResolveAndUnresolveActions() throws {
    let unresolved = DiffReviewInlineFeedback(
        id: "thread-1",
        providerName: "GitHub",
        author: "reviewer",
        bodyPreview: "Please fix this.",
        status: .actionable,
        providerURL: nil,
        anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 2, side: .new),
        evidenceItemID: "thread-1"
    )
    var replied = false
    var resolved = false
    var actions = DiffReviewInlineFeedbackActions()
    actions.availability = { _, _ in
        DiffReviewInlineFeedbackActionAvailability(
            canOpenProvider: false,
            canCopyContext: false,
            canSendToAgent: false,
            canReplyProvider: true,
            canResolveProvider: true,
            canUnresolveProvider: false
        )
    }
    actions.replyProvider = { _, _, body in
        replied = body == "Done"
    }
    actions.resolveProvider = { _, _ in
        resolved = true
    }

    let summary = DiffReviewFileSummary(
        path: "Sources/App.swift",
        namespace: "github",
        groupID: nil,
        groupTitle: nil,
        status: .modified,
        additions: 1,
        deletions: 0,
        isRenderable: true,
        originalPath: nil
    )
    var layout = DiffLayoutMode.stacked
    var wrap = false
    var whitespace = false
    let view = DiffReviewFileSection(
        file: DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil
        ),
        inlineFeedback: [unresolved],
        inlineFeedbackActions: actions,
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsSourceBadge: false
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 900, height: 520)

    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-reply-thread-1", in: controller.view) != nil)
    #expect(pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-inline-feedback-action-resolve-thread-1", in: controller.view))
    #expect(resolved)
    DiffReviewInlineFeedbackCardInteraction.reply(unresolved, body: "Done") { item, body in
        actions.replyProvider(item, summary, body)
    }
    #expect(replied)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests -only-testing:AlasTests/DiffReviewSurfaceTests -quiet test
```

Expected: compile or assertion failure for missing wiring/actions.

- [ ] **Step 3: Extend inline feedback actions**

In `DiffReviewInlineFeedbackActions.swift`, extend availability:

```swift
var canReplyProvider: Bool
var canResolveProvider: Bool
var canUnresolveProvider: Bool
```

Add action closures:

```swift
var replyProvider: (DiffReviewInlineFeedback, DiffReviewFileSummary, String) -> Void = { _, _, _ in }
var resolveProvider: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
var unresolveProvider: (DiffReviewInlineFeedback, DiffReviewFileSummary) -> Void = { _, _ in }
```

Update `.none` and all construction sites.

- [ ] **Step 4: Render provider feedback action buttons**

In `DiffReviewInlineFeedbackCard.actionRow`, render:

```swift
if availability.canReplyProvider {
    actionButton(id: "reply", title: "Reply") {
        isReplying = true
        replyBody = ""
    }
}
if availability.canResolveProvider {
    actionButton(id: "resolve", title: "Resolve") {
        actions.resolveProvider(item, file)
    }
}
if availability.canUnresolveProvider {
    actionButton(id: "unresolve", title: "Unresolve") {
        actions.unresolveProvider(item, file)
    }
}
```

Add minimal inline reply editor state:

```swift
@State private var isReplying = false
@State private var replyBody = ""
```

When saving:

```swift
let body = replyBody.trimmingCharacters(in: .whitespacesAndNewlines)
guard !body.isEmpty else { return }
actions.replyProvider(item, file, body)
isReplying = false
replyBody = ""
```

Accessibility ids:

- `diff-review-inline-feedback-reply-<id>`
- `diff-review-inline-feedback-resolve-<id>`
- `diff-review-inline-feedback-unresolve-<id>`
- `diff-review-inline-feedback-reply-save-<id>`

- [ ] **Step 5: Wire provider actions in `ReviewSessionTabView`**

Add state:

```swift
@State private var providerPublishConfirmation: ProviderReviewPublishConfirmationState?
@State private var providerPublishError: String?
@State private var isProviderPublishing = false
@State private var selectedProviderDecision: ProviderReviewDecision = .comment
```

Add state type near the view:

```swift
struct ProviderReviewPublishConfirmationState: Equatable {
    let commentID: String?
    let providerName: String
    let reviewIdentity: String
    let commentCount: Int
    let unpublishableMessages: [String]
}
```

Extend `draftCommentActions()` so:

- `availability.canPublishProvider` is true only for provider sessions, active unpublished drafts, and commentable line anchors.
- `publishProvider(comment)` opens confirmation for that comment.
- `canPublishReview()` is true when provider session has active unpublished drafts.
- `publishReview()` opens confirmation for all active unpublished drafts.

Extend `DiffReviewInlineFeedbackActions` produced by the tab so:

- reply/resolve/unresolve visibility follows provider capabilities and provider thread id presence
- actions call `ProviderReviewMutationController.mutateThread`
- after mutation, update `loaded` with the result's refreshed request/session, preserving current selected file

Use an overlay/sheet/popover for `ProviderReviewPublishConfirmationView`. In the confirm callback, call `ProviderReviewMutationController.publishReview`.

- [ ] **Step 6: Refresh loaded session from refreshed provider request**

Add helper:

```swift
private func applyRefreshedReviewRequest(_ request: ReviewRequest) async {
    guard var currentLoaded = loaded else { return }
    currentLoaded = currentLoaded.replacingReviewRequest(request)
    loaded = currentLoaded
}
```

Add replacement helpers for refreshed provider state:

```swift
extension ReviewSessionLoadedContext {
    func replacingReviewRequest(_ request: ReviewRequest) -> ReviewSessionLoadedContext {
        ReviewSessionLoadedContext(
            session: session.replacingReviewRequest(request),
            feedbackTarget: feedbackTarget
        )
    }
}
```

Add equivalent `DiffReviewLoadedSession.replacingReviewRequest`.

- [ ] **Step 7: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests -only-testing:AlasTests/DiffReviewSurfaceTests -quiet test
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run:

```bash
git add Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift Alas/Sources/Center/DiffReview/DiffReviewInlineFeedbackActions.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift AlasTests/ReviewSessionTabViewTests.swift AlasTests/DiffReviewSurfaceTests.swift
git commit -m "feat(review): wire provider review actions"
```

Expected: commit contains review-session wiring and provider-feedback UI actions.

---

## Task 8: Publish Filtering, Confirmation Safety, and Error States

**Files:**

- Modify: `Alas/Sources/Center/ReviewWorkspace/ProviderReviewMutationController.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift`
- Test: `AlasTests/ReviewSessionTabViewTests.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Write failing safety tests**

Add tests:

```swift
@Test @MainActor func publishReviewIgnoresAlreadyPublishedDraftsByDefault() throws {
    let comments = [
        activeUnpublishedDraft(id: "active"),
        activePublishedDraft(id: "published")
    ]
    let publishable = ProviderReviewPublishPlanner.publishableDrafts(comments)
    #expect(publishable.map(\.id) == ["active"])
}

@Test @MainActor func confirmationDisablesPublishWhenNoPublishableCommentsAndDecisionIsComment() {
    var decision = ProviderReviewDecision.comment
    var confirmed = false
    let view = ProviderReviewPublishConfirmationView(
        providerName: "GitHub",
        reviewIdentity: "PR #527",
        commentCount: 0,
        unpublishableMessages: [],
        selectedDecision: Binding(get: { decision }, set: { decision = $0 }),
        isPublishing: false,
        errorMessage: nil,
        onCancel: {},
        onConfirm: { confirmed = true }
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 420, height: 260)
    #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "provider-review-publish-confirm", in: controller.view))
    #expect(!confirmed)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests -only-testing:AlasTests/DiffReviewSurfaceTests -quiet test
```

Expected: failure for missing planner and disabled confirmation behavior.

- [ ] **Step 3: Add publish planner**

Create in `ProviderReviewMutationController.swift`:

```swift
enum ProviderReviewPublishPlanner {
    static func publishableDrafts(_ comments: [ReviewDraftComment]) -> [ReviewDraftComment] {
        comments.filter { comment in
            comment.state == .active
                && comment.providerPublish == nil
                && comment.startLine > 0
                && !comment.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func unpublishableMessages(_ comments: [ReviewDraftComment]) -> [String] {
        comments.compactMap { comment in
            if comment.providerPublish != nil {
                return "\(comment.path): already published"
            }
            if comment.state != .active {
                return "\(comment.path): not active"
            }
            if comment.startLine <= 0 {
                return "\(comment.path): missing line anchor"
            }
            if comment.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(comment.path): empty comment"
            }
            return nil
        }
    }
}
```

Use this planner in summary rail and per-comment publish availability.

- [ ] **Step 4: Harden confirmation view**

Add:

```swift
private var canConfirm: Bool {
    !isPublishing && (commentCount > 0 || selectedDecision != .comment)
}
```

Use `.disabled(!canConfirm)` on the confirm button and add an accessibility marker with id `provider-review-publish-confirm` whose press returns false when disabled.

- [ ] **Step 5: Render published/error state on local draft cards and summary rows**

In local draft cards, display:

- `published` status when `comment.providerPublish != nil`
- provider error text when `comment.providerError != nil`

Use existing text styles:

```swift
if let providerPublish = comment.providerPublish {
    Text("published to \(providerPublish.provider.displayName)")
}
if let providerError = comment.providerError {
    Text(providerError.message)
        .foregroundColor(theme.color("warn"))
}
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests -only-testing:AlasTests/DiffReviewSurfaceTests -quiet test
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
git add Alas/Sources/Center/ReviewWorkspace/ProviderReviewMutationController.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift AlasTests/ReviewSessionTabViewTests.swift AlasTests/DiffReviewSurfaceTests.swift
git commit -m "fix(review): harden provider publish safety"
```

Expected: commit contains safety filtering/error display only.

---

## Task 9: Final Integration Verification

**Files:**

- Verify all changed files.
- No new production behavior unless CI/focused tests reveal a bug that must be fixed.

- [ ] **Step 1: Run focused provider/review suites**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ProviderReviewActionsTests \
  -only-testing:AlasTests/GitHubCLIProviderTests \
  -only-testing:AlasTests/GitLabCLIProviderTests \
  -only-testing:AlasTests/ReviewDraftCommentStoreTests \
  -only-testing:AlasTests/ReviewSessionTabViewTests \
  -only-testing:AlasTests/DiffReviewSurfaceTests \
  -quiet test
```

Expected: PASS.

- [ ] **Step 2: Run project generation**

Run:

```bash
xcodegen
git status --short
```

Expected: no uncommitted project churn except intended source/test files. If `Alas.xcodeproj` changes due to new files, include it in the relevant commit.

- [ ] **Step 3: Run quiet build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0.

- [ ] **Step 5: Final status**

Run:

```bash
git status --short --branch
git log --oneline -8
```

Expected: clean working tree on `nacho/provider-review-actions`, with implementation commits above the design/plan commits.

Do not open or merge a PR automatically unless the user asks for the PR loop.
