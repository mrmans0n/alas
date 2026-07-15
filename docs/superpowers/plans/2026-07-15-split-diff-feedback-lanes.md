# Split Diff Feedback Lanes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render every hunk- or row-attached diff feedback item in its semantic left or right lane in split mode, and code-aligned across the full row in stacked mode.

**Architecture:** Add a pure lane resolver and a reusable SwiftUI lane wrapper backed by shared AppKit/SwiftUI gutter geometry. Keep the existing segmentation and provider models responsible for vertical placement and persistence; wrap existing composers and cards only at their current insertion sites.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, Swift Testing, XcodeGen, Xcode 16+

---

## File Structure

- Create `Alas/Sources/Center/Diff/DiffFeedbackLane.swift`: semantic lane resolution, line-label projection, gutter thickness, pure lane frames, and the generic SwiftUI lane wrapper.
- Create `AlasTests/DiffFeedbackLaneTests.swift`: resolver, geometry, label projection, and direct lane-view layout tests.
- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`: make the AppKit line ruler use the shared gutter thickness helper.
- Modify `Alas/Sources/Center/Diff/DiffPaneView.swift`: wrap provider threads and annotations in side-local lanes.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`: wrap actionable feedback, drafts, the pending composer, provider threads, and annotations without changing their vertical segmentation.
- Modify `Alas/Sources/Center/DiffTabView.swift`: wrap standalone-diff drafts and the pending composer.
- Modify `AlasTests/DiffPaneViewTests.swift`: integration coverage for provider thread and annotation lanes.
- Modify `AlasTests/DiffReviewSurfaceTests.swift`: integration coverage for actionable feedback, draft, composer, and review-surface provider lanes.

No `project.yml` edit is needed because both application and test targets already include their source directories recursively.

### Task 1: Semantic Feedback Lane Resolver

**Files:**
- Create: `Alas/Sources/Center/Diff/DiffFeedbackLane.swift`
- Create: `AlasTests/DiffFeedbackLaneTests.swift`

- [ ] **Step 1: Write failing resolver tests**

