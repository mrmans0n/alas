import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Guards the two costs that made fling-scrolling a multi-file review hitch:
/// syntax tokenization on the row-mount path, and a full row-height re-walk
/// every time the row plan is rebuilt (which happens on every file-boundary
/// crossing, because the active file changing re-renders the review surface).
///
/// These assert on work avoided rather than wall-clock time so they stay
/// meaningful on a loaded CI machine.
@Suite(.serialized)
@MainActor
struct AppKitDiffReviewFlingPerfTests {
    private static let fileCount = 6
    private static let hunksPerFile = 4
    private static let linesPerHunk = 40

    @Test func prewarmingRemovesTokenizationFromTheRowMountPath() throws {
        let theme = try ThemeStore().current
        let file = makeFile(index: 0, salt: "prewarm")
        let groups = try #require(file.displayModel?.groups)
        let font = CenterTypography.resolveCodeFont(family: "SF Mono", size: 13)

        DiffHighlightPrewarmer.prewarmSynchronously(
            groups: groups, expandedCollapsedRowIDs: [], layoutMode: .split,
            fileExtension: "swift", font: font, showWhitespace: false, theme: theme
        )

        // Building the same documents again is what a row mount does; after a
        // prewarm it must not tokenize anything.
        HighlightSpanCache.shared.resetStatisticsForTests()
        for group in groups {
            _ = DiffPaneTextDocumentBuilder.buildSplit(
                group: group, expandedCollapsedRowIDs: [], fileExtension: "swift",
                font: font, showWhitespace: false, theme: theme
            )
        }

        let stats = HighlightSpanCache.shared.statisticsForTests
        #expect(stats.hits > 0)
        #expect(stats.misses == 0)
    }

    @Test func rebuildingTheRowPlanDoesNotRewalkRowHeights() throws {
        let theme = try ThemeStore().current
        let files = (0..<Self.fileCount).map { makeFile(index: $0, salt: "replan") }
        let states = files.map { _ in AppKitDiffReviewFileState() }
        let inputs = zip(files, states).map { file, state in
            AppKitDiffReviewRowInput(file: file, state: state, theme: theme)
        }

        _ = AppKitDiffReviewRowPlanBuilder.build(inputs: inputs)

        // A file-boundary crossing changes the selected file, which re-renders
        // the surface and rebuilds this plan even though no row content moved.
        DiffPaneStaticHeightEstimator.rowsHeightCache.resetStatisticsForTests()
        _ = AppKitDiffReviewRowPlanBuilder.build(inputs: inputs)

        let stats = DiffPaneStaticHeightEstimator.rowsHeightCache.statisticsForTests
        #expect(stats.hits == Self.fileCount * Self.hunksPerFile)
        #expect(stats.misses == 0)
    }

    @Test func expandingContextInvalidatesOnlyTheAffectedHunkHeight() throws {
        let theme = try ThemeStore().current
        let file = collapsibleFile()
        let group = try #require(file.displayModel?.groups.first)
        let font = CenterTypography.resolveCodeFont(family: "SF Mono", size: 13)
        let collapsedID = try #require(
            group.rows.first(where: { $0.kind == .collapsed })?.id
        )

        func height(expanded: Set<String>) -> CGFloat {
            DiffPaneStaticHeightEstimator.estimatedHeight(
                for: .init(filePath: file.summary.path, groups: [group]),
                layoutMode: .split, expandedCollapsedRowIDs: expanded,
                codeFont: font, headerFont: font, wrapLines: false, showWhitespace: false
            )
        }

        let collapsed = height(expanded: [])
        let expanded = height(expanded: [collapsedID])

        #expect(expanded > collapsed)
        // Re-asking must return each cached value, not the other one.
        #expect(height(expanded: []) == collapsed)
        #expect(height(expanded: [collapsedID]) == expanded)
    }

    @Test func heightCacheKeysOnPresentationInputs() throws {
        let theme = try ThemeStore().current
        let file = makeFile(index: 0, salt: "keys")
        let group = try #require(file.displayModel?.groups.first)
        let model = DiffDisplayModel(filePath: file.summary.path, groups: [group])
        let small = CenterTypography.resolveCodeFont(family: "SF Mono", size: 11)
        let large = CenterTypography.resolveCodeFont(family: "SF Mono", size: 17)
        _ = theme

        func height(font: NSFont, layoutMode: DiffLayoutMode) -> CGFloat {
            DiffPaneStaticHeightEstimator.estimatedHeight(
                for: model, layoutMode: layoutMode, expandedCollapsedRowIDs: [],
                codeFont: font, headerFont: font, wrapLines: false, showWhitespace: false
            )
        }

        #expect(height(font: small, layoutMode: .split) < height(font: large, layoutMode: .split))
        #expect(height(font: small, layoutMode: .split) != height(font: small, layoutMode: .stacked))
    }

    private func makeFile(index: Int, salt: String) -> DiffReviewFileSectionModel {
        let hunks = (0..<Self.hunksPerFile).map { hunkIndex -> ParsedDiff.Hunk in
            let start = hunkIndex * 400 + 1
            var oldLine = start
            var newLine = start
            let lines = (0..<Self.linesPerHunk).map { lineIndex -> ParsedDiff.Hunk.Line in
                let text = "let value\(lineIndex) = SomeType.make(one: \(lineIndex), two: \"\(salt)-\(index)-\(hunkIndex)-\(lineIndex)\")"
                switch lineIndex % 4 {
                case 0:
                    defer { oldLine += 1 }
                    return .init(kind: .delete, text: text, oldNumber: oldLine, newNumber: nil)
                case 1:
                    defer { newLine += 1 }
                    return .init(kind: .add, text: text, oldNumber: nil, newNumber: newLine)
                default:
                    defer {
                        oldLine += 1
                        newLine += 1
                    }
                    return .init(kind: .context, text: text, oldNumber: oldLine, newNumber: newLine)
                }
            }
            return .init(
                header: "@@ -\(start),\(Self.linesPerHunk) +\(start),\(Self.linesPerHunk) @@",
                oldStart: start, newStart: start, lines: lines
            )
        }
        return file(hunks: hunks, path: "Sources/Module\(index)/File\(salt)\(index).swift")
    }

    /// A hunk with enough leading context to collapse.
    private func collapsibleFile() -> DiffReviewFileSectionModel {
        var lines = (1...30).map { index in
            ParsedDiff.Hunk.Line(kind: .context, text: "let context\(index) = \(index)", oldNumber: index, newNumber: index)
        }
        lines.append(.init(kind: .add, text: "let added = 0", oldNumber: nil, newNumber: 31))
        let hunk = ParsedDiff.Hunk(header: "@@ -1,30 +1,31 @@", oldStart: 1, newStart: 1, lines: lines)
        return file(hunks: [hunk], path: "Sources/Collapsible.swift")
    }

    private func file(hunks: [ParsedDiff.Hunk], path: String) -> DiffReviewFileSectionModel {
        let diff = ParsedDiff(hunks: hunks)
        let summary = DiffReviewFileSummary(
            path: path, namespace: "review", groupID: nil, groupTitle: nil,
            status: .modified, additions: 1, deletions: 1, isRenderable: true
        )
        return DiffReviewFileSectionModel(
            summary: summary, parsedDiff: diff,
            displayModel: DiffDisplayModelBuilder.build(diff: diff, filePath: summary.path),
            placeholderMessage: nil, openFile: nil, contextProvider: nil
        )
    }
}
