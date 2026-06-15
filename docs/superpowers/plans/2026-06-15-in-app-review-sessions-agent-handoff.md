# In-App Review Sessions And Agent Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent in-app review sessions for any reviewable diff target, with local feedback state and native send-to-agent handoff tracking.

**Architecture:** Build a durable review-session layer above the existing `DiffReviewSurface`, `ReviewDraftCommentStore`, and `ReviewFeedbackAgentSender`. Reuse existing diff loaders and draft comment storage; add session records, target identity, handoff history, a review-session tab shell, and launcher entry points.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, existing JSON persistence through `PersistenceStore`, existing ACP session APIs through `AppState`.

---

## File Map

- Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionModels.swift`
  - Owns `ReviewSessionTarget`, `ReviewSessionRecord`, `ReviewSessionStatus`, `ReviewFeedbackHandoff`, and deterministic IDs.
- Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionStore.swift`
  - Persists session records using the same `PersistenceStoreProtocol` style as `ReviewDraftCommentStore`.
- Modify `Alas/Sources/Persistence/Paths.swift`
  - Adds `reviewSessionsFile`.
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift`
  - Makes `ReviewFeedbackAgentTarget` persistable for handoff records.
- Test `AlasTests/ReviewSessionModelsTests.swift`
  - Covers target IDs, draft session IDs, prompt metadata, and handoff state.
- Test `AlasTests/ReviewSessionStoreTests.swift`
  - Covers persistence round trips, sorted session listing, and reuse lookup.
- Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`
  - Converts `ReviewSessionTarget` into `DiffReviewLoadedSession` plus `ReviewFeedbackTarget`.
- Modify existing loaders only where needed to expose pure helper methods:
  - `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
  - `Alas/Sources/Center/Commit/CommitReviewLoader.swift`
  - `Alas/Sources/Center/ReviewRequest/DraftReviewRequestDiffSessionBuilder.swift`
  - `Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift`
- Test `AlasTests/ReviewSessionLoaderTests.swift`
  - Covers target-to-loader routing with fake clients.
- Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
  - Thin SwiftUI shell around `DiffReviewSurface`, summary rail, target header, and send state.
- Modify `Alas/Sources/Center/Tab.swift`
  - Adds `case reviewSession(ReviewSessionTabState)`.
- Modify `Alas/Sources/Center/TabsManager.swift`
  - Adds `openOrFocusReviewSession` and `updateReviewSession`.
- Modify `Alas/Sources/Center/CenterPaneView.swift`
  - Hosts `ReviewSessionTabView`.
- Test `AlasTests/TabsManagerReviewSessionTests.swift`
  - Covers open/focus, update, and reuse behavior.
- Modify launcher surfaces:
  - `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
  - `Alas/Sources/Center/Commit/CommitTabView.swift`
  - `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
  - `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift`
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackBundle.swift`
  - Adds optional session/revision metadata to the prompt.
- Modify `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift`
  - Records successful handoffs through the session store after ACP accepts/queues the prompt.
- Test existing focused suites:
  - `AlasTests/ReviewFeedbackBundleTests.swift`
  - `AlasTests/ReviewChangesTabViewTests.swift`
  - `AlasTests/DiffReviewSurfaceTests.swift`

## Task 1: Review Session Models And Persistence

**Files:**
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionModels.swift`
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionStore.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift`
- Modify: `Alas/Sources/Persistence/Paths.swift`
- Test: `AlasTests/ReviewSessionModelsTests.swift`
- Test: `AlasTests/ReviewSessionStoreTests.swift`
- Modify after `xcodegen` when new Swift file references are generated: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing model tests for stable target identity**

Add `AlasTests/ReviewSessionModelsTests.swift`:

```swift
import Foundation
import Testing

struct ReviewSessionModelsTests {
    @Test func localChangesTargetDerivesStableIDs() {
        let repositoryPath = URL(fileURLWithPath: "/repo")
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            scope: .unstaged
        )

        #expect(target.kind == .localChanges)
        #expect(target.id.rawValue == "local-changes\u{1f}wt-1\u{1f}/repo\u{1f}unstaged")
        #expect(target.draftSessionID == .localChanges(worktreeID: "wt-1", worktreePath: repositoryPath, scope: .unstaged))
        #expect(target.title == "Review unstaged changes")
        #expect(target.sourceDescription == "Local changes: unstaged")
    }

    @Test func providerTargetIncludesProviderIdentity() {
        let target = ReviewSessionTarget.reviewRequest(
            worktreeID: "wt-1",
            provider: .github,
            host: "GitHub.com",
            repositorySlug: "mrmans0n/alas",
            number: 520,
            url: URL(string: "https://github.com/mrmans0n/alas/pull/520")!,
            title: "Use shared surface",
            headSHA: "abc123"
        )

        #expect(target.kind == .reviewRequest)
        #expect(target.id.rawValue.contains("github"))
        #expect(target.id.rawValue.contains("github.com"))
        #expect(target.draftSessionID == .reviewRequest(worktreeID: "wt-1", provider: .github, host: "github.com", repositorySlug: "mrmans0n/alas", number: 520))
        #expect(target.providerDescription == "GitHub mrmans0n/alas #520")
        #expect(target.revisionDescription == "abc123")
    }

    @Test func handoffTransitionsToSentAndAddressed() {
        let record = ReviewSessionRecord(
            id: ReviewSessionID(rawValue: "session-1"),
            target: .commit(
                worktreeID: "wt-1",
                repositoryPath: URL(fileURLWithPath: "/repo"),
                sha: "deadbeef",
                title: "Review deadbeef"
            ),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let handoff = ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: record.id,
            commentIDs: ["c1", "c2"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: Date(timeIntervalSince1970: 30),
            promptRevision: "rev-1",
            status: .sent
        )

        let withHandoff = record.recording(handoff: handoff)
        #expect(withHandoff.status == .sent)
        #expect(withHandoff.handoffs == [handoff])
        #expect(withHandoff.markedAddressed(now: Date(timeIntervalSince1970: 40)).status == .addressed)
    }
}
```

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionModelsTests test`

Expected: FAIL because `ReviewSessionTarget`, `ReviewSessionRecord`, and `ReviewFeedbackHandoff` do not exist.

- [ ] **Step 2: Implement review session models**

First modify `ReviewFeedbackAgentTarget` in `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift` so handoff records can be persisted:

```swift
enum ReviewFeedbackAgentTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    case newChat(agentID: String, title: String)
    case existingSession(worktreeID: String, sessionID: String, title: String)
}
```

Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionModels.swift` with these public-internal types:

```swift
import Foundation

struct ReviewSessionID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
    let rawValue: String
}

enum ReviewSessionTargetKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case draftCommit = "draft-commit"
    case commit
    case commitRange = "commit-range"
    case branch
    case reviewRequest = "review-request"
    case draftReviewRequest = "draft-review-request"
}

struct ReviewSessionTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: ReviewSessionID
    let kind: ReviewSessionTargetKind
    let worktreeID: String
    let repositoryPath: URL
    let title: String
    let sourceDescription: String
    let providerDescription: String?
    let providerURL: URL?
    let revisionDescription: String?
    let draftSessionID: ReviewDraftSessionID
    let payload: Payload

    enum Payload: Codable, Equatable, Hashable, Sendable {
        case localChanges(scope: ReviewDraftLocalChangesScope)
        case draftCommit
        case commit(sha: String)
        case commitRange(base: String, head: String)
        case branch(base: String, head: String)
        case reviewRequest(provider: CodeHostKind, host: String, repositorySlug: String, number: Int, headSHA: String?)
        case draftReviewRequest(provider: CodeHostKind, repositorySlug: String, base: String, head: String, headSHA: String?)
    }
}

enum ReviewSessionStatus: String, Codable, Equatable, Hashable, Sendable {
    case active
    case sent
    case addressing
    case addressed
    case archived
}

enum ReviewFeedbackHandoffStatus: String, Codable, Equatable, Hashable, Sendable {
    case sent
    case failed
    case addressed
}

struct ReviewFeedbackHandoff: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: ReviewSessionID
    let commentIDs: [String]
    let target: ReviewFeedbackAgentTarget
    let createdAt: Date
    let promptRevision: String
    var status: ReviewFeedbackHandoffStatus
}

struct ReviewSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: ReviewSessionID
    var target: ReviewSessionTarget
    var selectedFileID: DiffReviewFileID?
    var focusedCommentID: String?
    var status: ReviewSessionStatus
    var handoffs: [ReviewFeedbackHandoff]
    var lastSendError: String?
    let createdAt: Date
    var updatedAt: Date
}
```

Add factory methods on `ReviewSessionTarget` for every target listed in the spec. Use `\u{1f}` as the field separator and lowercase provider hosts. Derive `draftSessionID` with the existing `ReviewDraftSessionID` factories.

Add a convenience initializer on `ReviewSessionRecord` with defaults for optional state:

```swift
init(
    id: ReviewSessionID,
    target: ReviewSessionTarget,
    selectedFileID: DiffReviewFileID? = nil,
    focusedCommentID: String? = nil,
    status: ReviewSessionStatus = .active,
    handoffs: [ReviewFeedbackHandoff] = [],
    lastSendError: String? = nil,
    createdAt: Date,
    updatedAt: Date
)
```

Add convenience methods on `ReviewSessionRecord`:

```swift
func recording(handoff: ReviewFeedbackHandoff) -> ReviewSessionRecord
func markedAddressed(now: Date) -> ReviewSessionRecord
func selectingFile(_ fileID: DiffReviewFileID?, now: Date) -> ReviewSessionRecord
func focusingComment(_ commentID: String?, now: Date) -> ReviewSessionRecord
```

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionModelsTests test`

Expected: PASS.

- [ ] **Step 3: Add failing persistence tests**

Add `AlasTests/ReviewSessionStoreTests.swift`:

```swift
import Foundation
import Testing

struct ReviewSessionStoreTests {
    @Test func roundTripsSessionRecords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ReviewSessionStore(url: url)
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123",
            title: "Review abc123"
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            selectedFileID: DiffReviewFileID(namespace: "commit", path: "Sources/A.swift"),
            focusedCommentID: "comment-1",
            status: .active,
            handoffs: [],
            lastSendError: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        try store.save(record)

        #expect(try store.load(id: target.id) == record)
        #expect(try store.findActive(targetID: target.id) == record)
        #expect(try store.list(worktreeID: "wt-1") == [record])
    }

    @Test func archiveRemovesSessionFromActiveReuse() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ReviewSessionStore(url: url)
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        var record = ReviewSessionRecord(id: target.id, target: target, createdAt: .init(timeIntervalSince1970: 1), updatedAt: .init(timeIntervalSince1970: 1))
        try store.save(record)

        record.status = .archived
        try store.save(record)

        #expect(try store.findActive(targetID: target.id) == nil)
        #expect(try store.load(id: target.id)?.status == .archived)
    }
}
```

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionStoreTests test`

Expected: FAIL because `ReviewSessionStore` and `Paths.reviewSessionsFile` do not exist.

- [ ] **Step 4: Implement persistence**

Modify `Alas/Sources/Persistence/Paths.swift` with:

```swift
static var reviewSessionsFile: URL {
    appSupport.appendingPathComponent("review-sessions.json")
}
```

Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionStore.swift` following `ReviewDraftCommentStore`:

```swift
import Foundation

struct ReviewSessionStore {
    private let store: any PersistenceStoreProtocol
    private let url: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.reviewSessionsFile) {
        self.store = store
        self.url = url
    }

    func load(id: ReviewSessionID) throws -> ReviewSessionRecord?
    func list(worktreeID: String) throws -> [ReviewSessionRecord]
    func findActive(targetID: ReviewSessionID) throws -> ReviewSessionRecord?
    func save(_ record: ReviewSessionRecord) throws
}
```

Store records by `record.id.rawValue`, sort lists by `updatedAt` descending, and treat `.archived` records as not active for reuse.

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionModelsTests -only-testing:AlasTests/ReviewSessionStoreTests test
```

Expected: PASS.

- [ ] **Step 5: Regenerate project and commit Task 1**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionModelsTests -only-testing:AlasTests/ReviewSessionStoreTests test
git status --short
git add Alas/Sources/Center/ReviewWorkspace/ReviewSessionModels.swift Alas/Sources/Center/ReviewWorkspace/ReviewSessionStore.swift Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift Alas/Sources/Persistence/Paths.swift AlasTests/ReviewSessionModelsTests.swift AlasTests/ReviewSessionStoreTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): add review session records"
```

Expected: focused tests pass. If `xcodegen` does not change `Alas.xcodeproj/project.pbxproj`, do not stage it.

## Task 2: Review Session Loader And Prompt Context

**Files:**
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackBundle.swift`
- Test: `AlasTests/ReviewSessionLoaderTests.swift`
- Test: `AlasTests/ReviewFeedbackBundleTests.swift`
- Modify after `xcodegen` when new Swift file references are generated: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing loader tests**

Create `AlasTests/ReviewSessionLoaderTests.swift` with fake clients for commit and local-change sessions:

```swift
import Foundation
import Testing

struct ReviewSessionLoaderTests {
    @Test func localChangesLoaderBuildsGroupedSessionAndFeedbackTarget() async throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let loader = ReviewSessionLoader(
            localChanges: { target in
                #expect(target.kind == .localChanges)
                let summary = DiffReviewFileSummary(
                    path: "Sources/A.swift",
                    namespace: "unstaged",
                    groupID: "unstaged",
                    groupTitle: "Unstaged",
                    status: .modified,
                    additions: 1,
                    deletions: 0,
                    isRenderable: true
                )
                return DiffReviewLoadedSession(
                    files: [DiffReviewFileSectionModel(summary: summary, parsedDiff: nil, displayModel: nil, placeholderMessage: nil, openFile: nil)],
                    summary: DiffReviewSessionModel(files: [summary], groupsEnabled: true)
                )
            }
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.session.summary.fileCount == 1)
        #expect(loaded.feedbackTarget.title == "Review unstaged changes")
        #expect(loaded.feedbackTarget.repositoryPath == "/repo")
        #expect(loaded.feedbackTarget.sourceDescription == "Local changes: all")
    }

    @Test func commitLoaderBuildsPinnedSourceDescription() async throws {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "deadbeef",
            title: "Review deadbeef"
        )
        let loader = ReviewSessionLoader(
            commit: { target in
                #expect(target.revisionDescription == "deadbeef")
                return DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false))
            }
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.feedbackTarget.sourceDescription == "Commit deadbeef")
    }
}
```

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionLoaderTests test`

Expected: FAIL because `ReviewSessionLoader` does not exist.

- [ ] **Step 2: Implement loader shell and injected closures**

Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`:

```swift
import Foundation

struct ReviewSessionLoadedContext {
    let session: DiffReviewLoadedSession
    let feedbackTarget: ReviewFeedbackTarget
}

struct ReviewSessionLoader {
    var localChanges: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var draftCommit: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var commit: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var commitRange: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var branch: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var reviewRequest: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var draftReviewRequest: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession

    init(
        localChanges: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        draftCommit: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commit: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commitRange: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        branch: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        reviewRequest: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        draftReviewRequest: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget }
    )

    func load(target: ReviewSessionTarget) async throws -> ReviewSessionLoadedContext
}

enum ReviewSessionLoaderError: Error, Equatable {
    case unsupportedTarget
}
```

