# Diff Context Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add lazy, gutter-first context expansion to the shared Alas diff review surface.

**Architecture:** Keep parsed diffs immutable and derive expanded display rows from a file snapshot plus per-file expansion state. Context providers are optional and lazy, so repository-backed screens can expand outside hunks while imported/provider-only sessions keep existing behavior. The AppKit text/ruler renderer draws the gutter `+` and routes clicks back to SwiftUI state.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSViewRepresentable`, Swift Testing, existing `GitService` and diff display model.

---

## File Structure

- Create `Alas/Sources/Center/Diff/DiffContextExpansion.swift`
  - Owns expansion keys, state, file snapshots, expansion math, and derived display groups.
- Modify `Alas/Sources/Center/Diff/DiffDisplayModel.swift`
  - Adds display metadata for expanded context/boundary rows.
- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift`
  - Renders expandable boundary rows and expanded context as neutral context.
- Modify `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
  - Passes row metadata into scroll panes/rulers and handles gutter expansion clicks.
- Modify `Alas/Sources/Center/Diff/DiffPaneView.swift`
  - Threads expansion data/actions for non-review embedded diff panes.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewModels.swift`
  - Adds optional context provider to `DiffReviewFileSectionModel`.
- Modify `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
  - Owns per-file expansion state, lazy snapshot loading, failure display, and derived display groups.
- Create `Alas/Sources/Center/DiffReview/DiffReviewContextProvider.swift`
  - Defines provider protocol and provider factories for local changes, commits, and draft review requests.
- Modify `Alas/Sources/Git/GitService.swift`
  - Adds reusable text snapshot loading helpers.
- Modify `Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift`
  - Attaches providers for staged and unstaged local changes.
- Modify `Alas/Sources/Center/Commit/CommitReviewLoader.swift`
  - Attaches providers for commit review sessions.
- Modify `Alas/Sources/Center/ReviewRequest/DraftReviewRequestDiffSessionBuilder.swift`
  - Attaches providers for draft review request sessions.
- Add/modify tests:
  - `AlasTests/DiffContextExpansionTests.swift`
  - `AlasTests/DiffPaneViewTests.swift`
  - `AlasTests/ReviewChangesLoaderTests.swift`
  - `AlasTests/CommitReviewLoaderTests.swift`
  - `AlasTests/Integrations/ReviewRequestDraftTests.swift`

## Task 1: Expansion Model And Derived Rows

**Files:**
- Create: `Alas/Sources/Center/Diff/DiffContextExpansion.swift`
- Modify: `Alas/Sources/Center/Diff/DiffDisplayModel.swift`
- Test: `AlasTests/DiffContextExpansionTests.swift`

- [ ] **Step 1: Write failing tests for chunked and all-at-once expansion**

Add this file:

```swift
import Testing
@testable import Alas

struct DiffContextExpansionTests {
    private func group() -> DiffDisplayGroup {
        let hunk = ParsedDiff.Hunk(
            header: "@@ -4,3 +4,3 @@",
            oldStart: 4,
            newStart: 4,
            lines: [
                .init(kind: .context, text: "old/new 4", oldNumber: 4, newNumber: 4),
                .init(kind: .delete, text: "old 5", oldNumber: 5, newNumber: nil),
                .init(kind: .add, text: "new 5", oldNumber: nil, newNumber: 5),
                .init(kind: .context, text: "old/new 6", oldNumber: 6, newNumber: 6),
            ]
        )
        return DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk]), filePath: "a.swift").groups[0]
    }

    private func snapshot() -> DiffReviewFileContextSnapshot {
        DiffReviewFileContextSnapshot(
            old: .available((1...10).map { "old \($0)" }),
            new: .available((1...12).map { "new \($0)" })
        )
    }

    @Test func derivesAboveBoundaryAndChunkedRows() throws {
        let base = group()
        let snapshot = snapshot()
        var state = DiffContextExpansionState()

        let initial = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot,
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        #expect(initial[0].rows.first?.contextExpansion?.boundary == .above)
        #expect(initial[0].rows.first?.collapsedLineCount == 3)

        state.expand(.init(groupID: base.id, boundary: .above), available: 3, mode: .chunk(size: 2))
        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot,
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        #expect(expanded[0].rows.prefix(3).map(\.kind) == [.expandedContext, .expandedContext, .expandableContext])
        #expect(expanded[0].rows[0].old?.lineNumber == 2)
        #expect(expanded[0].rows[1].old?.lineNumber == 3)
        #expect(expanded[0].rows[0].new?.lineNumber == 2)
        #expect(expanded[0].rows[1].new?.lineNumber == 3)
    }

    @Test func optionExpansionRevealsAllBelowBoundary() {
        let base = group()
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: base.id, boundary: .below), available: 6, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        let trailing = expanded[0].rows.suffix(6)
        #expect(trailing.allSatisfy { $0.kind == .expandedContext })
        #expect(trailing.first?.old?.lineNumber == 7)
        #expect(trailing.last?.new?.lineNumber == 12)
        #expect(expanded[0].rows.contains { $0.contextExpansion?.boundary == .below } == false)
    }

    @Test func expansionStopsAtAdjacentHunkBoundaries() {
        let first = group()
        let secondHunk = ParsedDiff.Hunk(header: "@@ -8,1 +8,1 @@", oldStart: 8, newStart: 8, lines: [
            .init(kind: .context, text: "line 8", oldNumber: 8, newNumber: 8),
        ])
        let second = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [secondHunk]), filePath: "a.swift").groups[0]
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: first.id, boundary: .below), available: 10, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [first, second],
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )

        let firstTrailingContext = expanded[0].rows.filter { $0.kind == .expandedContext }
        #expect(firstTrailingContext.map { $0.old?.lineNumber } == [7])
        #expect(firstTrailingContext.map { $0.new?.lineNumber } == [7])
    }

    @Test func originalDiffAnchorsStayStableAfterExpansion() throws {
        let base = group()
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: base.id, boundary: .above), available: 3, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        let replacement = try #require(expanded[0].rows.first { $0.kind == .replacement })
        #expect(replacement.old?.anchor == base.rows.first { $0.kind == .replacement }?.old?.anchor)
        #expect(replacement.new?.anchor == base.rows.first { $0.kind == .replacement }?.new?.anchor)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffContextExpansionTests
