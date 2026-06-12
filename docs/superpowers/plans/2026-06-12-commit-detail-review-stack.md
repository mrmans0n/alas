# Commit Detail Review Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the read-only commit detail lower pane with the shared multi-file review surface: collapsible file rail on the left, stacked file diffs on the right, and the existing commit header preserved above it.

**Architecture:** Extract the current Review Changes rail, file card, scroll-spy, and surface model into generic `DiffReview` components. Review Changes becomes an adapter over the shared model with staged/unstaged source groups; `CommitTabView` gets a read-only `CommitReviewLoader` and hosts the same surface without source groups.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit-hosted diff body through `DiffPaneView`, Swift Testing, `xcodegen`, Xcode macOS test runner.

---

## File Structure

- Create `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
  - Generic IDs, source groups, file summaries, tree builder, loaded session, and conversion helpers.
- Create `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
  - Shared layout shell: rail + vertical scroll stream + scroll-spy selection.
- Create `Alas/Sources/Center/DiffReview/DiffReviewRail.swift`
  - Shared collapsible file rail, directory rows, source headers, file rows, collapsed markers.
- Create `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - Shared file card that embeds `DiffPaneView`, hides the per-file toolbar, and supports `Open File`.
- Create `Alas/Sources/Center/DiffReview/DiffReviewScrollSpy.swift`
  - Generic scroll-spy geometry and programmatic-scroll suppression.
- Create `Alas/Sources/Center/Commit/CommitReviewLoader.swift`
  - Loads all files in a commit into a `DiffReviewLoadedSession`.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesModels.swift`
  - Keep trigger summary and Review Changes compatibility aliases/adapters only.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesRail.swift`
  - Replace with a compatibility wrapper over `DiffReviewRail`.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesFileSection.swift`
  - Replace with a compatibility wrapper over `DiffReviewFileSection`.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesScrollSpy.swift`
  - Replace with compatibility aliases over `DiffReviewScrollSpy`.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift`
  - Return shared `DiffReviewLoadedSession` while preserving status/diff behavior.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
  - Host `DiffReviewSurface` through a Review Changes adapter.
- Modify `Alas/Sources/Center/Commit/CommitTabView.swift`
  - Keep `CommitHeaderView`; replace selected-file split body with `DiffReviewSurface`.
- Add/modify tests:
  - `AlasTests/DiffReviewModelsTests.swift`
  - `AlasTests/DiffReviewSurfaceTests.swift`
  - `AlasTests/ReviewChangesLoaderTests.swift`
  - `AlasTests/ReviewChangesTabViewTests.swift`
  - `AlasTests/CommitReviewLoaderTests.swift`
  - `AlasTests/CommitTabViewTests.swift`

---

### Task 1: Generic Diff Review Model And Scroll Spy

**Files:**
- Create: `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
- Create: `Alas/Sources/Center/DiffReview/DiffReviewScrollSpy.swift`
- Test: `AlasTests/DiffReviewModelsTests.swift`
- Test: `AlasTests/DiffReviewScrollSpyTests.swift`

- [ ] **Step 1: Write failing generic model tests**

Add `AlasTests/DiffReviewModelsTests.swift` with tests for identity, source grouping, ungrouped commit sessions, directory tree building, and row flattening:

```swift
import Foundation
import Testing
@testable import Alas

struct DiffReviewModelsTests {
    @Test func fileIdentityIncludesNamespaceAndPath() {
        let staged = DiffReviewFileID(namespace: "staged", path: "Sources/App.swift")
        let commit = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")

        #expect(staged.rawValue == "staged:Sources/App.swift")
        #expect(commit.rawValue == "commit:Sources/App.swift")
        #expect(staged != commit)
    }

    @Test func sessionCanOmitSourceGroupingForCommitDetails() {
        let files = [
            DiffReviewFileSummary(path: "b.swift", namespace: "commit", groupID: nil, groupTitle: nil, status: .modified, additions: 2, deletions: 1, isRenderable: true),
            DiffReviewFileSummary(path: "Sources/a.swift", namespace: "commit", groupID: nil, groupTitle: nil, status: .added, additions: 4, deletions: 0, isRenderable: true),
        ]

        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)

