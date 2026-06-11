# Review-Ready Diff Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace single-file text diff tabs with a native review-ready split/stacked diff pane while preserving existing hunk stage/discard behavior.

**Architecture:** Keep `ParsedDiff` and existing `GitService.diff(...)` loading as the input contract. Add a pure display-model layer for aligned rows, anchors, inline highlights, collapsed context, and selection; then render that model through reusable SwiftUI/native views integrated into `DiffTabView`.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit-backed attributed text where needed, Swift Testing, XcodeGen/Xcode build.

---

## File Structure

- Create `Alas/Sources/Center/Diff/DiffDisplayPreferences.swift`
  - Defines `DiffLayoutMode` and the persisted preference value.
- Create `Alas/Sources/Center/Diff/DiffDisplayModel.swift`
  - Defines anchors, inline spans, split rows, hunk groups, selection ranges, collapsed groups, and the display model.
- Create `Alas/Sources/Center/Diff/DiffInlineHighlighter.swift`
  - Computes inline changed spans for paired delete/add lines.
- Create `Alas/Sources/Center/Diff/DiffDisplayModelBuilder.swift`
  - Converts `ParsedDiff` into `DiffDisplayModel`.
- Create `Alas/Sources/Center/Diff/DiffPaneView.swift`
  - Renders toolbar, split/stacked layouts, collapsed groups, line selection, hunk actions, and local draft note affordance.
- Create `Alas/Sources/Center/Diff/DiffCodeText.swift`
  - Small syntax-highlighted line renderer using existing tree-sitter colors and theme tokens.
- Modify `Alas/Sources/Persistence/AppConfig.swift`
  - Persist diff display preferences under `changes`.
- Modify `Alas/Sources/Center/DiffTabView.swift`
  - Replace `HunkView` text rendering path with `DiffPaneView` while keeping loading, image routing, stage/discard, and file header behavior.
- Add `AlasTests/DiffDisplayModelBuilderTests.swift`
  - Tests model construction, alignment, collapsed groups, anchors, and selection.
- Add `AlasTests/DiffInlineHighlighterTests.swift`
  - Tests inline pairing and fallback behavior.
- Add `AlasTests/DiffPaneViewTests.swift`
  - Hosted rendering smoke tests for split/stacked and selection affordances.
- Modify `AlasTests/AppConfigChangesTests.swift`
  - Tests defaults, legacy decode, and round-trip for display preferences.

## Task 1: Persist Diff Display Preferences

**Files:**
- Create: `Alas/Sources/Center/Diff/DiffDisplayPreferences.swift`
- Modify: `Alas/Sources/Persistence/AppConfig.swift`
- Modify: `AlasTests/AppConfigChangesTests.swift`

- [ ] **Step 1: Write failing AppConfig tests**

Append these tests to `AppConfigChangesTests`:

```swift
@Test func defaultsHaveDiffDisplayPreferences() {
    #expect(AppConfig.defaults.changes.diffLayoutMode == .split)
    #expect(AppConfig.defaults.changes.diffWrapLines == false)
    #expect(AppConfig.defaults.changes.diffShowWhitespace == false)
}

@Test func decodesLegacyChangesWithoutDiffDisplayPreferences() throws {
    let json = """
    {
      "themeId": "cool-slate",
      "accent": "teal",
      "matchSystemTheme": false,
      "sidebarWidth": 244,
      "rightPaneWidth": 320,
      "rightPaneVisible": true,
      "general": {
        "launchAtLogin": false, "closeToTray": true, "confirmQuit": true,
        "autoUpdate": true, "updateChannel": "Stable",
        "crashReports": false, "usageAnalytics": false
      },
      "worktrees": {
        "rootPath": "~/.alas/worktrees",
        "pathTemplate": "{worktreeRoot}/{repo}/{branch}",
        "branchPrefix": "feature/", "baseBranch": "main",
        "trackUpstream": true, "deleteBranchOnRemove": true,
        "autoFetch": true, "fetchIntervalMinutes": 5, "pruneStale": false
      },
      "terminal": {
        "shell": "/bin/zsh", "workingDirectory": "worktreeRoot",
        "startupScript": "", "worktreeCreateScript": "",
        "inheritParentEnv": true, "fontFamily": "JetBrains Mono",
        "fontSize": 13, "cursorStyle": "beam", "cursorBlink": true,
        "scrollbackLines": 10000, "bell": "visual"
      },
      "harness": {"notifyOnFinish": true, "notifyOnAwaiting": true},
      "changes": {
        "aiToolId": "claude",
        "prompt": "p",
        "reviewRequestPrompt": "r",
        "mergeBulkResolvePrompt": "b",
        "mergeSingleResolvePrompt": "s",
        "trackUpstreamForCommits": true
      }
    }
    """
    let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(cfg.changes.diffLayoutMode == .split)
    #expect(cfg.changes.diffWrapLines == false)
    #expect(cfg.changes.diffShowWhitespace == false)
}

@Test func roundTripsDiffDisplayPreferences() throws {
    var cfg = AppConfig.defaults
    cfg.changes.diffLayoutMode = .stacked
    cfg.changes.diffWrapLines = true
    cfg.changes.diffShowWhitespace = true
    let data = try JSONEncoder().encode(cfg)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.changes.diffLayoutMode == .stacked)
    #expect(decoded.changes.diffWrapLines == true)
    #expect(decoded.changes.diffShowWhitespace == true)
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppConfigChangesTests
```