```

Expected: fail to compile because `DiffReviewFileContextSnapshot`, `DiffContextExpansionState`, and `.expandedContext` do not exist.

- [ ] **Step 3: Add row metadata and expansion types**

In `DiffDisplayModel.swift`, extend `DiffDisplayRow.Kind` and add metadata:

```swift
struct DiffContextExpansionKey: Codable, Equatable, Hashable, Sendable {
    let groupID: String
    let boundary: DiffContextBoundary
}

enum DiffContextBoundary: String, Codable, Equatable, Hashable, Sendable {
    case above
    case below
}

struct DiffContextExpansionRow: Codable, Equatable, Hashable, Sendable {
    let key: DiffContextExpansionKey
    let boundary: DiffContextBoundary
    let remainingLineCount: Int
}

struct DiffDisplayRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case context
        case add
        case delete
        case replacement
        case collapsed
        case expandedContext
        case expandableContext
    }

    let id: String
    let kind: Kind
    let old: DiffDisplayLine?
    let new: DiffDisplayLine?
    let collapsedLineCount: Int
    let collapsedRows: [DiffDisplayRow]
    var contextExpansion: DiffContextExpansionRow?

    init(
        id: String,
        kind: Kind,
        old: DiffDisplayLine?,
        new: DiffDisplayLine?,
        collapsedLineCount: Int,
        collapsedRows: [DiffDisplayRow] = [],
        contextExpansion: DiffContextExpansionRow? = nil
    ) {
        self.id = id
        self.kind = kind
        self.old = old
        self.new = new
        self.collapsedLineCount = collapsedLineCount
        self.collapsedRows = collapsedRows
        self.contextExpansion = contextExpansion
    }
}
```

- [ ] **Step 4: Add the expansion model**

Create `DiffContextExpansion.swift`:

```swift
import Foundation

struct DiffReviewFileContextSnapshot: Equatable, Sendable {
    enum Side: Equatable, Sendable {
        case unavailable
        case available([String])

        var lineCount: Int {
            if case .available(let lines) = self { return lines.count }
            return 0
        }

        func line(number: Int) -> String? {
            guard case .available(let lines) = self,
                  number >= 1,
                  number <= lines.count
            else { return nil }
            return lines[number - 1]
        }
    }

    let old: Side
    let new: Side
}

enum DiffContextExpansionMode: Equatable {
    case chunk(size: Int)
    case all
}

struct DiffContextExpansionState: Equatable {
    private var revealed: [DiffContextExpansionKey: Int] = [:]

    func revealedCount(for key: DiffContextExpansionKey) -> Int {
        revealed[key, default: 0]
    }

    mutating func expand(_ key: DiffContextExpansionKey, available: Int, mode: DiffContextExpansionMode) {
        let current = revealedCount(for: key)
        let next: Int
        switch mode {
        case .chunk(let size):
            next = min(available, current + max(size, 1))
        case .all:
            next = available
        }
        revealed[key] = next
    }
}

enum DiffContextExpandedDisplayBuilder {
    static func derive(
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?,
        providerAvailable: Bool,
        expansion: DiffContextExpansionState,
        filePath: String,
        chunkSize: Int
    ) -> [DiffDisplayGroup] {
        guard snapshot != nil || providerAvailable else { return groups }
        return groups.indices.map { index in
            let group = groups[index]
            DiffDisplayGroup(
                id: group.id,
                header: group.header,
                sourceHunk: group.sourceHunk,
                rows: rows(
                    for: group,
                    previous: index > 0 ? groups[index - 1] : nil,
                    next: index < groups.count - 1 ? groups[index + 1] : nil,
                    snapshot: snapshot,
                    providerAvailable: providerAvailable,
                    expansion: expansion,
                    filePath: filePath,
                    chunkSize: chunkSize
                )
            )
        }
    }

    private static func rows(
        for group: DiffDisplayGroup,
        previous: DiffDisplayGroup?,
        next: DiffDisplayGroup?,
        snapshot: DiffReviewFileContextSnapshot?,
        providerAvailable: Bool,
        expansion: DiffContextExpansionState,
        filePath: String,
        chunkSize: Int
    ) -> [DiffDisplayRow] {
        boundaryRows(.above, group: group, previous: previous, next: next, snapshot: snapshot, providerAvailable: providerAvailable, expansion: expansion, filePath: filePath, chunkSize: chunkSize)
            + group.rows
            + boundaryRows(.below, group: group, previous: previous, next: next, snapshot: snapshot, providerAvailable: providerAvailable, expansion: expansion, filePath: filePath, chunkSize: chunkSize)
    }

