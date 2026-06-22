# Stashes UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add v1 git stash support to the Changes tab: Park Changes, list stashes, preview stash diffs, apply, pop, and drop.

**Architecture:** Keep stash command execution in `GitService`, coordination in `RightPaneState`, and rendering in focused SwiftUI views under `Alas/Sources/Right`. Stash file preview opens a dedicated center tab backed by existing diff display primitives so preview remains read-only and never mutates the live worktree.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing (`import Testing`), git CLI through existing `Process.git`, existing `DiffParser`/`DiffDisplayModelBuilder`/`DiffPaneView`.

---

## File Structure

- Create `Alas/Sources/Git/GitService+Stash.swift`
  - Defines `GitStash`, `GitStashFile`, `StashOperationResult`, parser helpers, and stash git commands.
- Create `AlasTests/GitServiceStashTests.swift`
  - Unit and integration coverage for stash parsing and command behavior.
- Modify `Alas/Sources/Center/Tab.swift`
  - Adds `StashDiffTabState` and `Tab.stashDiff`.
- Modify `Alas/Sources/Center/TabsManager.swift`
  - Adds `appendStashDiff`.
- Modify `Alas/Sources/App/AppState.swift`
  - Adds `openStashDiffTab`.
- Modify `Alas/Sources/Center/CenterPaneView.swift`
  - Renders `StashDiffTabView`.
- Create `Alas/Sources/Center/StashDiffTabView.swift`
  - Loads a stash file diff and renders it read-only.
- Create `Alas/Sources/Right/PendingStashDrop.swift`
  - Encapsulates drop confirmation copy.
- Create `AlasTests/PendingStashDropTests.swift`
  - Covers destructive confirmation strings.
- Modify `Alas/Sources/Right/RightPaneState.swift`
  - Adds stash state, refresh loading, park/apply/pop/drop operations, and pending sheet/drop state.
- Modify `Alas/Sources/Right/WorkingTreeSectionView.swift`
  - Adds **Park Changes...** menu entry.
- Create `Alas/Sources/Right/ParkChangesSheet.swift`
  - Sheet for optional message and include-untracked checkbox.
- Create `Alas/Sources/Right/StashesSectionView.swift`
  - Collapsible Stashes section with menu-first row actions.
- Modify `Alas/Sources/Right/ChangesTabView.swift`
  - Places Stashes between Working tree and Commits and wires preview/actions.
- Modify `Alas/Sources/Right/RightPaneView.swift`
  - Hosts `ParkChangesSheet` and drop confirmation.
- Add or extend focused view/model tests under `AlasTests`.

## Task 1: Git Stash Models And Parsers

**Files:**
- Create: `Alas/Sources/Git/GitService+Stash.swift`
- Create: `AlasTests/GitServiceStashTests.swift`

- [ ] **Step 1: Write failing parser tests**

Add `AlasTests/GitServiceStashTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct GitServiceStashTests {
    @Test func parseStashListPreservesRefSubjectRelativeTimeAndSha() {
        let output = """
        stash@{0}\u{1f}WIP on main: abc123 update parser\u{1f}2 hours ago\u{1f}1111111111111111111111111111111111111111
        stash@{1}\u{1f}custom message\u{1f}3 days ago\u{1f}2222222222222222222222222222222222222222

        """

        let stashes = GitService.parseStashList(output)

        #expect(stashes == [
            GitStash(
                ref: "stash@{0}",
                subject: "WIP on main: abc123 update parser",
                relativeTime: "2 hours ago",
                sha: "1111111111111111111111111111111111111111"
            ),
            GitStash(
                ref: "stash@{1}",
                subject: "custom message",
                relativeTime: "3 days ago",
                sha: "2222222222222222222222222222222222222222"
            ),
        ])
    }

    @Test func parseStashFilesMergesNumstatAndNameStatus() {
        let numstat = """
        12\t3\tSources/App.swift
        -\t-\tAssets/icon.png
        4\t0\tSources/New.swift

        """
        let nameStatus = """
        M\tSources/App.swift
        M\tAssets/icon.png
        A\tSources/New.swift

        """

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/App.swift", status: "M", add: 12, del: 3),
            GitStashFile(path: "Assets/icon.png", status: "M", add: 0, del: 0),
            GitStashFile(path: "Sources/New.swift", status: "A", add: 4, del: 0),
        ])
    }

    @Test func parseStashFilesHandlesRenamesUsingNewPath() {
        let numstat = "1\t2\tSources/Old.swift => Sources/New.swift\n"
        let nameStatus = "R100\tSources/Old.swift\tSources/New.swift\n"

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/New.swift", status: "R", add: 1, del: 2),
        ])
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceStashTests test
```