Expected: fail to compile because `DiffLayoutMode`, `diffLayoutMode`, `diffWrapLines`, and `diffShowWhitespace` do not exist.

- [ ] **Step 3: Add the preferences type**

Create `Alas/Sources/Center/Diff/DiffDisplayPreferences.swift`:

```swift
import Foundation

enum DiffLayoutMode: String, Codable, Equatable, CaseIterable {
    case split
    case stacked

    var title: String {
        switch self {
        case .split: return "Split"
        case .stacked: return "Stacked"
        }
    }
}
```

- [ ] **Step 4: Add persisted fields to `AppConfig.Changes`**

In `AppConfig.Changes`, add:

```swift
var diffLayoutMode: DiffLayoutMode
var diffWrapLines: Bool
var diffShowWhitespace: Bool
```

Add the keys to `CodingKeys`:

```swift
case diffLayoutMode, diffWrapLines, diffShowWhitespace
```

Update `AppConfig.defaults.changes` with:

```swift
diffLayoutMode: .split,
diffWrapLines: false,
diffShowWhitespace: false
```

In custom decode, read:

```swift
let diffLayoutMode = (try? changesContainer.decode(DiffLayoutMode.self, forKey: .diffLayoutMode)) ?? .split
let diffWrapLines = (try? changesContainer.decode(Bool.self, forKey: .diffWrapLines)) ?? false
let diffShowWhitespace = (try? changesContainer.decode(Bool.self, forKey: .diffShowWhitespace)) ?? false
```

Pass those values into every `Changes(...)` initializer in the decode path.

- [ ] **Step 5: Run focused tests and commit**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppConfigChangesTests
```

Expected: `AppConfigChangesTests` passes.

Commit:

```bash
git add Alas/Sources/Center/Diff/DiffDisplayPreferences.swift Alas/Sources/Persistence/AppConfig.swift AlasTests/AppConfigChangesTests.swift
git commit -m "feat(diff): persist display preferences"
```

## Task 2: Build Diff Display Model

**Files:**
- Create: `Alas/Sources/Center/Diff/DiffDisplayModel.swift`
- Create: `Alas/Sources/Center/Diff/DiffInlineHighlighter.swift`
- Create: `Alas/Sources/Center/Diff/DiffDisplayModelBuilder.swift`
- Add: `AlasTests/DiffInlineHighlighterTests.swift`
- Add: `AlasTests/DiffDisplayModelBuilderTests.swift`

- [ ] **Step 1: Write failing inline highlighter tests**

Create `AlasTests/DiffInlineHighlighterTests.swift`:

```swift
import Testing
@testable import Alas

struct DiffInlineHighlighterTests {
    @Test func highlightsChangedWordInSingleLineReplacement() {
        let result = DiffInlineHighlighter.highlightDeleteAdd(
            old: "let mode = \"unified\"",
            new: "let mode = layout"
        )

        #expect(result.oldSpans.map { $0.text(in: "let mode = \"unified\"") } == ["\"unified\""])
        #expect(result.newSpans.map { $0.text(in: "let mode = layout") } == ["layout"])
    }

    @Test func returnsFullLineSpansWhenLinesAreCompletelyDifferent() {
        let result = DiffInlineHighlighter.highlightDeleteAdd(
            old: "final class Renderer {}",
            new: "import SwiftUI"
        )

        #expect(result.oldSpans == [DiffInlineSpan(start: 0, length: 23)])
        #expect(result.newSpans == [DiffInlineSpan(start: 0, length: 14)])
    }
}
```

- [ ] **Step 2: Write failing display model tests**

Create `AlasTests/DiffDisplayModelBuilderTests.swift`:

```swift
import Testing
@testable import Alas