    private static func boundaryRows(
        _ boundary: DiffContextBoundary,
        group: DiffDisplayGroup,
        previous: DiffDisplayGroup?,
        next: DiffDisplayGroup?,
        snapshot: DiffReviewFileContextSnapshot?,
        providerAvailable: Bool,
        expansion: DiffContextExpansionState,
        filePath: String,
        chunkSize: Int
    ) -> [DiffDisplayRow] {
        let key = DiffContextExpansionKey(groupID: group.id, boundary: boundary)
        let available = snapshot.map { availableCount(boundary, group: group, previous: previous, next: next, snapshot: $0) } ?? optimisticAvailableCount(boundary, group: group, previous: previous, next: next, providerAvailable: providerAvailable)
        guard available > 0 else { return [] }
        let revealed = min(expansion.revealedCount(for: key), available)
        var rows = expandedRows(
            boundary,
            group: group,
            previous: previous,
            next: next,
            snapshot: snapshot,
            filePath: filePath,
            revealed: revealed
        )
        let remaining = available - revealed
        if remaining > 0 {
            rows.append(DiffDisplayRow(
                id: "\(group.id)-context-\(boundary.rawValue)-control",
                kind: .expandableContext,
                old: nil,
                new: nil,
                collapsedLineCount: remaining,
                contextExpansion: DiffContextExpansionRow(key: key, boundary: boundary, remainingLineCount: remaining)
            ))
        }
        return rows
    }

    static func availableLineCount(
        key: DiffContextExpansionKey,
        groups: [DiffDisplayGroup],
        snapshot: DiffReviewFileContextSnapshot?
    ) -> Int {
        guard let group = groups.first(where: { $0.id == key.groupID }), let snapshot else { return 0 }
        let index = groups.firstIndex(where: { $0.id == key.groupID })!
        return availableCount(
            key.boundary,
            group: group,
            previous: index > 0 ? groups[index - 1] : nil,
            next: index < groups.count - 1 ? groups[index + 1] : nil,
            snapshot: snapshot
        )
    }

    private static func optimisticAvailableCount(
        _ boundary: DiffContextBoundary,
        group: DiffDisplayGroup,
        previous: DiffDisplayGroup?,
        next: DiffDisplayGroup?,
        providerAvailable: Bool
    ) -> Int {
        guard providerAvailable else { return 0 }
        switch boundary {
        case .above:
            let oldStart = group.sourceHunk.lines.compactMap(\.oldNumber).min() ?? 1
            let newStart = group.sourceHunk.lines.compactMap(\.newNumber).min() ?? 1
            let previousOldEnd = previous?.sourceHunk.lines.compactMap(\.oldNumber).max() ?? 0
            let previousNewEnd = previous?.sourceHunk.lines.compactMap(\.newNumber).max() ?? 0
            return max(oldStart - previousOldEnd - 1, newStart - previousNewEnd - 1)
        case .below:
            if let next {
                let oldEnd = group.sourceHunk.lines.compactMap(\.oldNumber).max() ?? 0
                let newEnd = group.sourceHunk.lines.compactMap(\.newNumber).max() ?? 0
                let nextOldStart = next.sourceHunk.lines.compactMap(\.oldNumber).min() ?? oldEnd + 1
                let nextNewStart = next.sourceHunk.lines.compactMap(\.newNumber).min() ?? newEnd + 1
                return max(nextOldStart - oldEnd - 1, nextNewStart - newEnd - 1)
            }
            return 1
        }
    }

    private static func availableCount(
        _ boundary: DiffContextBoundary,
        group: DiffDisplayGroup,
        previous: DiffDisplayGroup?,
        next: DiffDisplayGroup?,
        snapshot: DiffReviewFileContextSnapshot
    ) -> Int {
        let oldNumbers = group.sourceHunk.lines.compactMap(\.oldNumber)
        let newNumbers = group.sourceHunk.lines.compactMap(\.newNumber)
        switch boundary {
        case .above:
            let previousOldEnd = previous?.sourceHunk.lines.compactMap(\.oldNumber).max() ?? 0
            let previousNewEnd = previous?.sourceHunk.lines.compactMap(\.newNumber).max() ?? 0
            return max((oldNumbers.min() ?? 1) - previousOldEnd - 1, (newNumbers.min() ?? 1) - previousNewEnd - 1)
        case .below:
            let oldEnd = oldNumbers.max() ?? 0
            let newEnd = newNumbers.max() ?? 0
            let oldLimit = next?.sourceHunk.lines.compactMap(\.oldNumber).min().map { $0 - 1 } ?? snapshot.old.lineCount
            let newLimit = next?.sourceHunk.lines.compactMap(\.newNumber).min().map { $0 - 1 } ?? snapshot.new.lineCount
            return max(oldLimit - oldEnd, newLimit - newEnd)
        }
    }

    private static func expandedRows(
        _ boundary: DiffContextBoundary,
        group: DiffDisplayGroup,
        previous: DiffDisplayGroup?,
        next: DiffDisplayGroup?,
        snapshot: DiffReviewFileContextSnapshot?,
        filePath: String,
        revealed: Int
    ) -> [DiffDisplayRow] {
        guard revealed > 0, let snapshot else { return [] }
        let oldNumbers = group.sourceHunk.lines.compactMap(\.oldNumber)
        let newNumbers = group.sourceHunk.lines.compactMap(\.newNumber)
        let oldStart: Int
        let newStart: Int
        switch boundary {
        case .above:
            oldStart = max(1, (oldNumbers.min() ?? 1) - revealed)
            newStart = max(1, (newNumbers.min() ?? 1) - revealed)
        case .below:
            oldStart = (oldNumbers.max() ?? 0) + 1
            newStart = (newNumbers.max() ?? 0) + 1
        }

        return (0..<revealed).map { offset in
            let oldNumber = oldStart + offset
            let newNumber = newStart + offset
            let oldText = snapshot.old.line(number: oldNumber)
            let newText = snapshot.new.line(number: newNumber)
            return DiffDisplayRow(
                id: "\(group.id)-context-\(boundary.rawValue)-\(offset)",
                kind: .expandedContext,
                old: oldText.map { displayLine($0, filePath: filePath, group: group, rowIndex: -10_000 - offset, side: .old, lineNumber: oldNumber, pairedNewLine: newText == nil ? nil : newNumber) },
                new: newText.map { displayLine($0, filePath: filePath, group: group, rowIndex: -10_000 - offset, side: .new, lineNumber: newNumber, pairedOldLine: oldText == nil ? nil : oldNumber) },
                collapsedLineCount: 0
            )
        }
    }

