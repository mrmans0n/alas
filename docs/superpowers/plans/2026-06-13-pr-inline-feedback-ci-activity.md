# PR Inline Feedback And CI Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show provider review feedback inline in PR/MR file diffs and show CI activity rows while checks are pending or running.

**Architecture:** Keep provider-specific parsing in `Integrations/CodeHost`, map provider feedback into generic `DiffReviewInlineFeedback` values, and render those cards inside the shared `DiffReviewSurface`. CI activity uses the already-loaded `ReviewRequest.checks` as the base list, then overlays failed-check details where those logs already exist.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit-hosted diff panes, Swift Testing, existing `CodeHostProvider`, `ReviewEvidenceModel`, and `DiffReviewSurface`.

---

## File Structure

- Modify `Alas/Sources/Integrations/CodeHost/CodeHostModels.swift`
  - Add `ReviewThreadLocation` and a `location` field on `ReviewThreadSummary`.
- Modify `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
  - Request review-thread path/line metadata from GraphQL and parse it.
- Modify `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
  - Parse discussion note position metadata where `glab` provides it.
- Modify `Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift`
  - Add CI activity item construction and inline-feedback mapping helpers.
- Modify `Alas/Sources/Integrations/CodeHost/ReviewEvidenceModel.swift`
  - Publish CI activity rows and grouped inline feedback.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
  - Add `DiffReviewInlineFeedback` and anchor models.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
  - Accept inline feedback grouped by file ID and pass it into file sections.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - Render file-level and line-near inline feedback cards.
- Modify `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
  - Pass inline feedback into `DiffReviewSurface` and render CI activity rows in the evidence browser.
- Tests:
  - `AlasTests/Integrations/CodeHostProviderTests.swift`
  - `AlasTests/Integrations/GitHubCLIProviderTests.swift`
  - `AlasTests/Integrations/GitLabCLIProviderTests.swift`
  - `AlasTests/Integrations/ReviewEvidenceModelTests.swift`
  - `AlasTests/DiffReviewSurfaceTests.swift`
  - `AlasTests/Integrations/ReviewEvidenceTabViewTests.swift`

---

### Task 1: Provider Thread Locations

**Files:**
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostModels.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
- Test: `AlasTests/Integrations/CodeHostProviderTests.swift`
- Test: `AlasTests/Integrations/GitHubCLIProviderTests.swift`
- Test: `AlasTests/Integrations/GitLabCLIProviderTests.swift`

- [ ] **Step 1: Add failing model tests for thread location preservation**

Add to `CodeHostProviderTests.defaultEvidenceMethodsUseSummaryData` or a new adjacent test:

```swift
let location = ReviewThreadLocation(
    path: "Sources/App.swift",
    originalPath: nil,
    line: 42,
    side: .new,
    providerPosition: "github-position-1"
)
let thread = ReviewThreadSummary(
    id: "thread-located",
    author: "reviewer",
    body: "Inline feedback.",
    url: URL(string: "https://github.com/thread-located")!,
    isResolved: false,
    isActionable: true,
    location: location
)