Expected: compile fails because `GitStash`, `GitStashFile`, `parseStashList`, and `parseStashFiles` do not exist.

- [ ] **Step 3: Add stash models and parser helpers**

Create `Alas/Sources/Git/GitService+Stash.swift`:

```swift
import Foundation

struct GitStash: Codable, Equatable, Identifiable, Sendable {
    var id: String { ref }
    let ref: String
    let subject: String
    let relativeTime: String
    let sha: String
}

struct GitStashFile: Codable, Equatable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    let status: String
    let add: Int
    let del: Int
}

enum StashOperationResult: Equatable, Sendable {
    case clean
    case conflict(message: String)
    case error(message: String)
}

extension GitService {
    static func parseStashList(_ output: String) -> [GitStash] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> GitStash? in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4 else { return nil }
                let ref = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty else { return nil }
                return GitStash(
                    ref: ref,
                    subject: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                    relativeTime: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
                    sha: parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    static func parseStashFiles(numstat: String, nameStatus: String) -> [GitStashFile] {
        let counts = parseStashNumstat(numstat)
        return nameStatus
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> GitStashFile? in
                let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { return nil }
                let rawStatus = parts[0]
                let status = String(rawStatus.prefix(1))
                let path = parts.count >= 3 ? parts[2] : parts[1]
                let fallback = normalizeStashNumstatPath(path)
                let count = counts[path] ?? counts[fallback] ?? (add: 0, del: 0)
                return GitStashFile(path: path, status: status, add: count.add, del: count.del)
            }
    }

    private static func parseStashNumstat(_ output: String) -> [String: (add: Int, del: Int)] {
        var result: [String: (add: Int, del: Int)] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            let path = normalizeStashNumstatPath(parts[2])
            result[path] = (add, del)
        }
        return result
    }

    private static func normalizeStashNumstatPath(_ path: String) -> String {
        guard path.contains(" => ") else { return path }
        guard let suffix = path.split(separator: "=>", maxSplits: 1, omittingEmptySubsequences: false).last else {
            return path
        }
        return suffix
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run parser tests and verify they pass**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceStashTests test
```

Expected: parser tests pass.

- [ ] **Step 5: Commit parser work**

```bash
git add Alas/Sources/Git/GitService+Stash.swift AlasTests/GitServiceStashTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(changes): add stash parsers"
```

## Task 2: Git Stash Commands

**Files:**
- Modify: `Alas/Sources/Git/GitService+Stash.swift`
- Modify: `AlasTests/GitServiceStashTests.swift`

- [ ] **Step 1: Add failing integration tests for stash commands**

Append these tests inside `GitServiceStashTests`:

```swift
private func makeRepo() async throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("alas-stash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await gitOK(["init", "-q", "-b", "main"], cwd: dir)
    try await gitOK(["config", "user.email", "t@example.com"], cwd: dir)
    try await gitOK(["config", "user.name", "Test User"], cwd: dir)
    try "base\n".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await gitOK(["add", "file.txt"], cwd: dir)
    try await gitOK(["commit", "-q", "-m", "base"], cwd: dir)
    return dir
}

@discardableResult
private func gitOK(_ args: [String], cwd: URL) async throws -> ProcessResult {
    let result = try await Process.git(args, cwd: cwd)
    guard result.exitCode == 0 else {
        throw NSError(
            domain: "GitServiceStashTests.gitOK",
            code: Int(result.exitCode),
            userInfo: [NSLocalizedDescriptionKey: result.stderr]
        )
    }
    return result
}

@Test func pushListFilesAndDiffStash() async throws {
    let repo = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    try "base\nchanged\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

    let service = GitService()
    let result = try await service.pushStash(worktreePath: repo, message: "parser cleanup", includeUntracked: false)

    #expect(result == .clean)
    let stashes = try await service.stashes(worktreePath: repo)
    #expect(stashes.count == 1)
    #expect(stashes[0].subject.contains("parser cleanup"))
    let files = try await service.stashFiles(worktreePath: repo, stash: stashes[0])
    #expect(files == [GitStashFile(path: "file.txt", status: "M", add: 1, del: 0)])
    let diff = try await service.stashDiff(worktreePath: repo, stash: stashes[0], file: files[0])
    #expect(diff.hunks.contains { hunk in hunk.lines.contains { $0.kind == .add && $0.text == "changed" } })
}

@Test func pushStashCanIncludeUntrackedFiles() async throws {
    let repo = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

    let service = GitService()
    let result = try await service.pushStash(worktreePath: repo, message: "", includeUntracked: true)

    #expect(result == .clean)
    let files = try await service.stashFiles(worktreePath: repo, stash: try #require(try await service.stashes(worktreePath: repo).first))
    #expect(files.contains(GitStashFile(path: "new.txt", status: "A", add: 1, del: 0)))
}

@Test func applyPopAndDropStash() async throws {
    let repo = try await makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    try "base\nchanged\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

    let service = GitService()
    _ = try await service.pushStash(worktreePath: repo, message: "apply me", includeUntracked: false)
    var stash = try #require(try await service.stashes(worktreePath: repo).first)

    #expect(try await service.applyStash(worktreePath: repo, stash: stash) == .clean)
    #expect(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8) == "base\nchanged\n")
    try await gitOK(["checkout", "--", "file.txt"], cwd: repo)

    #expect(try await service.popStash(worktreePath: repo, stash: stash) == .clean)
    #expect(try await service.stashes(worktreePath: repo).isEmpty)

    _ = try await service.pushStash(worktreePath: repo, message: "drop me", includeUntracked: false)
    stash = try #require(try await service.stashes(worktreePath: repo).first)
    try await service.dropStash(worktreePath: repo, stash: stash)
    #expect(try await service.stashes(worktreePath: repo).isEmpty)
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceStashTests test
```

