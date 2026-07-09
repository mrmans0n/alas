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
}