Route by `target.kind`, call `Task.checkCancellation()` before and after the selected closure, and build `ReviewFeedbackTarget` from `target.title`, `target.repositoryPath.path`, `target.providerDescription`, and `target.sourceDescription`.

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionLoaderTests test`

Expected: PASS.

- [ ] **Step 3: Add failing prompt metadata test**

Extend `AlasTests/ReviewFeedbackBundleTests.swift`:

```swift
@Test func promptIncludesReviewSessionRevisionAndPreviousHandoff() {
    let target = ReviewFeedbackTarget(
        title: "Review deadbeef",
        repositoryPath: "/repo",
        providerDescription: nil,
        sourceDescription: "Commit deadbeef",
        sessionDescription: "Review session: commit deadbeef",
        revisionDescription: "deadbeef",
        priorHandoffDescription: "Previously sent to Codex at 1970-01-01 00:00:30 +0000"
    )
    let comment = ReviewDraftComment(
        id: "c1",
        sessionID: .commit(worktreeID: "wt-1", repositoryPath: URL(fileURLWithPath: "/repo"), sha: "deadbeef"),
        fileID: DiffReviewFileID(namespace: "commit", path: "Sources/A.swift"),
        path: "Sources/A.swift",
        originalPath: nil,
        side: .new,
        startLine: 10,
        endLine: nil,
        selectedText: nil,
        bodyMarkdown: "Fix this",
        state: .active,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    let prompt = ReviewFeedbackBundle(target: target, comments: [comment]).promptMarkdown()

    #expect(prompt.contains("Review session: commit deadbeef"))
    #expect(prompt.contains("Revision: deadbeef"))
    #expect(prompt.contains("Previously sent to Codex"))
}
```

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewFeedbackBundleTests test`

Expected: FAIL because `ReviewFeedbackTarget` has no optional session/revision/handoff descriptions.

- [ ] **Step 4: Extend prompt target metadata**

Modify `ReviewFeedbackTarget` in `ReviewFeedbackBundle.swift`:

```swift
struct ReviewFeedbackTarget: Equatable, Sendable {
    var title: String
    var repositoryPath: String?
    var providerDescription: String?
    var sourceDescription: String
    var sessionDescription: String? = nil
    var revisionDescription: String? = nil
    var priorHandoffDescription: String? = nil
}
```

In `promptMarkdown()`, append non-empty metadata after `Source`:

```swift
if let sessionDescription, !sessionDescription.isEmpty {
    lines.append(sessionDescription)
}
if let revisionDescription, !revisionDescription.isEmpty {
    lines.append("Revision: \(revisionDescription)")
}
if let priorHandoffDescription, !priorHandoffDescription.isEmpty {
    lines.append(priorHandoffDescription)
}
```

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionLoaderTests -only-testing:AlasTests/ReviewFeedbackBundleTests test
```

Expected: PASS.

- [ ] **Step 5: Regenerate project and commit Task 2**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionLoaderTests -only-testing:AlasTests/ReviewFeedbackBundleTests test
git status --short
git add Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackBundle.swift AlasTests/ReviewSessionLoaderTests.swift AlasTests/ReviewFeedbackBundleTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): add review session loading context"
```

Expected: focused tests pass. If `xcodegen` does not change the project, do not stage `Alas.xcodeproj/project.pbxproj`.

## Task 3: Review Session Tab And Tabs Manager

**Files:**
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Test: `AlasTests/TabsManagerReviewSessionTests.swift`
- Test: `AlasTests/ReviewSessionTabViewTests.swift`
- Modify after `xcodegen` when new Swift file references are generated: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing tab manager tests**

Add `AlasTests/TabsManagerReviewSessionTests.swift`:

```swift
import Foundation
import Testing

struct TabsManagerReviewSessionTests {
    @Test func opensOrFocusesReviewSessionForSameTarget() {
        var manager = TabsManager()
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(id: target.id, target: target, createdAt: .init(timeIntervalSince1970: 1), updatedAt: .init(timeIntervalSince1970: 1))

        let first = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: record)
        let second = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: record)

        #expect(first.id == second.id)
        #expect(manager.tabs(forWorktree: "wt-1").filter {
            if case .reviewSession = $0 { return true }
            return false
        }.count == 1)
    }

    @Test func updatesReviewSessionSelection() {
        var manager = TabsManager()
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc",
            title: "Review abc"
        )
        let record = ReviewSessionRecord(id: target.id, target: target, createdAt: .init(timeIntervalSince1970: 1), updatedAt: .init(timeIntervalSince1970: 1))
        let tab = manager.openOrFocusReviewSession(worktreeId: "wt-1", record: record)

        _ = manager.updateReviewSession(worktreeId: "wt-1", tabId: tab.id) { state in
            state.selectedFileID = DiffReviewFileID(namespace: "commit", path: "A.swift")
        }

        guard case .reviewSession(let state)? = manager.tabs(forWorktree: "wt-1").first(where: { $0.id == tab.id }) else {
            Issue.record("Missing review session tab")
            return
        }
        #expect(state.selectedFileID == DiffReviewFileID(namespace: "commit", path: "A.swift"))
    }
}
```

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerReviewSessionTests test`

Expected: FAIL because `Tab.reviewSession` and `ReviewSessionTabState` do not exist.

- [ ] **Step 2: Add tab state and manager APIs**

Modify `Alas/Sources/Center/Tab.swift`:

```swift
case reviewSession(ReviewSessionTabState)
```

Add `ReviewSessionTabState`:

```swift
struct ReviewSessionTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let sessionID: ReviewSessionID
    var title: String
    var selectedFileID: DiffReviewFileID?
    var focusedCommentID: String?

    init(worktreeId: String, record: ReviewSessionRecord) {
        self.id = "review-session:\(record.id.rawValue)"
        self.worktreeId = worktreeId
        self.sessionID = record.id
        self.title = record.target.title
        self.selectedFileID = record.selectedFileID
        self.focusedCommentID = record.focusedCommentID
    }
}
```

Update `Tab.id`, `Tab.title`, and `Tab.iconName` for `.reviewSession`.

Modify `TabsManager.swift` with:

```swift
@discardableResult
func openOrFocusReviewSession(worktreeId: String, record: ReviewSessionRecord) -> Tab

@discardableResult
func updateReviewSession(
    worktreeId: String,
    tabId: TabID,
    mutate: (inout ReviewSessionTabState) -> Void
) -> Tab?
```

Use the existing `openOrFocusDraftReviewRequest` pattern.

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerReviewSessionTests test`

Expected: PASS.

- [ ] **Step 3: Add failing hosted shell test**

Add `AlasTests/ReviewSessionTabViewTests.swift`:

```swift
import Foundation
import Testing
import SwiftUI

struct ReviewSessionTabViewTests {
    @MainActor
    @Test func rendersLoadedSessionTitleAndSummaryRail() throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(id: target.id, target: target, createdAt: .init(timeIntervalSince1970: 1), updatedAt: .init(timeIntervalSince1970: 1))
        let summary = DiffReviewFileSummary(
            path: "A.swift",
            namespace: "unstaged",
            groupID: "unstaged",
            groupTitle: "Unstaged",
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: false
        )
        let loaded = ReviewSessionLoadedContext(
            session: DiffReviewLoadedSession(
                files: [DiffReviewFileSectionModel(summary: summary, parsedDiff: nil, displayModel: nil, placeholderMessage: "No diff", openFile: nil)],
                summary: DiffReviewSessionModel(files: [summary], groupsEnabled: true)
            ),
            feedbackTarget: ReviewFeedbackTarget(title: target.title, repositoryPath: "/repo", providerDescription: nil, sourceDescription: target.sourceDescription)
        )
        let view = ReviewSessionTabView.preview(record: record, loaded: loaded)

        let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()

        #expect(host.recursiveDescriptionForTests.contains("Review all changes"))
    }
}
```

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests test`

Expected: FAIL because `ReviewSessionTabView` does not exist.

- [ ] **Step 4: Implement review session tab shell**

Create `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`.

The production initializer should accept:

```swift
struct ReviewSessionTabView: View {
    let worktree: Worktree
    let tabState: ReviewSessionTabState
    let appState: AppState
}
```

Implement internal dependencies:

- `ReviewSessionStore()`
- `ReviewDraftCommentStore()`
- `ReviewSessionLoader.production(appState:worktree:)`
- `ReviewFeedbackAgentSender.production(appState:worktreeID:)`

Keep the first implementation thin:

- load `ReviewSessionRecord` by `tabState.sessionID`
- call `ReviewSessionLoader.load(target:)`
- render retryable error text on load failure
- render `DiffReviewSurface(session:selectedFileID:...)` with existing `ReviewDraftWorkspaceActions`
- render `ReviewDraftSummaryRail` beside the diff surface
- update `ReviewSessionStore` and `TabsManager.updateReviewSession` when selected file or focused comment changes

Add a `static func preview(record:loaded:) -> some View` only for tests; it should use in-memory closures and no disk writes.

Modify `CenterPaneView.swift` to switch over `.reviewSession(let state)` and host `ReviewSessionTabView`.

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerReviewSessionTests -only-testing:AlasTests/ReviewSessionTabViewTests test
```

Expected: PASS.