        #expect(session.fileCount == 2)
        #expect(session.totalAdditions == 6)
        #expect(session.totalDeletions == 1)
        #expect(session.groups.isEmpty)
        #expect(session.tree.map(\.name) == ["Sources", "b.swift"])
    }

    @Test func sessionGroupsReviewChangesBySource() {
        let files = [
            DiffReviewFileSummary(path: "a.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged", status: .modified, additions: 1, deletions: 0, isRenderable: true),
            DiffReviewFileSummary(path: "b.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged", status: .deleted, additions: 0, deletions: 3, isRenderable: false),
        ]

        let session = DiffReviewSessionModel(files: files, groupsEnabled: true)

        #expect(session.groups.map(\.id) == ["unstaged", "staged"])
        #expect(session.groups.map(\.title) == ["Unstaged", "Staged"])
        #expect(session.groups.flatMap(\.files).map(\.id.rawValue) == ["unstaged:a.swift", "staged:b.swift"])
    }

    @Test func railRowsFlattenGroupedAndUngroupedTrees() {
        let grouped = DiffReviewSessionModel(files: [
            DiffReviewFileSummary(path: "Sources/App.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged", status: .modified, additions: 1, deletions: 0, isRenderable: true),
            DiffReviewFileSummary(path: "Tests/AppTests.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged", status: .added, additions: 2, deletions: 0, isRenderable: true),
        ], groupsEnabled: true)
        let ungrouped = DiffReviewSessionModel(files: [
            DiffReviewFileSummary(path: "Sources/App.swift", namespace: "commit", groupID: nil, groupTitle: nil, status: .modified, additions: 1, deletions: 0, isRenderable: true),
            DiffReviewFileSummary(path: "Tests/AppTests.swift", namespace: "commit", groupID: nil, groupTitle: nil, status: .added, additions: 2, deletions: 0, isRenderable: true),
        ], groupsEnabled: false)

        #expect(DiffReviewRailRows.rows(for: grouped).contains { $0.id == "source:unstaged" })
        #expect(!DiffReviewRailRows.rows(for: ungrouped).contains { $0.id.hasPrefix("source:") })
        #expect(DiffReviewRailRows.rows(for: ungrouped).contains { $0.id == "file:commit:Sources/App.swift" })
    }
}
```

- [ ] **Step 2: Write failing scroll-spy tests**

Add `AlasTests/DiffReviewScrollSpyTests.swift` by copying the current `ReviewChangesScrollSpyTests` scenarios and replacing types with `DiffReviewFileID`, `DiffReviewSectionFrame`, `DiffReviewScrollSpy`, `DiffReviewActiveFileSelection`, and `DiffReviewProgrammaticScrollController`.

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewModelsTests -only-testing:AlasTests/DiffReviewScrollSpyTests test
```

Expected: FAIL because `DiffReview*` model and scroll-spy types do not exist.

- [ ] **Step 3: Implement generic model types**

Create `Alas/Sources/Center/DiffReview/DiffReviewModels.swift` with these public-internal shapes:

```swift
import Foundation

struct DiffReviewFileID: Codable, Equatable, Hashable, Identifiable {
    let namespace: String
    let path: String
    var id: String { rawValue }
    var rawValue: String { "\(namespace):\(path)" }
}

enum DiffReviewFileStatus: String, Codable, Equatable, Hashable {
    case added, modified, deleted, renamed, copied, conflicted, unknown
    var glyph: String {
        switch self {
        case .added: "+"
        case .modified: "~"
        case .deleted: "-"
        case .renamed: ">"
        case .copied: "="
        case .conflicted: "!"
        case .unknown: "?"
        }
    }
    init(gitStatus: String, conflict: ConflictKind? = nil) {
        if conflict != nil {
            self = .conflicted
            return
        }
        switch gitStatus.prefix(1).uppercased() {
        case "A": self = .added
        case "M", "T": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .conflicted
        default: self = .unknown
        }
    }
}

struct DiffReviewFileSummary: Codable, Equatable, Identifiable {
    let id: DiffReviewFileID
    let path: String
    let namespace: String
    let groupID: String?
    let groupTitle: String?
    let status: DiffReviewFileStatus
    let additions: Int
    let deletions: Int
    let isRenderable: Bool
    var originalPath: String?
    var basename: String { (path as NSString).lastPathComponent }
    var directory: String? {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty || directory == "." ? nil : directory
    }
}

struct DiffReviewFileSectionModel: Equatable, Identifiable {
    var id: DiffReviewFileID { summary.id }
    let summary: DiffReviewFileSummary
    let parsedDiff: ParsedDiff?
    let displayModel: DiffDisplayModel?
    let placeholderMessage: String?
    let openFile: (() -> Void)?
}
```

Do not make `DiffReviewFileSectionModel` conform to `Equatable` through `openFile`; implement `Equatable` manually comparing `summary`, `parsedDiff`, `displayModel`, and `placeholderMessage`.

