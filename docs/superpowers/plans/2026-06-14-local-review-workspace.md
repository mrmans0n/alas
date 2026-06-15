# Local Review Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent local draft review comments on exact diff lines/ranges, render and manage them in the shared review surface, and bundle them for Copy Prompt / Send Feedback To Agent.

**Architecture:** Introduce a provider-independent local review model and JSON store, then extend the existing `DiffReviewSurface` with local-comment display/action hooks. Keep provider feedback read-only and separate. Add entry-point session IDs for existing diff review sources so local comments persist per repo and review target.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit `NSTextView` diff renderer, Swift Testing, existing `PersistenceStore`, existing `DiffReviewSurface`, existing ACP session infrastructure.

---

## File Structure

- Create `Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift`
  - `ReviewDraftSessionID`, `ReviewDraftComment`, local state enums, and source identity helpers.
- Create `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift`
  - JSON-backed persistence using `PersistenceStoreProtocol`.
- Create `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackBundle.swift`
  - ai-review-style prompt formatter and grouping logic.
- Create `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentActions.swift`
  - action closures and context shared by summary rail and inline cards.
- Create `Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift`
  - right-side local review rail.
- Modify `Alas/Sources/Persistence/Paths.swift`
  - add `reviewDraftCommentsFile`.
- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift`
  - expose stable source-line metadata needed for exact local comment placement.
- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
  - expose row hit/selection callbacks and local accessory row metadata.
- Modify `Alas/Sources/Center/Diff/DiffPaneView.swift`
  - pass local review interaction hooks into the AppKit body.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
  - add local review state inputs where they belong beside `DiffReviewLoadedSession` and file section models.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - render local draft comments exactly at row/range anchors and show inline composer.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
  - add right review rail, draft-comment bindings, scroll/focus support, and placeholder height accounting.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
  - create/load draft session for local changes and pass local comments/actions into `DiffReviewSurface`.
- Modify `Alas/Sources/Center/Commit/CommitTabView.swift`
  - create/load draft session for commit review body.
- Modify `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
  - create/load draft session for PR/MR Files while leaving provider feedback read-only.
- Modify `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift`
  - create/load draft session for create-PR branch diff review.
- Modify `Alas.xcodeproj/project.pbxproj`
  - regenerate or include new files so clean checkouts build.

Tests:

- Create `AlasTests/ReviewDraftModelsTests.swift`
- Create `AlasTests/ReviewDraftCommentStoreTests.swift`
- Create `AlasTests/ReviewFeedbackBundleTests.swift`
- Extend `AlasTests/DiffReviewSurfaceTests.swift`
- Extend `AlasTests/DiffPaneViewTests.swift`
- Extend `AlasTests/ReviewChangesTabViewTests.swift`
- Extend `AlasTests/CommitTabViewTests.swift`
- Extend `AlasTests/Integrations/ReviewEvidenceModelTests.swift`
- Extend `AlasTests/Integrations/ReviewRequestDraftTests.swift`

---

### Task 1: Draft Review Models And Persistence

**Files:**
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift`
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift`
- Modify: `Alas/Sources/Persistence/Paths.swift`
- Test: `AlasTests/ReviewDraftModelsTests.swift`
- Test: `AlasTests/ReviewDraftCommentStoreTests.swift`

- [ ] **Step 1: Write model tests for stable session IDs**

Add `AlasTests/ReviewDraftModelsTests.swift`:

```swift
import Foundation
import Testing

@Suite("Review draft models")
struct ReviewDraftModelsTests {
    @Test func localChangesSessionIDIsStableForSameWorktree() {
        let first = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let second = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )

        #expect(first == second)
        #expect(first.rawValue.contains("local-changes"))
        #expect(first.rawValue.contains("wt-1"))
    }

    @Test func commitAndProviderSessionsDoNotCollide() {
        let commit = ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123"
        )
        let pr = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 520
        )

        #expect(commit != pr)
        #expect(commit.sourceKind == .commit)
        #expect(pr.sourceKind == .reviewRequest)
    }

    @Test func draftCommentRangeNormalizesLineOrder() {
        let comment = ReviewDraftComment(
            id: "c1",
            sessionID: .localChanges(
                worktreeID: "wt",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 8,
            endLine: 3,
            selectedText: "let value = 1",
            bodyMarkdown: "Please extract this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(comment.normalizedLineRange == 3...8)
        #expect(comment.isActive)
    }
}
```

- [ ] **Step 2: Write persistence tests**

Add `AlasTests/ReviewDraftCommentStoreTests.swift`:

```swift
import Foundation
import Testing

@Suite("Review draft comment store")
struct ReviewDraftCommentStoreTests {
    @Test func savesLoadsAndDeletesCommentsBySession() throws {
        let directory = try #require(FileManager.default.urls(for: .itemReplacementDirectory, in: .userDomainMask).first)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let comment = ReviewDraftComment(
            id: "comment-1",
            sessionID: session,
            fileID: DiffReviewFileID(namespace: "unstaged", path: "A.swift"),
            path: "A.swift",
            originalPath: nil,
            side: .new,
            startLine: 4,
            endLine: nil,
            selectedText: "let a = 1",
            bodyMarkdown: "**Fix** this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )

        try store.save(comment)
        #expect(try store.load(sessionID: session) == [comment])

        var edited = comment
        edited.bodyMarkdown = "Updated"
        edited.state = .resolved
        edited.updatedAt = Date(timeIntervalSince1970: 12)
        try store.save(edited)
        #expect(try store.load(sessionID: session).single?.bodyMarkdown == "Updated")
        #expect(try store.load(sessionID: session).single?.state == .resolved)

        try store.delete(commentID: "comment-1", sessionID: session)
        #expect(try store.load(sessionID: session).isEmpty)
    }

    @Test func brokenStoreFileReturnsEmptySessions() throws {
        let directory = try #require(FileManager.default.urls(for: .itemReplacementDirectory, in: .userDomainMask).first)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        try Data("not json".utf8).write(to: url)
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )

        #expect(try store.load(sessionID: session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
```

- [ ] **Step 3: Run tests red**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewDraftModelsTests -only-testing:AlasTests/ReviewDraftCommentStoreTests test
```

Expected: fails to compile because `ReviewDraftSessionID`, `ReviewDraftComment`, and `ReviewDraftCommentStore` do not exist.

- [ ] **Step 4: Implement models and store**

Create `Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift`:

```swift
import Foundation

enum ReviewDraftSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case commit
    case draftCommit = "draft-commit"
    case branch
    case reviewRequest = "review-request"
    case draftReviewRequest = "draft-review-request"
}

enum ReviewDraftLocalChangesScope: String, Codable, Equatable, Hashable, Sendable {
    case all
    case unstaged
    case staged
}

struct ReviewDraftSessionID: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    let rawValue: String
    let sourceKind: ReviewDraftSourceKind

    init(rawValue: String, sourceKind: ReviewDraftSourceKind) {
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first,
              let sourceKind = ReviewDraftSourceKind(rawValue: first)
        else { return nil }
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    static func localChanges(worktreeID: String, worktreePath: URL, scope: ReviewDraftLocalChangesScope) -> Self {
        make(.localChanges, [worktreeID, worktreePath.standardizedFileURL.path, scope.rawValue])
    }

    static func commit(worktreeID: String, repositoryPath: URL, sha: String) -> Self {
        make(.commit, [worktreeID, repositoryPath.standardizedFileURL.path, sha])
    }

    static func draftCommit(worktreeID: String, repositoryPath: URL) -> Self {
        make(.draftCommit, [worktreeID, repositoryPath.standardizedFileURL.path])
    }

    static func branch(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.branch, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    static func reviewRequest(worktreeID: String, provider: CodeHostKind, host: String, repositorySlug: String, number: Int) -> Self {
        make(.reviewRequest, [worktreeID, provider.rawValue, host.lowercased(), repositorySlug, "\(number)"])
    }

    static func draftReviewRequest(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.draftReviewRequest, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    private static func make(_ kind: ReviewDraftSourceKind, _ fields: [String]) -> Self {
        let escapedFields = ([kind.rawValue] + fields).map(escape)
        return ReviewDraftSessionID(rawValue: escapedFields.joined(separator: "\u{1f}"), sourceKind: kind)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\u{1f}", with: "\\u001f")
    }
}

enum ReviewDraftCommentState: String, Codable, Equatable, Hashable, Sendable {
    case active
    case resolved
    case dismissed
}

struct ReviewDraftComment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sessionID: ReviewDraftSessionID
    var fileID: DiffReviewFileID
    var path: String
    var originalPath: String?
    var side: DiffReviewInlineFeedbackSide
    var startLine: Int
    var endLine: Int?
    var selectedText: String?
    var bodyMarkdown: String
    var state: ReviewDraftCommentState
    var createdAt: Date
    var updatedAt: Date

    var normalizedLineRange: ClosedRange<Int> {
        let end = endLine ?? startLine
        return min(startLine, end)...max(startLine, end)
    }

    var isActive: Bool { state == .active }
}
```

Create `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift`:

```swift
import Foundation

struct ReviewDraftCommentStore {
    private var store: any PersistenceStoreProtocol
    private var url: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.reviewDraftCommentsFile) {
        self.store = store
        self.url = url
    }

    func load(sessionID: ReviewDraftSessionID) throws -> [ReviewDraftComment] {
        let snapshot = try readSnapshot()
        return (snapshot.commentsBySessionID[sessionID.rawValue] ?? [])
            .sorted { lhs, rhs in
                if lhs.path != rhs.path { return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending }
                if lhs.normalizedLineRange.lowerBound != rhs.normalizedLineRange.lowerBound {
                    return lhs.normalizedLineRange.lowerBound < rhs.normalizedLineRange.lowerBound
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func save(_ comment: ReviewDraftComment) throws {
        var snapshot = try readSnapshot()
        var comments = snapshot.commentsBySessionID[comment.sessionID.rawValue] ?? []
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index] = comment
        } else {
            comments.append(comment)
        }
        snapshot.commentsBySessionID[comment.sessionID.rawValue] = comments
        try store.write(snapshot, to: url)
    }

    func delete(commentID: String, sessionID: ReviewDraftSessionID) throws {
        var snapshot = try readSnapshot()
        var comments = snapshot.commentsBySessionID[sessionID.rawValue] ?? []
        comments.removeAll { $0.id == commentID }
        if comments.isEmpty {
            snapshot.commentsBySessionID.removeValue(forKey: sessionID.rawValue)
        } else {
            snapshot.commentsBySessionID[sessionID.rawValue] = comments
        }
        try store.write(snapshot, to: url)
    }

    private func readSnapshot() throws -> Snapshot {
        try store.readIfExists(Snapshot.self, from: url) ?? Snapshot(commentsBySessionID: [:])
    }

    private struct Snapshot: Codable, Equatable {
        var commentsBySessionID: [String: [ReviewDraftComment]]
    }
}
```

Modify `Alas/Sources/Persistence/Paths.swift`:

```swift
static var reviewDraftCommentsFile: URL {
    appSupportRoot.appendingPathComponent("review-draft-comments.json")
}
```

- [ ] **Step 5: Run tests green**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewDraftModelsTests -only-testing:AlasTests/ReviewDraftCommentStoreTests test
```

Expected: both suites pass.

- [ ] **Step 6: Regenerate project and commit**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewDraftModelsTests -only-testing:AlasTests/ReviewDraftCommentStoreTests test
git add Alas/Sources/Center/ReviewWorkspace/ReviewDraftModels.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentStore.swift Alas/Sources/Persistence/Paths.swift AlasTests/ReviewDraftModelsTests.swift AlasTests/ReviewDraftCommentStoreTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): add draft comment store"
```

Expected: commit contains only Task 1 files and generated project references for the new sources/tests.

---

### Task 2: Feedback Bundle Formatter And Draft Actions

**Files:**
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackBundle.swift`
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentActions.swift`
- Test: `AlasTests/ReviewFeedbackBundleTests.swift`

- [ ] **Step 1: Write formatter tests**

Add `AlasTests/ReviewFeedbackBundleTests.swift`:

```swift
import Foundation
import Testing