#expect(thread.location?.path == "Sources/App.swift")
#expect(thread.location?.line == 42)
#expect(thread.location?.side == .new)
#expect(thread.location?.providerPosition == "github-position-1")
```

Expected failure: `ReviewThreadLocation` and `ReviewThreadSummary.location` do not exist.

- [ ] **Step 2: Add failing GitHub parser test**

In `GitHubCLIProviderTests`, add a test using `GitHubCLIProvider.parseReviewThreads` with GraphQL thread JSON that includes:

```json
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            {
              "id": "PRRT_kwDO",
              "isResolved": false,
              "isOutdated": false,
              "path": "Sources/App.swift",
              "line": 56,
              "originalLine": null,
              "diffSide": "RIGHT",
              "comments": {
                "nodes": [
                  {
                    "id": "PRRC_kwDO",
                    "body": "Please simplify this.",
                    "url": "https://github.com/mrmans0n/alas/pull/1#discussion_r1",
                    "author": { "login": "reviewer" }
                  }
                ]
              }
            }
          ],
          "pageInfo": { "hasNextPage": false, "endCursor": null }
        }
      }
    }
  }
}
```

Assert:

```swift
let threads = try GitHubCLIProvider.parseReviewThreads(json)
#expect(threads.first?.location?.path == "Sources/App.swift")
#expect(threads.first?.location?.line == 56)
#expect(threads.first?.location?.side == .new)
```

Expected failure: GitHub parser ignores location fields.

- [ ] **Step 3: Add failing GitLab parser test**

In `GitLabCLIProviderTests`, add a test for `GitLabCLIProvider.parseDiscussions` using note JSON with a position:

```json
[
  {
    "id": "discussion-1",
    "resolved": false,
    "notes": [
      {
        "id": 100,
        "body": "This needs a guard.",
        "system": false,
        "web_url": "https://gitlab.example.com/group/proj/-/merge_requests/7#note_100",
        "author": { "username": "reviewer" },
        "position": {
          "new_path": "Sources/App.swift",
          "old_path": "Sources/OldApp.swift",
          "new_line": 24,
          "old_line": null
        }
      }
    ]
  }
]
```

Assert:

```swift
let threads = try GitLabCLIProvider.parseDiscussions(json, requestURL: URL(string: "https://gitlab.example.com/group/proj/-/merge_requests/7")!)
#expect(threads.first?.location?.path == "Sources/App.swift")
#expect(threads.first?.location?.originalPath == "Sources/OldApp.swift")
#expect(threads.first?.location?.line == 24)
#expect(threads.first?.location?.side == .new)
```

Expected failure: GitLab note position metadata is not decoded.

- [ ] **Step 4: Implement location models**

In `CodeHostModels.swift`, add:

```swift
enum ReviewThreadSide: String, Codable, Equatable, Sendable {
    case old
    case new
    case unknown
}

struct ReviewThreadLocation: Codable, Equatable, Sendable {
    let path: String
    let originalPath: String?
    let line: Int?
    let side: ReviewThreadSide
    let providerPosition: String?
}
```

Update `ReviewThreadSummary`:

```swift
struct ReviewThreadSummary: Identifiable, Equatable, Sendable {
    let id: String
    let author: String?
    let body: String
    let url: URL?
    let isResolved: Bool
    let isActionable: Bool
    let location: ReviewThreadLocation?

    init(
        id: String,
        author: String?,
        body: String,
        url: URL?,
        isResolved: Bool,
        isActionable: Bool,
        location: ReviewThreadLocation? = nil
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.url = url
        self.isResolved = isResolved
        self.isActionable = isActionable
        self.location = location
    }
}
```

The initializer keeps existing call sites compiling.

- [ ] **Step 5: Implement GitHub location parsing**

Update `GitHubCLIProvider.reviewThreadsQuery` to request the thread-level fields:

```graphql
path
line
originalLine
diffSide
```

Update the private thread node decodable type with:

```swift
let path: String?
let line: Int?
let originalLine: Int?
let diffSide: String?
```

Add a mapper:

```swift
private static func reviewThreadLocation(from thread: ReviewThreadNode) -> ReviewThreadLocation? {
    guard let path = normalizedOptionalString(thread.path) else { return nil }
    let side: ReviewThreadSide
    let line: Int?
    switch thread.diffSide?.uppercased() {
    case "LEFT":
        side = .old
        line = thread.originalLine ?? thread.line
    case "RIGHT":
        side = .new
        line = thread.line ?? thread.originalLine
    default:
        side = .unknown
        line = thread.line ?? thread.originalLine
    }
    return ReviewThreadLocation(
        path: path,
        originalPath: nil,
        line: line,
        side: side,
        providerPosition: thread.id
    )
}
```

Pass `location: reviewThreadLocation(from: thread)` into `ReviewThreadSummary`.

- [ ] **Step 6: Implement GitLab location parsing**

Add `position` to the note decodable type:

```swift
let position: GitLabNotePosition?
```

Add:

```swift
private struct GitLabNotePosition: Decodable {
    let newPath: String?
    let oldPath: String?
    let newLine: Int?
    let oldLine: Int?