Expected: compile fails because stash command methods do not exist.

- [ ] **Step 3: Implement stash command methods**

Append to the `extension GitService` in `Alas/Sources/Git/GitService+Stash.swift`:

```swift
func stashes(worktreePath: URL) async throws -> [GitStash] {
    let result = try await Process.git(
        ["stash", "list", "--format=%gd%x1f%gs%x1f%cr%x1f%H"],
        cwd: worktreePath
    )
    guard result.exitCode == 0 else { throw GitStashError.stderr(result.stderr, fallback: "Could not list stashes.") }
    return Self.parseStashList(result.stdout)
}

func pushStash(worktreePath: URL, message: String, includeUntracked: Bool) async throws -> StashOperationResult {
    var args = ["stash", "push"]
    if includeUntracked { args.append("--include-untracked") }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        args.append(contentsOf: ["--message", trimmed])
    }
    let result = try await Process.git(args, cwd: worktreePath)
    return Self.stashOperationResult(result, fallback: "Could not park changes.")
}

func stashFiles(worktreePath: URL, stash: GitStash) async throws -> [GitStashFile] {
    let numstat = try await Process.git(
        ["stash", "show", "--include-untracked", "--numstat", "--format=", stash.ref],
        cwd: worktreePath
    )
    guard numstat.exitCode == 0 else {
        throw GitStashError.stderr(numstat.stderr, fallback: "Could not load stash files.")
    }
    let nameStatus = try await Process.git(
        ["stash", "show", "--include-untracked", "--name-status", "--format=", stash.ref],
        cwd: worktreePath
    )
    guard nameStatus.exitCode == 0 else {
        throw GitStashError.stderr(nameStatus.stderr, fallback: "Could not load stash files.")
    }
    return Self.parseStashFiles(numstat: numstat.stdout, nameStatus: nameStatus.stdout)
}

func stashDiff(worktreePath: URL, stash: GitStash, file: GitStashFile) async throws -> ParsedDiff {
    let result = try await Process.git(
        ["stash", "show", "--include-untracked", "--patch", "--format=", "--no-ext-diff", "--no-color", stash.ref, "--", file.path],
        cwd: worktreePath
    )
    guard result.exitCode == 0 else {
        throw GitStashError.stderr(result.stderr, fallback: "Could not load stash diff.")
    }
    return await Task.detached(priority: .userInitiated) {
        DiffParser.parse(result.stdout)
    }.value
}

func applyStash(worktreePath: URL, stash: GitStash) async throws -> StashOperationResult {
    let result = try await Process.git(["stash", "apply", stash.ref], cwd: worktreePath)
    return Self.stashOperationResult(result, fallback: "Could not apply stash.")
}

func popStash(worktreePath: URL, stash: GitStash) async throws -> StashOperationResult {
    let result = try await Process.git(["stash", "pop", stash.ref], cwd: worktreePath)
    return Self.stashOperationResult(result, fallback: "Could not pop stash.")
}

func dropStash(worktreePath: URL, stash: GitStash) async throws {
    let result = try await Process.git(["stash", "drop", stash.ref], cwd: worktreePath)
    guard result.exitCode == 0 else {
        throw GitStashError.stderr(result.stderr, fallback: "Could not drop stash.")
    }
}

private static func stashOperationResult(_ result: ProcessResult, fallback: String) -> StashOperationResult {
    if result.exitCode == 0 { return .clean }
    let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? fallback
        : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.localizedCaseInsensitiveContains("conflict") {
        return .conflict(message: message)
    }
    return .error(message: message)
}
```