@Suite("Review feedback bundle")
struct ReviewFeedbackBundleTests {
    @Test func promptGroupsActiveCommentsByFileAndLine() {
        let session = ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123"
        )
        let comments = [
            draftComment(id: "b", session: session, path: "Sources/B.swift", line: 9, body: "Rename this."),
            draftComment(id: "a", session: session, path: "Sources/A.swift", line: 2, body: "Extract helper."),
            draftComment(id: "resolved", session: session, path: "Sources/A.swift", line: 1, body: "Ignore", state: .resolved),
        ]
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review commit abc123",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "commit abc123"
            ),
            comments: comments
        )

        let prompt = bundle.promptMarkdown()

        #expect(prompt.contains("Please address each review comment below."))
        #expect(prompt.contains("Review target: Review commit abc123"))
        #expect(prompt.contains("Repository: /repo"))
        #expect(prompt.contains("Source: commit abc123"))
        #expect(prompt.contains("## Sources/A.swift"))
        #expect(prompt.contains("- `Sources/A.swift:2 (new)` — Extract helper."))
        #expect(prompt.contains("## Sources/B.swift"))
        #expect(prompt.contains("- `Sources/B.swift:9 (new)` — Rename this."))
        #expect(!prompt.contains("Ignore"))
    }

    @Test func promptIncludesLineRangesAndSelectedText() {
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let comment = ReviewDraftComment(
            id: "range",
            sessionID: session,
            fileID: DiffReviewFileID(namespace: "unstaged", path: "A.swift"),
            path: "A.swift",
            originalPath: nil,
            side: .old,
            startLine: 4,
            endLine: 6,
            selectedText: "old code",
            bodyMarkdown: "This behavior regressed.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(title: "Review changes", repositoryPath: nil, providerDescription: nil, sourceDescription: "local changes"),
            comments: [comment]
        )

        let prompt = bundle.promptMarkdown()

        #expect(prompt.contains("`A.swift:4-6 (old)`"))
        #expect(prompt.contains("> old code"))
        #expect(prompt.contains("This behavior regressed."))
    }

    private func draftComment(
        id: String,
        session: ReviewDraftSessionID,
        path: String,
        line: Int,
        body: String,
        state: ReviewDraftCommentState = .active
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: session,
            fileID: DiffReviewFileID(namespace: "review", path: path),
            path: path,
            originalPath: nil,
            side: .new,
            startLine: line,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: body,
            state: state,
            createdAt: Date(timeIntervalSince1970: Double(line)),
            updatedAt: Date(timeIntervalSince1970: Double(line))
        )
    }
}
```

- [ ] **Step 2: Run tests red**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewFeedbackBundleTests test
```

Expected: fails to compile because `ReviewFeedbackBundle` does not exist.

- [ ] **Step 3: Implement formatter and actions**

Create `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackBundle.swift`:

```swift
import Foundation

struct ReviewFeedbackTarget: Equatable, Sendable {
    let title: String
    let repositoryPath: String?
    let providerDescription: String?
    let sourceDescription: String
}

struct ReviewFeedbackBundle: Equatable, Sendable {
    let target: ReviewFeedbackTarget
    let comments: [ReviewDraftComment]

    var activeComments: [ReviewDraftComment] {
        comments.filter(\.isActive)
    }

    func promptMarkdown() -> String {
        var lines: [String] = [
            "Please address each review comment below.",
            "",
            "Inspect the referenced files and make the smallest safe changes. Explain what changed. Do not publish remote review comments unless explicitly asked.",
            "",
            "Review target: \(target.title)",
            "Source: \(target.sourceDescription)",
        ]
        if let repositoryPath = target.repositoryPath {
            lines.append("Repository: \(repositoryPath)")
        }
        if let providerDescription = target.providerDescription {
            lines.append("Provider: \(providerDescription)")
        }

        let grouped = Dictionary(grouping: activeComments, by: \.path)
        for path in grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            lines.append("")
            lines.append("## \(path)")
            let fileComments = (grouped[path] ?? []).sorted(by: sortComments)
            for comment in fileComments {
                lines.append("- `\(anchorLabel(comment))` — \(singleLine(comment.bodyMarkdown))")
                if let selectedText = comment.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selectedText.isEmpty {
                    for line in selectedText.components(separatedBy: .newlines) {
                        lines.append("> \(line)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func sortComments(_ lhs: ReviewDraftComment, _ rhs: ReviewDraftComment) -> Bool {
        if lhs.normalizedLineRange.lowerBound != rhs.normalizedLineRange.lowerBound {
            return lhs.normalizedLineRange.lowerBound < rhs.normalizedLineRange.lowerBound
        }
        return lhs.createdAt < rhs.createdAt
    }

    private func anchorLabel(_ comment: ReviewDraftComment) -> String {
        let range = comment.normalizedLineRange
        let line = range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound)-\(range.upperBound)"
        return "\(comment.path):\(line) (\(comment.side.rawValue))"
    }

    private func singleLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

Create `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentActions.swift`:

```swift
import Foundation

struct ReviewDraftCommentActionAvailability: Equatable {
    var canEdit: Bool
    var canDelete: Bool
    var canResolve: Bool
    var canCopyPrompt: Bool
    var canSendToAgent: Bool

    static let none = ReviewDraftCommentActionAvailability(
        canEdit: false,
        canDelete: false,
        canResolve: false,
        canCopyPrompt: false,
        canSendToAgent: false
    )
}

struct ReviewDraftCommentActions {
    var availability: (ReviewDraftComment) -> ReviewDraftCommentActionAvailability = { _ in .none }
    var edit: (ReviewDraftComment) -> Void = { _ in }
    var delete: (ReviewDraftComment) -> Void = { _ in }
    var resolve: (ReviewDraftComment) -> Void = { _ in }
    var copyPrompt: (ReviewDraftComment) -> Void = { _ in }
    var sendToAgent: (ReviewDraftComment) -> Void = { _ in }
}
```

- [ ] **Step 4: Run tests green and commit**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewFeedbackBundleTests test
git add Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackBundle.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentActions.swift AlasTests/ReviewFeedbackBundleTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(review): format draft feedback bundles"
```

Expected: focused formatter tests pass.

---

### Task 3: Exact Diff Row Anchors For Local Draft Comments

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift`
- Test: `AlasTests/DiffPaneViewTests.swift`

- [ ] **Step 1: Add row-anchor and hit-test regression tests**

Extend `AlasTests/DiffPaneViewTests.swift` with tests named:

```swift
@Test @MainActor func splitTextDocumentExposesSourceLineMetadataForBothSides() throws
@Test @MainActor func stackedTextDocumentExposesSourceLineMetadataForAddedAndDeletedLines() throws
@Test @MainActor func rowHitTestingReturnsLocalReviewAnchorForCodePoint() throws
```

Use the existing hosted `DiffPaneView` helpers in the file. The expected behavior:

```swift
#expect(oldCodeView.reviewLineAnchor(atRow: 0)?.side == .old)
#expect(newCodeView.reviewLineAnchor(atRow: 0)?.side == .new)
#expect(newCodeView.reviewLineAnchor(atRow: 0)?.line == 2)
#expect(stackedCodeView.reviewLineAnchor(atRow: 1)?.side == .new)
```

For the hit-test test, obtain a point inside a known row rect and expect:

```swift
let anchor = try #require(codeView.reviewLineAnchor(at: point))
#expect(anchor.path == "Sources/App.swift")
#expect(anchor.line == 2)
#expect(anchor.side == .new)
```

- [ ] **Step 2: Run tests red**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: fails because the review-anchor accessors do not exist.

- [ ] **Step 3: Implement row anchor exposure**

Add a provider-independent local anchor type in `DiffPaneTextDocumentView.swift` or a small sibling file if the type is reused by SwiftUI:

```swift
struct DiffReviewLineAnchor: Equatable, Hashable {
    let path: String
    let side: DiffReviewInlineFeedbackSide
    let line: Int
    let rowIndex: Int
    let selectedText: String
}
```

In `DiffPaneTextDocumentBuilder.LineMetadata`, keep using `sourceLine`. Add helpers that convert metadata into `DiffReviewLineAnchor`:

```swift
extension DiffPaneTextDocumentBuilder.LineMetadata {
    func reviewAnchor(rowIndex: Int) -> DiffReviewLineAnchor? {
        guard let sourceLine, let line = sourceLine.lineNumber else { return nil }
        let side: DiffReviewInlineFeedbackSide
        switch sourceLine.anchor.side {
        case .old: side = .old
        case .new: side = .new
        case .paired: side = .unknown
        }
        return DiffReviewLineAnchor(
            path: sourceLine.anchor.filePath,
            side: side,
            line: line,
            rowIndex: rowIndex,
            selectedText: sourceLine.text
        )
    }
}
```

Expose testing/internal methods on `DiffPaneCodeTextView`:

```swift
func reviewLineAnchor(atRow row: Int) -> DiffReviewLineAnchor? {
    guard row >= 0, row < lineMetadata.count else { return nil }
    return lineMetadata[row].reviewAnchor(rowIndex: row)
}