- [ ] **Step 5: Regenerate project and commit Task 3**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerReviewSessionTests -only-testing:AlasTests/ReviewSessionTabViewTests test
git status --short
git add Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift Alas/Sources/Center/CenterPaneView.swift AlasTests/TabsManagerReviewSessionTests.swift AlasTests/ReviewSessionTabViewTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): add review session tab"
```

Expected: focused tests pass. Do not stage the project file if unchanged.

## Task 4: Agent Handoff Recording

**Files:**
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
- Test: `AlasTests/ReviewChangesTabViewTests.swift`
- Test: `AlasTests/ReviewSessionModelsTests.swift`
- Test: `AlasTests/ReviewSessionTabViewTests.swift`

- [ ] **Step 1: Add failing handoff recording tests**

Extend `AlasTests/ReviewSessionModelsTests.swift`:

```swift
@Test func promptRevisionChangesWhenIncludedCommentsChange() {
    let first = ReviewFeedbackHandoff.revisionKey(commentIDs: ["b", "a"], prompt: "hello")
    let second = ReviewFeedbackHandoff.revisionKey(commentIDs: ["a", "b"], prompt: "hello")
    let third = ReviewFeedbackHandoff.revisionKey(commentIDs: ["a", "b"], prompt: "different")

    #expect(first == second)
    #expect(first != third)
}
```

Extend `AlasTests/ReviewChangesTabViewTests.swift` or add to `ReviewSessionTabViewTests.swift`:

```swift
@MainActor
@Test func sendToAgentRecordsSessionHandoff() {
    var sentPrompt: String?
    var recorded: ReviewFeedbackHandoff?
    let target = ReviewFeedbackAgentTarget.existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex")
    let sender = ReviewFeedbackAgentSender(
        availableTargets: { [target] },
        send: { prompt, _ in sentPrompt = prompt }
    )
    let sessionID = ReviewSessionID(rawValue: "session-1")
    let comment = ReviewDraftComment(
        id: "c1",
        sessionID: .localChanges(worktreeID: "wt-1", worktreePath: URL(fileURLWithPath: "/repo"), scope: .all),
        fileID: DiffReviewFileID(namespace: "unstaged", path: "A.swift"),
        path: "A.swift",
        originalPath: nil,
        side: .new,
        startLine: 1,
        endLine: nil,
        selectedText: nil,
        bodyMarkdown: "Fix it",
        state: .active,
        createdAt: .init(timeIntervalSince1970: 1),
        updatedAt: .init(timeIntervalSince1970: 1)
    )
    let bundle = ReviewFeedbackBundle(
        target: ReviewFeedbackTarget(title: "Review", repositoryPath: "/repo", providerDescription: nil, sourceDescription: "Local changes"),
        comments: [comment]
    )

    ReviewFeedbackPromptActions.sendToAgent(
        bundle,
        target: target,
        sender: sender,
        sessionID: sessionID,
        recordHandoff: { recorded = $0 },
        now: { Date(timeIntervalSince1970: 30) },
        makeID: { "handoff-1" }
    )

    #expect(sentPrompt?.contains("Fix it") == true)
    #expect(recorded?.id == "handoff-1")
    #expect(recorded?.sessionID == sessionID)
    #expect(recorded?.commentIDs == ["c1"])
    #expect(recorded?.status == .sent)
}
```

Run focused tests.

Expected: FAIL because `revisionKey` and the extended send API do not exist.

- [ ] **Step 2: Implement handoff recording API**

Modify `ReviewFeedbackAgentSender.swift`:

- Add `ReviewFeedbackHandoff.revisionKey(commentIDs:prompt:)` in `ReviewSessionModels.swift`.
- Overload `ReviewFeedbackPromptActions.sendToAgent` with optional session handoff parameters:

```swift
@MainActor
static func sendToAgent(
    _ bundle: ReviewFeedbackBundle,
    target: ReviewFeedbackAgentTarget,
    sender: ReviewFeedbackAgentSender,
    sessionID: ReviewSessionID?,
    recordHandoff: ((ReviewFeedbackHandoff) -> Void)?,
    now: () -> Date = Date.init,
    makeID: () -> String = { UUID().uuidString }
)
```

Keep the existing call site API by having the old method call the new one with `nil`.

Record a handoff only after `sender.send(prompt,target)` returns. Include only active comment IDs in sorted order.

In `ReviewSessionTabView`, pass a `recordHandoff` closure that:

- loads the current `ReviewSessionRecord`
- appends the handoff through `recording(handoff:)`
- saves the record through `ReviewSessionStore`
- updates visible record state

Run focused tests.

Expected: PASS.

- [ ] **Step 3: Surface sent state in summary rail**

Add a small visible state to `ReviewDraftSummaryRail`:

- When at least one handoff exists, show `Sent to agent` with the latest handoff time.
- If `lastSendError` is non-empty, show the error in muted destructive text.
- Keep existing copy/send controls available.

Add a hosted test in `ReviewSessionTabViewTests` that a preview record with one handoff renders `Sent to agent`.

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests -only-testing:AlasTests/ReviewSessionModelsTests -only-testing:AlasTests/ReviewChangesTabViewTests test`

Expected: PASS.

- [ ] **Step 4: Commit Task 4**

Run:

```bash
git status --short
git add Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift Alas/Sources/Center/ReviewWorkspace/ReviewSessionModels.swift AlasTests/ReviewChangesTabViewTests.swift AlasTests/ReviewSessionModelsTests.swift AlasTests/ReviewSessionTabViewTests.swift
git commit -m "feat(review): record agent handoffs"
```

Expected: focused tests pass and commit contains only handoff-related changes.

## Task 5: Launcher Entry Points And Production Loader Wiring

**Files:**
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
- Modify: `Alas/Sources/Center/Commit/CommitTabView.swift`
- Modify: `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift`
- Test: `AlasTests/ReviewSessionLoaderTests.swift`
- Test: `AlasTests/ReviewChangesTabViewTests.swift`
- Test: `AlasTests/CommitTabViewTests.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceModelTests.swift`
- Test: `AlasTests/Integrations/ReviewRequestDraftTests.swift`

- [ ] **Step 1: Add failing launcher tests**

Add targeted helper tests where the existing views already expose static helpers:

```swift
@Test func reviewChangesLauncherBuildsLocalChangesTarget() {
    let target = ReviewChangesTabView.reviewSessionTarget(
        worktreeID: "wt-1",
        repositoryPath: URL(fileURLWithPath: "/repo"),
        scope: .all
    )

    #expect(target.draftSessionID == .localChanges(worktreeID: "wt-1", worktreePath: URL(fileURLWithPath: "/repo"), scope: .all))
    #expect(target.title == "Review all changes")
}
```

Add equivalent helper tests for:

- `CommitTabView.reviewSessionTarget(worktreeID:repositoryPath:sha:title:)`
- `ReviewEvidenceTabView.reviewSessionTarget(worktreeID:tabState:)`
- `DraftReviewRequestTabView.reviewSessionTarget(worktreeID:repositoryPath:tabState:)`

Run focused suites.

Expected: FAIL because helpers and UI actions do not exist.

- [ ] **Step 2: Add production loader wiring**

Add `ReviewSessionLoader.production(appState:worktree:)`.

The production loader should:

- local changes / draft commit: reuse the existing review changes loading helpers for `DiffReviewLoadedSession`.
- commit: reuse `CommitReviewLoader`.
- commit range / branch: use git diff file discovery plus `DiffParser` and `DiffDisplayModelBuilder`, matching the existing draft review request builder pattern.
- review request: use `ReviewRequestDiffLoader` and provider snapshot data available from `ReviewEvidenceTabView`.
- draft review request: use `DraftReviewRequestDiffSessionBuilder`.

If an individual target cannot yet be loaded due to missing data at runtime, throw `ReviewSessionLoaderError.unsupportedTarget` and let the tab show the retryable error. Do not silently open an empty session.

Run `ReviewSessionLoaderTests`.

Expected: PASS.

- [ ] **Step 3: Add open/focus helper and launcher buttons**

In each launcher surface, add a static target helper plus a private open method:

```swift
@MainActor
private func openReviewSession(target: ReviewSessionTarget) {
    let store = ReviewSessionStore()
    let now = Date()
    let record = (try? store.findActive(targetID: target.id)) ?? ReviewSessionRecord(id: target.id, target: target, createdAt: now, updatedAt: now)
    try? store.save(record)
    appState.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: record)
}
```

Use the local state names in each file (`worktree`, `tabState`, `snapshot`, etc.) instead of inventing globals.

Add UI affordances:

- Changes tab toolbar/menu: `Review Changes`
- Commit tab review header: `Review This Commit`
- Review Evidence Files/Feedback header: `Review Pull Request` / `Review Merge Request`
- Draft PR/MR tab diff header: `Review Branch Diff`

Run focused view tests.

Expected: PASS.

- [ ] **Step 4: Commit Task 5**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionLoaderTests -only-testing:AlasTests/ReviewChangesTabViewTests -only-testing:AlasTests/CommitTabViewTests -only-testing:AlasTests/Integrations/ReviewEvidenceModelTests -only-testing:AlasTests/Integrations/ReviewRequestDraftTests test
git status --short
git add Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift Alas/Sources/Center/Commit/CommitTabView.swift Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift AlasTests/ReviewSessionLoaderTests.swift AlasTests/ReviewChangesTabViewTests.swift AlasTests/CommitTabViewTests.swift AlasTests/Integrations/ReviewEvidenceModelTests.swift AlasTests/Integrations/ReviewRequestDraftTests.swift
git commit -m "feat(review): launch in-app review sessions"
```

Expected: focused tests pass and launcher actions compile.

## Task 6: Final Integration Verification

**Files:**
- No planned source edits. Fix only issues found by verification.

- [ ] **Step 1: Run focused review suites**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionModelsTests -only-testing:AlasTests/ReviewSessionStoreTests -only-testing:AlasTests/ReviewSessionLoaderTests -only-testing:AlasTests/ReviewSessionTabViewTests -only-testing:AlasTests/TabsManagerReviewSessionTests -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/ReviewFeedbackBundleTests test
```

Expected: PASS.

- [ ] **Step 2: Regenerate project and build**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: both commands exit 0 and no unexpected generated project churn remains.

- [ ] **Step 3: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: PASS. If a known flaky suite fails, rerun that exact suite once and record the result before deciding whether to fix or report.

- [ ] **Step 4: Launch for manual verification**

Run:

```bash
rtk open -n /Users/nacho/Library/Developer/Xcode/DerivedData/Alas-eupuaczfhmjxxeczlwrweeuqzxqh/Build/Products/Debug/Alas.app
```

If the DerivedData path differs, locate the newest valid `Alas.app` with `Contents/MacOS/Alas` and launch that path with `rtk open -n`.

Manual checks:

- Open Review Changes, click `Review Changes`, and confirm a review session tab opens.
- Add a local draft comment, send it to an ACP target, and confirm the summary rail shows sent state.
- Reopen the same target and confirm the existing session is focused rather than duplicated.

- [ ] **Step 5: Final status**

Run:

```bash
git status --short
git log --oneline -6
```

Expected: clean worktree with all implementation commits present.