    private static func displayLine(
        _ text: String,
        filePath: String,
        group: DiffDisplayGroup,
        rowIndex: Int,
        side: DiffLineSide,
        lineNumber: Int,
        pairedOldLine: Int? = nil,
        pairedNewLine: Int? = nil
    ) -> DiffDisplayLine {
        let anchor = DiffLineAnchor(
            filePath: filePath,
            hunkIndex: group.sourceHunk.oldStart,
            rowIndex: rowIndex,
            side: side,
            oldLine: side == .old ? lineNumber : pairedOldLine,
            newLine: side == .new ? lineNumber : pairedNewLine
        )
        return DiffDisplayLine(
            id: "\(filePath):expanded:\(side.rawValue):\(lineNumber):\(rowIndex)",
            anchor: anchor,
            text: text,
            lineNumber: lineNumber,
            kind: .context,
            inlineSpans: [],
            noTrailingNewline: false
        )
    }
}
```

- [ ] **Step 5: Update row projection for new row kinds**

In `DiffPaneView.swift`, update changed-row checks:

```swift
private static func isChanged(_ row: DiffDisplayRow) -> Bool {
    row.kind == .replacement || row.kind == .delete || row.kind == .add
}

static func stackedLines(for row: DiffDisplayRow) -> [DiffDisplayLine] {
    if row.kind == .context || row.kind == .expandedContext {
        if let new = row.new { return [new] }
        if let old = row.old { return [old] }
        return []
    }
    return [row.old, row.new].compactMap { $0 }
}
```

- [ ] **Step 6: Run model tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffContextExpansionTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/Diff/DiffContextExpansion.swift Alas/Sources/Center/Diff/DiffDisplayModel.swift Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/DiffContextExpansionTests.swift
git commit -m "Add diff context expansion model"
```

## Task 2: Provider Protocol And Git Snapshot Loading

**Files:**
- Create: `Alas/Sources/Center/DiffReview/DiffReviewContextProvider.swift`
- Modify: `Alas/Sources/Git/GitService.swift`
- Test: `AlasTests/ReviewChangesLoaderTests.swift`

- [ ] **Step 1: Add failing provider tests**

In `ReviewChangesLoaderTests.swift`, extend `FakeReviewChangesGitClient` and add:

```swift
@Test func attachesContextProviderForUnstagedAndStagedFiles() async throws {
    let git = FakeReviewChangesGitClient(
        status: [
            ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 1, renameFrom: nil),
            ChangedFile(path: "b.swift", status: "M", stage: .staged, add: 1, del: 1, renameFrom: nil),
        ],
        diffs: [
            .init(path: "a.swift", staged: false): diff(lines: [.init(kind: .context, text: "a", oldNumber: 1, newNumber: 1)]),
            .init(path: "b.swift", staged: true): diff(lines: [.init(kind: .context, text: "b", oldNumber: 1, newNumber: 1)]),
        ],
        snapshots: [
            .init(path: "a.swift", staged: false): DiffReviewFileContextSnapshot(old: .available(["old a"]), new: .available(["new a"])),
            .init(path: "b.swift", staged: true): DiffReviewFileContextSnapshot(old: .available(["old b"]), new: .available(["new b"])),
        ]
    )
    let loader = ReviewChangesLoader(git: git)

    let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

    #expect(try await session.files[0].contextProvider?.snapshot() == DiffReviewFileContextSnapshot(old: .available(["old a"]), new: .available(["new a"])))
    #expect(try await session.files[1].contextProvider?.snapshot() == DiffReviewFileContextSnapshot(old: .available(["old b"]), new: .available(["new b"])))
}
```

Update the fake:

```swift
private struct FakeReviewChangesGitClient: ReviewChangesGitClient {
    var status: [ChangedFile]
    var diffs: [DiffKey: ParsedDiff]
    var snapshots: [DiffKey: DiffReviewFileContextSnapshot] = [:]

    func status(worktreePath: URL) async throws -> [ChangedFile] { status }

    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff {
        diffs[DiffKey(path: file, staged: staged, originalPath: originalPath), default: ParsedDiff(hunks: [])]
    }

    func contextSnapshot(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
        snapshots[DiffKey(path: file, staged: staged, originalPath: originalPath), default: DiffReviewFileContextSnapshot(old: .unavailable, new: .unavailable)]
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ReviewChangesLoaderTests/attachesContextProviderForUnstagedAndStagedFiles
```

Expected: fail to compile because `contextProvider`, `DiffReviewContextProvider`, and `contextSnapshot` do not exist.

- [ ] **Step 3: Add provider protocol and model property**

Create `DiffReviewContextProvider.swift`:

```swift
import Foundation

struct DiffReviewContextProvider {
    let snapshot: @Sendable () async throws -> DiffReviewFileContextSnapshot
}
```

In `DiffReviewModels.swift`, add to `DiffReviewFileSectionModel`:

```swift
let contextProvider: DiffReviewContextProvider?
```

Update every `DiffReviewFileSectionModel(...)` construction to pass `contextProvider: nil` until the next step wires real providers.

- [ ] **Step 4: Extend review changes git client**

In `ReviewChangesLoader.swift`, update the protocol:

```swift
protocol ReviewChangesGitClient {
    func status(worktreePath: URL) async throws -> [ChangedFile]
    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff
    func contextSnapshot(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> DiffReviewFileContextSnapshot
}
```

Attach the provider in `fileSection` by accepting `worktreePath` and passing:

```swift
contextProvider: DiffReviewContextProvider {
    try await git.contextSnapshot(
        worktreePath: worktreePath,
        file: change.path,
        staged: change.stage == .staged,
        originalPath: change.renameFrom
    )
}
```

- [ ] **Step 5: Implement GitService snapshot helpers**

In `GitService.swift`, add:

```swift
func contextSnapshot(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
    if staged {
        let head = try await hasHead(worktreePath: worktreePath)
        let oldPath = originalPath ?? file
        let old = head ? try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: "HEAD", path: oldPath) : .available([])
        let new = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: ":", path: file)
        return DiffReviewFileContextSnapshot(old: old, new: new)
    }

    let oldPath = originalPath ?? file
    let old = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: ":", path: oldPath)
    let new = try await worktreeLinesOrUnavailable(worktreePath: worktreePath, path: file)
    return DiffReviewFileContextSnapshot(old: old, new: new)
}

func commitContextSnapshot(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
    let parent = try await firstParentOrEmptyTree(worktreePath: worktreePath, sha: sha)
    let old = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: parent, path: originalPath ?? file)
    let new = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: sha, path: file)
    return DiffReviewFileContextSnapshot(old: old, new: new)
}

func refContextSnapshot(worktreePath: URL, baseRef: String, headRef: String, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
    let old = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: baseRef, path: originalPath ?? file)
    let new = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: headRef, path: file)
    return DiffReviewFileContextSnapshot(old: old, new: new)
}

private func firstParentOrEmptyTree(worktreePath: URL, sha: String) async throws -> String {
    let result = try await Process.git(["rev-list", "--parents", "-n", "1", sha], cwd: worktreePath)
    guard result.exitCode == 0 else { return "4b825dc642cb6eb9a060e54bf8d69288fbee4904" }
    let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    return parts.count > 1 ? String(parts[1]) : "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}

private func blobLinesOrUnavailable(worktreePath: URL, ref: String, path: String) async throws -> DiffReviewFileContextSnapshot.Side {
    let spec = ref == ":" ? ":\(path)" : "\(ref):\(path)"
    let result = try await Process.gitData(["show", spec], cwd: worktreePath)
    guard result.exitCode == 0, !Self.looksBinary(result.stdout) else { return .unavailable }
    guard let text = String(data: result.stdout, encoding: .utf8) else { return .unavailable }
    return .available(Self.splitContextLines(text))
}

private func worktreeLinesOrUnavailable(worktreePath: URL, path: String) async throws -> DiffReviewFileContextSnapshot.Side {
    let url = worktreePath.appendingPathComponent(path)
    let data = try Data(contentsOf: url)
    guard !Self.looksBinary(data), let text = String(data: data, encoding: .utf8) else { return .unavailable }
    return .available(Self.splitContextLines(text))
}

private static func splitContextLines(_ text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
}
```

- [ ] **Step 6: Run provider tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ReviewChangesLoaderTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewContextProvider.swift Alas/Sources/Center/DiffReview/DiffReviewModels.swift Alas/Sources/Center/ReviewChanges/ReviewChangesLoader.swift Alas/Sources/Git/GitService.swift AlasTests/ReviewChangesLoaderTests.swift
git commit -m "Load diff context snapshots lazily"
```

## Task 3: Commit And Draft Review Request Providers

**Files:**
- Modify: `Alas/Sources/Center/Commit/CommitReviewLoader.swift`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestDiffSessionBuilder.swift`
- Test: `AlasTests/CommitReviewLoaderTests.swift`
- Test: `AlasTests/Integrations/ReviewRequestDraftTests.swift`

- [ ] **Step 1: Write failing commit provider test**

In `CommitReviewLoaderTests.swift`, add:

```swift
@Test func attachesContextProviderForCommitFiles() async throws {
    let diff = ParsedDiff(hunks: [
        ParsedDiff.Hunk(header: "@@ -1,1 +1,1 @@", oldStart: 1, newStart: 1, lines: [
            .init(kind: .delete, text: "old", oldNumber: 1, newNumber: nil),
            .init(kind: .add, text: "new", oldNumber: nil, newNumber: 1),
        ]),
    ])
    let snapshot = DiffReviewFileContextSnapshot(old: .available(["old"]), new: .available(["new"]))
    let git = FakeCommitReviewGitClient(diffs: ["a.swift": diff], snapshots: ["abc123:a.swift": snapshot])
    let loader = CommitReviewLoader(git: git)

    let session = try await loader.load(
        worktreePath: URL(fileURLWithPath: "/tmp/repo"),
        sha: "abc123",
        files: [CommitChangedFile(path: "a.swift", status: "M", add: 1, del: 1, originalPath: nil)],
        openFileForPath: { _ in nil }
    )

    #expect(try await session.files.first?.contextProvider?.snapshot() == snapshot)
}
```

Update the fake to implement:

```swift
func commitContextSnapshot(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
    snapshots["\(sha):\(file)", default: DiffReviewFileContextSnapshot(old: .unavailable, new: .unavailable)]
}
```

- [ ] **Step 2: Write failing draft review request provider test**

In `ReviewRequestDraftTests.swift`, add:

```swift
@Test func draftReviewRequestSessionAttachesContextProvider() async throws {
    let context = ReviewRequestDraftContext(
        provider: .github,
        repositorySlug: "owner/repo",
        baseBranch: "main",
        headBranch: "feature",
        headSHA: "abc123",
        title: "Title",
        body: "",
        changedFiles: [
            CommitChangedFile(path: "Sources/App.swift", status: "M", add: 1, del: 1, originalPath: nil),
        ],
        fileDiffsByPath: [
            "Sources/App.swift": "@@ -1,1 +1,1 @@\n-old\n+new\n",
        ],
        commits: []
    )
    let provider = DiffReviewContextProvider {
        DiffReviewFileContextSnapshot(old: .available(["old"]), new: .available(["new"]))
    }

    let session = try await DraftReviewRequestDiffSessionBuilder.build(
        context: context,
        worktreePath: URL(fileURLWithPath: "/tmp/repo"),
        openFileForPath: { _ in nil },
        contextProviderForPath: { path, _ in path == "Sources/App.swift" ? provider : nil }
    )

    #expect(try await session.files.first?.contextProvider?.snapshot() == DiffReviewFileContextSnapshot(old: .available(["old"]), new: .available(["new"])))
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/CommitReviewLoaderTests/attachesContextProviderForCommitFiles -only-testing:AlasTests/Integrations/ReviewRequestDraftTests/draftReviewRequestSessionAttachesContextProvider
```