func reviewLineAnchor(at point: NSPoint) -> DiffReviewLineAnchor? {
    let rows = diffRowRects()
    guard let index = rows.firstIndex(where: { $0.contains(point) }) else { return nil }
    return reviewLineAnchor(atRow: index)
}
```

Keep these `internal` so tests can use them without public API.

- [ ] **Step 4: Add SwiftUI/AppKit selection callback plumbing**

Add optional callbacks to `DiffPaneTextDocumentView` and `DiffPaneView`:

```swift
var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
```

Wire the callback from `DiffPaneTextScrollView` when the user clicks the gutter or a modified-click-supported code row. Do not steal native text selection drags from the code text view. The click target for local review selection is the gutter/line-number area first.

- [ ] **Step 5: Run tests green and commit**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests test
git add Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/DiffPaneViewTests.swift
git commit -m "feat(diff): expose review line anchors"
```

Expected: `DiffPaneViewTests` pass and existing text selection behavior remains unchanged.

---

### Task 4: Local Draft Comment Placement And Inline Cards

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Add display model and placement tests**

Extend `AlasTests/DiffReviewSurfaceTests.swift`:

```swift
@Test func localDraftCommentsPositionAtExactMatchingRows() {
    let group = makeDisplayGroupWithChangedLines()
    let session = ReviewDraftSessionID.localChanges(
        worktreeID: "wt",
        worktreePath: URL(fileURLWithPath: "/repo"),
        scope: .all
    )
    let comment = ReviewDraftComment(
        id: "draft-1",
        sessionID: session,
        fileID: DiffReviewFileID(namespace: "unstaged", path: "A.swift"),
        path: "A.swift",
        originalPath: nil,
        side: .new,
        startLine: 2,
        endLine: nil,
        selectedText: "let newValue = 1",
        bodyMarkdown: "Please rename.",
        state: .active,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    let placement = ReviewDraftCommentPlacement.position([comment], in: [group])

    #expect(placement.fileLevel.isEmpty)
    #expect(placement.byRowAnchor.values.flatMap { $0 }.map(\.id) == ["draft-1"])
}

@Test func unmatchedLocalDraftCommentsFallBackToFileLevel() {
    let group = makeDisplayGroupWithChangedLines()
    let comment = makeDraftComment(path: "A.swift", side: .new, line: 99)
    let placement = ReviewDraftCommentPlacement.position([comment], in: [group])

    #expect(placement.fileLevel.map(\.id) == [comment.id])
    #expect(placement.byRowAnchor.isEmpty)
}
```

Use existing helper patterns from `DiffReviewSurfaceTests` to create `DiffDisplayGroup`.

- [ ] **Step 2: Run tests red**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: fails because `ReviewDraftCommentPlacement` and local draft comment inputs do not exist.

- [ ] **Step 3: Implement local comment display and placement**

Add local comment inputs to `DiffReviewSurface`:

```swift
var draftCommentsByFileID: [DiffReviewFileID: [ReviewDraftComment]] = [:]
var focusedDraftCommentID: String? = nil
var draftCommentActions = ReviewDraftCommentActions()
var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }
var onAddDraftComment: (DiffReviewLineAnchor) -> Void = { _ in }
```

Add matching inputs to `DiffReviewFileSection`.

Implement `ReviewDraftCommentPlacement` in `DiffReviewFileSection.swift`:

```swift
enum ReviewDraftCommentPlacement {
    struct RowKey: Hashable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
    }

    struct Result: Equatable {
        let fileLevel: [ReviewDraftComment]
        let byRowAnchor: [RowKey: [ReviewDraftComment]]
    }

    static func position(_ comments: [ReviewDraftComment], in groups: [DiffDisplayGroup]) -> Result {
        var visibleKeys = Set<RowKey>()
        for group in groups {
            for row in group.rows {
                if let old = row.old, let line = old.lineNumber {
                    visibleKeys.insert(RowKey(side: .old, line: line))
                }
                if let new = row.new, let line = new.lineNumber {
                    visibleKeys.insert(RowKey(side: .new, line: line))
                }
            }
        }

        var fileLevel: [ReviewDraftComment] = []
        var byRowAnchor: [RowKey: [ReviewDraftComment]] = [:]
        for comment in comments where comment.state != .dismissed {
            let key = RowKey(side: comment.side, line: comment.normalizedLineRange.upperBound)
            if visibleKeys.contains(key) {
                byRowAnchor[key, default: []].append(comment)
            } else {
                fileLevel.append(comment)
            }
        }
        return Result(fileLevel: fileLevel, byRowAnchor: byRowAnchor)
    }
}
```