- [ ] **Step 4: Implement session, tree, and rail rows**

In the same file, add:

```swift
struct DiffReviewSourceGroup: Equatable, Identifiable {
    let id: String
    let title: String
    let files: [DiffReviewFileSummary]
    let tree: [DiffReviewFileTreeNode]
    var fileCount: Int { files.count }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

struct DiffReviewSessionModel: Equatable {
    let files: [DiffReviewFileSummary]
    let groups: [DiffReviewSourceGroup]
    let tree: [DiffReviewFileTreeNode]
    let groupsEnabled: Bool
    init(files: [DiffReviewFileSummary], groupsEnabled: Bool) {
        self.groupsEnabled = groupsEnabled
        self.files = groupsEnabled ? files.sorted(by: Self.groupedFileOrder) : files
        self.tree = groupsEnabled ? [] : DiffReviewFileTreeBuilder.build(files: self.files)
        self.groups = groupsEnabled ? Self.buildGroups(files: self.files) : []
    }
}

struct DiffReviewLoadedSession {
    let files: [DiffReviewFileSectionModel]
    let summary: DiffReviewSessionModel
}

struct DiffReviewFileTreeNode: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case directory, file }
    var id: String {
        if let file { return "\(kind.rawValue):\(file.id.rawValue)" }
        return "\(kind.rawValue):\(path)"
    }
    let name: String
    let path: String
    let kind: Kind
    var children: [DiffReviewFileTreeNode]?
    var file: DiffReviewFileSummary?
}
enum DiffReviewFileTreeBuilder { static func build(files: [DiffReviewFileSummary]) -> [DiffReviewFileTreeNode] }
struct DiffReviewRailRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case sourceHeader(id: String, title: String, fileCount: Int)
        case directory(String, depth: Int)
        case file(DiffReviewFileSummary, depth: Int, name: String)
        case divider
    }
    let id: String
    let kind: Kind
}
enum DiffReviewRailRows { static func rows(for session: DiffReviewSessionModel) -> [DiffReviewRailRow] }
```

Sorting rules:

- Grouped sessions sort by group order `unstaged`, then `staged`, then lexical `groupID`.
- Ungrouped sessions preserve incoming commit file order for `files`, then tree children sort directories before files with localized name order.

- [ ] **Step 5: Implement generic scroll spy**

Create `Alas/Sources/Center/DiffReview/DiffReviewScrollSpy.swift` by porting `ReviewChangesSectionFrame`, `ReviewChangesScrollSpy`, `ReviewChangesActiveFileSelection`, and `ReviewChangesProgrammaticScrollController` to `DiffReviewFileID`.

- [ ] **Step 6: Run focused tests**

Regenerate the Xcode project because this task adds new Swift files:

```bash
xcodegen
```