Expected: fail to compile because loader protocols/builders do not expose provider hooks.

- [ ] **Step 4: Extend commit review protocol and loader**

In `CommitReviewLoader.swift`, update:

```swift
protocol CommitReviewGitClient {
    func diff(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> ParsedDiff
    func commitContextSnapshot(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot
}
```

Pass this in `DiffReviewFileSectionModel`:

```swift
contextProvider: DiffReviewContextProvider {
    try await git.commitContextSnapshot(
        worktreePath: worktreePath,
        sha: sha,
        file: file.path,
        originalPath: file.originalPath
    )
}
```

Thread `worktreePath` and `sha` into `fileSection`.

- [ ] **Step 5: Extend draft review request builder**

Change the builder signature:

```swift
static func build(
    context: ReviewRequestDraftContext,
    worktreePath: URL,
    openFileForPath: @escaping (String) -> (() -> Void)?,
    contextProviderForPath: @escaping (String, String?) -> DiffReviewContextProvider? = { _, _ in nil }
) async throws -> DiffReviewLoadedSession
```

Pass into `fileSection`:

```swift
contextProvider: contextProviderForPath(file.path, file.originalPath)
```

In `DraftReviewRequestTabView.swift` and `ReviewSessionLoader.swift`, create the provider:

```swift
contextProviderForPath: { path, originalPath in
    DiffReviewContextProvider {
        try await GitService().refContextSnapshot(
            worktreePath: worktreePath,
            baseRef: tabState.baseBranch,
            headRef: tabState.headSHA.isEmpty ? "HEAD" : tabState.headSHA,
            file: path,
            originalPath: originalPath
        )
    }
}
```

Use `base` and `headSHA ?? "HEAD"` in `ReviewSessionLoader.production` where `tabState` is not in scope.

