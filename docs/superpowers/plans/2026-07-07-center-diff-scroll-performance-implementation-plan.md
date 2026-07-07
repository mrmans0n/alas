# Center Diff Scroll Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve large diff scroll smoothness by caching exact-UI render derivations for review diff sections and regular diff tabs.

**Architecture:** Add pure render context/key/builder types next to the diff review feature, then wire `DiffReviewFileSection` and `DiffTabView` to render from cached placement/segmentation data. Keep `DiffPaneTextDocumentView`, `DiffPaneView`, line selection, context expansion, comments, annotations, and rail sync behavior unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit bridges, Swift Testing (`import Testing`), Xcode project generated from `project.yml`.

---

## Spec

Source design: `docs/superpowers/specs/2026-07-07-center-diff-scroll-performance-design.md`

## File Structure

- Create `Alas/Sources/Center/DiffReview/DiffReviewRenderContext.swift`
  - Owns `DiffReviewRenderContextKey`, `DiffReviewRenderContext`, `DiffReviewRenderContextBuilder`, and `DiffReviewRenderContextCache`.
  - Keeps render derivation pure and separate from `DiffReviewFileSection` view state.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - Replaces repeated `derivedDisplayGroups`, feedback placement, draft placement, row segmentation, and per-segment thread/annotation filtering with render context reads.
  - Keeps local UI state and actions in the view.
- Create `Alas/Sources/Center/Diff/DiffTabRenderContext.swift`
  - Owns the smaller regular-diff draft comment placement/segmentation helper.
- Modify `Alas/Sources/Center/DiffTabView.swift`
  - Uses the regular diff helper in the review diff body.
- Modify `AlasTests/DiffReviewSurfaceTests.swift`
  - Adds pure render-context/key tests and a cached file-section smoke test.
- Modify `AlasTests/DiffPaneViewTests.swift`
  - Adds regular diff helper tests if there is not a better existing `DiffTabView` test target.

## Shared Rules

- Use TDD. Write each test first, run it, and confirm it fails for the expected reason before production code.
- Commands must be prefixed with `rtk`.
- Do not change visible diff behavior.
- Do not add agent attribution to commits, code, docs, or PR text.
- Commit after each task.

---

### Task 1: Add Pure Diff Review Render Context

**Files:**
- Create: `Alas/Sources/Center/DiffReview/DiffReviewRenderContext.swift`
- Modify: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Add failing builder equivalence tests**

Add tests to `AlasTests/DiffReviewSurfaceTests.swift` near the existing placement tests:

```swift
@Test func renderContextBuilderMatchesExistingPlacementHelpers() throws {
    let model = displayModel()
    let firstGroup = try #require(model.groups.first)
    let feedback = [
        DiffReviewInlineFeedback(
            id: "feedback-new-line",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Review this line.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 2, side: .new),
            evidenceItemID: "feedback-new-line"
        ),
        DiffReviewInlineFeedback(
            id: "feedback-file",
            providerName: "GitHub",
            author: nil,
            bodyPreview: "Review this file.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
            evidenceItemID: "feedback-file"
        ),
    ]
    let comment = draftComment(id: "draft-line", path: "A.swift", side: .new, startLine: 2)
    let thread = DiffInlineCommentThread(
        id: "thread-2",
        filePath: "Sources/App.swift",
        newLine: 2,
        isResolved: false,
        isOutdated: false,
        comments: [DiffInlineComment(id: "comment-1", author: "reviewer", body: "Thread body")]
    )
    let annotation = DiffInlineAnnotation(
        id: "annotation-2",
        checkName: "CI",
        newLine: 2,
        level: .warning,
        message: "Warning",
        rawDetails: nil
    )

    let context = DiffReviewRenderContextBuilder.build(
        fileID: DiffReviewFileID(namespace: "test", path: "Sources/App.swift"),
        displayModel: model,
        contextSnapshot: nil,
        contextProviderAvailable: false,
        contextExpansion: DiffContextExpansionState(),
        inlineFeedback: feedback,
        draftComments: [comment],
        pendingDraftAnchor: nil,
        canCreateDraftComment: true,
        threads: [thread],
        annotations: [annotation]
    )

    let expectedFeedback = DiffReviewInlineFeedbackPlacement.position(feedback, in: model.groups)
    let expectedDraft = ReviewDraftCommentPlacement.position([comment], in: model.groups)
    let expectedSegments = ReviewDraftCommentRowSegmentation.segments(
        for: firstGroup,
        placement: expectedDraft,
        pendingAnchor: nil
    )

    #expect(context.groups == model.groups)
    #expect(context.fileLevelInlineFeedback == expectedFeedback.fileLevel)
    #expect(context.inlineFeedbackByGroupID == expectedFeedback.byGroupID)
    #expect(context.fileLevelDraftComments == expectedDraft.fileLevel)
    #expect(context.draftPlacement == expectedDraft)

    let group = try #require(context.group(id: firstGroup.id))
    #expect(group.segments.map(\.segment) == expectedSegments.items)
    #expect(group.segments.flatMap(\.blocks).contains { block in
        if case .thread(let found) = block { return found.id == thread.id }
        return false
    })
    #expect(group.segments.flatMap(\.blocks).contains { block in
        if case .annotation(let found) = block { return found.id == annotation.id }
        return false
    })
}
```