Expected: exit 0.

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewModelsTests -only-testing:AlasTests/DiffReviewScrollSpyTests test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewModels.swift Alas/Sources/Center/DiffReview/DiffReviewScrollSpy.swift AlasTests/DiffReviewModelsTests.swift AlasTests/DiffReviewScrollSpyTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): add shared review model"
```

---

### Task 2: Shared Rail, File Section, And Surface

**Files:**
- Create: `Alas/Sources/Center/DiffReview/DiffReviewRail.swift`
- Create: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Create: `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`
- Test: `AlasTests/DiffReviewSurfaceTests.swift`

- [ ] **Step 1: Write failing shared surface tests**

Add `AlasTests/DiffReviewSurfaceTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffReviewSurfaceTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func railRendersGroupedAndUngroupedSessions() {
        var selected = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")
        var collapsed = false
        let commitSession = DiffReviewSessionModel(files: [
            summary("Sources/App.swift", namespace: "commit", groupID: nil, groupTitle: nil),
            summary("Tests/AppTests.swift", namespace: "commit", groupID: nil, groupTitle: nil),
        ], groupsEnabled: false)

        let view = DiffReviewRail(session: commitSession, selectedFileID: Binding(get: { selected }, set: { selected = $0 }), collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }), onSelectFile: { selected = $0 })
            .environment(\.theme, theme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-commit:Sources/App.swift", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-commit", in: controller.view) == nil)
    }

    @Test func fileSectionEmbedsDiffPaneWithoutToolbarAndShowsOpenFileAction() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var opened = false
        let file = DiffReviewFileSectionModel(summary: summary("Sources/App.swift", namespace: "commit", groupID: nil, groupTitle: nil), parsedDiff: parsedDiff(), displayModel: displayModel(), placeholderMessage: nil, openFile: { opened = true })

        let view = DiffReviewFileSection(file: file, layoutMode: Binding(get: { layout }, set: { layout = $0 }), wrapLines: Binding(get: { wrap }, set: { wrap = $0 }), showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }), codeFontFamily: "", codeFontSize: 13, showsSourceBadge: false)
            .environment(\.theme, theme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-commit:Sources/App.swift", in: controller.view) != nil)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Open File") != nil)
        _ = opened
    }
}
```

Include helper functions in the test file for `summary`, `parsedDiff`, `displayModel`, `subview`, `allSubviews`, and `accessibilityLabel`, matching the existing helper style in `ReviewChangesTabViewTests`.

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: FAIL because `DiffReviewRail`, `DiffReviewFileSection`, and `DiffReviewSurface` do not exist.

- [ ] **Step 3: Implement `DiffReviewRail`**

Create `Alas/Sources/Center/DiffReview/DiffReviewRail.swift` by porting `ReviewChangesRail` to `DiffReviewSessionModel` and `DiffReviewFileID`.

Required differences from Review Changes:

- Accessibility identifiers use `diff-review-*`.
- Source headers render only when `DiffReviewRailRows.rows(for:)` includes `.sourceHeader`.
- Collapsed markers use `diff-review-rail-marker-\(file.id.rawValue)`.
- File rows use `diff-review-rail-row-\(file.id.rawValue)`.

- [ ] **Step 4: Implement `DiffReviewFileSection`**

Create `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift` by porting `ReviewChangesFileSection`.

Constructor:

```swift
struct DiffReviewFileSection: View {
    let file: DiffReviewFileSectionModel
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    var showsSourceBadge: Bool = true
}
```

Rules:

- Use `DiffPaneView(model:fileExtension:layoutMode:wrapLines:showWhitespace:codeFontFamily:codeFontSize:showsToolbar:verticalScrollMode:hunkActions:)` with `showsToolbar: false` and `verticalScrollMode: .staticHeight`.
- Show source badge only when `showsSourceBadge == true` and `file.summary.groupTitle != nil`.
- Show `Open File` button when `file.openFile != nil`.
- Placeholder text uses `file.placeholderMessage`.

- [ ] **Step 5: Implement `DiffReviewSurface`**

Create `Alas/Sources/Center/DiffReview/DiffReviewSurface.swift`.

Constructor:

```swift
struct DiffReviewSurface: View {
    let session: DiffReviewLoadedSession
    @Binding var selectedFileID: DiffReviewFileID?
    @Binding var railCollapsed: Bool
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    var showsSourceBadges: Bool = true
}
```

Implementation requirements:

- Use `ScrollViewReader`.
- Place `DiffReviewRail` on the left and a vertical `ScrollView` with `LazyVStack` on the right.
- Give each `DiffReviewFileSection` `.id(file.summary.id.rawValue)`.
- Use `DiffReviewSectionFramePreferenceKey` and `DiffReviewActiveFileSelection` to update `selectedFileID`.
- Use `DiffReviewProgrammaticScrollController` to suppress scroll-spy churn during click-to-scroll.

- [ ] **Step 6: Run focused tests**

Regenerate the Xcode project because this task adds new Swift files:

```bash
xcodegen
```

Expected: exit 0.

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewRail.swift Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift Alas/Sources/Center/DiffReview/DiffReviewSurface.swift AlasTests/DiffReviewSurfaceTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(diff): add shared review surface"
```

---

### Task 3: Migrate Review Changes To Shared Surface

**Files:**
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesModels.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesRail.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesFileSection.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesScrollSpy.swift`
- Modify tests: `AlasTests/ReviewChangesModelsTests.swift`, `AlasTests/ReviewChangesLoaderTests.swift`, `AlasTests/ReviewChangesTabViewTests.swift`, `AlasTests/ReviewChangesScrollSpyTests.swift`

- [ ] **Step 1: Update tests to assert compatibility through shared types**

Update `ReviewChangesTabViewTests.fileSectionEmbedsDiffPaneWithoutPerFileToolbar` to instantiate `DiffReviewFileSection` or the compatibility wrapper and check `diff-review-file-section-*`.

Update `ReviewChangesModelsTests` so it verifies:

```swift
let session = ReviewChangesSessionModel(files: files)
#expect(session.sections.map(\.source) == [.unstaged, .staged])
#expect(session.diffReviewSession.groups.map(\.id) == ["unstaged", "staged"])
```

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests -only-testing:AlasTests/ReviewChangesTabViewTests -only-testing:AlasTests/ReviewChangesLoaderTests -only-testing:AlasTests/ReviewChangesScrollSpyTests test
```

