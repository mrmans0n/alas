# Multi-File Review Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a diffs.com-quality `Review Changes` tab with a collapsible left file rail and one scroll-synced multi-file diff stream.

**Architecture:** Add pure review-session models and scroll-spy controllers first, then persistent tab state, then a loader that converts local git changes into per-file `DiffDisplayModel`s. The UI composes a session-level toolbar, collapsible rail, and file sections that reuse the existing AppKit-backed `DiffPaneView` without repeating per-file toolbar chrome.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit-hosted diff text, Swift Testing, existing `GitService`, `ParsedDiff`, `DiffDisplayModelBuilder`, `TabsManager`, `AppState`.

---

## File Structure

- Create `Alas/Sources/Center/ReviewChanges/ReviewChangesModels.swift`
  - Pure value models: source, status, file id, file item, file tree, session.
  - File-tree builder with directory-chain flattening.
- Create `Alas/Sources/Center/ReviewChanges/ReviewChangesScrollSpy.swift`
  - Pure scroll-spy active-file picker and programmatic-scroll suppression controller.
- Create `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift`
  - Async loader that gathers `GitService.status`, fetches per-file diffs, builds `DiffDisplayModel`s, and marks unsupported/image placeholder sections.
- Create `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
  - Top-level tab UI, loading/error/empty state, session toolbar, rail + stream layout, scroll sync.
- Create `Alas/Sources/Center/ReviewChanges/ReviewChangesRail.swift`
  - Collapsible left rail and tree rows.
- Create `Alas/Sources/Center/ReviewChanges/ReviewChangesFileSection.swift`
  - Sticky file header and per-file body wrapper around `DiffPaneView` or placeholders.
- Modify `Alas/Sources/Center/Tab.swift`
  - Add `ReviewChangesTabState` and `Tab.reviewChanges`.
- Modify `Alas/Sources/Center/TabsManager.swift`
  - Add `openOrFocusReviewChanges(worktreeId:)`.
- Modify `Alas/Sources/App/AppState.swift`
  - Add `openReviewChangesTab(for:)`.
- Modify `Alas/Sources/Center/CenterPaneView.swift`
  - Render `ReviewChangesTabView`.
- Modify `Alas/Sources/Center/Diff/DiffPaneView.swift`
  - Add an option to hide the internal toolbar for embedded file sections.
- Modify `Alas/Sources/Right/ChangesTabView.swift`
  - Add the `Review Changes` entry point.
- Add tests:
  - `AlasTests/ReviewChangesModelsTests.swift`
  - `AlasTests/ReviewChangesScrollSpyTests.swift`
  - `AlasTests/ReviewChangesLoaderTests.swift`
  - `AlasTests/ReviewChangesTabViewTests.swift`
  - Extend `AlasTests/TabsManagerTests.swift`
  - Extend `AlasTests/DiffPaneViewTests.swift`

New source files under `Alas/Sources` require `xcodegen` before Xcode builds can see them.

---

### Task 1: Pure Review Session Models

**Files:**
- Create: `Alas/Sources/Center/ReviewChanges/ReviewChangesModels.swift`
- Test: `AlasTests/ReviewChangesModelsTests.swift`

- [ ] **Step 1: Write failing model/tree tests**

Add `AlasTests/ReviewChangesModelsTests.swift`:

```swift
import Testing
@testable import Alas

struct ReviewChangesModelsTests {
    @Test func fileIdentityIncludesSourceAndPath() {
        let unstaged = ReviewChangesFileID(source: .unstaged, path: "Sources/App.swift")
        let staged = ReviewChangesFileID(source: .staged, path: "Sources/App.swift")

        #expect(unstaged.rawValue == "unstaged:Sources/App.swift")
        #expect(staged.rawValue == "staged:Sources/App.swift")
        #expect(unstaged != staged)
    }

    @Test func buildsFlattenedDirectoryTreeWithDirectoriesBeforeFiles() {
        let files = [
            ReviewChangesFileSummary(
                id: .init(source: .unstaged, path: "Sources/Center/DiffPaneView.swift"),
                path: "Sources/Center/DiffPaneView.swift",
                source: .unstaged,
                status: .modified,
                additions: 12,
                deletions: 3,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                id: .init(source: .unstaged, path: "README.md"),
                path: "README.md",
                source: .unstaged,
                status: .added,
                additions: 4,
                deletions: 0,
                isRenderable: true
            ),
        ]

        let tree = ReviewChangesFileTreeBuilder.build(files: files)

        #expect(tree.map(\.name) == ["Sources/Center", "README.md"])
        #expect(tree[0].kind == .directory)
        #expect(tree[0].path == "Sources/Center")
        #expect(tree[0].children?.map(\.name) == ["DiffPaneView.swift"])
        #expect(tree[0].children?.first?.file?.path == "Sources/Center/DiffPaneView.swift")
    }