- [ ] **Step 2: Add failing key invalidation tests**

Add tests that lock key behavior:

```swift
@Test func renderContextKeyChangesForPlacementInputsButNotPresentationInputs() {
    let model = displayModel()
    let fileID = DiffReviewFileID(namespace: "test", path: "Sources/App.swift")
    let base = DiffReviewRenderContextKey(
        fileID: fileID,
        displayModel: model,
        contextSnapshot: nil,
        contextProviderAvailable: false,
        contextExpansion: DiffContextExpansionState(),
        inlineFeedback: [],
        draftComments: [],
        pendingDraftAnchor: nil,
        canCreateDraftComment: true,
        threads: [],
        annotations: []
    )
    let comment = draftComment(id: "draft-line", path: "A.swift", side: .new, startLine: 2)
    let withComment = DiffReviewRenderContextKey(
        fileID: fileID,
        displayModel: model,
        contextSnapshot: nil,
        contextProviderAvailable: false,
        contextExpansion: DiffContextExpansionState(),
        inlineFeedback: [],
        draftComments: [comment],
        pendingDraftAnchor: nil,
        canCreateDraftComment: true,
        threads: [],
        annotations: []
    )
    let withPendingAnchor = DiffReviewRenderContextKey(
        fileID: fileID,
        displayModel: model,
        contextSnapshot: nil,
        contextProviderAvailable: false,
        contextExpansion: DiffContextExpansionState(),
        inlineFeedback: [],
        draftComments: [],
        pendingDraftAnchor: DiffReviewLineAnchor(
            path: "A.swift",
            side: .new,
            line: 2,
            endLine: nil,
            rowIndex: 1,
            selectedText: nil
        ),
        canCreateDraftComment: true,
        threads: [],
        annotations: []
    )

    #expect(base == DiffReviewRenderContextKey(
        fileID: fileID,
        displayModel: model,
        contextSnapshot: nil,
        contextProviderAvailable: false,
        contextExpansion: DiffContextExpansionState(),
        inlineFeedback: [],
        draftComments: [],
        pendingDraftAnchor: nil,
        canCreateDraftComment: true,
        threads: [],
        annotations: []
    ))
    #expect(base != withComment)
    #expect(base != withPendingAnchor)
}
```

The equality assertion represents presentation changes not being part of the key. Do not add layout mode, wrap lines, whitespace, theme, or font fields to the key.

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: FAIL because `DiffReviewRenderContextBuilder` and `DiffReviewRenderContextKey` do not exist.

- [ ] **Step 4: Implement render context types**

Create `Alas/Sources/Center/DiffReview/DiffReviewRenderContext.swift` with these responsibilities:

```swift
import Foundation

struct DiffReviewRenderContextKey: Hashable {
    // Build from compact signatures, not large object graphs.
}

struct DiffReviewRenderContext: Equatable {
    struct Group: Equatable, Identifiable {
        let id: String
        let group: DiffDisplayGroup
        let inlineFeedback: [DiffReviewInlineFeedback]
        let segments: [Segment]
    }

    struct Segment: Equatable, Identifiable {
        let id: String
        let segment: ReviewDraftCommentRowSegmentation.Segment
        let blocks: [DiffInlineCommentLayout.Block]
    }

    let key: DiffReviewRenderContextKey
    let groups: [DiffDisplayGroup]
    let fileLevelInlineFeedback: [DiffReviewInlineFeedback]
    let inlineFeedbackByGroupID: [String: [DiffReviewInlineFeedback]]
    let fileLevelDraftComments: [ReviewDraftComment]
    let draftPlacement: ReviewDraftCommentPlacement.Result
    let groupData: [Group]

    func group(id: String) -> Group? {
        groupData.first { $0.id == id }
    }
}
```