struct DiffDisplayModelBuilderTests {
    private func sampleDiff() -> ParsedDiff {
        ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -10,4 +10,4 @@",
                oldStart: 10,
                newStart: 10,
                lines: [
                    .init(kind: .context, text: "struct Foo {", oldNumber: 10, newNumber: 10),
                    .init(kind: .delete, text: "    let mode = \"unified\"", oldNumber: 11, newNumber: nil),
                    .init(kind: .add, text: "    let mode = layout", oldNumber: nil, newNumber: 11),
                    .init(kind: .context, text: "}", oldNumber: 12, newNumber: 12),
                ]
            )
        ])
    }

    @Test func buildsSplitRowsWithStableAnchors() {
        let model = DiffDisplayModelBuilder.build(diff: sampleDiff(), filePath: "Sources/Foo.swift")
        #expect(model.filePath == "Sources/Foo.swift")
        #expect(model.groups.count == 1)
        #expect(model.groups[0].rows.count == 3)

        let replacement = model.groups[0].rows[1]
        #expect(replacement.kind == .replacement)
        #expect(replacement.old?.anchor == DiffLineAnchor(filePath: "Sources/Foo.swift", side: .old, oldLine: 11, newLine: nil))
        #expect(replacement.new?.anchor == DiffLineAnchor(filePath: "Sources/Foo.swift", side: .new, oldLine: nil, newLine: 11))
        #expect(replacement.old?.inlineSpans.map(\.text(in: replacement.old?.text ?? "")) == ["\"unified\""])
        #expect(replacement.new?.inlineSpans.map(\.text(in: replacement.new?.text ?? "")) == ["layout"])
    }

    @Test func preservesHunkForActions() {
        let diff = sampleDiff()
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Foo.swift")
        #expect(model.groups[0].sourceHunk == diff.hunks[0])
    }

    @Test func collapsesLargeContextRunsInsideHunk() {
        let context = (1...12).map {
            ParsedDiff.Hunk.Line(kind: .context, text: "line \($0)", oldNumber: $0, newNumber: $0)
        }
        let hunk = ParsedDiff.Hunk(header: "@@ -1,12 +1,12 @@", oldStart: 1, newStart: 1, lines: context)
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [hunk]),
            filePath: "a.txt",
            collapseContextThreshold: 6,
            contextEdgeCount: 2
        )

        let rows = model.groups[0].rows
        #expect(rows.map(\.kind) == [.context, .context, .collapsed, .context, .context])
        #expect(rows[2].collapsedLineCount == 8)
    }

    @Test func selectionRangeNormalizesAnchorOrder() {
        let a = DiffLineAnchor(filePath: "a.txt", side: .new, oldLine: nil, newLine: 4)
        let b = DiffLineAnchor(filePath: "a.txt", side: .new, oldLine: nil, newLine: 2)
        let range = DiffSelectionRange(first: a, last: b)
        #expect(range.normalized.lowerBound == b)
        #expect(range.normalized.upperBound == a)
    }
}
```

- [ ] **Step 3: Run focused tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffInlineHighlighterTests -only-testing:AlasTests/DiffDisplayModelBuilderTests
```

Expected: fail to compile because the new model and builder types do not exist.

- [ ] **Step 4: Add the display model types**

Create `Alas/Sources/Center/Diff/DiffDisplayModel.swift`:

```swift
import Foundation

enum DiffLineSide: String, Codable, Equatable, Comparable, Hashable {
    case old
    case new
    case paired

    static func < (lhs: DiffLineSide, rhs: DiffLineSide) -> Bool {
        lhs.sortValue < rhs.sortValue
    }

    private var sortValue: Int {
        switch self {
        case .old: return 0
        case .paired: return 1
        case .new: return 2
        }
    }
}

struct DiffLineAnchor: Codable, Equatable, Comparable, Hashable {
    let filePath: String
    let side: DiffLineSide
    let oldLine: Int?
    let newLine: Int?

    static func < (lhs: DiffLineAnchor, rhs: DiffLineAnchor) -> Bool {
        if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
        let lhsLine = lhs.newLine ?? lhs.oldLine ?? 0
        let rhsLine = rhs.newLine ?? rhs.oldLine ?? 0
        if lhsLine != rhsLine { return lhsLine < rhsLine }
        if lhs.side != rhs.side { return lhs.side < rhs.side }
        return (lhs.oldLine ?? 0) < (rhs.oldLine ?? 0)
    }
}

struct DiffSelectionRange: Equatable {
    let first: DiffLineAnchor
    let last: DiffLineAnchor

    var normalized: ClosedRange<DiffLineAnchor> {
        min(first, last)...max(first, last)
    }

    func contains(_ anchor: DiffLineAnchor) -> Bool {
        normalized.contains(anchor)
    }
}

struct DiffInlineSpan: Equatable {
    let start: Int
    let length: Int

    func text(in source: String) -> String {
        let ns = source as NSString
        guard start >= 0, length >= 0, start + length <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: start, length: length))
    }
}

struct DiffDisplayLine: Identifiable, Equatable {
    let id: DiffLineAnchor
    let anchor: DiffLineAnchor
    let text: String
    let lineNumber: Int?
    let kind: ParsedDiff.Hunk.Line.Kind
    let inlineSpans: [DiffInlineSpan]
    let noTrailingNewline: Bool
}

struct DiffDisplayRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case context
        case add
        case delete
        case replacement
        case collapsed
    }

    let id: String
    let kind: Kind
    let old: DiffDisplayLine?
    let new: DiffDisplayLine?
    let collapsedLineCount: Int
}

struct DiffDisplayGroup: Identifiable, Equatable {
    let id: String
    let header: String
    let sourceHunk: ParsedDiff.Hunk
    let rows: [DiffDisplayRow]
}

struct DiffDisplayModel: Equatable {
    let filePath: String
    let groups: [DiffDisplayGroup]
}
```

- [ ] **Step 5: Add the inline highlighter**

Create `Alas/Sources/Center/Diff/DiffInlineHighlighter.swift`:

```swift
import Foundation

enum DiffInlineHighlighter {
    struct Result: Equatable {
        let oldSpans: [DiffInlineSpan]
        let newSpans: [DiffInlineSpan]
    }

    static func highlightDeleteAdd(old: String, new: String) -> Result {
        if old == new { return Result(oldSpans: [], newSpans: []) }

        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard !oldTokens.isEmpty, !newTokens.isEmpty else {
            return Result(oldSpans: fullSpan(old), newSpans: fullSpan(new))
        }

        var prefix = 0
        while prefix < oldTokens.count,
              prefix < newTokens.count,
              oldTokens[prefix].text == newTokens[prefix].text {
            prefix += 1
        }

        var suffix = 0
        while suffix + prefix < oldTokens.count,
              suffix + prefix < newTokens.count,
              oldTokens[oldTokens.count - 1 - suffix].text == newTokens[newTokens.count - 1 - suffix].text {
            suffix += 1
        }

        let oldChanged = oldTokens[prefix..<(oldTokens.count - suffix)]
        let newChanged = newTokens[prefix..<(newTokens.count - suffix)]

        let oldSpans = collapse(tokens: Array(oldChanged), source: old)
        let newSpans = collapse(tokens: Array(newChanged), source: new)

        if oldSpans.isEmpty || newSpans.isEmpty {
            return Result(oldSpans: fullSpan(old), newSpans: fullSpan(new))
        }
        return Result(oldSpans: oldSpans, newSpans: newSpans)
    }

    private struct Token {
        let text: String
        let range: NSRange
    }

    private static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var start: Int?
        var lastClass: CharacterSet?

        func flush(upTo index: Int) {
            guard let s = start else { return }
            let range = NSRange(location: s, length: index - s)
            if range.length > 0 {
                tokens.append(Token(text: ns.substring(with: range), range: range))
            }
            start = nil
            lastClass = nil
        }

        for index in 0..<ns.length {
            let scalar = UnicodeScalar(ns.character(at: index)) ?? " "
            let cls: CharacterSet
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                cls = .alphanumerics
            } else if CharacterSet.whitespaces.contains(scalar) {
                flush(upTo: index)
                continue
            } else {
                cls = .punctuationCharacters
            }

            if start == nil {
                start = index
                lastClass = cls
            } else if lastClass != cls {
                flush(upTo: index)
                start = index
                lastClass = cls
            }
        }
        flush(upTo: ns.length)
        return tokens
    }

    private static func collapse(tokens: [Token], source: String) -> [DiffInlineSpan] {
        guard let first = tokens.first, let last = tokens.last else { return [] }
        let end = last.range.location + last.range.length
        return [DiffInlineSpan(start: first.range.location, length: end - first.range.location)]
    }

    private static func fullSpan(_ text: String) -> [DiffInlineSpan] {
        text.isEmpty ? [] : [DiffInlineSpan(start: 0, length: (text as NSString).length)]
    }
}
```

- [ ] **Step 6: Add the model builder**

Create `Alas/Sources/Center/Diff/DiffDisplayModelBuilder.swift`:

```swift
import Foundation

enum DiffDisplayModelBuilder {
    static func build(
        diff: ParsedDiff,
        filePath: String,
        collapseContextThreshold: Int = 12,
        contextEdgeCount: Int = 3
    ) -> DiffDisplayModel {
        let groups = diff.hunks.enumerated().map { hunkIndex, hunk in
            DiffDisplayGroup(
                id: "\(filePath):hunk:\(hunkIndex)",
                header: hunk.header,
                sourceHunk: hunk,
                rows: rows(
                    for: hunk,
                    hunkIndex: hunkIndex,
                    filePath: filePath,
                    collapseContextThreshold: collapseContextThreshold,
                    contextEdgeCount: contextEdgeCount
                )
            )
        }
        return DiffDisplayModel(filePath: filePath, groups: groups)
    }

    private static func rows(
        for hunk: ParsedDiff.Hunk,
        hunkIndex: Int,
        filePath: String,
        collapseContextThreshold: Int,
        contextEdgeCount: Int
    ) -> [DiffDisplayRow] {
        let aligned = alignRows(for: hunk, hunkIndex: hunkIndex, filePath: filePath)
        return collapseContextRows(
            aligned,
            hunkIndex: hunkIndex,
            filePath: filePath,
            threshold: collapseContextThreshold,
            edgeCount: contextEdgeCount
        )
    }

    private static func alignRows(
        for hunk: ParsedDiff.Hunk,
        hunkIndex: Int,
        filePath: String
    ) -> [DiffDisplayRow] {
        var rows: [DiffDisplayRow] = []
        var index = 0
        while index < hunk.lines.count {
            let line = hunk.lines[index]
            if line.kind == .context {
                let display = displayLine(line, filePath: filePath, side: .paired)
                rows.append(DiffDisplayRow(
                    id: "\(filePath):\(hunkIndex):ctx:\(line.oldNumber ?? 0):\(line.newNumber ?? 0)",
                    kind: .context,
                    old: display,
                    new: display,
                    collapsedLineCount: 0
                ))
                index += 1
                continue
            }

            var deletes: [ParsedDiff.Hunk.Line] = []
            var adds: [ParsedDiff.Hunk.Line] = []
            while index < hunk.lines.count, hunk.lines[index].kind != .context {
                if hunk.lines[index].kind == .delete {
                    deletes.append(hunk.lines[index])
                } else if hunk.lines[index].kind == .add {
                    adds.append(hunk.lines[index])
                }
                index += 1
            }

            let pairCount = min(deletes.count, adds.count)
            for pairIndex in 0..<pairCount {
                let oldLine = deletes[pairIndex]
                let newLine = adds[pairIndex]
                let highlights = DiffInlineHighlighter.highlightDeleteAdd(old: oldLine.text, new: newLine.text)
                rows.append(DiffDisplayRow(
                    id: "\(filePath):\(hunkIndex):rep:\(oldLine.oldNumber ?? 0):\(newLine.newNumber ?? 0)",
                    kind: .replacement,
                    old: displayLine(oldLine, filePath: filePath, side: .old, spans: highlights.oldSpans),
                    new: displayLine(newLine, filePath: filePath, side: .new, spans: highlights.newSpans),
                    collapsedLineCount: 0
                ))
            }

            for oldLine in deletes.dropFirst(pairCount) {
                rows.append(DiffDisplayRow(
                    id: "\(filePath):\(hunkIndex):del:\(oldLine.oldNumber ?? 0)",
                    kind: .delete,
                    old: displayLine(oldLine, filePath: filePath, side: .old),
                    new: nil,
                    collapsedLineCount: 0
                ))
            }

            for newLine in adds.dropFirst(pairCount) {
                rows.append(DiffDisplayRow(
                    id: "\(filePath):\(hunkIndex):add:\(newLine.newNumber ?? 0)",
                    kind: .add,
                    old: nil,
                    new: displayLine(newLine, filePath: filePath, side: .new),
                    collapsedLineCount: 0
                ))
            }
        }
        return rows
    }

    private static func collapseContextRows(
        _ rows: [DiffDisplayRow],
        hunkIndex: Int,
        filePath: String,
        threshold: Int,
        edgeCount: Int
    ) -> [DiffDisplayRow] {
        guard threshold > edgeCount * 2 else { return rows }
        var result: [DiffDisplayRow] = []
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .context else {
                result.append(rows[index])
                index += 1
                continue
            }
            let start = index
            while index < rows.count, rows[index].kind == .context {
                index += 1
            }
            let run = Array(rows[start..<index])
            if run.count > threshold {
                result.append(contentsOf: run.prefix(edgeCount))
                result.append(DiffDisplayRow(
                    id: "\(filePath):\(hunkIndex):collapsed:\(start):\(run.count)",
                    kind: .collapsed,
                    old: nil,
                    new: nil,
                    collapsedLineCount: run.count - edgeCount * 2
                ))
                result.append(contentsOf: run.suffix(edgeCount))
            } else {
                result.append(contentsOf: run)
            }
        }
        return result
    }

    private static func displayLine(
        _ line: ParsedDiff.Hunk.Line,
        filePath: String,
        side: DiffLineSide,
        spans: [DiffInlineSpan] = []
    ) -> DiffDisplayLine {
        let anchor = DiffLineAnchor(
            filePath: filePath,
            side: side,
            oldLine: line.oldNumber,
            newLine: line.newNumber
        )
        return DiffDisplayLine(
            id: anchor,
            anchor: anchor,
            text: line.text,
            lineNumber: line.newNumber ?? line.oldNumber,
            kind: line.kind,
            inlineSpans: spans,
            noTrailingNewline: line.noTrailingNewline
        )
    }
}
```

- [ ] **Step 7: Run focused tests and commit**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffInlineHighlighterTests -only-testing:AlasTests/DiffDisplayModelBuilderTests
```

Expected: both test suites pass.

Commit:

```bash
git add Alas/Sources/Center/Diff/DiffDisplayModel.swift Alas/Sources/Center/Diff/DiffInlineHighlighter.swift Alas/Sources/Center/Diff/DiffDisplayModelBuilder.swift AlasTests/DiffInlineHighlighterTests.swift AlasTests/DiffDisplayModelBuilderTests.swift
git commit -m "feat(diff): build display model"
```

## Task 3: Render Native Split And Stacked Diff Pane

**Files:**
- Create: `Alas/Sources/Center/Diff/DiffCodeText.swift`
- Create: `Alas/Sources/Center/Diff/DiffPaneView.swift`
- Add: `AlasTests/DiffPaneViewTests.swift`

- [ ] **Step 1: Write failing hosted rendering tests**

Create `AlasTests/DiffPaneViewTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffPaneViewTests {
    private func theme() -> Theme { try! ThemeStore().current }

    private func model() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,2 +1,2 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
                        .init(kind: .delete, text: "let b = 2", oldNumber: 2, newNumber: nil),
                        .init(kind: .add, text: "let b = 3", oldNumber: nil, newNumber: 2),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
    }

    @Test func splitModeHostsRendererWithoutCrashing() {
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
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.subviews.isEmpty == false)
    }

    @Test func stackedModeHostsRendererWithoutCrashing() {
        var layout = DiffLayoutMode.stacked
        var wrap = true
        var whitespace = true
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.subviews.isEmpty == false)
    }
}
```

- [ ] **Step 2: Run the hosted tests and verify they fail**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests
```

Expected: fail to compile because `DiffPaneView` and `DiffPaneHunkActions` do not exist.