    @Test func sessionTotalsIncludeAllFiles() {
        let files = [
            ReviewChangesFileSummary(
                id: .init(source: .unstaged, path: "a.swift"),
                path: "a.swift",
                source: .unstaged,
                status: .modified,
                additions: 3,
                deletions: 1,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                id: .init(source: .staged, path: "b.swift"),
                path: "b.swift",
                source: .staged,
                status: .deleted,
                additions: 0,
                deletions: 5,
                isRenderable: false
            ),
        ]

        let session = ReviewChangesSessionModel(files: files)

        #expect(session.fileCount == 2)
        #expect(session.totalAdditions == 3)
        #expect(session.totalDeletions == 6)
        #expect(session.sections.map(\.source) == [.unstaged, .staged])
    }
}
```

- [ ] **Step 2: Run tests red**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests test
```

Expected: FAIL because `ReviewChangesFileID`, `ReviewChangesFileSummary`, `ReviewChangesFileTreeBuilder`, and `ReviewChangesSessionModel` do not exist.

- [ ] **Step 3: Implement pure models**

Create `Alas/Sources/Center/ReviewChanges/ReviewChangesModels.swift`:

```swift
import Foundation

struct ReviewChangesFileID: Codable, Equatable, Hashable, Identifiable {
    let source: ReviewChangesSource
    let path: String

    var id: String { rawValue }
    var rawValue: String { "\(source.rawValue):\(path)" }
}

enum ReviewChangesSource: String, Codable, Equatable, Hashable, Comparable {
    case unstaged
    case staged

    var title: String {
        switch self {
        case .unstaged: return "Unstaged"
        case .staged: return "Staged"
        }
    }

    static func < (lhs: ReviewChangesSource, rhs: ReviewChangesSource) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .unstaged: return 0
        case .staged: return 1
        }
    }
}

enum ReviewChangesFileStatus: String, Codable, Equatable, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case conflicted
    case unknown

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

    var glyph: String {
        switch self {
        case .added: return "+"
        case .modified: return "~"
        case .deleted: return "-"
        case .renamed: return ">"
        case .copied: return "="
        case .conflicted: return "!"
        case .unknown: return "?"
        }
    }
}

struct ReviewChangesFileSummary: Codable, Equatable, Identifiable {
    let id: ReviewChangesFileID
    let path: String
    let source: ReviewChangesSource
    let status: ReviewChangesFileStatus
    let additions: Int
    let deletions: Int
    let isRenderable: Bool
    var originalPath: String? = nil

    var basename: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct ReviewChangesFileSectionModel: Equatable, Identifiable {
    let summary: ReviewChangesFileSummary
    let parsedDiff: ParsedDiff?
    let displayModel: DiffDisplayModel?
    let placeholderMessage: String?

    var id: ReviewChangesFileID { summary.id }
}

struct ReviewChangesSourceSection: Equatable, Identifiable {
    let source: ReviewChangesSource
    let files: [ReviewChangesFileSummary]

    var id: ReviewChangesSource { source }
}

struct ReviewChangesSessionModel: Equatable {
    let files: [ReviewChangesFileSummary]

    var fileCount: Int { files.count }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    var sections: [ReviewChangesSourceSection] {
        Dictionary(grouping: files, by: \.source)
            .keys
            .sorted()
            .compactMap { source in
                let sourceFiles = files.filter { $0.source == source }
                guard !sourceFiles.isEmpty else { return nil }
                return ReviewChangesSourceSection(source: source, files: sourceFiles)
            }
    }
}

struct ReviewChangesLoadedSession: Equatable {
    let files: [ReviewChangesFileSectionModel]

    var summary: ReviewChangesSessionModel {
        ReviewChangesSessionModel(files: files.map(\.summary))
    }
}

struct ReviewChangesFileTreeNode: Equatable, Identifiable {
    enum Kind: Equatable { case directory, file }

    let id: String
    let name: String
    let path: String
    let kind: Kind
    let children: [ReviewChangesFileTreeNode]?
    let file: ReviewChangesFileSummary?
}

enum ReviewChangesFileTreeBuilder {
    private final class BuildNode {
        let name: String
        let path: String
        let isDirectory: Bool
        var file: ReviewChangesFileSummary?
        var children: [String: BuildNode] = [:]

        init(name: String, path: String, isDirectory: Bool, file: ReviewChangesFileSummary?) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
            self.file = file
        }
    }

    static func build(files: [ReviewChangesFileSummary]) -> [ReviewChangesFileTreeNode] {
        var roots: [String: BuildNode] = [:]
        for file in files {
            let parts = normalizedParts(file.path)
            insert(parts: parts, file: file, into: &roots, prefix: "")
        }
        return compact(finalize(roots)).sorted(by: nodeOrder)
    }

    private static func normalizedParts(_ path: String) -> [String] {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
    }

    private static func insert(
        parts: [String],
        file: ReviewChangesFileSummary,
        into map: inout [String: BuildNode],
        prefix: String
    ) {
        guard let head = parts.first else { return }
        let isLeaf = parts.count == 1
        let path = prefix.isEmpty ? head : "\(prefix)/\(head)"
        let key = "\(isLeaf ? "file" : "dir"):\(head)"

        if isLeaf {
            map[key] = BuildNode(name: head, path: file.path, isDirectory: false, file: file)
        } else {
            let node = map[key] ?? BuildNode(name: head, path: path, isDirectory: true, file: nil)
            map[key] = node
            insert(parts: Array(parts.dropFirst()), file: file, into: &node.children, prefix: path)
        }
    }

    private static func finalize(_ map: [String: BuildNode]) -> [ReviewChangesFileTreeNode] {
        map.values.map { node in
            let children = node.isDirectory ? finalize(node.children).sorted(by: nodeOrder) : nil
            return ReviewChangesFileTreeNode(
                id: "\(node.isDirectory ? "dir" : "file"):\(node.path)",
                name: node.name,
                path: node.path,
                kind: node.isDirectory ? .directory : .file,
                children: children,
                file: node.file
            )
        }
    }

    private static func compact(_ nodes: [ReviewChangesFileTreeNode]) -> [ReviewChangesFileTreeNode] {
        nodes.map { node in
            guard node.kind == .directory else { return node }
            var current = ReviewChangesFileTreeNode(
                id: node.id,
                name: node.name,
                path: node.path,
                kind: .directory,
                children: compact(node.children ?? []),
                file: nil
            )
            while current.children?.count == 1,
                  let child = current.children?.first,
                  child.kind == .directory {
                current = ReviewChangesFileTreeNode(
                    id: "dir:\(child.path)",
                    name: "\(current.name)/\(child.name)",
                    path: child.path,
                    kind: .directory,
                    children: child.children,
                    file: nil
                )
            }
            return current
        }
    }

    private static func nodeOrder(_ lhs: ReviewChangesFileTreeNode, _ rhs: ReviewChangesFileTreeNode) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .directory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
```