Implementation details:

- `DiffReviewRenderContextKey` initializer should accept the same inputs as the builder.
- Include `fileID.rawValue`, group ids/headers/row ids/line numbers/collapsed row ids, provider availability, context expansion state, a compact context snapshot content signature, feedback signatures, draft comment signatures, pending draft placement key, `canCreateDraftComment`, thread signatures, and annotation signatures.
- It is acceptable to use strings/arrays of small nested `Hashable` signatures inside the key.
- For `contextExpansion`, because `DiffContextExpansionState` is not currently hashable or introspectable, derive a visible expansion signature from the resulting derived `groups` row ids and line text. The key initializer can call the same group-derivation helper used by the builder and then hash row ids plus `old?.text`/`new?.text` for visible expanded context rows.
- For `contextSnapshot`, do not rely only on availability and line counts. Hash the available old/new line arrays, or hash the visible expanded context row text from the derived groups. This prevents stale cached rows when a new snapshot has the same line counts but different content.
- `pendingDraftAnchor` should affect the key through `ReviewDraftCommentPlacement.RowKey(side: anchor.side, line: anchor.draftPlacementLine)` only. Do not include `pendingDraftBody`.
- `DiffReviewRenderContextBuilder.build(...)` should:
  - derive groups with `DiffContextExpandedDisplayBuilder.derive(...)`
  - calculate `DiffReviewInlineFeedbackPlacement.position(...)`
  - calculate `ReviewDraftCommentPlacement.position(...)`
  - calculate `ReviewDraftCommentRowSegmentation.segments(...)` for each group
  - prefilter threads and annotations per segment using the same conditions now in `DiffReviewFileSection.reviewGroup`
  - calculate `DiffInlineCommentLayout.blocks(...)` for each segment
- Add `DiffReviewRenderContextCache`:

```swift
@MainActor
final class DiffReviewRenderContextCache: ObservableObject {
    private var storage: [DiffReviewRenderContextKey: DiffReviewRenderContext] = [:]
    private let limit: Int

    init(limit: Int = 8) { self.limit = max(1, limit) }

    func context(
        key: DiffReviewRenderContextKey,
        build: () -> DiffReviewRenderContext
    ) -> DiffReviewRenderContext {
        if let cached = storage[key] { return cached }
        let context = build()
        storage[key] = context
        if storage.count > limit, let first = storage.keys.first {
            storage.removeValue(forKey: first)
        }
        return context
    }

    func removeAll() {
        storage.removeAll()
    }
}
```

- If `DiffInlineCommentLayout.Block` is not `Equatable`, add `Equatable` conformance where it is defined by comparing row segments, thread values, and annotation values.

- [ ] **Step 5: Regenerate the Xcode project**

Run:

```bash
rtk xcodegen
```

Expected: succeeds. Include `Alas.xcodeproj` changes in the task commit if the new source file is added to the project.