- [ ] **Step 6: Run targeted tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/CommitReviewLoaderTests -only-testing:AlasTests/Integrations/ReviewRequestDraftTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/Commit/CommitReviewLoader.swift Alas/Sources/Center/ReviewRequest/DraftReviewRequestDiffSessionBuilder.swift Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift AlasTests/CommitReviewLoaderTests.swift AlasTests/Integrations/ReviewRequestDraftTests.swift
git commit -m "Attach context providers to review sessions"
```

## Task 4: Render Expansion Boundary Rows In Text Documents

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
- Test: `AlasTests/DiffPaneViewTests.swift`

- [ ] **Step 1: Add failing document builder expectations**

In `DiffPaneViewTests.swift`, add:

```swift
@Test @MainActor func expandableContextRowsRenderAsGutterPlusRows() throws {
    let group = DiffDisplayGroup(
        id: "hunk-0",
        header: "@@ -2,1 +2,1 @@",
        sourceHunk: ParsedDiff.Hunk(header: "@@ -2,1 +2,1 @@", oldStart: 2, newStart: 2, lines: []),
        rows: [
            DiffDisplayRow(
                id: "expand",
                kind: .expandableContext,
                old: nil,
                new: nil,
                collapsedLineCount: 9,
                contextExpansion: DiffContextExpansionRow(
                    key: DiffContextExpansionKey(groupID: "hunk-0", boundary: .above),
                    boundary: .above,
                    remainingLineCount: 9
                )
            ),
        ]
    )
    let result = DiffPaneTextDocumentBuilder.buildSplit(
        group: group,
        expandedCollapsedRowIDs: [],
        fileExtension: "swift",
        font: CenterTypography.resolveCodeFont(family: "", size: 13),
        showWhitespace: false,
        theme: theme()
    )

    #expect(result.oldGutter.string.contains("+"))
    #expect(result.oldCode.attributedString.string.contains("9 unchanged lines above"))
    #expect(result.oldCode.lines.first?.expansionKey == DiffContextExpansionKey(groupID: "hunk-0", boundary: .above))
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests/expandableContextRowsRenderAsGutterPlusRows
```

Expected: fail because `LineMetadata.expansionKey` and rendering do not exist.

- [ ] **Step 3: Add expansion metadata to text document lines**

In `DiffPaneTextDocumentBuilder.LineMetadata`, add:

```swift
var expansionKey: DiffContextExpansionKey? = nil
var expansionBoundary: DiffContextBoundary? = nil
```

When appending rows, preserve `row.contextExpansion?.key` and `row.contextExpansion?.boundary`.

- [ ] **Step 4: Render expandable rows**

Update `buildSplit` and `buildStacked` row loops:

```swift
if row.kind == .expandableContext {
    let text = expandableContextText(row)
    oldColumn.append(text, kind: row.kind, tone: .collapsed, sourceLine: nil, expansion: row.contextExpansion)
    newColumn.append(emptyLayoutGlyph(font: font, theme: theme), kind: row.kind, tone: .collapsed, sourceLine: nil, expansion: row.contextExpansion)
    oldGutter.append("+", side: .paired)
    newGutter.append("", side: .paired)
    continue
}
```

Add:

```swift
private static func expandableContextText(_ row: DiffDisplayRow, font: NSFont, theme: Theme) -> NSAttributedString {
    let boundary = row.contextExpansion?.boundary == .above ? "above" : "below"
    let label = row.collapsedLineCount > 0
        ? "\(row.collapsedLineCount) unchanged lines \(boundary)"
        : "Expand context \(boundary)"
    return NSAttributedString(
        string: label,
        attributes: [
            .font: font,
            .foregroundColor: NSColor(theme.color("fg-dim")),
            .backgroundColor: NSColor(theme.color("bg-2")),
            .paragraphStyle: CenterTypography.paragraphStyle(),
        ]
    )
}
```

Adjust the existing accumulator `append` helper to accept an optional `expansion`.

- [ ] **Step 5: Treat expanded context as normal context for colors**

Update `DiffPaneLineTone.init`:

```swift
case .expandedContext:
    self = .context
case .expandableContext:
    self = .collapsed
```

Update any `switch row.kind` in `DiffPaneTextDocumentBuilder` to include `.expandedContext` with `.context` and `.expandableContext` with `.collapsed`.

- [ ] **Step 6: Run rendering tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/Diff/DiffPaneTextDocumentBuilder.swift Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift AlasTests/DiffPaneViewTests.swift
git commit -m "Render expandable diff context rows"
```

## Task 5: Gutter Click Handling

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift`
- Modify: `Alas/Sources/Center/Diff/DiffPaneView.swift`
- Test: `AlasTests/DiffPaneViewTests.swift`

- [ ] **Step 1: Add failing gutter interaction test**

In `DiffPaneViewTests.swift`, add:

```swift
@Test @MainActor func lineNumberRulerInvokesExpansionActionForExpandableRows() throws {
    let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .above)
    let font = CenterTypography.resolveCodeFont(family: "", size: 13)
    let document = DiffPaneTextDocumentBuilder.CodeDocument(
        attributedString: NSAttributedString(string: "9 unchanged lines above", attributes: [.font: font]),
        lines: [
            .init(
                kind: .expandableContext,
                range: NSRange(location: 0, length: 23),
                tone: .collapsed,
                expansionKey: key,
                expansionBoundary: .above
            ),
        ]
    )
    var captured: (DiffContextExpansionKey, DiffContextExpansionMode)?

    scrollView.update(
        document: document,
        lineLabels: ["+"],
        wraps: false,
        font: font,
        theme: theme(),
        lspContext: nil,
        allowedLSPSide: .new,
        onContextExpansion: { key, mode in captured = (key, mode) }
    )
    let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
    ruler.invokeExpansionForTesting(row: 0, optionKey: false)

    #expect(captured?.0 == key)
    #expect(captured?.1 == .chunk(size: 10))
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests/lineNumberRulerInvokesExpansionActionForExpandableRows
```

Expected: fail because `onContextExpansion` and `invokeExpansionForTesting` do not exist.

- [ ] **Step 3: Thread expansion actions through the text document view**

Add to `DiffPaneTextDocumentView`:

```swift
var onContextExpansion: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
```

Pass it into `DiffPaneTextDocumentContainerView.update`, then to each `DiffPaneTextScrollView.update`.

- [ ] **Step 4: Store expansion metadata in scroll/ruler**

In `DiffPaneTextScrollView`, add:

```swift
private var expansionKeys: [DiffContextExpansionKey?] = []
private var onContextExpansion: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
```

In `update`, assign:

```swift
self.expansionKeys = document.lines.map(\.expansionKey)
self.onContextExpansion = onContextExpansion
```

Pass both to the ruler:

```swift
ruler.update(..., expansionKeys: expansionKeys, onContextExpansion: onContextExpansion)
```

- [ ] **Step 5: Handle ruler clicks**

In `DiffPaneLineNumberRulerView`, add:

```swift
private var expansionKeys: [DiffContextExpansionKey?] = []
private var onContextExpansion: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
private let defaultExpansionChunkSize = 10
```

Update `mouseDown` before review-line selection:

```swift
let row = rowIndex(at: sourcePoint)
if let row, expansionKeys.indices.contains(row), let key = expansionKeys[row] {
    let mode: DiffContextExpansionMode = event.modifierFlags.contains(.option)
        ? .all
        : .chunk(size: defaultExpansionChunkSize)
    onContextExpansion(key, mode)
    return
}
```

Add helpers:

```swift
private func rowIndex(at point: NSPoint) -> Int? {
    diffRowRects().firstIndex { $0.contains(point) }
}

func invokeExpansionForTesting(row: Int, optionKey: Bool) {
    guard expansionKeys.indices.contains(row), let key = expansionKeys[row] else { return }
    onContextExpansion(key, optionKey ? .all : .chunk(size: defaultExpansionChunkSize))
}
```

- [ ] **Step 6: Run gutter tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests/lineNumberRulerInvokesExpansionActionForExpandableRows
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Center/Diff/DiffPaneTextDocumentView.swift Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/DiffPaneViewTests.swift
git commit -m "Handle gutter context expansion clicks"
```

## Task 6: Wire Expansion Into DiffReviewFileSection

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift`
- Test: `AlasTests/ReviewChangesTabViewTests.swift`

- [ ] **Step 1: Add failing surface rendering test**

In `ReviewChangesTabViewTests.swift`, add:

```swift
@Test @MainActor func diffReviewFileSectionShowsLazyExpandableContextControlsForProvider() throws {
    var layout = DiffLayoutMode.split
    var wrap = false
    var whitespace = false
    let hunk = ParsedDiff.Hunk(header: "@@ -4,1 +4,1 @@", oldStart: 4, newStart: 4, lines: [
        .init(kind: .context, text: "line 4", oldNumber: 4, newNumber: 4),
    ])
    let diff = ParsedDiff(hunks: [hunk])
    let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "a.swift")
    let file = DiffReviewFileSectionModel(
        summary: summary(path: "a.swift", source: .unstaged, status: .modified, additions: 0, deletions: 0),
        parsedDiff: diff,
        displayModel: model,
        placeholderMessage: nil,
        openFile: nil,
        contextProvider: DiffReviewContextProvider {
            DiffReviewFileContextSnapshot(
                old: .available((1...8).map { "old \($0)" }),
                new: .available((1...8).map { "new \($0)" })
            )
        }
    )

    let view = DiffReviewFileSection(
        file: file,
        layoutMode: Binding(get: { layout }, set: { layout = $0 }),
        wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
        showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
        codeFontFamily: "",
        codeFontSize: 13,
        showsSourceBadge: false
    )
    .environment(\.theme, try! ThemeStore().current)

    let controller = NSHostingController(rootView: view)
    controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 400)
    controller.view.layoutSubtreeIfNeeded()

    let text = allSubviews(of: controller.view)
        .compactMap { ($0 as? NSTextView)?.string }
        .joined(separator: "\n")
    #expect(text.contains("Expand context above"))
    #expect(text.contains("Expand context below"))
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ReviewChangesTabViewTests/diffReviewFileSectionShowsLazyExpandableContextControlsForProvider
```

Expected: fail because `DiffReviewFileSection` does not derive optimistic provider-backed boundary controls.

- [ ] **Step 3: Add state and lazy load helper**

In `DiffReviewFileSection`, add:

```swift
@State private var contextSnapshot: DiffReviewFileContextSnapshot?
@State private var contextExpansion = DiffContextExpansionState()
@State private var contextLoadTask: Task<Void, Never>?
@State private var contextLoadError: String?
```

Add:

```swift
private func loadContextAndExpand(_ key: DiffContextExpansionKey, mode: DiffContextExpansionMode) {
    guard let provider = file.contextProvider else { return }
    if contextSnapshot != nil {
        applyContextExpansion(key, mode: mode)
        return
    }
    guard contextLoadTask == nil else { return }
    contextLoadError = nil
    contextLoadTask = Task {
        do {
            let snapshot = try await provider.snapshot()
            await MainActor.run {
                contextSnapshot = snapshot
                contextLoadTask = nil
                applyContextExpansion(key, mode: mode)
            }
        } catch {
            await MainActor.run {
                contextLoadError = error.localizedDescription
                contextLoadTask = nil
            }
        }
    }
}