Render draft comment cards with a distinct local treatment and buttons for edit/delete/resolve/copy/send. Keep provider cards unchanged.

- [ ] **Step 4: Render composer trigger from line selection**

When `DiffPaneView` emits `onReviewLineSelected`, set a local composer state in `DiffReviewFileSection`:

```swift
@State private var pendingDraftAnchor: DiffReviewLineAnchor?
```

Render a compact inline composer at the matching row insertion point:

- markdown text editor
- Save
- Cancel

Saving calls `onAddDraftComment(anchor)` through a closure that also receives the body text. Use this signature:

```swift
var onSaveDraftComment: (DiffReviewLineAnchor, String) -> Void = { _, _ in }
```

- [ ] **Step 5: Update height estimator**

Update `DiffReviewFileSectionHeightEstimator` so placeholders include local draft comment height:

```swift
static func estimatedHeight(
    for file: DiffReviewFileSectionModel,
    inlineFeedback: [DiffReviewInlineFeedback],
    draftComments: [ReviewDraftComment]
) -> CGFloat
```

Use this from `DiffReviewSurface.fileSection`.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
git add Alas/Sources/Center/DiffReview/DiffReviewModels.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift Alas/Sources/Center/DiffReview/DiffReviewSurface.swift AlasTests/DiffReviewSurfaceTests.swift
git commit -m "feat(review): render local draft comments"
```

Expected: surface tests pass and provider feedback tests remain green.

---

### Task 5: Review Summary Rail And Draft Comment State Controller

**Files:**
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift`
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentController.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`
- Test: `AlasTests/ReviewDraftCommentStoreTests.swift`

- [ ] **Step 1: Add controller tests**

Extend `AlasTests/ReviewDraftCommentStoreTests.swift`:

```swift
@Test @MainActor func controllerAddsEditsDeletesAndResolvesComments() throws {
    let directory = try #require(FileManager.default.urls(for: .itemReplacementDirectory, in: .userDomainMask).first)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ReviewDraftCommentStore(store: PersistenceStore(), url: directory.appendingPathComponent("comments.json"))
    let session = ReviewDraftSessionID.localChanges(
        worktreeID: "wt",
        worktreePath: URL(fileURLWithPath: "/repo"),
        scope: .all
    )
    let controller = ReviewDraftCommentController(sessionID: session, store: store, now: { Date(timeIntervalSince1970: 100) })

    try controller.load()
    let anchor = DiffReviewLineAnchor(path: "A.swift", side: .new, line: 4, rowIndex: 0, selectedText: "let a = 1")
    try controller.add(anchor: anchor, fileID: DiffReviewFileID(namespace: "unstaged", path: "A.swift"), bodyMarkdown: "Fix naming.")
    let added = try #require(controller.comments.single)
    #expect(added.bodyMarkdown == "Fix naming.")

    try controller.edit(commentID: added.id, bodyMarkdown: "Fix naming and tests.")
    #expect(controller.comments.single?.bodyMarkdown == "Fix naming and tests.")

    try controller.resolve(commentID: added.id)
    #expect(controller.comments.single?.state == .resolved)

    try controller.delete(commentID: added.id)
    #expect(controller.comments.isEmpty)
}
```

- [ ] **Step 2: Add summary rail hosted test**

Extend `AlasTests/DiffReviewSurfaceTests.swift`:

```swift
@Test @MainActor func reviewSurfaceShowsLocalDraftSummaryRailAndScrollsToComment() throws {
    let comment = makeDraftComment(path: "A.swift", side: .new, line: 2)
    var selectedCommentID: String?
    let view = DiffReviewSurface(
        session: loadedSessionWithOneFile(),
        selectedFileID: .constant(nil),
        railCollapsed: .constant(false),
        layoutMode: .constant(.split),
        wrapLines: .constant(false),
        showWhitespace: .constant(false),
        codeFontFamily: "SF Mono",
        codeFontSize: 12,
        draftCommentsByFileID: [comment.fileID: [comment]],
        onSelectDraftComment: { selectedCommentID = $0.id }
    )

    let host = try ViewHosting.host(view)
    let button = try #require(host.findButton(accessibilityIdentifier: "review-draft-summary-comment-\(comment.id)"))
    button.performClick(nil)

    #expect(selectedCommentID == comment.id)
}
```

- [ ] **Step 3: Implement controller**

Create `ReviewDraftCommentController` as an `@MainActor @Observable` reference type:

```swift
@MainActor
@Observable
final class ReviewDraftCommentController {
    private let sessionID: ReviewDraftSessionID
    private let store: ReviewDraftCommentStore
    private let now: () -> Date
    private(set) var comments: [ReviewDraftComment] = []
    var errorMessage: String?

    init(
        sessionID: ReviewDraftSessionID,
        store: ReviewDraftCommentStore = ReviewDraftCommentStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionID = sessionID
        self.store = store
        self.now = now
    }