    enum CodingKeys: String, CodingKey {
        case newPath = "new_path"
        case oldPath = "old_path"
        case newLine = "new_line"
        case oldLine = "old_line"
    }
}
```

Add a mapper:

```swift
private static func reviewThreadLocation(from note: GitLabNote) -> ReviewThreadLocation? {
    guard let position = note.position else { return nil }
    let newPath = normalizedOptionalString(position.newPath)
    let oldPath = normalizedOptionalString(position.oldPath)
    guard let path = newPath ?? oldPath else { return nil }

    let side: ReviewThreadSide
    let line: Int?
    if let newLine = position.newLine {
        side = .new
        line = newLine
    } else if let oldLine = position.oldLine {
        side = .old
        line = oldLine
    } else {
        side = .unknown
        line = nil
    }

    return ReviewThreadLocation(
        path: path,
        originalPath: oldPath,
        line: line,
        side: side,
        providerPosition: String(note.id)
    )
}
```

Pass the location into `ReviewThreadSummary`.

- [ ] **Step 7: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/CodeHostProviderTests \
  -only-testing:AlasTests/GitHubCLIProviderTests \
  -only-testing:AlasTests/GitLabCLIProviderTests
```

Expected: the new and existing provider tests pass.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/Integrations/CodeHost/CodeHostModels.swift \
        Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift \
        Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift \
        AlasTests/Integrations/CodeHostProviderTests.swift \
        AlasTests/Integrations/GitHubCLIProviderTests.swift \
        AlasTests/Integrations/GitLabCLIProviderTests.swift
git commit -m "feat(review): preserve provider thread locations"
```

---

### Task 2: Inline Feedback Models And Mapping

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewEvidenceModel.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceModelTests.swift`

- [ ] **Step 1: Add failing tests for inline feedback mapping**

In `ReviewEvidenceModelTests`, add:

```swift
@Test func modelBuildsInlineFeedbackForLocatedThreads() async {
    let request = Self.reviewRequest(threads: [
        ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please simplify this.",
            url: URL(string: "https://github.com/thread-1")!,
            isResolved: false,
            isActionable: true,
            location: ReviewThreadLocation(
                path: "Sources/App.swift",
                originalPath: nil,
                line: 2,
                side: .new,
                providerPosition: "pos-1"
            )
        ),
        ReviewThreadSummary(
            id: "thread-no-path",
            author: "reviewer",
            body: "General note.",
            url: URL(string: "https://github.com/thread-2")!,
            isResolved: false,
            isActionable: true,
            location: nil
        ),
    ])
    let model = ReviewEvidenceModel(
        snapshot: Self.snapshot(reviewRequest: request),
        provider: FakeCodeHostProvider(),
        cwd: URL(fileURLWithPath: "/tmp/alas"),
        initialSection: nil
    )

    await model.load()

    let fileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App.swift")
    #expect(model.inlineFeedbackByFileID[fileID]?.map(\.id) == ["thread-1"])
    #expect(model.feedbackItems.map(\.id).contains("thread-no-path"))
}
```

Add:

```swift
@Test func inlineFeedbackMatchesRenamedOldSideToOriginalPath() async {
    let request = Self.reviewRequest(threads: [
        ReviewThreadSummary(
            id: "thread-old",
            author: "reviewer",
            body: "Old side note.",
            url: URL(string: "https://github.com/thread-old")!,
            isResolved: false,
            isActionable: true,
            location: ReviewThreadLocation(
                path: "Sources/NewName.swift",
                originalPath: "Sources/OldName.swift",
                line: 4,
                side: .old,
                providerPosition: "pos-old"
            )
        ),
    ])
    let summary = DiffReviewFileSummary(
        path: "Sources/NewName.swift",
        namespace: "github-pr",
        groupID: nil,
        groupTitle: nil,
        status: .renamed,
        additions: 1,
        deletions: 1,
        isRenderable: true,
        originalPath: "Sources/OldName.swift"
    )
    let inline = ReviewEvidenceInlineFeedbackMapper.feedbackByFileID(
        threads: request.threads,
        files: [summary],
        providerName: request.provider.displayName
    )

    #expect(inline[summary.id]?.first?.anchor.side == .old)
    #expect(inline[summary.id]?.first?.anchor.line == 4)
}
```

Expected failure: `DiffReviewInlineFeedback`, `inlineFeedbackByFileID`, and `ReviewEvidenceInlineFeedbackMapper` do not exist.

- [ ] **Step 2: Add generic inline feedback models**

In `DiffReviewModels.swift`, add:

```swift
enum DiffReviewInlineFeedbackSide: String, Codable, Equatable, Sendable {
    case old
    case new
    case unknown
}

struct DiffReviewInlineFeedbackAnchor: Codable, Equatable, Hashable, Sendable {
    let path: String
    let line: Int?
    let side: DiffReviewInlineFeedbackSide

    var isFileLevel: Bool { line == nil }
}

struct DiffReviewInlineFeedback: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let providerName: String
    let author: String?
    let bodyPreview: String
    let status: ReviewEvidenceStatus
    let providerURL: URL?
    let anchor: DiffReviewInlineFeedbackAnchor
    let evidenceItemID: String
}
```

- [ ] **Step 3: Add mapper**

In `ReviewEvidence.swift`, add:

```swift
enum ReviewEvidenceInlineFeedbackMapper {
    static func feedbackByFileID(
        threads: [ReviewThreadSummary],
        files: [DiffReviewFileSummary],
        providerName: String
    ) -> [DiffReviewFileID: [DiffReviewInlineFeedback]] {
        var output: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
        for thread in threads where !thread.isResolved && thread.isActionable {
            guard let location = thread.location else { continue }
            guard let file = matchingFile(for: location, in: files) else { continue }

            let item = DiffReviewInlineFeedback(
                id: thread.id,
                providerName: providerName,
                author: thread.author,
                bodyPreview: String(thread.body.prefix(240)),
                status: .actionable,
                providerURL: thread.url,
                anchor: DiffReviewInlineFeedbackAnchor(
                    path: file.path,
                    line: location.line,
                    side: inlineSide(from: location.side)
                ),
                evidenceItemID: thread.id
            )
            output[file.id, default: []].append(item)
        }

        return output.mapValues { items in
            items.sorted {
                ($0.anchor.line ?? Int.min, $0.id) < ($1.anchor.line ?? Int.min, $1.id)
            }
        }
    }

    private static func matchingFile(
        for location: ReviewThreadLocation,
        in files: [DiffReviewFileSummary]
    ) -> DiffReviewFileSummary? {
        switch location.side {
        case .old:
            return files.first { $0.originalPath == location.originalPath || $0.originalPath == location.path }
                ?? files.first { $0.path == location.path }
        case .new, .unknown:
            return files.first { $0.path == location.path }
                ?? files.first { $0.originalPath == location.originalPath || $0.originalPath == location.path }
        }
    }

    private static func inlineSide(from side: ReviewThreadSide) -> DiffReviewInlineFeedbackSide {
        switch side {
        case .old: .old
        case .new: .new
        case .unknown: .unknown
        }
    }
}
```

If Swift requires explicit returns in the switch expression for the local compiler version, use normal `switch` statements with `return`.

- [ ] **Step 4: Publish inline feedback from the model**

In `ReviewEvidenceModel`, add:

```swift
private(set) var inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
```

Update evidence/file publishing so inline feedback is recomputed after either `fileSession` or `feedbackItems`/request threads load:

```swift
private func refreshInlineFeedback() {
    guard let fileSession,
          let request = snapshot.reviewRequest
    else {
        inlineFeedbackByFileID = [:]
        return
    }

    inlineFeedbackByFileID = ReviewEvidenceInlineFeedbackMapper.feedbackByFileID(
        threads: request.threads,
        files: fileSession.summary.files,
        providerName: request.provider.displayName
    )
}
```

Call `refreshInlineFeedback()` after successful `publishFiles` and after successful `publishEvidence`.

- [ ] **Step 5: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ReviewEvidenceModelTests
```

Expected: `ReviewEvidenceModelTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewModels.swift \
        Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift \
        Alas/Sources/Integrations/CodeHost/ReviewEvidenceModel.swift \
        AlasTests/Integrations/ReviewEvidenceModelTests.swift
