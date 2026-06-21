# Changed File HEAD View and History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add changed-file context-menu actions for viewing a file at `HEAD`, comparing it with `HEAD`, and opening path-scoped file history.

**Architecture:** Add two focused center-pane tab types: a read-only `HEAD` snapshot tab and a file-history tab. Reuse the existing unstaged `DiffTabView` for compare-with-HEAD and existing commit tabs for history row selection. Keep Git access in `GitService`, tab identity in `TabsManager`, and menu wiring in the right-pane changed-file views.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, existing `Process.git` / `Process.gitData`, existing `TabsManager`, `CommitInfo`, `CommitRow`, and `DiffTabView`.

---

## File Structure

- Modify `Alas/Sources/Git/GitService.swift`
  - Add `HeadBlobTextResult`.
  - Add `headBlobText(worktreePath:relativePath:)`.
  - Add `fileHistory(worktreePath:relativePath:limit:)`.
- Modify `Alas/Sources/Center/Tab.swift`
  - Add `fileSnapshot` and `fileHistory` tab cases.
  - Add `FileSnapshotTabState` and `FileHistoryTabState`.
- Modify `Alas/Sources/Center/TabsManager.swift`
  - Add open-or-focus helpers for the new tab cases.
- Create `Alas/Sources/Center/FileSnapshotTabView.swift`
  - Load and render `HEAD:<path>` read-only text/error states.
- Create `Alas/Sources/Center/ReadonlyTextView.swift` if no reusable whole-file selectable text view exists.
  - Render selectable, non-editable monospace text for the snapshot tab.
- Create `Alas/Sources/Center/FileHistoryTabView.swift`
  - Load and render path-scoped commits, selecting rows into existing commit tabs.
- Modify `Alas/Sources/Center/CenterPaneView.swift`
  - Render the two new tab cases.
- Modify `Alas/Sources/App/AppState.swift`
  - Add app-level helpers that focus the worktree and delegate to `TabsManager`.
- Modify `Alas/Sources/Right/ChangedRow.swift`
  - Add menu items and enabled flags.
- Modify `Alas/Sources/Right/WorkingTreeSectionView.swift`
  - Thread callbacks and calculate `View at HEAD` availability.
- Modify `Alas/Sources/Right/ChangesTabView.swift`
  - Wire callbacks to `AppState` and existing diff tab behavior.
- Tests:
  - Modify `AlasTests/TabsManagerTests.swift`.
  - Modify `AlasTests/GitServiceTests.swift`.

---

### Task 1: GitService HEAD Blob and File History

**Files:**
- Modify: `Alas/Sources/Git/GitService.swift`
- Test: `AlasTests/GitServiceTests.swift`

- [ ] **Step 1: Write failing tests for HEAD blob states**

Add tests that create a temporary git repo, commit a text file, then verify:

```swift
@Test func headBlobTextReturnsCommittedText() async throws {
    let repo = try makeTempRepo()
    try await gitOK(["init"], cwd: repo)
    try await gitOK(["config", "user.email", "you@example.com"], cwd: repo)
    try await gitOK(["config", "user.name", "You"], cwd: repo)
    try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try await gitOK(["add", "a.txt"], cwd: repo)
    try await gitOK(["commit", "-m", "add a"], cwd: repo)

    let result = try await GitService().headBlobText(worktreePath: repo, relativePath: "a.txt")

    #expect(result == .available("hello\n"))
}

@Test func headBlobTextReportsMissingPath() async throws {
    let repo = try makeTempRepo()
    try await seedRepoWithInitialCommit(repo)

    let result = try await GitService().headBlobText(worktreePath: repo, relativePath: "missing.txt")

    #expect(result == .missing)
}

@Test func headBlobTextReportsBinaryAsUndisplayable() async throws {
    let repo = try makeTempRepo()
    try await seedRepoWithInitialCommit(repo)
    try Data([0, 1, 2, 3]).write(to: repo.appendingPathComponent("blob.bin"))
    try await gitOK(["add", "blob.bin"], cwd: repo)
    try await gitOK(["commit", "-m", "add binary"], cwd: repo)

    let result = try await GitService().headBlobText(worktreePath: repo, relativePath: "blob.bin")

    #expect(result == .undisplayable)
}
```