- [ ] **Step 3: Add syntax-highlighted line view**

Create `Alas/Sources/Center/Diff/DiffCodeText.swift`:

```swift
import SwiftUI

struct DiffCodeText: View {
    let text: String
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let wrapLines: Bool
    let showWhitespace: Bool
    let inlineSpans: [DiffInlineSpan]
    let inlineTone: ParsedDiff.Hunk.Line.Kind

    @Environment(\.theme) private var theme

    var body: some View {
        Text(attributedText)
            .textSelection(.enabled)
            .lineLimit(wrapLines ? nil : 1)
            .truncationMode(.tail)
            .font(Font(CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize)))
    }

    private var attributedText: AttributedString {
        let source = showWhitespace ? visibleWhitespace(text) : text
        var attributed = AttributedString(source)
        attributed.foregroundColor = theme.color("fg")

        for token in TreeSitterHighlighter.tokenize(line: text, fileExtension: fileExtension) {
            guard let range = Range(token.range, in: text) else { continue }
            let lower = source.distance(from: source.startIndex, to: range.lowerBound)
            let upper = source.distance(from: source.startIndex, to: range.upperBound)
            guard let start = attributed.index(attributed.startIndex, offsetByCharacters: lower),
                  let end = attributed.index(attributed.startIndex, offsetByCharacters: upper) else {
                continue
            }
            attributed[start..<end].foregroundColor = syntaxColor(for: token.capture)
        }

        for span in inlineSpans {
            guard let start = attributed.index(attributed.startIndex, offsetByCharacters: span.start),
                  let end = attributed.index(start, offsetByCharacters: span.length) else {
                continue
            }
            attributed[start..<end].backgroundColor = inlineBackground
        }
        return attributed
    }

    private var inlineBackground: Color {
        switch inlineTone {
        case .add: return theme.color("add").opacity(0.28)
        case .delete: return theme.color("del").opacity(0.28)
        case .context: return theme.color("accent").opacity(0.18)
        }
    }

    private func syntaxColor(for capture: HighlightCapture) -> Color {
        switch capture {
        case .keyword: return theme.color("syntax-keyword")
        case .type: return theme.color("syntax-type")
        case .function: return theme.color("syntax-function")
        case .string: return theme.color("add")
        case .number: return theme.color("mod")
        case .comment: return theme.color("fg-faint")
        default: return theme.color("fg")
        }
    }

    private func visibleWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→   ")
    }
}
```

Add this extension at the bottom of `DiffCodeText.swift`:

```swift
private extension AttributedString {
    func index(_ start: AttributedString.Index, offsetByCharacters offset: Int) -> AttributedString.Index? {
        characters.index(start, offsetBy: offset, limitedBy: endIndex)
    }
}
```

- [ ] **Step 4: Add the diff pane view**

Create `Alas/Sources/Center/Diff/DiffPaneView.swift`:

```swift
import SwiftUI

struct DiffPaneHunkActions {
    var stage: (() -> Void)?
    var discard: (() -> Void)?
    var dropFromCommit: (() -> Void)?
}

struct DiffPaneView: View {
    let model: DiffDisplayModel
    let fileExtension: String
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    let hunkActions: (ParsedDiff.Hunk) -> DiffPaneHunkActions

    @Environment(\.theme) private var theme
    @State private var expandedCollapsedRows: Set<String> = []
    @State private var selection: DiffSelectionRange?
    @State private var draftAnchor: DiffLineAnchor?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { group in
                        groupView(group)
                    }
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .background(theme.color("bg-1"))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Seg(value: $layoutMode, options: DiffLayoutMode.allCases.map { ($0, $0.title) })
            Spacer()
            iconToggle("Wrap", systemImage: "text.justify.left", isOn: $wrapLines)
            iconToggle("Whitespace", systemImage: "paragraphsign", isOn: $showWhitespace)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.45), alignment: .bottom)
    }

    private func groupView(_ group: DiffDisplayGroup) -> some View {
        let actions = hunkActions(group.sourceHunk)
        return VStack(alignment: .leading, spacing: 0) {
            hunkHeader(group: group, actions: actions)
            ForEach(group.rows) { row in
                rowView(row)
            }
        }
    }

    private func hunkHeader(group: DiffDisplayGroup, actions: DiffPaneHunkActions) -> some View {
        HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: (codeFontSize * 0.85).rounded()))
                .foregroundColor(theme.color("fg-dim"))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let stage = actions.stage {
                AlasButton(title: "Stage hunk", style: .subtle, action: stage)
            }
            if let discard = actions.discard {
                AlasButton(title: "Discard hunk...", style: .subtle, action: discard)
            }
            if let drop = actions.dropFromCommit {
                AlasButton(title: "Drop hunk...", style: .subtle, action: drop)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .top)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func rowView(_ row: DiffDisplayRow) -> some View {
        if row.kind == .collapsed {
            collapsedRow(row)
        } else if layoutMode == .split {
            splitRow(row)
        } else {
            stackedRow(row)
        }
    }

    private func splitRow(_ row: DiffDisplayRow) -> some View {
        HStack(spacing: 0) {
            diffCell(row.old, side: .old, rowKind: row.kind)
            Rectangle().fill(theme.color("line").opacity(0.5)).frame(width: 1)
            diffCell(row.new, side: .new, rowKind: row.kind)
        }
        .background(rowBackground(row.kind))
    }

    private func stackedRow(_ row: DiffDisplayRow) -> some View {
        VStack(spacing: 0) {
            if let old = row.old, row.kind != .context {
                diffLine(old, side: .old, rowKind: row.kind)
            }
            if let new = row.new {
                diffLine(new, side: .new, rowKind: row.kind)
            } else if row.kind == .context, let old = row.old {
                diffLine(old, side: .paired, rowKind: row.kind)
            }
        }
        .background(rowBackground(row.kind))
    }

    private func diffCell(_ line: DiffDisplayLine?, side: DiffLineSide, rowKind: DiffDisplayRow.Kind) -> some View {
        Group {
            if let line {
                diffLine(line, side: side, rowKind: rowKind)
            } else {
                Color.clear.frame(minHeight: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diffLine(_ line: DiffDisplayLine, side: DiffLineSide, rowKind: DiffDisplayRow.Kind) -> some View {
        HStack(spacing: 0) {
            Text(lineNumberText(line, side: side))
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
                .foregroundColor(markerColor(line.kind))
                .frame(width: 62, alignment: .trailing)
                .padding(.trailing, 8)
            DiffCodeText(
                text: line.text,
                fileExtension: fileExtension,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                wrapLines: wrapLines,
                showWhitespace: showWhitespace,
                inlineSpans: line.inlineSpans,
                inlineTone: line.kind
            )
            .padding(.leading, 10)
            Spacer(minLength: 0)
            if draftAnchor == line.anchor {
                Text("Draft note")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("accent"))
                    .padding(.trailing, 8)
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .background(isSelected(line.anchor) ? theme.color("accent").opacity(0.14) : Color.clear)
        .onTapGesture {
            selection = DiffSelectionRange(first: line.anchor, last: line.anchor)
        }
        .contextMenu {
            Button("Add Note") { draftAnchor = line.anchor }
            Button("Copy Line") { Clipboard.copy(line.text) }
        }
    }

    private func collapsedRow(_ row: DiffDisplayRow) -> some View {
        Button {
            if expandedCollapsedRows.contains(row.id) {
                expandedCollapsedRows.remove(row.id)
            } else {
                expandedCollapsedRows.insert(row.id)
            }
        } label: {
            Text("\(row.collapsedLineCount) unchanged lines")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .background(theme.color("bg-2").opacity(0.72))
    }

    private func iconToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .foregroundColor(isOn.wrappedValue ? theme.color("fg") : theme.color("fg-muted"))
                .background(isOn.wrappedValue ? theme.color("bg-3") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func isSelected(_ anchor: DiffLineAnchor) -> Bool {
        selection?.contains(anchor) ?? false
    }

    private func lineNumberText(_ line: DiffDisplayLine, side: DiffLineSide) -> String {
        switch side {
        case .old: return line.anchor.oldLine.map(String.init) ?? ""
        case .new: return line.anchor.newLine.map(String.init) ?? ""
        case .paired: return line.lineNumber.map(String.init) ?? ""
        }
    }

    private func rowBackground(_ kind: DiffDisplayRow.Kind) -> Color {
        switch kind {
        case .add: return theme.color("add").opacity(0.10)
        case .delete: return theme.color("del").opacity(0.10)
        case .replacement: return theme.color("mod").opacity(0.08)
        case .context, .collapsed: return .clear
        }
    }

    private func markerColor(_ kind: ParsedDiff.Hunk.Line.Kind) -> Color {
        switch kind {
        case .add: return theme.color("add")
        case .delete: return theme.color("del")
        case .context: return theme.color("fg-faint")
        }
    }
}
```

- [ ] **Step 5: Run hosted tests and commit**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests
```

Expected: `DiffPaneViewTests` passes.

Commit:

```bash
git add Alas/Sources/Center/Diff/DiffCodeText.swift Alas/Sources/Center/Diff/DiffPaneView.swift AlasTests/DiffPaneViewTests.swift
git commit -m "feat(diff): render split and stacked pane"
```

## Task 4: Integrate Renderer Into DiffTabView

**Files:**
- Modify: `Alas/Sources/Center/DiffTabView.swift`
- Modify: `AlasTests/DiffSelectableTextTests.swift` only if existing `HunkView` tests need updated names after integration.

- [ ] **Step 1: Add a failing hosted integration test**

Append this test to `DiffPaneViewTests` so integration is validated through the new view API before touching `DiffTabView`:

```swift
@Test func hunkActionsRenderInPaneHeader() {
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
        hunkActions: { _ in
            DiffPaneHunkActions(stage: {}, discard: {}, dropFromCommit: nil)
        }
    )
    .environment(\.theme, theme())

    let controller = NSHostingController(rootView: view)
    controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
    controller.view.layoutSubtreeIfNeeded()
    let buttons = allSubviews(of: controller.view).compactMap { $0 as? NSButton }
    let titles = buttons.map(\.title)
    #expect(titles.contains("Stage hunk"))
    #expect(titles.contains("Discard hunk..."))
}
```

Also add this helper inside the test struct:

```swift
private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
}
```

- [ ] **Step 2: Run focused test and verify the action contract**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffPaneViewTests/hunkActionsRenderInPaneHeader
```