- [ ] **Step 4: Regenerate project and run tests green**

Run:

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesModelsTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/ReviewChanges/ReviewChangesModels.swift AlasTests/ReviewChangesModelsTests.swift Alas.xcodeproj
git commit -m "feat(diff): add review changes model"
```

---

### Task 2: Scroll-Spy Controller

**Files:**
- Create: `Alas/Sources/Center/ReviewChanges/ReviewChangesScrollSpy.swift`
- Test: `AlasTests/ReviewChangesScrollSpyTests.swift`

- [ ] **Step 1: Write failing scroll-spy tests**

Add `AlasTests/ReviewChangesScrollSpyTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import Alas

struct ReviewChangesScrollSpyTests {
    @Test func picksVisibleSectionNearestViewportTopFromBelow() {
        let frames = [
            ReviewChangesSectionFrame(id: .init(source: .unstaged, path: "a.swift"), minY: -180, maxY: 200),
            ReviewChangesSectionFrame(id: .init(source: .unstaged, path: "b.swift"), minY: 24, maxY: 360),
            ReviewChangesSectionFrame(id: .init(source: .unstaged, path: "c.swift"), minY: 380, maxY: 720),
        ]

        let active = ReviewChangesScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(active?.path == "b.swift")
    }

    @Test func keepsLongFileActiveWhenItsTopHasScrolledAboveViewport() {
        let frames = [
            ReviewChangesSectionFrame(id: .init(source: .unstaged, path: "large.swift"), minY: -500, maxY: 700),
            ReviewChangesSectionFrame(id: .init(source: .unstaged, path: "next.swift"), minY: 760, maxY: 1000),
        ]

        let active = ReviewChangesScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(active?.path == "large.swift")
    }

    @Test func ignoresNonIntersectingSections() {
        let frames = [
            ReviewChangesSectionFrame(id: .init(source: .unstaged, path: "above.swift"), minY: -400, maxY: -20),
            ReviewChangesSectionFrame(id: .init(source: .unstaged, path: "below.swift"), minY: 520, maxY: 700),
        ]

        let active = ReviewChangesScrollSpy.activeFile(in: frames, viewportMinY: 0, viewportMaxY: 500)

        #expect(active == nil)
    }

    @Test func suppressionIgnoresUpdatesUntilReleased() {
        var controller = ReviewChangesProgrammaticScrollController()
        let first = ReviewChangesFileID(source: .unstaged, path: "a.swift")
        let second = ReviewChangesFileID(source: .unstaged, path: "b.swift")

        #expect(controller.acceptsScrollSpyUpdate(for: first))
        controller.beginProgrammaticScroll(to: second)
        #expect(!controller.acceptsScrollSpyUpdate(for: first))
        #expect(controller.acceptsScrollSpyUpdate(for: second))
        controller.finishProgrammaticScroll()
        #expect(controller.acceptsScrollSpyUpdate(for: first))
    }
}
```

- [ ] **Step 2: Run tests red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesScrollSpyTests test
```

Expected: FAIL because scroll-spy types do not exist.

