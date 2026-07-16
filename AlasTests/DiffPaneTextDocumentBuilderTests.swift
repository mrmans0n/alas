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

    @Test func pillFillAlphaByState() {
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: false, pressed: false) == 0.18)
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: true, pressed: false) == 0.28)
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: true, pressed: true) == 0.36)
        #expect(DiffPaneCodeTextView.expandPillFillAlpha(hovered: false, pressed: true) == 0.36)
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
}