Add this private error type at the bottom of the file:

```swift
private enum GitStashError: LocalizedError {
    case stderr(String, fallback: String)

    var errorDescription: String? {
        switch self {
        case .stderr(let stderr, let fallback):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? fallback : message
        }
    }
}
```

- [ ] **Step 4: Run stash command tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceStashTests test
```

Expected: all stash tests pass.

- [ ] **Step 5: Commit command work**

```bash
git add Alas/Sources/Git/GitService+Stash.swift AlasTests/GitServiceStashTests.swift
git commit -m "feat(changes): add stash git operations"
```

## Task 3: Stash Diff Center Tab

**Files:**
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Create: `Alas/Sources/Center/StashDiffTabView.swift`
- Modify: `AlasTests/TabsManagerTests.swift`

- [ ] **Step 1: Write failing tab manager test**

Append to `AlasTests/TabsManagerTests.swift`:

```swift
@Test func appendStashDiffCreatesStableReadOnlyPreviewTab() {
    let mgr = TabsManager()
    let worktreeId = "wt1"
    let stash = GitStash(ref: "stash@{0}", subject: "parser cleanup", relativeTime: "now", sha: "abc")
    let file = GitStashFile(path: "Sources/App.swift", status: "M", add: 2, del: 1)

    let tab = mgr.appendStashDiff(worktreeId: worktreeId, stash: stash, file: file)

    guard case .stashDiff(let state) = tab else {
        Issue.record("Expected stashDiff tab")
        return
    }
    #expect(state.id == "stash-diff:wt1:stash@{0}:Sources/App.swift")
    #expect(state.title == "App.swift @ stash@{0}")
    #expect(state.stash == stash)
    #expect(state.file == file)
}
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerTests/appendStashDiffCreatesStableReadOnlyPreviewTab test
```

Expected: compile fails because `stashDiff` tab support does not exist.

- [ ] **Step 3: Add tab state and enum case**

In `Alas/Sources/Center/Tab.swift`, add `case stashDiff(StashDiffTabState)` to `Tab`, then update `id`, `title`, `iconName`, and `relativeFilePath` switches:

```swift
case stashDiff(StashDiffTabState)
```

```swift
case .stashDiff(let s): return s.id
```

```swift
case .stashDiff(let s): return s.title
```

```swift
case .stashDiff: return "archivebox"
```

```swift
case .stashDiff(let s): return s.file.path
```

Add this state near `DiffTabState`:

```swift
struct StashDiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let stash: GitStash
    let file: GitStashFile
    let title: String

    init(worktreeId: String, stash: GitStash, file: GitStashFile) {
        self.worktreeId = worktreeId
        self.stash = stash
        self.file = file
        self.title = "\((file.path as NSString).lastPathComponent) @ \(stash.ref)"
        self.id = "stash-diff:\(worktreeId):\(stash.ref):\(file.path)"
    }
}
```

Because `Tab` is `Codable`, ensure the compiler synthesizes successfully after adding the case. `TabsFile.FailableTab` already skips unknown cases for older persisted files.

- [ ] **Step 4: Add append and open helpers**

In `Alas/Sources/Center/TabsManager.swift`, add:

```swift
@discardableResult
func appendStashDiff(worktreeId: String, stash: GitStash, file: GitStashFile) -> Tab {
    let state = StashDiffTabState(worktreeId: worktreeId, stash: stash, file: file)
    let tab = Tab.stashDiff(state)
    append(tab, to: worktreeId)
    return tab
}
```

In `Alas/Sources/App/AppState.swift`, add near `openDiffTab`:

```swift
func openStashDiffTab(worktree: Worktree, stash: GitStash, file: GitStashFile) {
    let worktreeId = worktree.id
    let existing = tabs.tabs(forWorktree: worktreeId).first { tab in
        if case .stashDiff(let state) = tab {
            return state.stash.ref == stash.ref && state.file.path == file.path
        }
        return false
    }
    if let existing {
        tabs.activate(worktreeId: worktreeId, tabId: existing.id)
        return
    }
    let tab = tabs.appendStashDiff(worktreeId: worktreeId, stash: stash, file: file)
    tabs.activate(worktreeId: worktreeId, tabId: tab.id)
}
```

- [ ] **Step 5: Create stash diff tab view**

Create `Alas/Sources/Center/StashDiffTabView.swift`:

```swift
import SwiftUI