git commit -m "feat(review): map feedback to diff anchors"
```

---

### Task 3: Inline Feedback Rendering In Diff Review Surface

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Add failing surface tests**

In `DiffReviewSurfaceTests`, add:

```swift
@Test func fileSectionRendersFileLevelInlineFeedbackBelowHeader() {
    let file = DiffReviewFileSectionModel(
        summary: summary(path: "Sources/App.swift"),
        parsedDiff: parsedDiff(),
        displayModel: displayModel(),
        placeholderMessage: nil,
        openFile: nil
    )
    let feedback = [
        DiffReviewInlineFeedback(
            id: "thread-file",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please review this file.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/thread-file")!,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
            evidenceItemID: "thread-file"
        ),
    ]
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false

    let view = DiffReviewFileSection(
        file: file,
        inlineFeedback: feedback,
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsSourceBadge: false
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 900, height: 500)

    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-file", in: controller.view) != nil)
    #expect(accessibilityLabel(in: controller.view, containing: "Please review this file.") != nil)
}
```

Add:

```swift
@Test func surfacePassesFeedbackToMatchingFileOnly() {
    let first = summary(path: "Sources/App.swift")
    let second = summary(path: "Sources/Other.swift")
    let session = loadedSession(summaries: [first, second])
    let feedback = [
        first.id: [
            DiffReviewInlineFeedback(
                id: "thread-app",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "App feedback.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: first.path, line: 2, side: .new),
                evidenceItemID: "thread-app"
            ),
        ],
    ]
    var selected = first.id
    var collapsed = false
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false

    let view = DiffReviewSurface(
        session: session,
        selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
        railCollapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        inlineFeedbackByFileID: feedback
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 1000, height: 700)

    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-app", in: controller.view) != nil)
}
```

Expected failure: initializers do not accept inline feedback and cards do not render.

- [ ] **Step 2: Add surface parameters**

In `DiffReviewSurface`, add:

```swift
var inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
```

Pass `inlineFeedbackByFileID[file.id] ?? []` into `DiffReviewFileSection` for rendered sections. Placeholders do not need inline cards in V1.

- [ ] **Step 3: Add file section parameter**

In `DiffReviewFileSection`, add:

```swift
var inlineFeedback: [DiffReviewInlineFeedback] = []
```

Update initializers/call sites as needed, relying on the default for existing tests.

- [ ] **Step 4: Render compact feedback cards**

In `DiffReviewFileSection.body`, render file-level cards after `header` and before `content`:

```swift
VStack(spacing: 0) {
    header
    inlineFeedbackStack
    content
}
```

Add:

```swift
@ViewBuilder
private var inlineFeedbackStack: some View {
    let items = inlineFeedback
    if !items.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                DiffReviewInlineFeedbackCard(item: item)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-1"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }
}
```

Add a private card view in `DiffReviewFileSection.swift`:

```swift
private struct DiffReviewInlineFeedbackCard: View {
    let item: DiffReviewInlineFeedback
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.color("accent"))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.providerName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.color("accent"))
                    if let author = item.author, !author.isEmpty {
                        Text(author)
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-muted"))
                    }
                    if let line = item.anchor.line {
                        Text("line \(line)")
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-faint"))
                    }
                }
                Text(item.bodyPreview)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.color("line"), lineWidth: 0.5))
        .background(DiffReviewAccessibilityMarker(identifier: "diff-review-inline-feedback-\(item.id)", label: item.bodyPreview))
    }
}
```

V1 renders cards at file level even when they have line metadata. The model keeps the line metadata for a later precise row-placement pass. This is intentional to avoid destabilizing the AppKit diff body.

- [ ] **Step 5: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: `DiffReviewSurfaceTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewSurface.swift \
        Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift \
        AlasTests/DiffReviewSurfaceTests.swift
git commit -m "feat(diff): show inline review feedback cards"
```

---

### Task 4: CI Activity Rows

**Files:**
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
- Test: `AlasTests/Integrations/CodeHostProviderTests.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceModelTests.swift`

- [ ] **Step 1: Add failing tests for CI activity evidence**

In `CodeHostProviderTests.defaultEvidenceMethodsUseSummaryData`, update the expectation from failed-only CI to all checks:

```swift
#expect(ci.map(\.id) == ["check-passed", "check-1", "check-pending"])
#expect(ci.map(\.status) == [.passed, .failed, .pending])
```

Add a focused test:

```swift
@Test func ciActivityEvidenceMapsAllCheckBuckets() {
    let checks = [
        ReviewCheck(id: "pass", name: "build", workflow: "CI", bucket: .pass, detailURL: nil, completedAt: Date()),
        ReviewCheck(id: "fail", name: "test", workflow: "CI", bucket: .fail, detailURL: nil, completedAt: nil),
        ReviewCheck(id: "pending", name: "lint", workflow: "CI", bucket: .pending, detailURL: nil, completedAt: nil),
        ReviewCheck(id: "skip", name: "docs", workflow: "CI", bucket: .skipping, detailURL: nil, completedAt: nil),
        ReviewCheck(id: "cancel", name: "deploy", workflow: "CI", bucket: .cancel, detailURL: nil, completedAt: nil),
    ]

    let items = ReviewEvidenceCIActivityMapper.items(for: checks)

    #expect(items.map(\.id) == ["pass", "fail", "pending", "skip", "cancel"])
    #expect(items.map(\.status) == [.passed, .failed, .pending, .unknown, .cancelled])
}
```

Expected failure: mapper does not exist and providers only return failed checks.

- [ ] **Step 2: Implement CI activity mapper**

In `ReviewEvidence.swift`, add:

```swift
enum ReviewEvidenceCIActivityMapper {
    static func items(for checks: [ReviewCheck]) -> [ReviewEvidenceItem] {
        checks.map { check in
            ReviewEvidenceItem(
                id: check.id,
                section: .ci,
                title: check.name,
                subtitle: check.workflow,
                status: status(for: check.bucket),
                providerURL: check.detailURL
            )
        }
    }