    func load() throws {
        comments = try store.load(sessionID: sessionID)
        errorMessage = nil
    }

    func add(anchor: DiffReviewLineAnchor, fileID: DiffReviewFileID, bodyMarkdown: String) throws {
        let date = now()
        let comment = ReviewDraftComment(
            id: UUID().uuidString,
            sessionID: sessionID,
            fileID: fileID,
            path: anchor.path,
            originalPath: nil,
            side: anchor.side,
            startLine: anchor.line,
            endLine: nil,
            selectedText: anchor.selectedText,
            bodyMarkdown: bodyMarkdown,
            state: .active,
            createdAt: date,
            updatedAt: date
        )
        var updated = comments
        updated.append(comment)
        try persist(updated)
    }

    func edit(commentID: String, bodyMarkdown: String) throws {
        var updated = comments
        guard let index = updated.firstIndex(where: { $0.id == commentID }) else { return }
        updated[index].bodyMarkdown = bodyMarkdown
        updated[index].updatedAt = now()
        try persist(updated)
    }

    func resolve(commentID: String) throws {
        var updated = comments
        guard let index = updated.firstIndex(where: { $0.id == commentID }) else { return }
        updated[index].state = .resolved
        updated[index].updatedAt = now()
        try persist(updated)
    }

    func delete(commentID: String) throws {
        var updated = comments
        updated.removeAll { $0.id == commentID }
        try store.delete(commentID: commentID, sessionID: sessionID)
        comments = updated
        errorMessage = nil
    }