Expected: FAIL until adapters are in place.

- [ ] **Step 2: Add Review Changes compatibility aliases/adapters**

In `ReviewChangesModels.swift`, keep `ReviewChangesTriggerSummary`, `ReviewChangesSource`, and type aliases/adapters:

```swift
typealias ReviewChangesFileID = DiffReviewFileID
typealias ReviewChangesFileStatus = DiffReviewFileStatus
typealias ReviewChangesFileSectionModel = DiffReviewFileSectionModel
typealias ReviewChangesLoadedSession = DiffReviewLoadedSession
typealias ReviewChangesFileTreeNode = DiffReviewFileTreeNode

struct ReviewChangesFileSummary: Codable, Equatable, Identifiable {
    private let storage: DiffReviewFileSummary
    var diffReviewSummary: DiffReviewFileSummary { storage }
    var id: ReviewChangesFileID { storage.id }
    var path: String { storage.path }
    var source: ReviewChangesSource { ReviewChangesSource(rawValue: storage.namespace)! }
    var status: ReviewChangesFileStatus { storage.status }
    var additions: Int { storage.additions }
    var deletions: Int { storage.deletions }
    var isRenderable: Bool { storage.isRenderable }
    var originalPath: String? { storage.originalPath }
    var basename: String { storage.basename }
    var directory: String? { storage.directory }
}
```

Do not typealias `ReviewChangesFileSummary` to `DiffReviewFileSummary`; keep the wrapper so existing Review Changes tests and code can keep reading `source`.

- [ ] **Step 3: Update `ReviewChangesLoader` to build shared section models**

Keep `ReviewChangesGitClient` unchanged. Return `DiffReviewLoadedSession` with `DiffReviewFileSummary(path: change.path, namespace: source.rawValue, groupID: source.rawValue, groupTitle: source.title, status: DiffReviewFileStatus(gitStatus: change.status, conflict: change.conflict), additions: counts.additions, deletions: counts.deletions, isRenderable: canRender, originalPath: change.renameFrom)`.

Keep these behaviors:

- Ignore conflict files.
- Sort unstaged before staged, then path.
- Pass `originalPath` to `git.diff`.
- Derive counts from parsed diffs.
- Image and empty diffs stay placeholder sections.

- [ ] **Step 4: Replace Review Changes UI body with `DiffReviewSurface`**

In `ReviewChangesTabView.reviewSurface(_:)`, replace the local `HStack`, `mainReviewStream`, `sectionFrameReader`, `scrollToFile`, and `updateSelectedFileFromScroll` implementation with:

```swift
DiffReviewSurface(
    session: session,
    selectedFileID: Binding(
        get: { selectedFileID },
        set: { selectedFileID = $0 }
    ),
    railCollapsed: $railCollapsed,
    layoutMode: diffPreferences.layoutMode,
    wrapLines: diffPreferences.wrapLines,
    showWhitespace: diffPreferences.showWhitespace,
    codeFontFamily: appState.config.code.fontFamily,
    codeFontSize: CGFloat(appState.config.code.fontSize),
    showsSourceBadges: true
)
```

Remove the now-unused local `programmaticScroll` state and local frame preference key from `ReviewChangesTabView`.

- [ ] **Step 5: Keep compatibility wrappers**

Make wrappers so any remaining Review Changes references continue to compile:

```swift
typealias ReviewChangesRail = DiffReviewRail
typealias ReviewChangesFileSection = DiffReviewFileSection
typealias ReviewChangesSectionFrame = DiffReviewSectionFrame
typealias ReviewChangesScrollSpy = DiffReviewScrollSpy
typealias ReviewChangesActiveFileSelection = DiffReviewActiveFileSelection
typealias ReviewChangesProgrammaticScrollController = DiffReviewProgrammaticScrollController
```

If no code references a wrapper file, delete the old file and let tests use `DiffReview*` names.