    static func status(for bucket: ReviewCheckBucket) -> ReviewEvidenceStatus {
        switch bucket {
        case .pass:
            return .passed
        case .fail:
            return .failed
        case .pending:
            return .pending
        case .cancel:
            return .cancelled
        case .skipping, .unknown:
            return .unknown
        }
    }
}
```

- [ ] **Step 3: Use mapper in providers**

Update default `CodeHostProvider.failedCheckEvidence`:

```swift
func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
    ReviewEvidenceCIActivityMapper.items(for: request.checks)
}
```

Update `GitHubCLIProvider.failedCheckEvidence` and `GitLabCLIProvider.failedCheckEvidence` to return `ReviewEvidenceCIActivityMapper.items(for: request.checks)`.

Keep method names unchanged for compatibility; the method now returns CI activity evidence, not only failed rows.

- [ ] **Step 4: Preserve failed check details and generic running details**

Do not change failed-log fetching. In `GitHubCLIProvider.checkEvidenceDetail` and `GitLabCLIProvider.checkEvidenceDetail`, keep the existing logic. For non-failed rows where no run/job ID can be extracted, the current fallback text is acceptable:

```swift
"Open this check in GitHub to inspect full logs."
```

and

```swift
"Open this job in GitLab to inspect full logs."
```

- [ ] **Step 5: Add model test for running CI rows**

In `ReviewEvidenceModelTests`, update or add:

```swift
@Test func ciSectionShowsPendingChecksFromRequest() async {
    let request = Self.reviewRequest(checks: [
        ReviewCheck(
            id: "pending-check",
            name: "build-test",
            workflow: "Build",
            bucket: .pending,
            detailURL: URL(string: "https://github.com/checks/1"),
            completedAt: nil
        ),
    ])
    let model = ReviewEvidenceModel(
        snapshot: Self.snapshot(reviewRequest: request),
        provider: FakeCodeHostProvider(),
        cwd: URL(fileURLWithPath: "/tmp/alas"),
        initialSection: .ci
    )

    await model.load()

    #expect(model.ciItems.map(\.id) == ["pending-check"])
    #expect(model.ciItems.first?.status == .pending)
}
```

Replace the existing `reviewRequest()` helper with this signature and default values:

```swift
private static func reviewRequest(
    checks: [ReviewCheck] = [],
    threads: [ReviewThreadSummary] = []
) -> ReviewRequest {
    let remote = Self.remote()
    return ReviewRequest(
        remote: remote,
        number: 428,
        title: "Review loop",
        url: URL(string: "https://github.com/mrmans0n/alas/pull/428")!,
        state: .open,
        isDraft: false,
        headRefName: "feature/review-loop",
        baseRefName: "main",
        reviewDecision: .changesRequested,
        mergeState: .blocked,
        checks: checks,
        threads: threads
    )
}
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/CodeHostProviderTests \
  -only-testing:AlasTests/ReviewEvidenceModelTests
```

Expected: provider and model CI tests pass.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift \
        Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift \
        Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift \
        Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift \
        AlasTests/Integrations/CodeHostProviderTests.swift \
        AlasTests/Integrations/ReviewEvidenceModelTests.swift
git commit -m "feat(review): show CI activity rows"
```