Create `AlasTests/DiffFeedbackLaneTests.swift` with the resolver matrix. The helper must retain whether selected lines are changes so context does not override the changed side:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffFeedbackLaneTests {
    @Test func pendingAnchorUsesChangedSideBeforeContext() {
        #expect(DiffFeedbackLaneResolver.lane(for: anchor(side: .old, lines: [
            .init(side: .old, line: 10, isChange: true),
            .init(side: .unknown, line: 11, isChange: false),
        ])) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: anchor(side: .new, lines: [
            .init(side: .unknown, line: 10, isChange: false),
            .init(side: .new, line: 11, isChange: true),
        ])) == .right)
    }

    @Test func pendingAnchorDefaultsMixedChangesToRight() {
        let mixed = anchor(side: .unknown, lines: [
            .init(side: .old, line: 10, isChange: true),
            .init(side: .new, line: 10, isChange: true),
        ])
        #expect(DiffFeedbackLaneResolver.lane(for: mixed) == .right)
    }

    @Test func pendingContextOnlyAnchorUsesSelectionPane() {
        #expect(DiffFeedbackLaneResolver.lane(for: anchor(side: .old, lines: [
            .init(side: .old, line: 10, isChange: false),
        ])) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: anchor(side: .new, lines: [
            .init(side: .new, line: 10, isChange: false),
        ])) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: anchor(side: .unknown, lines: [
            .init(side: .unknown, line: 10, isChange: false),
        ])) == .right)
    }

    @Test func modelAdaptersUsePersistedSemanticSide() {
        #expect(DiffFeedbackLaneResolver.lane(for: draft(side: .old)) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: draft(side: .new)) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: feedback(side: .old)) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: feedback(side: .new)) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: thread(isOldSide: true)) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: thread(isOldSide: false)) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: annotation()) == .right)
    }

    private func anchor(
        side: DiffReviewInlineFeedbackSide,
        lines: [DiffReviewLineAnchor.SelectedLine]
    ) -> DiffReviewLineAnchor {
        DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: side,
            line: lines.first?.line ?? 1,
            endLine: lines.last?.line,
            rowIndex: 0,
            endRowIndex: max(lines.count - 1, 0),
            selectedLines: lines,
            selectedText: "selection"
        )
    }

    private func draft(side: DiffReviewInlineFeedbackSide) -> ReviewDraftComment {
        ReviewDraftComment(
            id: "draft-\(side.rawValue)",
            sessionID: .localChanges(
                worktreeID: "worktree",
                worktreePath: URL(fileURLWithPath: "/tmp/worktree"),
                scope: .unstaged
            ),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: side,
            startLine: 10,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Draft",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func feedback(side: DiffReviewInlineFeedbackSide) -> DiffReviewInlineFeedback {
        DiffReviewInlineFeedback(
            id: "feedback-\(side.rawValue)",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Feedback",
            status: .actionable,
            providerURL: nil,
            anchor: .init(path: "Sources/App.swift", line: 10, side: side),
            evidenceItemID: "feedback-\(side.rawValue)"
        )
    }

    private func thread(isOldSide: Bool) -> DiffInlineCommentThread {
        DiffInlineCommentThread(
            id: isOldSide ? "old-thread" : "new-thread",
            filePath: "Sources/App.swift",
            newLine: 10,
            isOldSide: isOldSide,
            isResolved: false,
            isOutdated: false,
            comments: [.init(id: "comment", author: "reviewer", body: "Feedback")]
        )
    }

    private func annotation() -> DiffInlineAnnotation {
        DiffInlineAnnotation(
            id: "annotation",
            checkName: "SwiftLint",
            newLine: 10,
            level: .warning,
            message: "Warning",
            rawDetails: nil
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodegen
```

Expected: exit 0 and the generated project includes both new files.

Then run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffFeedbackLaneTests
```

Expected: compilation fails because `DiffFeedbackLaneResolver` and `DiffFeedbackLane` do not exist.

- [ ] **Step 3: Implement the minimal resolver**

Start `Alas/Sources/Center/Diff/DiffFeedbackLane.swift` with:

```swift
import AppKit
import SwiftUI

enum DiffFeedbackLane: String, Equatable, Hashable {
    case left
    case right
    case full
}

enum DiffFeedbackLaneResolver {
    static func lane(for anchor: DiffReviewLineAnchor) -> DiffFeedbackLane {
        let changedSides = Set(anchor.selectedLines.lazy.filter(\.isChange).map(\.side))
        if changedSides.contains(.new) { return .right }
        if changedSides.contains(.old) { return .left }
        return lane(for: anchor.side)
    }

    static func lane(for comment: ReviewDraftComment) -> DiffFeedbackLane {
        lane(for: comment.side)
    }

    static func lane(for feedback: DiffReviewInlineFeedback) -> DiffFeedbackLane {
        lane(for: feedback.anchor.side)
    }

    static func lane(for thread: DiffInlineCommentThread) -> DiffFeedbackLane {
        thread.isOldSide ? .left : .right
    }

    static func lane(for _: DiffInlineAnnotation) -> DiffFeedbackLane {
        .right
    }

    static func lane(for side: DiffReviewInlineFeedbackSide) -> DiffFeedbackLane {
        switch side {
        case .old: .left
        case .new, .unknown: .right
        }
    }
}
```

The `.new` check intentionally precedes `.old`, which makes a mixed changed-side selection resolve right.

- [ ] **Step 4: Run the focused test and verify it passes**

Run the command from Step 2.

Expected: `DiffFeedbackLaneTests` passes.

- [ ] **Step 5: Commit the resolver**

```bash
git add Alas/Sources/Center/Diff/DiffFeedbackLane.swift AlasTests/DiffFeedbackLaneTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "Add diff feedback lane resolver"
```

### Task 2: Shared Gutter Geometry And Lane Layout

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffFeedbackLane.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift:1817-1818,2215-2223`
- Modify: `AlasTests/DiffFeedbackLaneTests.swift`
- Modify: `AlasTests/DiffPaneViewTests.swift:1280-1330`

- [ ] **Step 1: Add failing geometry and label-projection tests**

Append these tests to `DiffFeedbackLaneTests`:

```swift
@Test func laneFramesMatchTheDiffPaneDividerMath() {
    #expect(DiffFeedbackLaneGeometry.contentFrame(
        containerWidth: 901,
        layoutMode: .split,
        lane: .left,
        gutterWidth: 42
    ) == CGRect(x: 42, y: 0, width: 408, height: 0))
    #expect(DiffFeedbackLaneGeometry.contentFrame(
        containerWidth: 901,
        layoutMode: .split,
        lane: .right,
        gutterWidth: 42
    ) == CGRect(x: 493, y: 0, width: 408, height: 0))
    #expect(DiffFeedbackLaneGeometry.contentFrame(
        containerWidth: 901,
        layoutMode: .stacked,
        lane: .right,
        gutterWidth: 42
    ) == CGRect(x: 42, y: 0, width: 859, height: 0))
}