Use existing test helpers in `GitServiceTests.swift` if present instead of duplicating setup helpers.

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceTests test
```

Expected: FAIL because `HeadBlobTextResult` and `headBlobText` do not exist.

- [ ] **Step 3: Implement `HeadBlobTextResult` and `headBlobText`**

Add near other GitService helper types:

```swift
enum HeadBlobTextResult: Equatable, Sendable {
    case available(String)
    case missing
    case undisplayable
}
```

Add a public helper in `GitService`:

```swift
func headBlobText(worktreePath: URL, relativePath: String) async throws -> HeadBlobTextResult {
    let result = try await Process.gitData(["show", "HEAD:\(relativePath)"], cwd: worktreePath)
    guard result.exitCode == 0 else {
        return .missing
    }
    guard !result.stdout.contains(0),
          let text = String(data: result.stdout, encoding: .utf8)
    else {
        return .undisplayable
    }
    return .available(text)
}
```

If implementation reveals `Process.gitData` names stdout differently, adapt to the existing result shape.

- [ ] **Step 4: Write failing tests for file history**

Add a test that commits `a.txt`, commits unrelated `b.txt`, commits `a.txt` again, then verifies `fileHistory(..., relativePath: "a.txt", limit: 200)` returns only the two `a.txt` commits in newest-first order.

```swift
@Test func fileHistoryReturnsCommitsTouchingPathNewestFirst() async throws {
    let repo = try makeTempRepo()
    try await seedRepoWithInitialCommit(repo)
    try await commitFile(repo, path: "a.txt", contents: "one\n", message: "add a")
    try await commitFile(repo, path: "b.txt", contents: "other\n", message: "add b")
    try await commitFile(repo, path: "a.txt", contents: "two\n", message: "update a")

    let commits = try await GitService().fileHistory(worktreePath: repo, relativePath: "a.txt", limit: 200)

    #expect(commits.map(\.subject) == ["update a", "add a"])
    #expect(commits.allSatisfy { $0.filesChanged >= 1 })
}
```

- [ ] **Step 5: Run tests and verify they fail**

Run the same GitService test command.

Expected: FAIL because `fileHistory` does not exist.

- [ ] **Step 6: Implement `fileHistory` with a shared parser shape**

Use the same record separator format as `commitsAhead` / `commitsOlder`:

```swift
func fileHistory(worktreePath: URL, relativePath: String, limit: Int = 200) async throws -> [CommitInfo] {
    let boundedLimit = max(1, limit)
    let format = "%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s"
    let log = try await Process.git(
        ["log", "--follow", "-n", String(boundedLimit), "--pretty=tformat:\(format)", "--numstat", "--", relativePath],
        cwd: worktreePath
    )
    guard log.exitCode == 0 else {
        throw NSError(
            domain: "GitService.fileHistory",
            code: Int(log.exitCode),
            userInfo: [NSLocalizedDescriptionKey: log.stderr.isEmpty ? "git log failed" : log.stderr]
        )
    }
    return Self.parseFileHistoryCommitInfoRecords(log.stdout)
}
```

Add `private static func parseFileHistoryCommitInfoRecords(_ stdout: String) -> [CommitInfo]` that mirrors the `commitsAhead` / `commitsOlder` parsing shape: split on `\u{1e}`, parse header fields separated by `\u{1f}`, parse ISO dates, run `CommitInfo.parseConventional(subject:)`, and count `--numstat` rows for files/insertions/deletions. Refactor duplicate parsing from existing methods only if it stays small and local; otherwise keep this private parser for the new helper to avoid unrelated churn.

- [ ] **Step 7: Run GitService tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceTests test
```

Expected: PASS for the new tests.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/Git/GitService.swift AlasTests/GitServiceTests.swift
git commit -m "feat(git): add file snapshot and history helpers"
```

---

### Task 2: Tab State and Open-or-Focus Helpers

**Files:**
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Test: `AlasTests/TabsManagerTests.swift`

- [ ] **Step 1: Write failing tab identity tests**

Add tests:

```swift
@Test func openOrFocusFileSnapshotReusesWorktreePathRefTab() {
    let manager = TabsManager()
    let first = manager.openOrFocusFileSnapshot(worktreeId: "wt", relativePath: "a.txt", ref: "HEAD")
    let second = manager.openOrFocusFileSnapshot(worktreeId: "wt", relativePath: "a.txt", ref: "HEAD")

    #expect(first.id == second.id)
    #expect(manager.tabs(forWorktree: "wt").count == 1)
}