- [ ] **Step 3: Implement scroll-spy types**

Create `Alas/Sources/Center/ReviewChanges/ReviewChangesScrollSpy.swift`:

```swift
import CoreGraphics
import Foundation

struct ReviewChangesSectionFrame: Equatable {
    let id: ReviewChangesFileID
    let minY: CGFloat
    let maxY: CGFloat

    func intersects(viewportMinY: CGFloat, viewportMaxY: CGFloat) -> Bool {
        maxY > viewportMinY && minY < viewportMaxY
    }
}

enum ReviewChangesScrollSpy {
    static func activeFile(
        in frames: [ReviewChangesSectionFrame],
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> ReviewChangesFileID? {
        let visible = frames.filter { $0.intersects(viewportMinY: viewportMinY, viewportMaxY: viewportMaxY) }
        guard !visible.isEmpty else { return nil }

        let atOrBelowTop = visible
            .filter { $0.minY >= viewportMinY }
            .sorted { lhs, rhs in
                (lhs.minY - viewportMinY) < (rhs.minY - viewportMinY)
            }
        if let first = atOrBelowTop.first {
            return first.id
        }

        return visible
            .sorted { lhs, rhs in
                (viewportMinY - lhs.minY) < (viewportMinY - rhs.minY)
            }
            .first?
            .id
    }
}

struct ReviewChangesProgrammaticScrollController: Equatable {
    private(set) var target: ReviewChangesFileID?

    var isSuppressing: Bool { target != nil }

    mutating func beginProgrammaticScroll(to id: ReviewChangesFileID) {
        target = id
    }

    mutating func finishProgrammaticScroll() {
        target = nil
    }

    func acceptsScrollSpyUpdate(for id: ReviewChangesFileID) -> Bool {
        guard let target else { return true }
        return target == id
    }
}
```

- [ ] **Step 4: Regenerate project and run tests green**

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesScrollSpyTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/ReviewChanges/ReviewChangesScrollSpy.swift AlasTests/ReviewChangesScrollSpyTests.swift Alas.xcodeproj
git commit -m "feat(diff): add review scroll spy"
```

---

### Task 3: Persistent Review Changes Tab

**Files:**
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Create placeholder: `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
- Test: extend `AlasTests/TabsManagerTests.swift`

- [ ] **Step 1: Write failing tab persistence tests**

Append to `TabsManagerTests`:

```swift
@Test func openOrFocusReviewChangesCreatesStableWorktreeScopedTab() {
    let worktreeId = "tabs-manager-review-changes"
    defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
    let mgr = TabsManager()

    let first = mgr.openOrFocusReviewChanges(worktreeId: worktreeId)
    let second = mgr.openOrFocusReviewChanges(worktreeId: worktreeId)

    #expect(first.id == "review-changes:\(worktreeId)")
    #expect(second.id == first.id)
    #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
    #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
    #expect(first.title == "Review Changes")
}

@Test func reviewChangesTabStateRoundTrips() throws {
    let state = ReviewChangesTabState(worktreeId: "wt")
    let tab = Tab.reviewChanges(state)

    let data = try JSONEncoder().encode(tab)
    let decoded = try JSONDecoder().decode(Tab.self, from: data)

    #expect(decoded == tab)
    #expect(decoded.title == "Review Changes")
    #expect(decoded.iconName == "diff")
}
```

- [ ] **Step 2: Run tests red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerTests/openOrFocusReviewChangesCreatesStableWorktreeScopedTab -only-testing:AlasTests/TabsManagerTests/reviewChangesTabStateRoundTrips test
```

Expected: FAIL because the tab state and manager method do not exist.

- [ ] **Step 3: Add tab state and manager method**

In `Alas/Sources/Center/Tab.swift`:

```swift
enum Tab: Codable, Equatable, Identifiable {
    case terminal(TerminalTabState)
    case editor(EditorTabState)
    case diff(DiffTabState)
    case reviewChanges(ReviewChangesTabState)
    case commit(CommitTabState)
    ...
}

struct ReviewChangesTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String

    init(worktreeId: String) {
        self.id = "review-changes:\(worktreeId)"
        self.worktreeId = worktreeId
    }
}
```

Update `Tab.id`, `Tab.title`, and `Tab.iconName`:

```swift
case .reviewChanges(let s): return s.id
case .reviewChanges: return "Review Changes"
case .reviewChanges: return "diff"
```

In `TabsManager.swift`, add:

```swift
@discardableResult
func openOrFocusReviewChanges(worktreeId: String) -> Tab {
    let state = ReviewChangesTabState(worktreeId: worktreeId)
    if var file = byWorktree[worktreeId],
       let existing = file.tabs.first(where: {
           if case .reviewChanges(let s) = $0 { return s.id == state.id }
           return false
       }) {
        file.activeTabId = existing.id
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return existing
    }
    let tab = Tab.reviewChanges(state)
    append(tab, to: worktreeId)
    return tab
}
```

In `AppState.swift`, add near `openDiffTab`:

```swift
func openReviewChangesTab(for worktree: Worktree) {
    _ = tabs.openOrFocusReviewChanges(worktreeId: worktree.id)
}
```

- [ ] **Step 4: Add a compiling placeholder view and CenterPane switch case**

Create `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`:

```swift
import SwiftUI