private func applyContextExpansion(_ key: DiffContextExpansionKey, mode: DiffContextExpansionMode) {
    guard let displayModel = file.displayModel else { return }
    let available = DiffContextExpandedDisplayBuilder.availableLineCount(
        key: key,
        groups: displayModel.groups,
        snapshot: contextSnapshot
    )
    contextExpansion.expand(key, available: available, mode: mode)
}
```

Expose `availableLineCount` from `DiffContextExpandedDisplayBuilder`. The first click loads the snapshot and then applies the requested chunk or all-at-once expansion with the exact available line count.

- [ ] **Step 4: Derive groups before rendering**

In `content`, compute:

```swift
let groups = DiffContextExpandedDisplayBuilder.derive(
    groups: displayModel.groups,
    snapshot: contextSnapshot,
    providerAvailable: file.contextProvider != nil,
    expansion: contextExpansion,
    filePath: displayModel.filePath,
    chunkSize: 10
)
```

Use `groups` for placement and rendering. Before the snapshot loads, `providerAvailable: true` creates optimistic `Expand context above/below` rows. After the first successful expansion click, the loaded snapshot gives exact counts and concrete expanded rows.

- [ ] **Step 5: Pass expansion action to text views**

For both `DiffPaneTextDocumentView` and `DiffPaneView`, pass:

```swift
onContextExpansion: loadContextAndExpand
```

- [ ] **Step 6: Show load failure**

Below the file header and before content, add:

```swift
if let contextLoadError {
    Text("Could not load surrounding context: \(contextLoadError)")
        .font(.system(size: 11))
        .foregroundColor(theme.color("warn"))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
}
```

- [ ] **Step 7: Run file section test**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ReviewChangesTabViewTests/diffReviewFileSectionShowsLazyExpandableContextControlsForProvider
```

Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift Alas/Sources/Center/Diff/DiffContextExpansion.swift AlasTests/ReviewChangesTabViewTests.swift
git commit -m "Wire context expansion into review diffs"
```

## Task 7: Final Verification And Project Regeneration Check

**Files:**
- Modify only if `project.yml` or generated project membership requires it.

- [ ] **Step 1: Check whether new source/test files are included by project generation**

Run:

```bash
xcodegen
git status --short
```

Expected: if `Alas.xcodeproj/project.pbxproj` changes, keep it. If it does not change, the project already included the files through generation rules.

- [ ] **Step 2: Run focused tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffContextExpansionTests -only-testing:AlasTests/DiffPaneViewTests -only-testing:AlasTests/ReviewChangesLoaderTests -only-testing:AlasTests/CommitReviewLoaderTests -only-testing:AlasTests/Integrations/ReviewRequestDraftTests -only-testing:AlasTests/ReviewChangesTabViewTests
```

Expected: pass.

- [ ] **Step 3: Run required build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: pass.

- [ ] **Step 4: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: pass.

- [ ] **Step 5: Commit generated project or final fixes**

If `xcodegen` changed the project:

```bash
git add Alas.xcodeproj/project.pbxproj
git commit -m "Regenerate Xcode project"
```

If final verification required code fixes, commit those files with a targeted message:

```bash
git add <fixed-files>
git commit -m "Fix diff context expansion verification issues"
```

- [ ] **Step 6: Final status**

Run:

```bash
git status --short
```

Expected: no tracked changes. Ignored `.build/` or `.superpowers/` may remain.
