import AppKit
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