struct ReviewChangesTabView: View {
    let worktree: Worktree
    let tabState: ReviewChangesTabState
    let appState: AppState

    @Environment(\.theme) private var theme

    var body: some View {
        Text("Review Changes")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.color("fg"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color("bg-1"))
    }
}
```

In `CenterPaneView`, add:

```swift
case .reviewChanges(let reviewState):
    ReviewChangesTabView(
        worktree: worktree,
        tabState: reviewState,
        appState: state
    )
    .id(reviewState.id)
```

- [ ] **Step 5: Regenerate project and run tests green**

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerTests/openOrFocusReviewChangesCreatesStableWorktreeScopedTab -only-testing:AlasTests/TabsManagerTests/reviewChangesTabStateRoundTrips test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift Alas/Sources/App/AppState.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift AlasTests/TabsManagerTests.swift Alas.xcodeproj
git commit -m "feat(diff): add review changes tab state"
```

---

### Task 4: Review Changes Loader

**Files:**
- Create: `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift`
- Test: `AlasTests/ReviewChangesLoaderTests.swift`

- [ ] **Step 1: Write failing loader aggregation tests**

Add `AlasTests/ReviewChangesLoaderTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct ReviewChangesLoaderTests {
    @Test func buildsSectionsForStagedAndUnstagedTextDiffs() async throws {
        let git = FakeReviewChangesGitClient(
            statusFiles: [
                ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 2, del: 1, renameFrom: nil),
                ChangedFile(path: "b.swift", status: "A", stage: .staged, add: 1, del: 0, renameFrom: nil),
            ],
            diffs: [
                "unstaged:a.swift": ParsedDiff(hunks: [
                    ParsedDiff.Hunk(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
                        .init(kind: .delete, text: "old", oldNumber: 1, newNumber: nil),
                        .init(kind: .add, text: "new", oldNumber: nil, newNumber: 1),
                    ])
                ]),
                "staged:b.swift": ParsedDiff(hunks: [
                    ParsedDiff.Hunk(header: "@@ -0,0 +1 @@", oldStart: 0, newStart: 1, lines: [
                        .init(kind: .add, text: "added", oldNumber: nil, newNumber: 1),
                    ])
                ]),
            ]
        )
        let loader = ReviewChangesLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        #expect(session.files.map(\.summary.id.rawValue) == ["unstaged:a.swift", "staged:b.swift"])
        #expect(session.files[0].displayModel?.filePath == "a.swift")
        #expect(session.files[1].displayModel?.filePath == "b.swift")
        #expect(session.summary.sections.map(\.source) == [.unstaged, .staged])
    }

    @Test func keepsUnsupportedFilesVisibleAsPlaceholders() async throws {
        let git = FakeReviewChangesGitClient(
            statusFiles: [
                ChangedFile(path: "image.png", status: "M", stage: .unstaged, add: 0, del: 0, renameFrom: nil),
            ],
            diffs: ["unstaged:image.png": ParsedDiff(hunks: [])]
        )
        let loader = ReviewChangesLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        #expect(session.files.count == 1)
        #expect(session.files[0].summary.path == "image.png")
        #expect(session.files[0].summary.isRenderable == false)
        #expect(session.files[0].placeholderMessage != nil)
    }
}

private struct FakeReviewChangesGitClient: ReviewChangesGitClient {
    let statusFiles: [ChangedFile]
    let diffs: [String: ParsedDiff]

    func status(worktreePath: URL) async throws -> [ChangedFile] {
        statusFiles
    }

    func diff(worktreePath: URL, file: String, staged: Bool) async throws -> ParsedDiff {
        diffs["\(staged ? "staged" : "unstaged"):\(file)"] ?? ParsedDiff(hunks: [])
    }
}
```

- [ ] **Step 2: Run tests red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesLoaderTests test
```

Expected: FAIL because `ReviewChangesLoader` and `ReviewChangesGitClient` do not exist.

- [ ] **Step 3: Implement loader with injectable git client**

Create `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift`:

```swift
import Foundation

protocol ReviewChangesGitClient {
    func status(worktreePath: URL) async throws -> [ChangedFile]
    func diff(worktreePath: URL, file: String, staged: Bool) async throws -> ParsedDiff
}

extension GitService: ReviewChangesGitClient {}

struct ReviewChangesLoader {
    let git: ReviewChangesGitClient

    init(git: ReviewChangesGitClient = GitService()) {
        self.git = git
    }

