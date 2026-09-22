import AppKit
import Foundation
import CoreGraphics
import Testing
@testable import Alas

struct DiffPaneTextDocumentBuilderTests {
    @Test func chevronPointsDownForBelowBoundary() {
        #expect(DiffPaneTextDocumentBuilder.expandableContextSymbolName(boundary: .below) == "chevron.down")
    }

    @Test func chevronPointsUpForAboveBoundary() {
        #expect(DiffPaneTextDocumentBuilder.expandableContextSymbolName(boundary: .above) == "chevron.up")
    }

    @Test func chevronDefaultsToDownWhenBoundaryMissing() {
        #expect(DiffPaneTextDocumentBuilder.expandableContextSymbolName(boundary: nil) == "chevron.down")
    }

    @Test func expandAllUsesDoubleChevron() {
        #expect(
            DiffPaneTextDocumentBuilder.expandableContextSymbolName(boundary: .above, mode: .all)
                == "chevron.up.2"
        )
        #expect(
            DiffPaneTextDocumentBuilder.expandableContextSymbolName(boundary: .below, mode: .all)
                == "chevron.down.2"
        )
    }

    @Test func pillFillAlphaByState() {
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: false, pressed: false) == 0)
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: true, pressed: false) == 0.28)
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: true, pressed: true) == 0.36)
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: false, pressed: true) == 0.36)
    }

    @MainActor
    @Test func expandableContextRowContainsPillWithVerticalClearance() throws {
        let font = CenterTypography.resolveCodeFont(family: "", size: 32)
        let row = expandableContextRow(remainingLineCount: 46, boundary: .below)
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            rows: [row],
            fileExtension: "swift",
            font: font,
            showWhitespace: false,
            theme: try ThemeStore().current
        )
        let paragraph = try #require(
            result.oldCode.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let rowHeight = paragraph.minimumLineHeight
        let labelHeight = font.ascender - font.descender
        let rowRect = CGRect(x: 0, y: 0, width: 600, height: rowHeight)
        let textRect = CGRect(
            x: 120,
            y: (rowHeight - labelHeight) / 2,
            width: 260,
            height: labelHeight
        )

        let pillRect = DiffPaneCodeTextView.expandPillRect(
            textRect: textRect,
            firstLineRect: rowRect,
            rowRect: rowRect,
            chevronSize: CGSize(width: 31, height: 31)
        )

        #expect(pillRect.minY - rowRect.minY >= 4)
        #expect(rowRect.maxY - pillRect.maxY >= 4)
    }

    @Test func expandPillStaysWithFirstTextFragmentInTallRows() {
        let textRect = CGRect(x: 120, y: 18, width: 230, height: 16)
        let firstLineRect = CGRect(x: 0, y: 14, width: 700, height: 72)
        let rowRect = CGRect(x: 0, y: 14, width: 700, height: 72)
        let chevronSize = CGSize(width: 12, height: 12)

        let pillRect = DiffPaneCodeTextView.expandPillRect(
            textRect: textRect,
            firstLineRect: firstLineRect,
            rowRect: rowRect,
            chevronSize: chevronSize
        )

        #expect(pillRect.midY == textRect.midY)
        #expect(pillRect.midY != firstLineRect.midY)
        #expect(pillRect.midY != rowRect.midY)

        let chevronRect = DiffPaneCodeTextView.expandChevronRect(
            chevronLeftX: textRect.minX - 5 - chevronSize.width,
            chevronSize: chevronSize,
            pillRect: pillRect
        )

        #expect(chevronRect.midY == pillRect.midY)
        #expect(chevronRect.midY != rowRect.midY)
    }

    @Test func expandPillRectClampsInsideRowWhenTextRectEscapes() {
        let textRect = CGRect(x: 120, y: -3, width: 230, height: 20)
        let firstLineRect = CGRect(x: 0, y: 0, width: 700, height: 28)
        let rowRect = CGRect(x: 0, y: 0, width: 700, height: 28)
        let chevronSize = CGSize(width: 12, height: 12)

        let pillRect = DiffPaneCodeTextView.expandPillRect(
            textRect: textRect,
            firstLineRect: firstLineRect,
            rowRect: rowRect,
            chevronSize: chevronSize
        )

        #expect(pillRect.minY >= rowRect.minY)
        #expect(pillRect.maxY <= rowRect.maxY)
    }

    /// tree-sitter-kotlin-ng's external scanner has two annotation-scanning
    /// loops (constructor and get/set accessor contexts) that used to
    /// advance without checking EOF. `DiffPaneTextDocumentBuilder` slices a
    /// document's syntax source into per-hunk segments
    /// (`highlightedCodeDocument`); a hunk that adds a bare `@Foo` as its
    /// last line — its annotated declaration lives outside the hunk, which
    /// is completely ordinary for a diff — produces exactly that truncated
    /// segment. `buildSplit` is the exact function named in the live crash
    /// stack (`DiffPaneTextDocumentBuilder.buildSplit` → `highlightedCodeDocument`
    /// → `TreeSitterHighlighter.computeHighlight`), so this drives it
    /// directly rather than through the shared `DiffPaneDocumentCache`
    /// singleton: that cache's `misses` counter increments on a lookup miss
    /// *before* the parse it guards even starts, so polling it cannot bound
    /// the parse, and the singleton is also mutated by other un-coordinated
    /// test suites. Bounding the call itself on a background thread with a
    /// semaphore timeout avoids both problems and still fails fast — instead
    /// of hanging the whole test process — if the scanner regresses.
    @MainActor
    @Test func kotlinTruncatedAnnotationDoesNotHangDiffPaneBuildSplit() throws {
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let theme = try ThemeStore().current
        let cases: [(label: String, lines: [ParsedDiff.Hunk.Line])] = [
            (
                "top-level truncated annotation (get/set accessor context)",
                [
                    .init(kind: .context, text: "val x = 1", oldNumber: 1, newNumber: 1),
                    .init(kind: .add, text: "@Foo", oldNumber: nil, newNumber: 2),
                ]
            ),
            (
                "class-body truncated annotation (constructor context)",
                [
                    .init(kind: .context, text: "class A {", oldNumber: 1, newNumber: 1),
                    .init(kind: .context, text: "val x = 1", oldNumber: 2, newNumber: 2),
                    .init(kind: .add, text: "@Foo", oldNumber: nil, newNumber: 3),
                ]
            ),
        ]

        for testCase in cases {
            let hunk = ParsedDiff.Hunk(
                header: "@@ -1,\(testCase.lines.count) +1,\(testCase.lines.count) @@",
                oldStart: 1,
                newStart: 1,
                lines: testCase.lines
            )
            let group = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk]), filePath: "a.kt").groups[0]
            let rows = DiffPaneRowProjection.visibleRows(in: group, expandedCollapsedRowIDs: [])

            let box = UncheckedResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                box.result = DiffPaneTextDocumentBuilder.buildSplit(
                    rows: rows, fileExtension: "kt", font: font, showWhitespace: false, theme: theme
                )
                semaphore.signal()
            }

            let waitResult = semaphore.wait(timeout: .now() + 5.0)
            #expect(
                waitResult == .success,
                "\(testCase.label): buildSplit hung past the 5s bound — kotlin-ng scanner likely hung on the truncated annotation"
            )
            guard waitResult == .success, let result = box.result else { continue }
            #expect(result.newCode.attributedString.string.contains("@Foo"), "\(testCase.label): annotation text was lost")
        }
    }

    private func expandableContextRow(
        remainingLineCount: Int,
        boundary: DiffContextBoundary
    ) -> DiffDisplayRow {
        DiffDisplayRow(
            id: "expand-\(boundary.rawValue)",
            kind: .expandableContext,
            old: nil,
            new: nil,
            collapsedLineCount: remainingLineCount,
            contextExpansion: DiffContextExpansionRow(
                key: DiffContextExpansionKey(groupID: "hunk-0", boundary: boundary),
                boundary: boundary,
                remainingLineCount: remainingLineCount
            )
        )
    }
}

/// `DiffPaneTextDocumentBuilder.SplitResult` holds `NSAttributedString`,
/// which is not `Sendable`. Access here is externally serialized by the
/// semaphore in the test above (write happens-before the signal, read
/// happens-after a successful wait), matching `UncheckedFontBox`'s rationale
/// in `DiffHighlightPrewarmer.swift`.
private final class UncheckedResultBox: @unchecked Sendable {
    var result: DiffPaneTextDocumentBuilder.SplitResult?
}