- [ ] **Step 6: Run targeted tests and verify GREEN**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add Alas/Sources/Center/DiffReview/DiffReviewRenderContext.swift Alas/Sources/Center/Diff/DiffInlineCommentModel.swift AlasTests/DiffReviewSurfaceTests.swift Alas.xcodeproj
rtk git commit -m "perf(diff): add review render context"
```

Only include `DiffInlineCommentModel.swift` if `Equatable` conformance was needed. Only include `Alas.xcodeproj` if `xcodegen` changed it.

---

### Task 2: Integrate Render Context Into Review File Sections

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Modify: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Add failing test-only cache probe support**

Before writing the test, plan to expose debug-only cache metrics from
`DiffReviewRenderContextCache`:

```swift
#if DEBUG
var missCountForTests: Int { missCount }
#endif
```

The production implementation should increment `missCount` only when a key is
not found and the build closure runs. Do not add this before the failing test.

- [ ] **Step 2: Add failing cache reuse test**

Add a pure cache test to `AlasTests/DiffReviewSurfaceTests.swift`:

```swift
@MainActor
@Test func renderContextCacheReusesMatchingKeyAndRebuildsAfterKeyChange() {
    let model = displayModel()
    let fileID = DiffReviewFileID(namespace: "test", path: "Sources/App.swift")
    let cache = DiffReviewRenderContextCache(limit: 2)
    let key = DiffReviewRenderContextKey(
        fileID: fileID,
        displayModel: model,
        contextSnapshot: nil,
        contextProviderAvailable: false,
        contextExpansion: DiffContextExpansionState(),
        inlineFeedback: [],
        draftComments: [],
        pendingDraftAnchor: nil,
        canCreateDraftComment: true,
        threads: [],
        annotations: []
    )
    var buildCount = 0

    _ = cache.context(key: key) {
        buildCount += 1
        return DiffReviewRenderContextBuilder.build(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
    }
    _ = cache.context(key: key) {
        buildCount += 1
        return DiffReviewRenderContextBuilder.build(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
    }

    #expect(buildCount == 1)
}
```

- [ ] **Step 3: Add failing view cache-wiring test**

Add a debug-only test hook to `DiffReviewFileSection` after the failing test is
written. The hook should be optional and default to `nil`:

```swift
#if DEBUG
var onRenderContextCacheMissForTesting: (() -> Void)? = nil
#endif
```

Add a view test that drives a presentation-only change and expects the same
render context to be reused:

```swift
@MainActor
@Test func fileSectionReusesRenderContextAcrossPresentationChanges() {
    let file = DiffReviewFileSectionModel(
        summary: summary(path: "Sources/App.swift"),
        parsedDiff: parsedDiff(),
        displayModel: displayModel(),
        placeholderMessage: nil,
        openFile: nil,
        contextProvider: nil
    )
    let comment = draftComment(id: "draft-cached", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false
    var cacheMisses = 0

    let view = DiffReviewFileSection(
        file: file,
        draftComments: [comment],
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsSourceBadge: false,
        onRenderContextCacheMissForTesting: { cacheMisses += 1 }
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 900, height: 620)
    controller.view.layoutSubtreeIfNeeded()
    #expect(cacheMisses == 1)

    wrap = true
    controller.rootView = view
    controller.view.layoutSubtreeIfNeeded()

    #expect(cacheMisses == 1)
    #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-draft-cached", in: controller.view) != nil)
}
```

If the exact host controller type does not allow assigning `rootView`, use the
existing project pattern for forcing a SwiftUI hosted view update. The key
requirement is that a presentation-only input changes while placement inputs
remain the same.

- [ ] **Step 4: Keep visible-card smoke coverage**

Add a view test that combines inline feedback and a draft comment, then asserts the same visible cards render:

```swift
@Test func fileSectionRendersInlineFeedbackAndDraftCommentThroughRenderContext() {
    let file = DiffReviewFileSectionModel(
        summary: summary(path: "Sources/App.swift"),
        parsedDiff: parsedDiff(),
        displayModel: displayModel(),
        placeholderMessage: nil,
        openFile: nil,
        contextProvider: nil
    )
    let feedback = DiffReviewInlineFeedback(
        id: "feedback-cached",
        providerName: "GitHub",
        author: "reviewer",
        bodyPreview: "Cached feedback.",
        status: .actionable,
        providerURL: nil,
        anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: 2, side: .new),
        evidenceItemID: "feedback-cached"
    )
    let comment = draftComment(id: "draft-cached", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false

    let view = DiffReviewFileSection(
        file: file,
        inlineFeedback: [feedback],
        draftComments: [comment],
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsSourceBadge: false
    )
    .environment(\.theme, theme())

    let controller = host(view, width: 900, height: 620)

    #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-feedback-cached", in: controller.view) != nil)
    #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-draft-cached", in: controller.view) != nil)
}
```

- [ ] **Step 5: Run tests and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: FAIL because `DiffReviewFileSection` does not yet accept the
debug-only `onRenderContextCacheMissForTesting` hook and does not own/use a
render context cache.

- [ ] **Step 6: Wire the cache into `DiffReviewFileSection`**

In `DiffReviewFileSection`:

- Add `@StateObject private var renderContextCache = DiffReviewRenderContextCache()`.
- Add the debug-only `onRenderContextCacheMissForTesting` stored property.
- Replace `derivedDisplayGroups`, `inlineFeedbackPlacement(groups:)`, and `draftCommentPlacement(groups:)` body-path calls with a `renderContext` computed property.
- The computed property should return `nil` when `file.displayModel == nil`.
- Build the key from:
  - `file.id`
  - `displayModel`
  - `contextSnapshot`
  - `file.contextProvider != nil`
  - `contextExpansion`
  - `inlineFeedback`
  - `draftComments`
  - `pendingDraftAnchor`
  - `allowsDraftCommentCreation`
  - `threads`
  - `annotations`
- Use `renderContext.groups` anywhere `derivedDisplayGroups` was used.
- Use `renderContext.fileLevelDraftComments` in `fileLevelDraftCommentStack`.
- Use `renderContext.fileLevelInlineFeedback` in `fileLevelInlineFeedbackStack`.
- In `content`, iterate `renderContext.groupData`.
- For each group:
  - render `inlineFeedbackStack(group.inlineFeedback, file: file.summary)` when non-empty
  - call a revised `reviewGroup(_ groupData: DiffReviewRenderContext.Group, displayModel: DiffDisplayModel)` for segmented groups
- In segmented rendering, use `groupData.segments` and each segment’s precomputed `blocks`.
- Keep the existing `DiffPaneView` path for groups where `segments.containsLocalAccessories == false`.
- Update `currentDraftRowKeys` to use `renderContext?.groups`.
- Keep `contextLoadErrorRow`, context load/reset behavior, LSP context, actions, and all callbacks unchanged.

- [ ] **Step 7: Run targeted review surface tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
rtk git add Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift AlasTests/DiffReviewSurfaceTests.swift
rtk git commit -m "perf(diff): cache review file render context"
```

---

### Task 3: Add Regular Diff Draft Segmentation Helper

**Files:**
- Create: `Alas/Sources/Center/Diff/DiffTabRenderContext.swift`
- Modify: `Alas/Sources/Center/DiffTabView.swift`
- Modify: `AlasTests/DiffPaneViewTests.swift` or a more specific existing `DiffTabView` test file if one already covers draft comments.

- [ ] **Step 1: Add failing helper tests**

Add tests near existing diff pane draft/comment tests:

```swift
@Test func diffTabRenderContextMatchesDraftPlacementAndSegmentationHelpers() throws {
    let model = DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")
    let group = try #require(model.groups.first)
    let fileID = DiffReviewFileID(namespace: "diff-tab", path: "Sources/App.swift")
    let comment = ReviewDraftComment(
        id: "draft-tab",
        sessionID: .localDraft(worktreeID: "worktree", scope: "diff-tab"),
        fileID: fileID,
        path: "Sources/App.swift",
        originalPath: nil,
        side: .new,
        startLine: 2,
        endLine: nil,
        selectedText: nil,
        bodyMarkdown: "Draft body",
        state: .active,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    let context = DiffTabRenderContextBuilder.build(
        model: model,
        comments: [comment],
        pendingDraftAnchor: nil
    )

    let expectedPlacement = ReviewDraftCommentPlacement.position([comment], in: model.groups)
    let expectedSegments = ReviewDraftCommentRowSegmentation.segments(
        for: group,
        placement: expectedPlacement,
        pendingAnchor: nil
    )

    #expect(context.fileLevelDraftComments == expectedPlacement.fileLevel)
    #expect(context.group(id: group.id)?.segments == expectedSegments.items)
}
```

If `DiffPaneViewTests.swift` does not have `parsedDiff()` helpers with compatible line numbers, add small local helpers in the test file rather than depending on private helpers from another test suite.

- [ ] **Step 2: Add failing regular diff cache key and reuse tests**

Add tests mirroring the review cache behavior:

```swift
@MainActor
@Test func diffTabRenderContextCacheReusesMatchingKey() throws {
    let model = DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")
    let cache = DiffTabRenderContextCache(limit: 2)
    let key = DiffTabRenderContextKey(
        model: model,
        comments: [],
        pendingDraftAnchor: nil
    )
    var buildCount = 0

    _ = cache.context(key: key) {
        buildCount += 1
        return DiffTabRenderContextBuilder.build(
            model: model,
            comments: [],
            pendingDraftAnchor: nil
        )
    }
    _ = cache.context(key: key) {
        buildCount += 1
        return DiffTabRenderContextBuilder.build(
            model: model,
            comments: [],
            pendingDraftAnchor: nil
        )
    }

    #expect(buildCount == 1)
}

@Test func diffTabRenderContextKeyIgnoresPresentationInputs() {
    let model = DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")

    #expect(DiffTabRenderContextKey(
        model: model,
        comments: [],
        pendingDraftAnchor: nil
    ) == DiffTabRenderContextKey(
        model: model,
        comments: [],
        pendingDraftAnchor: nil
    ))
}
```

Do not add layout mode, wrap lines, whitespace, theme, or font fields to `DiffTabRenderContextKey`.

- [ ] **Step 3: Add failing view cache-wiring test**

Add a debug-only cache miss hook to `DiffTabView` after the failing test is written:

```swift
#if DEBUG
var onRenderContextCacheMissForTesting: (() -> Void)? = nil
#endif
```

Then add or update a `DiffTabView`/diff-pane view test to change a presentation-only diff preference and assert the hook fires once. If direct `DiffTabView` hosting requires too much setup, add a smaller SwiftUI harness around the regular diff review body helper. The required behavior is: same `DiffTabRenderContextKey` across layout/wrap/whitespace changes, and no second cache miss for those changes.

- [ ] **Step 4: Run tests and verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: FAIL because `DiffTabRenderContextBuilder` does not exist.

- [ ] **Step 5: Implement regular diff helper and cache**

Create `Alas/Sources/Center/Diff/DiffTabRenderContext.swift`:

```swift
import Foundation

struct DiffTabRenderContextKey: Hashable {
    init(
        model: DiffDisplayModel,
        comments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?
    ) {
        // Use compact display row/comment/pending-anchor signatures.
    }
}

struct DiffTabRenderContext: Equatable {
    struct Group: Equatable, Identifiable {
        let id: String
        let group: DiffDisplayGroup
        let segments: [ReviewDraftCommentRowSegmentation.Segment]
    }

    let key: DiffTabRenderContextKey
    let fileLevelDraftComments: [ReviewDraftComment]
    let draftPlacement: ReviewDraftCommentPlacement.Result
    let groupData: [Group]

    func group(id: String) -> Group? {
        groupData.first { $0.id == id }
    }
}

enum DiffTabRenderContextBuilder {
    static func build(
        model: DiffDisplayModel,
        comments: [ReviewDraftComment],
        pendingDraftAnchor: DiffReviewLineAnchor?
    ) -> DiffTabRenderContext {
        // Build placement once, then per-group segments.
    }
}
```

Add a mandatory `@MainActor final class DiffTabRenderContextCache: ObservableObject` with the same API shape as `DiffReviewRenderContextCache`, including debug-only miss counting if the view test needs it.

- [ ] **Step 6: Wire helper and cache into `DiffTabView`**

In `reviewDiffBody(model:)`:

- Compute `comments` as today.
- Add `@StateObject private var renderContextCache = DiffTabRenderContextCache()` to `DiffTabView`.
- Build a `DiffTabRenderContextKey` from `model`, `comments`, and `pendingDraftAnchor`.
- Read `DiffTabRenderContext` through `renderContextCache.context(key:build:)`.
- Invoke the debug-only cache-miss hook only when the cache misses.
- Use `context.fileLevelDraftComments` instead of local `placement.fileLevel`.
- Iterate `context.groupData` instead of `model.groups`.
- Change `reviewDiffGroup` to accept `DiffTabRenderContext.Group` and render from `groupData.segments`.
- Keep the existing no-local-accessories path that renders a whole `DiffPaneTextDocumentView` unchanged.
- Keep toolbar, scroll view, draft composer, hunk actions, LSP, and selection callbacks unchanged.

- [ ] **Step 7: Regenerate the Xcode project**

Run:

```bash
rtk xcodegen
```

Expected: succeeds. Include `Alas.xcodeproj` changes in the task commit if the new source file is added to the project.

- [ ] **Step 8: Run targeted tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
rtk git add Alas/Sources/Center/Diff/DiffTabRenderContext.swift Alas/Sources/Center/DiffTabView.swift AlasTests/DiffPaneViewTests.swift Alas.xcodeproj
rtk git commit -m "perf(diff): cache regular diff draft segmentation"
```

Only include `Alas.xcodeproj` if `xcodegen` changed it.

---

### Task 4: Final Verification And Polish

**Files:**
- Modify only files required to fix failures found by verification.

- [ ] **Step 1: Run focused test suites**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/DiffPaneViewTests test
```

Expected: PASS.

- [ ] **Step 2: Run project generation check**

Run:

```bash
rtk xcodegen
```

Expected: project generation succeeds and does not create unrelated changes. If it changes `Alas.xcodeproj`, inspect and include the project changes only if they are required.

- [ ] **Step 3: Run required build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 4: Run full tests if time permits**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: PASS. If this is too slow or fails outside the touched area, capture the failure and run the focused suites from Step 1 again.

- [ ] **Step 5: Commit verification fixes**

If any fixes were needed:

```bash
rtk git add <changed-files>
rtk git commit -m "fix(diff): polish render context integration"
```

If no fixes were needed, do not create an empty commit.