@Test func gutterThicknessUsesExistingMinimumAndExpandsForWideLabels() {
    #expect(DiffPaneLineNumberGutterGeometry.thickness(labels: ["1", "22"]) == 42)
    #expect(DiffPaneLineNumberGutterGeometry.thickness(labels: ["1234567890"]) > 42)
}

@Test func labelProjectionUsesTheActivePane() throws {
    let model = DiffDisplayModelBuilder.build(
        diff: ParsedDiff(hunks: [.init(
            header: "@@ -9,1 +99,1 @@",
            oldStart: 9,
            newStart: 99,
            lines: [
                .init(kind: .delete, text: "old", oldNumber: 9, newNumber: nil),
                .init(kind: .add, text: "new", oldNumber: nil, newNumber: 99),
            ]
        )]),
        filePath: "Sources/App.swift"
    )
    let rows = try #require(model.groups.first?.rows)
    #expect(DiffFeedbackLineLabels.labels(for: rows, layoutMode: .split, lane: .left) == ["9"])
    #expect(DiffFeedbackLineLabels.labels(for: rows, layoutMode: .split, lane: .right) == ["99"])
    #expect(DiffFeedbackLineLabels.labels(for: rows, layoutMode: .stacked, lane: .right) == ["9", "99"])
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run the Task 1 focused test command.

Expected: compilation fails because the geometry and label helpers do not exist.

- [ ] **Step 3: Add the shared geometry and generic lane wrapper**

Append these units to `DiffFeedbackLane.swift`:

```swift
enum DiffPaneLineNumberGutterGeometry {
    static let minimumThickness: CGFloat = 42
    static let horizontalPadding: CGFloat = 8
    static let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    static func thickness(labels: [String]) -> CGFloat {
        let maxDigits = labels
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+- ")) }
            .map(\.count)
            .max() ?? 1
        let sample = String(repeating: "8", count: max(maxDigits, 1)) as NSString
        let width = ceil(sample.size(withAttributes: [.font: labelFont]).width)
        return max(minimumThickness, width + horizontalPadding * 2)
    }
}

enum DiffFeedbackLineLabels {
    static func labels(
        for rows: [DiffDisplayRow],
        layoutMode: DiffLayoutMode,
        lane: DiffFeedbackLane
    ) -> [String] {
        switch layoutMode {
        case .split:
            switch lane {
            case .left:
                return rows.compactMap { $0.old?.lineNumber.map(String.init) }
            case .right, .full:
                return rows.compactMap { $0.new?.lineNumber.map(String.init) }
            }
        case .stacked:
            return DiffPaneRowProjection.stackedLines(for: rows).compactMap { $0.line.lineNumber.map(String.init) }
        }
    }
}

enum DiffFeedbackLaneGeometry {
    static let dividerWidth: CGFloat = 1

    static func contentFrame(
        containerWidth: CGFloat,
        layoutMode: DiffLayoutMode,
        lane: DiffFeedbackLane,
        gutterWidth: CGFloat
    ) -> CGRect {
        let width = max(containerWidth, 0)
        guard layoutMode == .split else {
            let inset = min(gutterWidth, width)
            return CGRect(x: inset, y: 0, width: width - inset, height: 0)
        }
        let oldWidth = floor(max(width - dividerWidth, 0) / 2)
        let newOrigin = oldWidth + min(dividerWidth, width)
        let newWidth = max(width - newOrigin, 0)
        if lane == .left {
            let inset = min(gutterWidth, oldWidth)
            return CGRect(x: inset, y: 0, width: oldWidth - inset, height: 0)
        }
        let inset = min(gutterWidth, newWidth)
        return CGRect(x: newOrigin + inset, y: 0, width: newWidth - inset, height: 0)
    }
}

private struct DiffFeedbackLaneLayout: Layout {
    let layoutMode: DiffLayoutMode
    let lane: DiffFeedbackLane
    let gutterWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = proposal.width ?? 0
        let frame = DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: width,
            layoutMode: layoutMode,
            lane: lane,
            gutterWidth: gutterWidth
        )
        let contentSize = subview.sizeThatFits(.init(width: frame.width, height: proposal.height))
        return CGSize(width: width, height: contentSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let frame = DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: bounds.width,
            layoutMode: layoutMode,
            lane: lane,
            gutterWidth: gutterWidth
        )
        subview.place(
            at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: .init(width: frame.width, height: proposal.height)
        )
    }
}

struct DiffFeedbackLaneView<Content: View>: View {
    let lane: DiffFeedbackLane
    let layoutMode: DiffLayoutMode
    let rows: [DiffDisplayRow]
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    private var effectiveLane: DiffFeedbackLane {
        layoutMode == .stacked ? .full : lane
    }

    var body: some View {
        let labels = DiffFeedbackLineLabels.labels(for: rows, layoutMode: layoutMode, lane: lane)
        let gutterWidth = DiffPaneLineNumberGutterGeometry.thickness(labels: labels)
        DiffFeedbackLaneLayout(layoutMode: layoutMode, lane: effectiveLane, gutterWidth: gutterWidth) {
            content()
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if layoutMode == .split {
                Rectangle()
                    .fill(theme.color("line"))
                    .frame(width: DiffFeedbackLaneGeometry.dividerWidth)
            }
        }
        .background(DiffFeedbackLaneAccessibilityMarker(lane: effectiveLane))
    }
}

private struct DiffFeedbackLaneAccessibilityMarker: NSViewRepresentable {
    let lane: DiffFeedbackLane

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier("diff-feedback-lane-\(lane.rawValue)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier("diff-feedback-lane-\(lane.rawValue)")
    }
}
```

The environment theme's `line` color and the one-point geometry match the
existing diff divider.

- [ ] **Step 4: Make the AppKit ruler consume the shared thickness helper**

In `DiffPaneLineNumberRulerView`, delete its private `minimumThickness` and `horizontalPadding` constants. Initialize and update thickness through the helper:

```swift
ruleThickness = DiffPaneLineNumberGutterGeometry.minimumThickness
```

```swift
private func updateThickness() {
    ruleThickness = DiffPaneLineNumberGutterGeometry.thickness(labels: labels)
}
```

Keep drawing-only padding local by replacing drawing references to the deleted instance property with `DiffPaneLineNumberGutterGeometry.horizontalPadding`.

- [ ] **Step 5: Run geometry and existing ruler tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/DiffFeedbackLaneTests \
  -only-testing:AlasTests/DiffPaneViewTests
```

Expected: both suites pass, including the existing 42-point ruler geometry assertions.

- [ ] **Step 6: Commit shared layout geometry**

```bash
git add Alas/Sources/Center/Diff/DiffFeedbackLane.swift Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift AlasTests/DiffFeedbackLaneTests.swift AlasTests/DiffPaneViewTests.swift
git commit -m "Add diff feedback lane layout"
```

### Task 3: Provider Threads And Annotations In The Shared Diff Renderer

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift:330-390`
- Modify: `AlasTests/DiffPaneViewTests.swift`

- [ ] **Step 1: Add failing shared-renderer lane tests**

Add a test that hosts `DiffPaneView` with one old-side thread and one new-side annotation in split mode, then asserts both accessibility markers exist. Add a second host in stacked mode and assert full-lane markers are emitted:

```swift
@Test func providerAccessoriesUseSemanticLanesAndStackedFullWidth() {
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false
    let thread = DiffInlineCommentThread(
        id: "old-thread",
        filePath: "a.swift",
        newLine: 2,
        isOldSide: true,
        isResolved: false,
        isOutdated: false,
        comments: [.init(id: "comment", author: "reviewer", body: "Old side")]
    )
    let annotation = DiffInlineAnnotation(
        id: "new-annotation",
        checkName: "SwiftLint",
        newLine: 2,
        level: .warning,
        message: "New side",
        rawDetails: nil
    )
    let makeView = {
        DiffPaneView(
            model: self.model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            threads: [thread],
            annotations: [annotation],
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, self.theme())
    }

    let split = NSHostingController(rootView: makeView())
    split.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    split.view.layoutSubtreeIfNeeded()
    #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-left", in: split.view) != nil)
    #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-right", in: split.view) != nil)

    layout = .stacked
    let stacked = NSHostingController(rootView: makeView())
    stacked.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    stacked.view.layoutSubtreeIfNeeded()
    #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-full", in: stacked.view) != nil)
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests/providerAccessoriesUseSemanticLanesAndStackedFullWidth
```

Expected: the lane accessibility markers are absent.

- [ ] **Step 3: Wrap existing cards without changing block placement**

In `DiffPaneView.hunk(_:)`, wrap only the `.thread` and `.annotation` card branches. Pass `visibleRows` so their gutter width is stable for the hunk:

```swift
case .thread(let thread):
    DiffFeedbackLaneView(
        lane: DiffFeedbackLaneResolver.lane(for: thread),
        layoutMode: layoutMode,
        rows: visibleRows
    ) {
        DiffInlineCommentCard(
            thread: thread,
            onReply: { body in onReply(thread, body) },
            onStageReply: { body in onStageReply(thread, body) },
            onResolve: { onResolve(thread) },
            onUnresolve: { onUnresolve(thread) },
            onEdit: { comment, newBody in onEdit(thread, comment, newBody) },
            onDelete: { comment in onDelete(thread, comment) },
            canReply: canReply && thread.viewerCanReply,
            canResolve: canResolve && (thread.viewerCanResolve || thread.viewerCanUnresolve),
            canAddToReview: canAddToReview,
            onActiveChange: { active in
                activeThreadID = active ? thread.id : (activeThreadID == thread.id ? nil : activeThreadID)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
case .annotation(let annotation):
    DiffFeedbackLaneView(
        lane: DiffFeedbackLaneResolver.lane(for: annotation),
        layoutMode: layoutMode,
        rows: visibleRows
    ) {
        DiffInlineAnnotationCard(annotation: annotation)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
```

Do not alter `DiffInlineCommentLayout.blocks`; it remains the source of vertical ordering.

- [ ] **Step 4: Run the shared-renderer tests**

Run the full `DiffPaneViewTests` suite.

Expected: all tests pass.

- [ ] **Step 5: Commit shared-renderer integration**

```bash
git add Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/DiffPaneViewTests.swift
git commit -m "Place provider feedback in diff lanes"
```

### Task 4: Review Surface Feedback Lanes

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift:329-365,486-505,520-610,734-805`
- Modify: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Add failing review-surface integration tests**

Add this focused host test through accessibility markers:

```swift
@Test func reviewSurfaceUsesLanesForActionableFeedbackAndDrafts() {
    let file = DiffReviewFileSectionModel(
        summary: summary(path: "Sources/App/AlphaView.swift"),
        parsedDiff: parsedDiff(),
        displayModel: displayModel(),
        placeholderMessage: nil,
        openFile: nil,
        contextProvider: nil
    )
    let feedback = DiffReviewInlineFeedback(
        id: "old-feedback",
        providerName: "GitHub",
        author: "reviewer",
        bodyPreview: "Old-side feedback",
        status: .actionable,
        providerURL: nil,
        anchor: .init(path: file.summary.path, line: 2, side: .old),
        evidenceItemID: "old-feedback"
    )
    let comment = draftComment(
        id: "new-draft",
        fileID: file.id,
        path: file.summary.path,
        side: .new,
        startLine: 2
    )
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

    #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-left", in: controller.view) != nil)
    #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-right", in: controller.view) != nil)
}
```

The pending composer uses the same resolver exercised by
`pendingAnchorUsesChangedSideBeforeContext`,
`pendingAnchorDefaultsMixedChangesToRight`, and
`pendingContextOnlyAnchorUsesSelectionPane`. Existing segmentation tests remain
the coverage for one composer and range-end insertion because the composer
state is private to `DiffReviewFileSection`.

- [ ] **Step 2: Run the focused review tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffReviewSurfaceTests
```

Expected: new lane marker assertions fail while existing vertical-placement assertions pass.

- [ ] **Step 3: Make actionable provider feedback side-local**

Split `inlineFeedbackStack` into a file-level path that preserves today's full-width stack and a hunk-attached path that receives `rows` and wraps each visible item:

```swift
private func inlineFeedbackStack(
    _ items: [DiffReviewInlineFeedback],
    file: DiffReviewFileSummary,
    rows: [DiffDisplayRow]? = nil
) -> some View
```

At the hunk call site, pass `group.displayGroup.rows`. For every visible feedback item with rows, render:

```swift
DiffFeedbackLaneView(
    lane: DiffFeedbackLaneResolver.lane(for: item),
    layoutMode: layoutMode,
    rows: rows
) {
    inlineFeedbackCard(item, file: file)
        .padding(.horizontal, 14)
}
```

Extract the existing card construction to `inlineFeedbackCard(_:file:)` so file-level and lane-local paths share focus, hover, actions, and stable IDs. Keep `DiffReviewInlineFeedbackMoreRow` outside lane resolution because it summarizes possibly mixed-side hidden items.

- [ ] **Step 4: Make drafts and the pending composer side-local**

Change `draftCommentStack` to accept segment rows and wrap each comment independently, preserving mixed old/new drafts on one display row:

```swift
private func draftCommentStack(
    _ comments: [ReviewDraftComment],
    rows: [DiffDisplayRow]
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(comments) { comment in
            DiffFeedbackLaneView(
                lane: DiffFeedbackLaneResolver.lane(for: comment),
                layoutMode: layoutMode,
                rows: rows
            ) {
                draftCommentCard(comment)
                    .padding(.horizontal, 14)
            }
        }
    }
    .padding(.vertical, 10)
    .background(theme.color("bg-1"))
}
```

Extract the existing `ReviewDraftCommentCard` construction to `draftCommentCard(_:)` so IDs, hover, focus, selection, and actions remain identical.

Change `draftComposer` to accept rows, and wrap `draftComposerBody` using the pending selection rather than the canonical saved anchor:

```swift
private func draftComposer(rows: [DiffDisplayRow]) -> some View {
    if allowsDraftCommentCreation, let pendingDraftAnchor {
        DiffFeedbackLaneView(
            lane: DiffFeedbackLaneResolver.lane(for: pendingDraftAnchor),
            layoutMode: layoutMode,
            rows: rows
        ) {
            draftComposerBody
        }
    }
}
```

Update segment call sites to pass `segment.rows`. Keep `savePendingDraft()` and `canonicalPendingAnchor` unchanged.

- [ ] **Step 5: Wrap segmented provider threads and annotations**

In `reviewGroup`, apply the Task 3 wrappers to `.thread` and `.annotation` blocks, passing `segment.rows`. Preserve every callback exactly.

- [ ] **Step 6: Run review-surface and render-context regression tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/DiffReviewSurfaceTests \
  -only-testing:AlasTests/DiffReviewRenderableContentEqualityTests \
  -only-testing:AlasTests/DiffReviewRenderEligibilityTests
```

Expected: all selected suites pass. Existing tests still cover one composer, range-end insertion, context-only selection, focus, and block order.

- [ ] **Step 7: Commit review-surface integration**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift AlasTests/DiffReviewSurfaceTests.swift
git commit -m "Align review feedback with diff lanes"
```

### Task 5: Standalone Diff Draft Lanes

**Files:**
- Modify: `Alas/Sources/Center/DiffTabView.swift:650-835`
- Modify: `AlasTests/DiffPaneViewTests.swift:100-260`

- [ ] **Step 1: Add failing standalone diff lane tests**

Extend the existing `DiffTabRenderContextBuilder` test and add a pending old-side assertion:

```swift
#expect(DiffFeedbackLaneResolver.lane(for: comment) == .right)
let pendingOld = DiffReviewLineAnchor(
    path: "Sources/App.swift",
    side: .old,
    line: 2,
    rowIndex: 1,
    selectedLines: [.init(side: .old, line: 2, isChange: true)],
    selectedText: "let b = 2"
)
#expect(DiffFeedbackLaneResolver.lane(for: pendingOld) == .left)
```

Add a geometry assertion that demonstrates the standalone view's layout-mode
input changes the same semantic lane from a split half to the full stacked row:

```swift
let splitFrame = DiffFeedbackLaneGeometry.contentFrame(
    containerWidth: 900,
    layoutMode: .split,
    lane: DiffFeedbackLaneResolver.lane(for: pendingOld),
    gutterWidth: 42
)
let stackedFrame = DiffFeedbackLaneGeometry.contentFrame(
    containerWidth: 900,
    layoutMode: .stacked,
    lane: DiffFeedbackLaneResolver.lane(for: pendingOld),
    gutterWidth: 42
)
#expect(splitFrame.width == 407)
#expect(stackedFrame.width == 858)
```

- [ ] **Step 2: Run standalone diff tests and verify lane markers fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests
```

Expected: the new resolver and geometry assertions pass. The implementation
step remains necessary because `reviewDiffGroup` still emits unwrapped,
full-width accessories; the existing cache/layout test will exercise both
render branches after the edit.

- [ ] **Step 3: Wrap saved drafts and the composer**

Change `reviewDraftCommentStack` to accept rows, wrap each comment independently, and retain existing card IDs and actions:

```swift
DiffFeedbackLaneView(
    lane: DiffFeedbackLaneResolver.lane(for: comment),
    layoutMode: diffPreferences.layoutMode.wrappedValue,
    rows: rows
) {
    ReviewDraftCommentCard(
        comment: comment,
        file: fileSummary,
        isFocused: false,
        actions: actions,
        reviewFeedbackTarget: reviewFeedbackTarget,
        onSelect: { _ in }
    )
    .id(DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: fileID))
        .padding(.horizontal, 14)
}
```

Change `reviewDraftComposer` to accept rows and wrap its existing body:

```swift
if let pendingDraftAnchor {
    DiffFeedbackLaneView(
        lane: DiffFeedbackLaneResolver.lane(for: pendingDraftAnchor),
        layoutMode: diffPreferences.layoutMode.wrappedValue,
        rows: rows
    ) {
        reviewDraftComposerBody
    }
}
```

Update `reviewDiffGroup` segment call sites to pass `segment.rows`. Extract `reviewDraftComposerBody` only to avoid recursive wrapping; keep save, cancel, focus, and accessibility identifiers unchanged.

- [ ] **Step 4: Run standalone diff regression tests**

Run the `DiffPaneViewTests` suite.

Expected: all tests pass, including render-context cache reuse across layout changes.

- [ ] **Step 5: Commit standalone diff integration**

```bash
git add Alas/Sources/Center/DiffTabView.swift AlasTests/DiffPaneViewTests.swift
git commit -m "Align diff draft comments with lanes"
```

### Task 6: Project Regeneration And Full Verification

**Files:**
- Modify if generated output changes: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Regenerate the Xcode project**

Run:

```bash
xcodegen
```

Expected: exit 0. The generated project includes `DiffFeedbackLane.swift` and `DiffFeedbackLaneTests.swift`. Review `git diff -- Alas.xcodeproj/project.pbxproj` and keep only deterministic XcodeGen output.

- [ ] **Step 2: Run the required build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0 with no Swift compiler errors.

- [ ] **Step 3: Run the complete test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0 and all Swift Testing suites pass.

- [ ] **Step 4: Inspect final scope**

Run:

```bash
git status --short
git diff --check
git log --oneline 63d058d5..HEAD
```

Expected: no unstaged implementation changes, no whitespace errors, and only the planned focused commits after the design commit.

- [ ] **Step 5: Commit generated project changes if needed**

If `xcodegen` changes `Alas.xcodeproj/project.pbxproj` and it was not committed in Task 1:

```bash
git add Alas.xcodeproj/project.pbxproj
git commit -m "Regenerate project for feedback lanes"
```

If the generated project is unchanged, skip this commit.