Expected: pass after Task 3. If it fails, fix `DiffPaneView` so hunk action buttons render in the hunk header before continuing.

- [ ] **Step 3: Replace text diff body in `DiffTabView`**

In `DiffTabView`, add the app state environment and a display model:

```swift
@EnvironmentObject private var appState: AppState
@State private var displayModel: DiffDisplayModel?
```

After loading `loadedDiff`, build the display model off-main:

```swift
let loadedDisplayModel = await Task.detached(priority: .userInitiated) {
    DiffDisplayModelBuilder.build(diff: loadedDiff, filePath: relativePath)
}.value
```

Publish it with the diff:

```swift
diff = loadedDiff
displayModel = loadedDisplayModel
```

Reset it at the start of `load()`:

```swift
displayModel = nil
```

Replace the old `ForEach(diff.hunks...) { HunkView(...) }` block with:

```swift
if let displayModel {
    DiffPaneView(
        model: displayModel,
        fileExtension: LanguageRegistry.highlighterExtension(forPath: relativePath),
        layoutMode: diffLayoutBinding,
        wrapLines: diffWrapBinding,
        showWhitespace: diffWhitespaceBinding,
        codeFontFamily: codeFontFamily,
        codeFontSize: codeFontSize,
        hunkActions: { hunk in
            let actions = stagedHunkActions(hunk: hunk)
            return DiffPaneHunkActions(stage: actions.stage, discard: actions.discard)
        }
    )
} else {
    Spinner()
        .frame(width: 16, height: 16)
        .padding()
}
```

Add these bindings to `DiffTabView`:

```swift
private var diffLayoutBinding: Binding<DiffLayoutMode> {
    Binding(
        get: { appState.config.changes.diffLayoutMode },
        set: {
            appState.config.changes.diffLayoutMode = $0
            appState.saveConfig()
        }
    )
}

private var diffWrapBinding: Binding<Bool> {
    Binding(
        get: { appState.config.changes.diffWrapLines },
        set: {
            appState.config.changes.diffWrapLines = $0
            appState.saveConfig()
        }
    )
}

private var diffWhitespaceBinding: Binding<Bool> {
    Binding(
        get: { appState.config.changes.diffShowWhitespace },
        set: {
            appState.config.changes.diffShowWhitespace = $0
            appState.saveConfig()
        }
    )
}
```

- [ ] **Step 4: Run existing diff UI tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/DiffSelectableTextTests -only-testing:AlasTests/DiffPaneViewTests
```

Expected: both suites pass. If `HunkView` tests remain valid because `HunkView` still exists for commit views, keep them.

- [ ] **Step 5: Commit integration**

Commit:

```bash
git add Alas/Sources/Center/DiffTabView.swift AlasTests/DiffPaneViewTests.swift AlasTests/DiffSelectableTextTests.swift
git commit -m "feat(diff): use review-ready pane in diff tabs"
```

If `AlasTests/DiffSelectableTextTests.swift` was not modified, omit it from `git add`.

## Task 5: Final Verification And Polish

**Files:**
- Modify only files needed for compile/test fixes found by verification.

- [ ] **Step 1: Confirm project generation state**

Run:

```bash
git diff --name-only HEAD | rg '^project\.yml$'
```

Expected: no output. If output is `project.yml`, run:

```bash
xcodegen
git add project.yml Alas.xcodeproj
git commit -m "chore: regenerate xcode project"
```

- [ ] **Step 2: Run focused diff and config test suites**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppConfigChangesTests -only-testing:AlasTests/DiffInlineHighlighterTests -only-testing:AlasTests/DiffDisplayModelBuilderTests -only-testing:AlasTests/DiffPaneViewTests -only-testing:AlasTests/DiffSelectableTextTests -only-testing:AlasTests/DiffParserTests
```

Expected: all selected test suites pass.

- [ ] **Step 3: Run full build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: test action exits 0. If full tests fail for an unrelated existing issue, capture the failing test names, confirm the focused diff suites still pass, and include the unrelated failures in the final report.

- [ ] **Step 5: Inspect git diff and commit verification fixes**

Run:

```bash
git status --short
git diff --stat
```

If verification required fixes, commit them:

```bash
git add Alas/Sources/Center/Diff Alas/Sources/Center/DiffTabView.swift Alas/Sources/Persistence/AppConfig.swift AlasTests
git commit -m "fix(diff): polish review-ready pane"
```

Expected: working tree contains only intentional changes or is clean after commits.

## Execution Notes

- Follow TDD: every production change in Tasks 1-4 starts with the failing test listed in the task.
- Keep commits per task. Do not combine unrelated fixes across tasks.
- Preserve `HunkView`; commit and draft-commit views still use it in this V1 plan.
- Do not edit `project.yml`; the existing `Alas/Sources` source glob picks up the new Swift files.
- Do not add attribution footers, generated-by markers, or co-author trailers.
