import AppKit
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffPaneDocumentCacheTests {
    @Test func secondBuildWithSameInputsIsAHit() throws {
        let cache = DiffPaneDocumentCache()
        let rows = try rows()
        let font = CenterTypography.resolveCodeFont(family: "SF Mono", size: 13)
        let theme = try ThemeStore().current

        let first = cache.splitResult(
            rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme
        )
        let second = cache.splitResult(
            rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme
        )

        #expect(first.newCode.attributedString === second.newCode.attributedString)
        #expect(cache.statisticsForTests == (hits: 1, misses: 1))
    }

    @Test func presentationInputsAreCacheKeys() throws {
        let cache = DiffPaneDocumentCache()
        let rows = try rows()
        let small = CenterTypography.resolveCodeFont(family: "SF Mono", size: 11)
        let large = CenterTypography.resolveCodeFont(family: "SF Mono", size: 17)
        let theme = try ThemeStore().current

        _ = cache.splitResult(rows: rows, fileExtension: "swift", font: small, showWhitespace: false, theme: theme)
        _ = cache.splitResult(rows: rows, fileExtension: "swift", font: large, showWhitespace: false, theme: theme)
        _ = cache.splitResult(rows: rows, fileExtension: "swift", font: small, showWhitespace: true, theme: theme)
        _ = cache.splitResult(rows: rows, fileExtension: "txt", font: small, showWhitespace: false, theme: theme)

        #expect(cache.statisticsForTests == (hits: 0, misses: 4))
    }

    @Test func splitAndStackedDoNotShareEntries() throws {
        let cache = DiffPaneDocumentCache()
        let rows = try rows()
        let font = CenterTypography.resolveCodeFont(family: "SF Mono", size: 13)
        let theme = try ThemeStore().current

        _ = cache.splitResult(rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme)
        _ = cache.stackedResult(rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme)

        #expect(cache.statisticsForTests == (hits: 0, misses: 2))
    }

    @Test func prewarmerPopulatesTheSharedCacheForRowMounts() throws {
        let theme = try ThemeStore().current
        let font = CenterTypography.resolveCodeFont(family: "SF Mono", size: 13)
        let group = try group()

        DiffPaneDocumentCache.shared.removeAll()
        DiffHighlightPrewarmer.prewarmSynchronously(
            groups: [group], expandedCollapsedRowIDs: [], layoutMode: .split,
            fileExtension: "swift", font: font, showWhitespace: false, theme: theme
        )

        // A row mount projects the group's visible rows and asks the cache;
        // after a prewarm that must not build anything.
        DiffPaneDocumentCache.shared.resetStatisticsForTests()
        _ = DiffPaneDocumentCache.shared.splitResult(
            rows: DiffPaneRowProjection.visibleRows(in: group, expandedCollapsedRowIDs: []),
            fileExtension: "swift", font: font, showWhitespace: false, theme: theme
        )

        let stats = DiffPaneDocumentCache.shared.statisticsForTests
        #expect(stats.hits == 1)
        #expect(stats.misses == 0)
    }

    private func rows() throws -> [DiffDisplayRow] {
        try group().rows.filter { $0.kind != .collapsed }
    }

    private func group() throws -> DiffDisplayGroup {
        let lines = (0..<24).map { index -> ParsedDiff.Hunk.Line in
            let text = "let value\(index) = compute(\(index))"
            switch index % 3 {
            case 0:
                return .init(kind: .delete, text: text, oldNumber: index + 1, newNumber: nil)
            case 1:
                return .init(kind: .add, text: text, oldNumber: nil, newNumber: index + 1)
            default:
                return .init(kind: .context, text: text, oldNumber: index + 1, newNumber: index + 1)
            }
        }
        let hunk = ParsedDiff.Hunk(header: "@@ -1,24 +1,24 @@", oldStart: 1, newStart: 1, lines: lines)
        let model = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk]), filePath: "Cache.swift")
        return try #require(model.groups.first)
    }
}