- [ ] **Step 6: Run focused compatibility tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests -only-testing:AlasTests/ReviewChangesTabViewTests -only-testing:AlasTests/ReviewChangesLoaderTests -only-testing:AlasTests/ReviewChangesScrollSpyTests -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/ReviewChanges Alas/Sources/Center/DiffReview AlasTests/ReviewChangesModelsTests.swift AlasTests/ReviewChangesTabViewTests.swift AlasTests/ReviewChangesLoaderTests.swift AlasTests/ReviewChangesScrollSpyTests.swift AlasTests/DiffReviewSurfaceTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "refactor(review): use shared diff review surface"
```

---

### Task 4: Commit Review Loader

**Files:**
- Create: `Alas/Sources/Center/Commit/CommitReviewLoader.swift`
- Test: `AlasTests/CommitReviewLoaderTests.swift`

- [ ] **Step 1: Write failing commit loader tests**

Add `AlasTests/CommitReviewLoaderTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct CommitReviewLoaderTests {
    @Test func loadsAllCommitFilesIntoUngroupedSessionInCommitOrder() async throws {
        let files = [
            CommitChangedFile(path: "b.swift", originalPath: nil, status: "M", add: 99, del: 99),
            CommitChangedFile(path: "a.swift", originalPath: nil, status: "A", add: 99, del: 99),
        ]
        let git = FakeCommitReviewGitClient(diffs: [
            "b.swift": diff(lines: [.init(kind: .delete, text: "old", oldNumber: 1, newNumber: nil), .init(kind: .add, text: "new", oldNumber: nil, newNumber: 1)]),
            "a.swift": diff(lines: [.init(kind: .add, text: "let a = 1", oldNumber: nil, newNumber: 1)]),
        ])
        let loader = CommitReviewLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"), sha: "abc123", files: files, openFileForPath: { path in { _ = path } })

        #expect(session.summary.groups.isEmpty)
        #expect(session.files.map(\.summary.id.rawValue) == ["commit:b.swift", "commit:a.swift"])
        #expect(session.files.map(\.summary.additions) == [1, 1])
        #expect(session.files.map(\.summary.deletions) == [1, 0])
    }

    @Test func passesOriginalPathForRenamesAndCopies() async throws {
        let file = CommitChangedFile(path: "new.swift", originalPath: "old.swift", status: "R", add: 1, del: 1)
        let git = FakeCommitReviewGitClient(diffs: [
            "new.swift|old.swift": diff(lines: [.init(kind: .add, text: "renamed", oldNumber: nil, newNumber: 1)]),
        ])
        let loader = CommitReviewLoader(git: git)

        _ = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"), sha: "abc123", files: [file], openFileForPath: { path in { _ = path } })

        #expect(git.requests == [FakeCommitReviewGitClient.Request(file: "new.swift", originalPath: "old.swift")])
    }

    @Test func keepsImagesAndEmptyDiffsAsPlaceholders() async throws {
        let files = [
            CommitChangedFile(path: "image.png", originalPath: nil, status: "M", add: 0, del: 0),
            CommitChangedFile(path: "empty.swift", originalPath: nil, status: "M", add: 0, del: 0),
        ]
        let git = FakeCommitReviewGitClient(diffs: [
            "image.png": ParsedDiff(hunks: []),
            "empty.swift": ParsedDiff(hunks: []),
        ])
        let loader = CommitReviewLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"), sha: "abc123", files: files, openFileForPath: { _ in nil })

        #expect(session.files.allSatisfy { $0.displayModel == nil })
        #expect(session.files.map(\.placeholderMessage).allSatisfy { $0 != nil })
    }
}
```

Include fake client and helper functions:

```swift
private final class FakeCommitReviewGitClient: CommitReviewGitClient {
    struct Request: Equatable { let file: String; let originalPath: String? }
    var diffs: [String: ParsedDiff]
    private(set) var requests: [Request] = []
    init(diffs: [String: ParsedDiff]) { self.diffs = diffs }
    func diff(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> ParsedDiff {
        requests.append(Request(file: file, originalPath: originalPath))
        return diffs["\(file)|\(originalPath ?? "")"] ?? diffs[file, default: ParsedDiff(hunks: [])]
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitReviewLoaderTests test
```

Expected: FAIL because `CommitReviewLoader` and `CommitReviewGitClient` do not exist.

- [ ] **Step 3: Implement `CommitReviewLoader`**

Create `Alas/Sources/Center/Commit/CommitReviewLoader.swift`:

```swift
import Foundation

protocol CommitReviewGitClient {
    func diff(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> ParsedDiff
}

extension GitService: CommitReviewGitClient {}

struct CommitReviewLoader {
    let git: CommitReviewGitClient
    init(git: CommitReviewGitClient = GitService()) { self.git = git }

    func load(
        worktreePath: URL,
        sha: String,
        files: [CommitChangedFile],
        openFileForPath: @escaping (String) -> (() -> Void)?
    ) async throws -> DiffReviewLoadedSession {
        var sections: [DiffReviewFileSectionModel] = []
        for file in files {
            try Task.checkCancellation()
            let diff = try await git.diff(worktreePath: worktreePath, sha: sha, file: file.path, originalPath: file.originalPath)
            try Task.checkCancellation()
            sections.append(try await section(for: file, diff: diff, openFile: openFileForPath(file.path)))
        }
        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }
}
```

Implement private helpers:

- `section(for:diff:openFile:)`
- `lineCounts(in:)`
- `buildDisplayModel(diff:filePath:)`
- `placeholderMessage(for:diff:)`

Rules:

- Namespace is always `"commit"`.
- `groupID` and `groupTitle` are `nil`.
- Status maps from `CommitChangedFile.status`.
- Counts come from parsed diff, not `CommitChangedFile.add/del`.
- Image-supported paths and empty diffs get placeholder sections.
- `openFileForPath` returns `nil` for files that cannot be opened from the working tree; the loader stores that optional action on the file section.

- [ ] **Step 4: Run focused loader tests**

Regenerate the Xcode project because this task adds a new Swift file:

```bash
xcodegen
```

Expected: exit 0.

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitReviewLoaderTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/Commit/CommitReviewLoader.swift AlasTests/CommitReviewLoaderTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(commit): load review stack diffs"
```

---

### Task 5: Wire Read-Only Commit Details To Shared Review Surface

**Files:**
- Modify: `Alas/Sources/Center/Commit/CommitTabView.swift`
- Test: `AlasTests/CommitTabViewTests.swift`
- Test: `AlasTests/DiffSelectableTextTests.swift`

- [ ] **Step 1: Write failing commit tab tests**

Add `AlasTests/CommitTabViewTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct CommitTabViewTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func loadedCommitBodyHostsSharedReviewSurfaceBelowHeader() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var selected: DiffReviewFileID? = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")
        var collapsed = false
        let session = DiffReviewLoadedSession(
            files: [DiffReviewFileSectionModel(summary: summary("Sources/App.swift"), parsedDiff: parsedDiff(), displayModel: displayModel(), placeholderMessage: nil, openFile: nil)],
            summary: DiffReviewSessionModel(files: [summary("Sources/App.swift")], groupsEnabled: false)
        )

        let body = CommitReviewBody(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            railCollapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: body)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "commit-review-body", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-commit:Sources/App.swift", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-commit:Sources/App.swift", in: controller.view) != nil)
    }
}
```

This test targets `CommitReviewBody`, a small extracted view from `CommitTabView`, so it can be hosted without waiting for async git loading.

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitTabViewTests test
```

Expected: FAIL because `CommitReviewBody` does not exist.

- [ ] **Step 3: Refactor `CommitTabView` state**

In `CommitTabView.swift`, remove selected-file diff state:

- `selectedPath`
- `diff`
- `displayModel`
- `displayModelKey`
- `loadingDiff`
- `diffError`
- `activeDiffKey`
- `diffTaskKey`
- `.task(id: diffTaskKey)`
- `loadDiffIfNeeded()`
- `splitBody(details:)`

Add review session state:

```swift
@State private var reviewSession: DiffReviewLoadedSession?
@State private var loadingReviewSession = false
@State private var reviewSessionError: String?
@State private var selectedReviewFileID: DiffReviewFileID?
@State private var railCollapsed = false
@State private var activeReviewKey: String?
private let reviewLoader = CommitReviewLoader()
```

- [ ] **Step 4: Add `CommitReviewBody`**

In `CommitTabView.swift`, below `CommitTabView`, add:

```swift
struct CommitReviewBody: View {
    let session: DiffReviewLoadedSession
    @Binding var selectedFileID: DiffReviewFileID?
    @Binding var railCollapsed: Bool
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat

    var body: some View {
        DiffReviewSurface(
            session: session,
            selectedFileID: $selectedFileID,
            railCollapsed: $railCollapsed,
            layoutMode: $layoutMode,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace,
            codeFontFamily: codeFontFamily,
            codeFontSize: codeFontSize,
            showsSourceBadges: false
        )
        .accessibilityIdentifier("commit-review-body")
    }
}
```

- [ ] **Step 5: Wire loaded details to review session**

After `details` loads successfully, call a new `loadReviewSession(details:)` from the same `.task(id: sha)` flow, or add `.task(id: reviewTaskKey)` after details state is assigned. Required behavior:

```swift
private func loadReviewSession(details: CommitDetails) async {
    let requestedKey = "\(sha)\u{0}\(details.files.map(\.path).joined(separator: "\u{1f}"))"
    activeReviewKey = requestedKey
    loadingReviewSession = true
    reviewSessionError = nil
    reviewSession = nil
    defer { if activeReviewKey == requestedKey { loadingReviewSession = false } }
    do {
        let loaded = try await reviewLoader.load(
            worktreePath: worktreePath,
            sha: sha,
            files: details.files,
            openFileForPath: { path in
                guard DiffOpenFileAvailability.isAvailable(worktreePath: worktreePath, relativePath: path) else {
                    return nil
                }
                return {
                    Task { @MainActor in appState.openFile(relativePath: path, worktreeId: worktreeId) }
                }
            }
        )
        guard !Task.isCancelled, activeReviewKey == requestedKey else { return }
        reviewSession = loaded
        selectedReviewFileID = selectedReviewFileID.flatMap { selected in
            loaded.summary.files.contains { $0.id == selected } ? selected : loaded.summary.files.first?.id
        } ?? loaded.summary.files.first?.id
    } catch {
        guard !Task.isCancelled, activeReviewKey == requestedKey else { return }
        reviewSessionError = (error as NSError).localizedDescription
    }
}
```

Only set `openFile` closures for paths where `DiffOpenFileAvailability.isAvailable(worktreePath:relativePath:)` returns true.

- [ ] **Step 6: Render commit body states**

In `body`, keep:

```swift
CommitHeaderView(details: details, expanded: $headerExpanded)
commitReviewContent(details: details)
```

Add `commitReviewContent(details:)`:

```swift
@ViewBuilder
private func commitReviewContent(details: CommitDetails) -> some View {
    if loadingReviewSession {
        Spinner().frame(width: 20, height: 20).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let reviewSessionError {
        VStack(spacing: 8) {
            Text("Could not load commit diffs")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("del"))
            Text(reviewSessionError)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(3)
            AlasButton(title: "Retry", style: .subtle) {
                Task { await loadReviewSession(details: details) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let reviewSession, !reviewSession.files.isEmpty {
        CommitReviewBody(
            session: reviewSession,
            selectedFileID: $selectedReviewFileID,
            railCollapsed: $railCollapsed,
            layoutMode: diffPreferences.layoutMode,
            wrapLines: diffPreferences.wrapLines,
            showWhitespace: diffPreferences.showWhitespace,
            codeFontFamily: appState.config.code.fontFamily,
            codeFontSize: CGFloat(appState.config.code.fontSize)
        )
    } else {
        Text("No files changed in this commit")
            .foregroundColor(theme.color("fg-dim"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 7: Preserve editor/draft commit behavior**

Run the existing `CommitDiffView` integration tests:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffSelectableTextTests test
```

Expected: PASS. Do not migrate `CommitEditorTabView` or `DraftCommitTabView` in this task.

- [ ] **Step 8: Run focused commit tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitTabViewTests -only-testing:AlasTests/CommitReviewLoaderTests -only-testing:AlasTests/DiffSelectableTextTests test
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Alas/Sources/Center/Commit/CommitTabView.swift AlasTests/CommitTabViewTests.swift
git commit -m "feat(commit): show review stack in commit details"
```

---

### Task 6: Final Integration Verification

**Files:**
- Modify only files required by compile/test failures found during verification.

- [ ] **Step 1: Regenerate project**

Run:

```bash
xcodegen
```

Expected: exit 0.

- [ ] **Step 2: Run focused suites**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffReviewModelsTests -only-testing:AlasTests/DiffReviewScrollSpyTests -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/ReviewChangesModelsTests -only-testing:AlasTests/ReviewChangesTabViewTests -only-testing:AlasTests/ReviewChangesLoaderTests -only-testing:AlasTests/ReviewChangesScrollSpyTests -only-testing:AlasTests/CommitReviewLoaderTests -only-testing:AlasTests/CommitTabViewTests -only-testing:AlasTests/DiffSelectableTextTests test
```

Expected: exit 0.

- [ ] **Step 3: Run quiet app build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0. If a known unrelated flaky test fails, rerun that exact test once, record the result, and do not claim full-suite success unless the full suite exits 0.

- [ ] **Step 5: Final commit if verification required code changes**

If verification required fixes after Task 5, stage the exact files changed by those fixes and commit them. Example for a compile fix in the commit tab:

```bash
git add Alas/Sources/Center/Commit/CommitTabView.swift AlasTests/CommitTabViewTests.swift
git commit -m "fix(commit): harden commit review stack"
```

If no files changed during verification, do not create an empty commit.