---

### Task 5: Wire Inline Feedback And CI Activity Into Review Evidence View

**Files:**
- Modify: `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceTabViewTests.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceModelTests.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Add failing view route tests**

In `ReviewEvidenceTabViewTests`, add hosted tests or route-helper tests that assert:

```swift
#expect(ReviewEvidenceTabView.emptyText(for: .ci, isLoadingList: true, itemCount: 0) == "Loading checks…")
#expect(ReviewEvidenceTabView.emptyText(for: .ci, isLoadingList: false, itemCount: 0) == "No checks")
```

If `emptyText` is private, make a small internal static helper:

```swift
static func emptyText(for section: ReviewEvidenceSection, isLoadingList: Bool, itemCount: Int) -> String
```

Expected failure: helper does not exist and current CI empty text says `"No failed checks"`.

- [ ] **Step 2: Pass inline feedback into the diff surface**

In `ReviewEvidenceTabView`, update the existing `.files` view branch by adding the inline-feedback argument to the existing `DiffReviewSurface` call. The resulting call must keep the existing bindings and add this final argument:

```swift
DiffReviewSurface(
    session: fileSession,
    selectedFileID: $selectedFileID,
    railCollapsed: $railCollapsed,
    layoutMode: diffPreferences.layoutMode,
    wrapLines: diffPreferences.wrapLines,
    showWhitespace: diffPreferences.showWhitespace,
    codeFontFamily: appState.config.appearance.codeFontFamily,
    codeFontSize: CGFloat(appState.config.appearance.codeFontSize),
    showsSourceBadges: false,
    inlineFeedbackByFileID: model.inlineFeedbackByFileID
)
```

If the live call site has different local binding names after nearby refactors, keep those existing names and add only `inlineFeedbackByFileID: model.inlineFeedbackByFileID`.

- [ ] **Step 3: Improve CI empty/loading text**

Replace the private empty text helper with:

```swift
static func emptyText(
    for section: ReviewEvidenceSection,
    isLoadingList: Bool,
    itemCount: Int
) -> String {
    switch section {
    case .files:
        return "No changed files"
    case .ci:
        if isLoadingList && itemCount == 0 { return "Loading checks…" }
        return "No checks"
    case .feedback:
        if isLoadingList && itemCount == 0 { return "Loading feedback…" }
        return "No feedback"
    }
}
```

Update call sites to pass `model.isLoadingList` and `model.items(for: section).count`.

- [ ] **Step 4: Keep detail actions available**

Do not remove or rewrite these existing actions in `detailPane`:

- rerun failed checks
- copy context
- open in provider
- send to agent

Run a focused grep after editing:

```bash
rg -n "Rerun Failed|Copy Context|Open|Send" Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift
```

Expected: existing action labels or equivalent button titles remain.

- [ ] **Step 5: Run focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/ReviewEvidenceTabViewTests \
  -only-testing:AlasTests/ReviewEvidenceModelTests \
  -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: review evidence view/model and diff review surface tests pass.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift \
        AlasTests/Integrations/ReviewEvidenceTabViewTests.swift \
        AlasTests/Integrations/ReviewEvidenceModelTests.swift \
        AlasTests/DiffReviewSurfaceTests.swift
git commit -m "feat(review): surface inline feedback and CI activity"
```

---

### Task 6: Final Verification

**Files:**
- No intended source edits.

- [ ] **Step 1: Run project generation**

Run:

```bash
xcodegen
```

Expected: command exits 0. If it changes `Alas.xcodeproj/project.pbxproj`, include that generated file in the final commit for the task that introduced new source files.

- [ ] **Step 2: Run focused suites**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/CodeHostProviderTests \
  -only-testing:AlasTests/GitHubCLIProviderTests \
  -only-testing:AlasTests/GitLabCLIProviderTests \
  -only-testing:AlasTests/ReviewEvidenceModelTests \
  -only-testing:AlasTests/ReviewEvidenceTabViewTests \
  -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: focused suites pass.

- [ ] **Step 3: Run quiet build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [ ] **Step 4: Run full suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: full suite exits 0. If it fails in a known flaky non-review area, rerun the exact failing suite once and report the result honestly.

- [ ] **Step 5: Final status**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: working tree clean and latest commits correspond to this plan.