@Test func openOrFocusFileHistoryReusesWorktreePathTab() {
    let manager = TabsManager()
    let first = manager.openOrFocusFileHistory(worktreeId: "wt", relativePath: "a.txt")
    let second = manager.openOrFocusFileHistory(worktreeId: "wt", relativePath: "a.txt")

    #expect(first.id == second.id)
    #expect(manager.tabs(forWorktree: "wt").count == 1)
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerTests test
```

Expected: FAIL because tab cases and helpers do not exist.

- [ ] **Step 3: Add tab cases and states**

In `Tab`, add:

```swift
case fileSnapshot(FileSnapshotTabState)
case fileHistory(FileHistoryTabState)
```

Update `id`, `title`, `iconName`, and `relativeFilePath` switches.

Add states:

```swift
struct FileSnapshotTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let relativePath: String
    let ref: String
    var title: String

    init(worktreeId: String, relativePath: String, ref: String = "HEAD") {
        self.worktreeId = worktreeId
        self.relativePath = relativePath
        self.ref = ref
        self.title = "\((relativePath as NSString).lastPathComponent) @ \(ref)"
        self.id = "file-snapshot:\(worktreeId):\(ref):\(relativePath)"
    }
}

struct FileHistoryTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let relativePath: String
    var title: String

    init(worktreeId: String, relativePath: String) {
        self.worktreeId = worktreeId
        self.relativePath = relativePath
        self.title = "\((relativePath as NSString).lastPathComponent) History"
        self.id = "file-history:\(worktreeId):\(relativePath)"
    }
}
```

- [ ] **Step 4: Add `TabsManager` open-or-focus helpers**

Add:

```swift
@discardableResult
func openOrFocusFileSnapshot(worktreeId: String, relativePath: String, ref: String = "HEAD") -> Tab {
    let state = FileSnapshotTabState(worktreeId: worktreeId, relativePath: relativePath, ref: ref)
    if tabs(forWorktree: worktreeId).contains(where: { $0.id == state.id }) {
        activate(worktreeId: worktreeId, tabId: state.id)
        return tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) ?? .fileSnapshot(state)
    }
    let tab = Tab.fileSnapshot(state)
    append(tab, to: worktreeId)
    return tab
}

@discardableResult
func openOrFocusFileHistory(worktreeId: String, relativePath: String) -> Tab {
    let state = FileHistoryTabState(worktreeId: worktreeId, relativePath: relativePath)
    if tabs(forWorktree: worktreeId).contains(where: { $0.id == state.id }) {
        activate(worktreeId: worktreeId, tabId: state.id)
        return tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) ?? .fileHistory(state)
    }
    let tab = Tab.fileHistory(state)
    append(tab, to: worktreeId)
    return tab
}
```

Prefer a small private helper if existing `TabsManager` has a reuse pattern nearby.

- [ ] **Step 5: Run tab tests**

Run the TabsManager test command.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift AlasTests/TabsManagerTests.swift
git commit -m "feat(tabs): add file snapshot and history tabs"
```

---

### Task 3: File Snapshot Tab View

**Files:**
- Create: `Alas/Sources/Center/FileSnapshotTabView.swift`
- Create: `Alas/Sources/Center/ReadonlyTextView.swift` if needed.
- Modify: `Alas/Sources/Center/CenterPaneView.swift`

- [ ] **Step 1: Add a minimal compile target view**

Create `FileSnapshotTabView`:

```swift
import SwiftUI

struct FileSnapshotTabView: View {
    let worktreePath: URL
    let state: FileSnapshotTabState
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13

    @Environment(\.theme) private var theme
    @State private var result: HeadBlobTextResult?
    @State private var error: String?
    private let git = GitService()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: loadKey) { await load() }
    }

    private var loadKey: String { "\(worktreePath.path)\u{0}\(state.ref)\u{0}\(state.relativePath)" }
}
```

- [ ] **Step 2: Implement header, content, and loading**

Add a header with filename, `HEAD`, and directory path. Content states:

```swift
@ViewBuilder
private var content: some View {
    if let error {
        Text(error)
            .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
            .foregroundColor(theme.color("del"))
            .padding()
    } else if let result {
        switch result {
        case .available(let text):
            ReadonlyTextView(
                text: text,
                font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
                textColor: NSColor.labelColor,
                backgroundColor: .clear
            )
        case .missing:
            emptyText("No HEAD version for \(state.relativePath)")
        case .undisplayable:
            emptyText("HEAD version is not displayable as text")
        }
    } else {
        Spinner()
            .frame(width: 16, height: 16)
            .padding()
    }
}
```

Implement `ReadonlyTextView` as an `NSViewRepresentable` wrapping `NSScrollView` + `NSTextView` with `isEditable = false`, `isSelectable = true`, no rich text, and no background. If an equivalent reusable whole-file selectable text view already exists, use it instead.

- [ ] **Step 3: Wire into `CenterPaneView`**

Add a `case .fileSnapshot(let s)` branch:

```swift
case .fileSnapshot(let s):
    FileSnapshotTabView(
        worktreePath: worktree.path,
        state: s,
        codeFontFamily: state.config.code.fontFamily,
        codeFontSize: CGFloat(state.config.code.fontSize)
    )
```

- [ ] **Step 4: Regenerate project and build**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: project generation succeeds and build succeeds. If `Alas.xcodeproj/project.pbxproj` changes because new Swift files were added, include that generated project change in the task commit.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/FileSnapshotTabView.swift Alas/Sources/Center/CenterPaneView.swift Alas.xcodeproj/project.pbxproj
git add Alas/Sources/Center/ReadonlyTextView.swift # only if this file was created
git commit -m "feat(center): add file snapshot tab view"
```

---

### Task 4: File History Tab View

**Files:**
- Create: `Alas/Sources/Center/FileHistoryTabView.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `Alas/Sources/App/AppState.swift`

- [ ] **Step 1: Add AppState commit-opening helper if needed**

Find existing private helpers such as `openOrFocusCommit(worktree:commit:)` in `RootView.swift`. If not globally available, add an `AppState` helper:

```swift
func openCommitTab(worktreeId: String, commit: CommitInfo) {
    guard let worktree = worktree(withId: worktreeId) else { return }
    if selectedWorktreeId != worktree.id {
        focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
    }
    let existing = tabs.tabs(forWorktree: worktree.id).first { tab in
        if case .commit(let s) = tab { return s.sha == commit.sha }
        return false
    }
    if let existing {
        tabs.activate(worktreeId: worktree.id, tabId: existing.id)
    } else {
        let tab = tabs.appendCommit(worktreeId: worktree.id, sha: commit.sha, title: commit.shortSha)
        tabs.activate(worktreeId: worktree.id, tabId: tab.id)
    }
}
```

Reuse an existing public helper if one already exists.

- [ ] **Step 2: Create `FileHistoryTabView`**

Create a SwiftUI view that loads `GitService.fileHistory(worktreePath:relativePath:limit: 200)` and renders:

```swift
struct FileHistoryTabView: View {
    let worktreePath: URL
    let state: FileHistoryTabState
    let onSelectCommit: (CommitInfo) -> Void
    let onCopySHA: (CommitInfo) -> Void

    @Environment(\.theme) private var theme
    @State private var commits: [CommitInfo] = []
    @State private var loaded = false
    @State private var error: String?
    private let git = GitService()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.color("bg-1"))
        .task(id: loadKey) { await load() }
    }
}
```

Use `CommitRow` for rows:

```swift
ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
    CommitRow(
        commit: commit,
        isLast: index == commits.count - 1,
        onSelect: { onSelectCommit(commit) },
        onCopySHA: { onCopySHA(commit) }
    )
}
```

- [ ] **Step 3: Wire into `CenterPaneView`**

Add:

```swift
case .fileHistory(let s):
    FileHistoryTabView(
        worktreePath: worktree.path,
        state: s,
        onSelectCommit: { state.openCommitTab(worktreeId: worktree.id, commit: $0) },
        onCopySHA: { Clipboard.copy($0.sha) }
    )
```