    func load(worktreePath: URL) async throws -> ReviewChangesLoadedSession {
        let changes = try await git.status(worktreePath: worktreePath)
            .filter { $0.conflict == nil }
            .sorted(by: changeOrder)

        var sections: [ReviewChangesFileSectionModel] = []
        for change in changes {
            try Task.checkCancellation()
            let source = ReviewChangesSource(change.stage)
            let summaryBase = ReviewChangesFileSummary(
                id: ReviewChangesFileID(source: source, path: change.path),
                path: change.path,
                source: source,
                status: ReviewChangesFileStatus(gitStatus: change.status, conflict: change.conflict),
                additions: change.add,
                deletions: change.del,
                isRenderable: true,
                originalPath: change.renameFrom
            )

            let diff = try await git.diff(
                worktreePath: worktreePath,
                file: change.path,
                staged: change.stage == .staged
            )
            try Task.checkCancellation()

            guard !diff.hunks.isEmpty, !ImageFileType.isSupported(relativePath: change.path) else {
                let summary = ReviewChangesFileSummary(
                    id: summaryBase.id,
                    path: summaryBase.path,
                    source: summaryBase.source,
                    status: summaryBase.status,
                    additions: summaryBase.additions,
                    deletions: summaryBase.deletions,
                    isRenderable: false,
                    originalPath: summaryBase.originalPath
                )
                sections.append(
                    ReviewChangesFileSectionModel(
                        summary: summary,
                        parsedDiff: diff,
                        displayModel: nil,
                        placeholderMessage: ImageFileType.isSupported(relativePath: change.path)
                            ? "Image diff preview is not available in multi-file review yet."
                            : "No textual diff is available for this file."
                    )
                )
                continue
            }

            let display = DiffDisplayModelBuilder.build(diff: diff, filePath: change.path)
            sections.append(
                ReviewChangesFileSectionModel(
                    summary: summaryBase,
                    parsedDiff: diff,
                    displayModel: display,
                    placeholderMessage: nil
                )
            )
        }

        return ReviewChangesLoadedSession(files: sections)
    }

