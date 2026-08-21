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

    /// Regression for a font/theme change leaving the row-mount path cold:
    /// `DiffPaneRowPlanBuilder.prewarmHighlightsIfNeeded` dedupes on
    /// `DiffHighlightPrewarmer.signature`, and `warm` populates
    /// `DiffPaneDocumentCache`, whose key includes font and theme. If the
    /// signature didn't also vary with font/theme, a font-size or theme
    /// change would be treated as "already prewarmed" and every row mount
    /// after that would miss the document cache and rebuild synchronously
    /// during scroll.
    @Test func prewarmDedupeSignatureVariesWithFontAndTheme() throws {
        let theme = try ThemeStore().current
        var otherTheme = theme
        otherTheme.accentOverrideHex = "#ff0000"
        let small = CenterTypography.resolveCodeFont(family: "SF Mono", size: 11)
        let large = CenterTypography.resolveCodeFont(family: "SF Mono", size: 17)
        let group = try group()

        func signature(font: NSFont, theme: Theme) -> Int {
            DiffHighlightPrewarmer.signature(
                groups: [group], expandedCollapsedRowIDs: [], layoutMode: .split,
                fileExtension: "swift", font: font, showWhitespace: false, theme: theme
            )
        }

        let base = signature(font: small, theme: theme)
        #expect(signature(font: large, theme: theme) != base)
        #expect(signature(font: small, theme: otherTheme) != base)
    }

    /// A font change must both re-trigger the prewarm (the dedupe signature
    /// differs) and leave the document cache warm for the new font, so the
    /// subsequent row mount at that font is a cache hit rather than a
    /// synchronous rebuild.
    @Test func prewarmingAtANewFontWarmsTheCacheForThatFont() throws {
        let theme = try ThemeStore().current
        let originalFont = CenterTypography.resolveCodeFont(family: "SF Mono", size: 11)
        let newFont = CenterTypography.resolveCodeFont(family: "SF Mono", size: 17)
        let group = try group()

        DiffPaneDocumentCache.shared.removeAll()
        DiffHighlightPrewarmer.prewarmSynchronously(
            groups: [group], expandedCollapsedRowIDs: [], layoutMode: .split,
            fileExtension: "swift", font: originalFont, showWhitespace: false, theme: theme
        )
        DiffHighlightPrewarmer.prewarmSynchronously(
            groups: [group], expandedCollapsedRowIDs: [], layoutMode: .split,
            fileExtension: "swift", font: newFont, showWhitespace: false, theme: theme
        )

        DiffPaneDocumentCache.shared.resetStatisticsForTests()
        _ = DiffPaneDocumentCache.shared.splitResult(
            rows: DiffPaneRowProjection.visibleRows(in: group, expandedCollapsedRowIDs: []),
            fileExtension: "swift", font: newFont, showWhitespace: false, theme: theme
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