struct StashDiffTabView: View {
    let worktreePath: URL
    let state: StashDiffTabState
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13

    @Environment(\.theme) private var theme
    @State private var loaded = false
    @State private var error: String?
    @State private var displayModel: DiffDisplayModel?
    @State private var layoutMode: DiffLayoutMode = .split
    @State private var wrapLines = false
    @State private var showWhitespace = false

    private let git = GitService()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error {
                Text(error)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
                    .foregroundColor(theme.color("del"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-2"))
            }
            if !loaded {
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            } else if let displayModel {
                DiffPaneView(
                    model: displayModel,
                    fileExtension: (state.file.path as NSString).pathExtension,
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    allowsReviewLineSelection: false,
                    hunkActions: { _ in DiffPaneHunkActions() }
                )
            } else {
                Text("No changes for \(state.file.path)")
                    .foregroundColor(theme.color("fg-dim"))
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: "\(state.stash.ref)\u{0}\(state.file.path)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text((state.file.path as NSString).lastPathComponent)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
            Text(state.stash.ref)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("accent").opacity(0.16))
                .foregroundColor(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((state.file.path as NSString).deletingLastPathComponent)
                .font(.system(size: codeFontSize - 1.5))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private func load() async {
        loaded = false
        error = nil
        displayModel = nil
        do {
            let diff = try await git.stashDiff(worktreePath: worktreePath, stash: state.stash, file: state.file)
            guard !Task.isCancelled else { return }
            let model = await Task.detached(priority: .userInitiated) {
                DiffDisplayModelBuilder.build(diff: diff, filePath: state.file.path)
            }.value
            guard !Task.isCancelled else { return }
            displayModel = diff.hunks.isEmpty ? nil : model
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            loaded = true
        }
    }
}
```

- [ ] **Step 6: Render stash diff tab in center pane**

In `Alas/Sources/Center/CenterPaneView.swift`, add a switch case:

```swift
case .stashDiff(let s):
    StashDiffTabView(
        worktreePath: worktree.path,
        state: s,
        codeFontFamily: state.config.code.fontFamily,
        codeFontSize: CGFloat(state.config.code.fontSize)
    )
    .id(s.id)
```

- [ ] **Step 7: Run tab tests**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerTests/appendStashDiffCreatesStableReadOnlyPreviewTab test
```

Expected: test passes.

- [ ] **Step 8: Commit stash preview tab**

```bash
git add Alas/Sources/Center/Tab.swift Alas/Sources/Center/TabsManager.swift Alas/Sources/App/AppState.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/Center/StashDiffTabView.swift AlasTests/TabsManagerTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(changes): add stash diff preview tab"
```

## Task 4: RightPaneState Stash Coordination

**Files:**
- Create: `Alas/Sources/Right/PendingStashDrop.swift`
- Create: `AlasTests/PendingStashDropTests.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`

- [ ] **Step 1: Write failing drop copy tests**

Create `AlasTests/PendingStashDropTests.swift`:

```swift
import Testing
@testable import Alas

struct PendingStashDropTests {
    @Test func alertCopyUsesStashRefAndSubject() {
        let stash = GitStash(ref: "stash@{0}", subject: "parser cleanup", relativeTime: "2 hours ago", sha: "abc")
        let pending = PendingStashDrop(stash: stash)

        #expect(PendingStashDrop.alertTitle(for: pending) == "Drop stash@{0}?")
        #expect(PendingStashDrop.alertMessage(for: pending) == "This permanently deletes \"parser cleanup\" from the stash list. This cannot be undone.")
    }
}
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PendingStashDropTests test
```

Expected: compile fails because `PendingStashDrop` does not exist.

- [ ] **Step 3: Add pending drop model**

Create `Alas/Sources/Right/PendingStashDrop.swift`:

```swift
struct PendingStashDrop: Equatable {
    let stash: GitStash

    static func alertTitle(for pending: PendingStashDrop) -> String {
        "Drop \(pending.stash.ref)?"
    }

    static func alertMessage(for pending: PendingStashDrop) -> String {
        "This permanently deletes \"\(pending.stash.subject)\" from the stash list. This cannot be undone."
    }
}

extension PendingStashDrop {
    static let placeholder = PendingStashDrop(
        stash: GitStash(ref: "stash@{0}", subject: "stash", relativeTime: "", sha: "")
    )
}
```

- [ ] **Step 4: Add stash state to RightPaneState**

In `Alas/Sources/Right/RightPaneState.swift`, add stored properties near existing Changes tab state:

```swift
var stashes: [GitStash] = []
var stashesExpanded: Bool = true
var expandedStashRefs: Set<String> = []
var stashFilesByRef: [String: [GitStashFile]] = [:]
var loadingStashRefs: Set<String> = []
var pendingParkChanges: Bool = false
var pendingStashDrop: PendingStashDrop? = nil
private(set) var stashOperationInFlight: Bool = false
```

In `markSnapshotUnknown()`, clear stash state:

```swift
stashes = []
expandedStashRefs = []
stashFilesByRef = [:]
loadingStashRefs = []
pendingParkChanges = false
pendingStashDrop = nil
stashOperationInFlight = false
```

- [ ] **Step 5: Load stashes during refresh**

In `refresh()`, add this async load next to the other git loads:

```swift
async let stashProbe = git.stashes(worktreePath: worktree.path)
```

After `entries` and before publishing state, resolve:

```swift
let stashes = (try? await stashProbe) ?? []
```

When publishing state, add:

```swift
self.stashes = stashes
let validRefs = Set(stashes.map(\.ref))
self.expandedStashRefs.formIntersection(validRefs)
self.stashFilesByRef = self.stashFilesByRef.filter { validRefs.contains($0.key) }
```

- [ ] **Step 6: Add park/apply/pop/drop methods**

Add these methods before the merge operation section:

```swift
func requestParkChanges() {
    guard !changes.isEmpty, mergeOp.current == nil, !stashOperationInFlight else { return }
    pendingParkChanges = true
}

func cancelParkChanges() {
    pendingParkChanges = false
}

func parkChanges(message: String, includeUntracked: Bool) {
    guard pendingParkChanges, !stashOperationInFlight else { return }
    pendingParkChanges = false
    stashOperationInFlight = true
    sidebarError = nil
    Task { @MainActor in
        defer { self.stashOperationInFlight = false }
        do {
            let result = try await self.git.pushStash(
                worktreePath: self.worktree.path,
                message: message,
                includeUntracked: includeUntracked
            )
            await self.refresh()
            self.handleStashOperationResult(result)
        } catch {
            self.sidebarError = error.localizedDescription
        }
    }
}

func toggleStashExpanded(_ stash: GitStash) {
    if expandedStashRefs.contains(stash.ref) {
        expandedStashRefs.remove(stash.ref)
    } else {
        expandedStashRefs.insert(stash.ref)
        loadFiles(for: stash)
    }
}

func loadFiles(for stash: GitStash) {
    guard stashFilesByRef[stash.ref] == nil, !loadingStashRefs.contains(stash.ref) else { return }
    loadingStashRefs.insert(stash.ref)
    Task { @MainActor in
        defer { self.loadingStashRefs.remove(stash.ref) }
        do {
            self.stashFilesByRef[stash.ref] = try await self.git.stashFiles(worktreePath: self.worktree.path, stash: stash)
        } catch {
            self.sidebarError = error.localizedDescription
        }
    }
}

func applyStash(_ stash: GitStash) {
    runStashOperation { try await self.git.applyStash(worktreePath: self.worktree.path, stash: stash) }
}

func popStash(_ stash: GitStash) {
    runStashOperation { try await self.git.popStash(worktreePath: self.worktree.path, stash: stash) }
}

func requestDropStash(_ stash: GitStash) {
    pendingStashDrop = PendingStashDrop(stash: stash)
}

func cancelDropStash() {
    pendingStashDrop = nil
}

func confirmDropStash(_ pending: PendingStashDrop) {
    if pendingStashDrop == pending { pendingStashDrop = nil }
    guard !stashOperationInFlight else { return }
    stashOperationInFlight = true
    sidebarError = nil
    Task { @MainActor in
        defer { self.stashOperationInFlight = false }
        do {
            try await self.git.dropStash(worktreePath: self.worktree.path, stash: pending.stash)
            await self.refresh()
        } catch {
            self.sidebarError = error.localizedDescription
        }
    }
}

private func runStashOperation(_ operation: @escaping () async throws -> StashOperationResult) {
    guard !stashOperationInFlight else { return }
    stashOperationInFlight = true
    sidebarError = nil
    Task { @MainActor in
        defer { self.stashOperationInFlight = false }
        do {
            let result = try await operation()
            await self.refresh()
            self.handleStashOperationResult(result)
        } catch {
            self.sidebarError = error.localizedDescription
        }
    }
}

private func handleStashOperationResult(_ result: StashOperationResult) {
    switch result {
    case .clean:
        return
    case .conflict(let message), .error(let message):
        sidebarError = message
    }
}
```

- [ ] **Step 7: Run drop tests**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PendingStashDropTests test
```

Expected: tests pass.

- [ ] **Step 8: Commit state coordination**

```bash
git add Alas/Sources/Right/PendingStashDrop.swift Alas/Sources/Right/RightPaneState.swift AlasTests/PendingStashDropTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(changes): coordinate stash operations"
```

## Task 5: Right Pane Stash UI

**Files:**
- Modify: `Alas/Sources/Right/WorkingTreeSectionView.swift`
- Create: `Alas/Sources/Right/ParkChangesSheet.swift`
- Create: `Alas/Sources/Right/StashesSectionView.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Modify: `Alas/Sources/Right/RightPaneView.swift`

- [ ] **Step 1: Add Park Changes callback to WorkingTreeSectionView**

In `WorkingTreeSectionView`, add this property:

```swift
var onParkChanges: (() -> Void)? = nil
var parkChangesDisabled: Bool = false
```

Add this menu item in the section header context menu before the discard divider:

```swift
Button("Park Changes…") {
    onParkChanges?()
}
.disabled(parkChangesDisabled || changes.isEmpty || onParkChanges == nil)
```

- [ ] **Step 2: Create ParkChangesSheet**

Create `Alas/Sources/Right/ParkChangesSheet.swift`:

```swift
import SwiftUI

struct ParkChangesSheet: View {
    let onPark: (String, Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var message = ""
    @State private var includeUntracked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Park Changes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("Move current working-tree changes into a git stash.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
            AlasField(
                text: $message,
                placeholder: "Optional message",
                focusOnAppear: true,
                onSubmit: { onPark(message, includeUntracked) }
            )
            Toggle("Include untracked files", isOn: $includeUntracked)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Park Changes") {
                    onPark(message, includeUntracked)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(theme.color("bg-2"))
    }
}
```

- [ ] **Step 3: Create StashesSectionView**

Create `Alas/Sources/Right/StashesSectionView.swift`:

```swift
import SwiftUI

struct StashesSectionView: View {
    let stashes: [GitStash]
    let filesByRef: [String: [GitStashFile]]
    let loadingRefs: Set<String>
    @Binding var expanded: Bool
    let expandedRefs: Set<String>
    let onToggleSection: () -> Void
    let onToggleStash: (GitStash) -> Void
    let onSelectFile: (GitStash, GitStashFile) -> Void
    let onApply: (GitStash) -> Void
    let onPop: (GitStash) -> Void
    let onDrop: (GitStash) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if !stashes.isEmpty {
            Section {
                if expanded {
                    ForEach(stashes) { stash in
                        stashRow(stash)
                    }
                }
            } header: {
                SectionHeader(
                    title: "Stashes",
                    count: stashes.count,
                    expanded: expanded,
                    onToggle: onToggleSection
                )
            }
        }
    }

    @ViewBuilder
    private func stashRow(_ stash: GitStash) -> some View {
        let open = expandedRefs.contains(stash.ref)
        Button {
            onToggleStash(stash)
        } label: {
            HStack(spacing: 6) {
                Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                Text(stash.subject.isEmpty ? stash.ref : stash.subject)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stash.ref)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                Spacer()
                if loadingRefs.contains(stash.ref) {
                    Spinner(lineWidth: 1.2, duration: 0.7)
                        .frame(width: 10, height: 10)
                }
                Menu {
                    Button("Apply") { onApply(stash) }
                    Button("Pop") { onPop(stash) }
                    Divider()
                    Button("Drop…", role: .destructive) { onDrop(stash) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Stash actions")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply") { onApply(stash) }
            Button("Pop") { onPop(stash) }
            Divider()
            Button("Drop…", role: .destructive) { onDrop(stash) }
        }
        if open {
            expandedFiles(for: stash)
        }
    }

    @ViewBuilder
    private func expandedFiles(for stash: GitStash) -> some View {
        let files = filesByRef[stash.ref] ?? []
        if loadingRefs.contains(stash.ref) && files.isEmpty {
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.2, duration: 0.7).frame(width: 10, height: 10)
                Text("Loading stash files…")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
            }
            .padding(.leading, 32)
            .padding(.vertical, 6)
        } else if files.isEmpty {
            Text("no files")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .padding(.leading, 32)
                .padding(.vertical, 6)
        } else {
            ForEach(files) { file in
                Button {
                    onSelectFile(stash, file)
                } label: {
                    HStack(spacing: 6) {
                        FileTypeIconView(filename: (file.path as NSString).lastPathComponent, size: 16)
                        Text((file.path as NSString).lastPathComponent)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if file.add > 0 { Text("+\(file.add)").foregroundColor(theme.color("add")) }
                        if file.del > 0 { Text("−\(file.del)").foregroundColor(theme.color("del")) }
                        StatusBadge(status: file.status)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.leading, 32)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 4: Wire Stashes into ChangesTabView**

In the `WorkingTreeSectionView` call in `ChangesTabView`, add:

```swift
onParkChanges: { rps.requestParkChanges() },
parkChangesDisabled: rps.mergeOp.current != nil || rps.stashOperationInFlight,
```

After the `WorkingTreeSectionView` block and before the divider before commits, insert:

```swift
StashesSectionView(
    stashes: rps.stashes,
    filesByRef: rps.stashFilesByRef,
    loadingRefs: rps.loadingStashRefs,
    expanded: $rps.stashesExpanded,
    expandedRefs: rps.expandedStashRefs,
    onToggleSection: { rps.stashesExpanded.toggle() },
    onToggleStash: { rps.toggleStashExpanded($0) },
    onSelectFile: { stash, file in
        appState.openStashDiffTab(worktree: rps.worktree, stash: stash, file: file)
    },
    onApply: { rps.applyStash($0) },
    onPop: { rps.popStash($0) },
    onDrop: { rps.requestDropStash($0) }
)
```

- [ ] **Step 5: Host sheet and drop alert in RightPaneView**

In `RightPaneView`, after the existing alerts, add:

```swift
.sheet(
    isPresented: Binding(
        get: { rps.pendingParkChanges },
        set: { if !$0 { rps.cancelParkChanges() } }
    )
) {
    ParkChangesSheet(
        onPark: { message, includeUntracked in
            rps.parkChanges(message: message, includeUntracked: includeUntracked)
        },
        onCancel: { rps.cancelParkChanges() }
    )
}
.alert(
    PendingStashDrop.alertTitle(for: rps.pendingStashDrop ?? .placeholder),
    isPresented: Binding(
        get: { rps.pendingStashDrop != nil },
        set: { if !$0 { rps.cancelDropStash() } }
    ),
    presenting: rps.pendingStashDrop,
    actions: { pending in
        Button("Drop", role: .destructive) {
            rps.confirmDropStash(pending)
        }
        Button("Cancel", role: .cancel) {
            rps.cancelDropStash()
        }
    },
    message: { pending in
        Text(PendingStashDrop.alertMessage(for: pending))
    }
)
```

- [ ] **Step 6: Run a targeted build**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 7: Commit right-pane UI**

```bash
git add Alas/Sources/Right/WorkingTreeSectionView.swift Alas/Sources/Right/ParkChangesSheet.swift Alas/Sources/Right/StashesSectionView.swift Alas/Sources/Right/ChangesTabView.swift Alas/Sources/Right/RightPaneView.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(changes): surface stashes in changes tab"
```

## Task 6: Verification And Polish

**Files:**
- Modify files from prior tasks only when verification finds compile or behavior gaps.

- [ ] **Step 1: Run focused tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceStashTests -only-testing:AlasTests/PendingStashDropTests -only-testing:AlasTests/TabsManagerTests test
```

Expected: all selected tests pass.

- [ ] **Step 2: Run full build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds with no Swift errors.

- [ ] **Step 3: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all tests pass.

- [ ] **Step 4: Manual verification in a temporary repository**

Use Alas UI against a small repo and verify:

```bash
mkdir /tmp/alas-stash-manual
cd /tmp/alas-stash-manual
git init -b main
git config user.email t@example.com
git config user.name "Test User"
printf "base\n" > file.txt
git add file.txt
git commit -m base
printf "base\nchanged\n" > file.txt
printf "new\n" > new.txt
```

Expected UI results:

- Working tree menu shows **Park Changes...**.
- Park sheet accepts an empty message.
- Include untracked files parks `new.txt`.
- Stashes section appears below Working tree.
- Expanding a stash lists `file.txt` and `new.txt`.
- Selecting `file.txt` opens a read-only stash diff tab.
- Apply keeps the stash.
- Pop removes the stash when apply succeeds.
- Drop asks for confirmation and removes the stash.

- [ ] **Step 5: Final commit for verification fixes**

If verification required edits:

```bash
git add Alas/Sources AlasTests
git commit -m "fix(changes): polish stash ui"
```

If verification required no edits, do not create an empty commit.

## Final Verification

Before claiming implementation complete, run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: `xcodegen` completes, build succeeds, and the full test suite passes.