    private func persist(_ updated: [ReviewDraftComment]) throws {
        let previous = comments
        do {
            for comment in updated {
                try store.save(comment)
            }
            comments = updated
            errorMessage = nil
        } catch {
            comments = previous
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
```

Every mutating method persists through `ReviewDraftCommentStore`. On error, leave the in-memory mutation applied only when persistence succeeded; otherwise keep the previous `comments` array and set `errorMessage`.

- [ ] **Step 4: Implement right summary rail**

Create `ReviewDraftSummaryRail`:

- width 260 expanded
- width 44 collapsed
- active count pill
- grouped-by-file comment list
- Edit/Delete/Resolve buttons
- Copy Prompt and Send Feedback To Agent buttons in the rail header/footer

Use accessibility identifiers:

- `review-draft-summary-rail`
- `review-draft-summary-comment-<commentID>`
- `review-draft-summary-copy-prompt`
- `review-draft-summary-send-agent`

- [ ] **Step 5: Wire rail into `DiffReviewSurface`**

Add inputs:

```swift
@Binding var reviewSummaryCollapsed: Bool
var draftCommentsByFileID: [DiffReviewFileID: [ReviewDraftComment]] = [:]
var focusedDraftCommentID: String? = nil
var draftCommentActions = ReviewDraftCommentActions()
var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }
```

Render `ReviewDraftSummaryRail` to the right of `mainReviewStream` when there is a draft session. Keep the existing left file rail unchanged.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/ReviewDraftCommentStoreTests test
git add Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftCommentController.swift Alas/Sources/Center/DiffReview/DiffReviewSurface.swift AlasTests/DiffReviewSurfaceTests.swift AlasTests/ReviewDraftCommentStoreTests.swift
git commit -m "feat(review): add draft comment summary rail"
```

Expected: focused suites pass.

---

### Task 6: Entry Point Integration And Agent Handoff

**Files:**
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
- Modify: `Alas/Sources/Center/Commit/CommitTabView.swift`
- Modify: `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Test: `AlasTests/ReviewChangesTabViewTests.swift`
- Test: `AlasTests/CommitTabViewTests.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceModelTests.swift`
- Test: `AlasTests/Integrations/ReviewRequestDraftTests.swift`

- [ ] **Step 1: Add session-id helper tests at entry points**

Add tests:

```swift
@Test func reviewChangesDraftSessionIDUsesWorktreeAndLocalChangesScope()
@Test func commitReviewDraftSessionIDUsesCommitSHA()
@Test func reviewEvidenceDraftSessionIDUsesProviderRepositoryAndNumber()
@Test func draftReviewRequestDraftSessionIDUsesBaseAndHeadBranches()
```

Each test calls a static helper on the relevant view/model:

```swift
ReviewChangesTabView.reviewDraftSessionID(worktree: worktree)
CommitReviewBody.reviewDraftSessionID(worktreeID: "wt", repositoryPath: URL(fileURLWithPath: "/repo"), sha: "abc")
ReviewEvidenceTabView.reviewDraftSessionID(worktreeID: "wt", provider: .github, host: "github.com", repositorySlug: "mrmans0n/alas", number: 520)
DraftReviewRequestTabView.reviewDraftSessionID(worktreeID: "wt", repositoryPath: URL(fileURLWithPath: "/repo"), base: "main", head: "feature")
```

- [ ] **Step 2: Add action wiring tests**

Add focused tests that inject fake `ReviewDraftCommentController` or action closures and verify:

- selecting a draft comment in the summary focuses and scrolls to its inline card
- Copy Prompt receives `ReviewFeedbackBundle.promptMarkdown()`
- Send Feedback To Agent receives the same prompt text

Use existing hosted-view and helper patterns from the files listed above. Do not start a real ACP process in tests.

- [ ] **Step 3: Run tests red**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesTabViewTests -only-testing:AlasTests/CommitTabViewTests -only-testing:AlasTests/ReviewEvidenceModelTests -only-testing:AlasTests/ReviewRequestDraftTests test
```

Expected: fails because entry-point helpers and action wiring are missing.

- [ ] **Step 4: Wire draft comment controllers**

In each entry point:

- create a `ReviewDraftSessionID`
- create a `ReviewDraftCommentController`
- call `load()` when the diff review session loads or appears
- pass `draftCommentsByFileID`, focused state, summary collapsed binding, and action closures into `DiffReviewSurface`

Use one helper to group comments by `DiffReviewFileID`:

```swift
enum ReviewDraftCommentGrouping {
    static func commentsByFileID(_ comments: [ReviewDraftComment]) -> [DiffReviewFileID: [ReviewDraftComment]] {
        Dictionary(grouping: comments, by: \.fileID)
    }
}
```

- [ ] **Step 5: Implement Copy Prompt**

Build `ReviewFeedbackBundle` from active controller comments and write to `NSPasteboard.general` through a small injectable closure in production views:

```swift
private func copyReviewPrompt(_ prompt: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
}
```

Tests call the pure bundle helper and an injected pasteboard closure, not the global pasteboard.

- [ ] **Step 6: Implement Send Feedback To Agent target path**

For this phase, route through a deterministic ACP target model:

```swift
enum ReviewFeedbackAgentTarget: Equatable, Identifiable {
    case newChat(agentID: String, title: String)
    case existingSession(worktreeID: String, sessionID: String, title: String)

    var id: String {
        switch self {
        case .newChat(let agentID, _):
            return "new:\(agentID)"
        case .existingSession(let worktreeID, let sessionID, _):
            return "existing:\(worktreeID):\(sessionID)"
        }
    }

    var title: String {
        switch self {
        case .newChat(_, let title), .existingSession(_, _, let title):
            return title
        }
    }
}

@MainActor
struct ReviewFeedbackAgentSender {
    var availableTargets: () -> [ReviewFeedbackAgentTarget]
    var send: (String, ReviewFeedbackAgentTarget) -> Void
}
```

Production target discovery:

- Include `.newChat(agentID: appState.config.changes.aiToolId, title: "New chat")` when `aiToolId != "none"` and the agent exists.
- Include `.existingSession(worktreeID:sessionID:title:)` for live ACP sessions in the current worktree when `ACPSessionManager.isWriter(for:)` is true.
- Hide Send Feedback To Agent when the target list is empty.

Production sending:

- `.newChat` calls `appState.openNewACPSession(agentID:initialPrompt:)`.
- `.existingSession` calls `ACPSessionManager.sendPrompt(for:text:attachments:onResult:)` with empty attachments.
- Sending never mutates provider feedback or provider review state.

- [ ] **Step 7: Run focused tests and commit**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesTabViewTests -only-testing:AlasTests/CommitTabViewTests -only-testing:AlasTests/ReviewEvidenceModelTests -only-testing:AlasTests/ReviewRequestDraftTests test
git add Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift Alas/Sources/Center/Commit/CommitTabView.swift Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift Alas/Sources/Center/DiffReview/DiffReviewSurface.swift AlasTests/ReviewChangesTabViewTests.swift AlasTests/CommitTabViewTests.swift AlasTests/Integrations/ReviewEvidenceModelTests.swift AlasTests/Integrations/ReviewRequestDraftTests.swift
git commit -m "feat(review): wire draft feedback workspace"
```

Expected: entry-point tests pass and no provider feedback behavior regresses.

---

### Task 7: Final Integration Verification

**Files:**
- No planned production files.
- Modify tests only if final review finds a missing regression.

- [ ] **Step 1: Run focused review suites**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewDraftModelsTests -only-testing:AlasTests/ReviewDraftCommentStoreTests -only-testing:AlasTests/ReviewFeedbackBundleTests -only-testing:AlasTests/DiffPaneViewTests -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/ReviewChangesTabViewTests -only-testing:AlasTests/CommitTabViewTests -only-testing:AlasTests/ReviewEvidenceModelTests -only-testing:AlasTests/ReviewRequestDraftTests test
```

Expected: all focused suites pass.

- [ ] **Step 2: Run project generation**

Run:

```bash
xcodegen
git status --short
```

Expected: no project diff. If project files changed because a prior task added source/test files without committing the generated reference, stage and commit the generated project file before final review.

- [ ] **Step 3: Run quiet build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: full suite exits 0. If an unrelated known flaky test fails, rerun that exact failing suite once and record the result before deciding whether to fix or report it.

- [ ] **Step 5: Final review**

Dispatch a final code-review subagent over the whole branch. It must check:

- local draft comments never mutate provider state
- provider feedback actions still work
- exact local placement is stable in split and stacked modes
- draft comment persistence cannot leak across worktrees or review targets
- Send Feedback To Agent / Copy Prompt use the same formatter

Expected: reviewer approves or all findings are fixed before completion.