    private func changeOrder(_ lhs: ChangedFile, _ rhs: ChangedFile) -> Bool {
        let lhsSource = ReviewChangesSource(lhs.stage)
        let rhsSource = ReviewChangesSource(rhs.stage)
        if lhsSource != rhsSource { return lhsSource < rhsSource }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}

private extension ReviewChangesSource {
    init(_ stage: ChangeStage) {
        switch stage {
        case .unstaged: self = .unstaged
        case .staged: self = .staged
        }
    }
}
```

- [ ] **Step 4: Regenerate project and run tests green**

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesLoaderTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift AlasTests/ReviewChangesLoaderTests.swift Alas.xcodeproj
git commit -m "feat(diff): load review changes session"
```

---

### Task 5: Embed DiffPaneView Without Per-File Toolbar

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift`
- Test: extend `AlasTests/DiffPaneViewTests.swift`

- [ ] **Step 1: Write failing toolbar visibility test**

Append to `DiffPaneViewTests`:

```swift
@Test func embeddedModeHidesDiffToolbar() {
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false
    let view = DiffPaneView(
        model: model(),
        fileExtension: "swift",
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsToolbar: false,
        hunkActions: { _ in DiffPaneHunkActions() }
    )
    .environment(\.theme, theme())

    let controller = NSHostingController(rootView: view)
    controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
    controller.view.layoutSubtreeIfNeeded()

    let buttonTitles = allSubviews(of: controller.view)
        .compactMap { ($0 as? NSButton)?.title }

    #expect(!buttonTitles.contains("Split"))
    #expect(!buttonTitles.contains("Stacked"))
}
```

- [ ] **Step 2: Run test red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests/embeddedModeHidesDiffToolbar test
```

Expected: FAIL because `showsToolbar` is not a `DiffPaneView` parameter.

- [ ] **Step 3: Add `showsToolbar` with default true**

In `DiffPaneView` add:

```swift
let showsToolbar: Bool
```

Update the initializer member order by adding a defaulted stored-property parameter where the struct is constructed:

```swift
let codeFontSize: CGFloat
var showsToolbar: Bool = true
let hunkActions: (ParsedDiff.Hunk) -> DiffPaneHunkActions
```

Update `body`:

```swift
VStack(spacing: 0) {
    if showsToolbar {
        toolbar
    }
    diffBody
}
```

Keep all existing `DiffPaneView` call sites compiling because `showsToolbar` defaults to `true`.

- [ ] **Step 4: Run focused tests green**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests/embeddedModeHidesDiffToolbar -only-testing:AlasTests/DiffPaneViewTests/splitModeHostsRendererWithoutCrashing test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/DiffPaneViewTests.swift
git commit -m "feat(diff): allow embedded diff panes"
```

---

### Task 6: Review Changes UI, Rail, and Scroll Sync

**Files:**
- Replace placeholder: `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
- Create: `Alas/Sources/Center/ReviewChanges/ReviewChangesRail.swift`
- Create: `Alas/Sources/Center/ReviewChanges/ReviewChangesFileSection.swift`
- Test: `AlasTests/ReviewChangesTabViewTests.swift`

- [ ] **Step 1: Write failing hosted view tests**

Add `AlasTests/ReviewChangesTabViewTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct ReviewChangesTabViewTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func railRendersFilesAndCollapsedStateKeepsMarkers() throws {
        let files = [
            ReviewChangesFileSummary(
                id: .init(source: .unstaged, path: "Sources/App.swift"),
                path: "Sources/App.swift",
                source: .unstaged,
                status: .modified,
                additions: 3,
                deletions: 1,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                id: .init(source: .staged, path: "Tests/AppTests.swift"),
                path: "Tests/AppTests.swift",
                source: .staged,
                status: .added,
                additions: 5,
                deletions: 0,
                isRenderable: true
            ),
        ]
        var collapsed = false
        var selected: ReviewChangesFileID? = files[0].id
        let rail = ReviewChangesRail(
            session: ReviewChangesSessionModel(files: files),
            selectedFileID: selected,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: rail)
        controller.view.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        let expandedText = textContent(in: controller.view)
        #expect(expandedText.contains("App.swift"))
        #expect(expandedText.contains("+3"))

        collapsed = true
        controller.rootView = rail
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.fittingSize.width < 90)
    }

    @Test func fileSectionEmbedsDiffPaneWithoutPerFileToolbar() {
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
                .init(kind: .delete, text: "old", oldNumber: 1, newNumber: nil),
                .init(kind: .add, text: "new", oldNumber: nil, newNumber: 1),
            ])
        ])
        let summary = ReviewChangesFileSummary(
            id: .init(source: .unstaged, path: "Sources/App.swift"),
            path: "Sources/App.swift",
            source: .unstaged,
            status: .modified,
            additions: 1,
            deletions: 1,
            isRenderable: true
        )
        let section = ReviewChangesFileSection(
            file: ReviewChangesFileSectionModel(
                summary: summary,
                parsedDiff: diff,
                displayModel: DiffDisplayModelBuilder.build(diff: diff, filePath: summary.path),
                placeholderMessage: nil
            ),
            layoutMode: .constant(.split),
            wrapLines: .constant(false),
            showWhitespace: .constant(false),
            codeFontFamily: "",
            codeFontSize: 13
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: section)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        controller.view.layoutSubtreeIfNeeded()

        let text = textContent(in: controller.view)
        #expect(text.contains("Sources/App.swift"))
        #expect(!text.contains("Stacked"))
    }

    private func textContent(in view: NSView) -> String {
        var result = ""
        func walk(_ view: NSView) {
            if let text = view as? NSTextField {
                result += " " + text.stringValue
            }
            if let button = view as? NSButton {
                result += " " + button.title
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return result
    }
}
```

- [ ] **Step 2: Run tests red**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesTabViewTests test
```

Expected: FAIL because `ReviewChangesRail` and `ReviewChangesFileSection` do not exist.

- [ ] **Step 3: Implement rail view**

Create `Alas/Sources/Center/ReviewChanges/ReviewChangesRail.swift` with:

- expanded width about `260`
- collapsed width about `44`
- header with `Changed Files`, count, `+/-`
- collapse toggle using an icon button
- tree rows from `ReviewChangesFileTreeBuilder`
- active file row with accent left rail
- collapsed mode with marker buttons for each file id
- middle truncation for long file names

Use this public initializer:

```swift
struct ReviewChangesRail: View {
    let session: ReviewChangesSessionModel
    let selectedFileID: ReviewChangesFileID?
    @Binding var collapsed: Bool
    let onSelectFile: (ReviewChangesFileID) -> Void
}
```

The implementation must use Alas theme tokens only. Do not add new theme keys.

- [ ] **Step 4: Implement file section view**

Create `Alas/Sources/Center/ReviewChanges/ReviewChangesFileSection.swift`:

```swift
import SwiftUI

struct ReviewChangesFileSection: View {
    let file: ReviewChangesFileSectionModel
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            if let displayModel = file.displayModel {
                DiffPaneView(
                    model: displayModel,
                    fileExtension: LanguageRegistry.highlighterExtension(forPath: file.summary.path),
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    showsToolbar: false,
                    hunkActions: { _ in DiffPaneHunkActions() }
                )
                .fixedSize(horizontal: false, vertical: true)
            } else {
                placeholder
            }
        }
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.color("line"), lineWidth: 0.75))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(file.summary.status.glyph)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(statusColor)
            Text(file.summary.path)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(file.summary.source.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer()
            Text("+\(file.summary.additions)")
                .foregroundColor(theme.color("add"))
            Text("−\(file.summary.deletions)")
                .foregroundColor(theme.color("del"))
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(theme.color("bg-2").opacity(0.88))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var placeholder: some View {
        Text(file.placeholderMessage ?? "No textual diff is available for this file.")
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-dim"))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }

    private var statusColor: Color {
        switch file.summary.status {
        case .added, .copied: return theme.color("add")
        case .deleted: return theme.color("del")
        case .renamed: return theme.color("warning")
        case .conflicted: return theme.color("del")
        case .modified, .unknown: return theme.color("accent")
        }
    }
}
```

If the local theme does not have `warning`, use `accent` for renamed instead.

- [ ] **Step 5: Implement top-level tab view**

Replace placeholder `ReviewChangesTabView` with:

- `@State private var loadState`
- `@State private var selectedFileID`
- `@State private var railCollapsed`
- `@State private var scrollController = ReviewChangesProgrammaticScrollController()`
- `@State private var sectionFrames: [ReviewChangesSectionFrame]`
- Session-level toolbar with split/stacked, wrap, whitespace controls bound to `AppConfig`.
- `ScrollViewReader` and a vertical `ScrollView`.
- Per-file section `.id(file.id.rawValue)`.
- Geometry/preference-based reporting of section frames into `ReviewChangesScrollSpy`.
- Rail click:
  - set selected id
  - begin suppression
  - `withAnimation { proxy.scrollTo(id.rawValue, anchor: .top) }`
  - clear suppression after a short `Task.sleep`.

The top-level initializer remains:

```swift
struct ReviewChangesTabView: View {
    let worktree: Worktree
    let tabState: ReviewChangesTabState
    let appState: AppState
}
```

- [ ] **Step 6: Run hosted tests green**

```bash
xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewChangesTabViewTests test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift Alas/Sources/Center/ReviewChanges/ReviewChangesRail.swift Alas/Sources/Center/ReviewChanges/ReviewChangesFileSection.swift AlasTests/ReviewChangesTabViewTests.swift Alas.xcodeproj
git commit -m "feat(diff): render review changes tab"
```

---

### Task 7: Changes Pane Entry Point

**Files:**
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Do not modify `Alas/Sources/Right/WorkingTreeSectionView.swift`; individual file rows keep their existing single-file behavior.
- Verification: build plus manual inspection, because this task only adds a small entry row to an existing view with no stable hosted test harness.

- [ ] **Step 1: Add a visible `Review Changes` action**

In `ChangesTabView.scrollContent`, before `WorkingTreeSectionView`, add a compact action row when `nonConflictChanges` is non-empty:

```swift
ReviewChangesTriggerRow(
    count: nonConflictChanges.count,
    totalAdd: nonConflictChanges.reduce(0) { $0 + $1.add },
    totalDel: nonConflictChanges.reduce(0) { $0 + $1.del },
    onOpen: {
        appState.openReviewChangesTab(for: rps.worktree)
    }
)
```

Add a private `ReviewChangesTriggerRow` in `ChangesTabView.swift` modeled after `DraftCommitTriggerRow`:

```swift
private struct ReviewChangesTriggerRow: View {
    let count: Int
    let totalAdd: Int
    let totalDel: Int
    let onOpen: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Icon(name: "diff", size: 11, color: theme.color("fg-dim"))
                Text("Review changes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text("\(count) files")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
                Text("+\(totalAdd)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("add"))
                Text("−\(totalDel)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("del"))
                Spacer()
                Icon(name: "chev-right", size: 10, color: theme.color("fg-faint"))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(theme.color("bg-2"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open all local changes in a review tab")
    }
}
```

- [ ] **Step 2: Verify build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/Right/ChangesTabView.swift
git commit -m "feat(diff): add review changes entry point"
```

---

### Task 8: Final Visual/Behavior Polish And Verification

**Files:**
- Modify only files already touched by Tasks 1-7, and only to fix issues found by the verification steps below.

- [ ] **Step 1: Run focused tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ReviewChangesModelsTests \
  -only-testing:AlasTests/ReviewChangesScrollSpyTests \
  -only-testing:AlasTests/ReviewChangesLoaderTests \
  -only-testing:AlasTests/ReviewChangesTabViewTests \
  -only-testing:AlasTests/DiffPaneViewTests \
  -only-testing:AlasTests/TabsManagerTests test
```

Expected: exit 0.

- [ ] **Step 2: Run project-required generation and build**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 3: Run full tests**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0. If only a known unrelated flake fails, rerun the failing test once and record the exact result before proceeding.

- [ ] **Step 4: Launch for manual inspection**

```bash
rtk open -n /path/to/latest/Alas.app
```

Open a worktree with multiple staged/unstaged changes. Confirm:

- `Review changes` row opens one `Review Changes` tab.
- Left rail is expanded by default and collapsible.
- Rail click scrolls the main diff document to the file.
- Scrolling the document updates the active rail item.
- Split and stacked modes apply to every file section.
- Per-file diff sections do not repeat the toolbar.
- Long paths do not overlap in the rail.

- [ ] **Step 5: Commit any final polish**

If Step 4 required code changes:

```bash
git add <changed-files>
git commit -m "fix(diff): polish review changes tab"
```

If no code changes were needed, do not create an empty commit.
