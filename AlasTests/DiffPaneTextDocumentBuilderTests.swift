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
}