- [ ] **Step 4: Regenerate project and build**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: project generation succeeds and build succeeds. If `Alas.xcodeproj/project.pbxproj` changes because the new Swift file was added, include that generated project change in the task commit.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/FileHistoryTabView.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/App/AppState.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(center): add file history tab view"
```

---

### Task 5: Context Menu Wiring

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Right/ChangedRow.swift`
- Modify: `Alas/Sources/Right/WorkingTreeSectionView.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Optional Test: small callback plumbing tests if existing right-pane tests can cover this cheaply.

- [ ] **Step 1: Add AppState helpers for snapshot/history**

Add:

```swift
func openFileSnapshotAtHEAD(relativePath: String, worktreeId: String) {
    guard let worktree = worktree(withId: worktreeId) else { return }
    guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
    if selectedWorktreeId != worktree.id {
        focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
    }
    _ = tabs.openOrFocusFileSnapshot(worktreeId: worktree.id, relativePath: relativePath, ref: "HEAD")
}

func openFileHistory(relativePath: String, worktreeId: String) {
    guard let worktree = worktree(withId: worktreeId) else { return }
    guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
    if selectedWorktreeId != worktree.id {
        focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
    }
    _ = tabs.openOrFocusFileHistory(worktreeId: worktree.id, relativePath: relativePath)
}
```

- [ ] **Step 2: Add `ChangedRow` callbacks and menu items**

Add properties:

```swift
var onViewAtHEAD: (() -> Void)? = nil
var onCompareWithHEAD: (() -> Void)? = nil
var onFileHistory: (() -> Void)? = nil
var viewAtHEADEnabled: Bool = true
```

Add menu items near `Open File`:

```swift
Button("View at HEAD") { onViewAtHEAD?() }
    .disabled(!viewAtHEADEnabled || onViewAtHEAD == nil)
Button("Compare with HEAD") { onCompareWithHEAD?() }
    .disabled(onCompareWithHEAD == nil)
Button("File History") { onFileHistory?() }
    .disabled(onFileHistory == nil)
```

- [ ] **Step 3: Thread callbacks through `WorkingTreeSectionView`**

Add properties:

```swift
var onViewAtHEAD: ((ChangedFile) -> Void)? = nil
var onCompareWithHEAD: ((ChangedFile) -> Void)? = nil
var onFileHistory: ((ChangedFile) -> Void)? = nil
```

When constructing `ChangedRow`, pass mapped closures and:

```swift
viewAtHEADEnabled: !isUntracked(file)
```

Use an availability helper instead of only `isUntracked(file)`:

```swift
private func hasHeadVersion(_ file: ChangedFile) -> Bool {
    file.status != "A"
}
```

This disables unstaged untracked adds and staged adds, both of which have no `HEAD:<path>` blob. It keeps tracked deletes enabled, which is the important deleted-file case from the spec.

- [ ] **Step 4: Wire from `ChangesTabView`**

In `WorkingTreeSectionView(...)` add:

```swift
onViewAtHEAD: { file in
    appState.openFileSnapshotAtHEAD(relativePath: file.path, worktreeId: rps.worktree.id)
},
onCompareWithHEAD: { file in
    appState.openDiffTab(forFileInWorktree: rps.worktree, relativePath: file.path)
},
onFileHistory: { file in
    appState.openFileHistory(relativePath: file.path, worktreeId: rps.worktree.id)
},
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/App/AppState.swift Alas/Sources/Right/ChangedRow.swift Alas/Sources/Right/WorkingTreeSectionView.swift Alas/Sources/Right/ChangesTabView.swift
git commit -m "feat(changes): add file history context actions"
```

---

### Task 6: Final Verification

**Files:**
- No planned edits unless verification finds a defect.

- [ ] **Step 1: Run focused tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceTests -only-testing:AlasTests/TabsManagerTests test
```

Expected: PASS.

- [ ] **Step 2: Run required project build**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: project generation succeeds and build succeeds.

- [ ] **Step 3: Run required project tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: PASS.

- [ ] **Step 4: Manual smoke test**

In the app, use a worktree with:

- Modified tracked file: `View at HEAD`, `Compare with HEAD`, and `File History` all open the expected tabs.
- Deleted tracked file: `View at HEAD` opens committed content and `Open File` remains unavailable.
- Added untracked file: `View at HEAD` is disabled and `File History` opens empty history.
- Renamed tracked file: `File History` follows prior path where Git detects the rename.

- [ ] **Step 5: Final commit if verification fixes were needed**

If Step 1-4 required follow-up fixes:

```bash
git add <changed-files>
git commit -m "fix(changes): polish file history actions"
```
