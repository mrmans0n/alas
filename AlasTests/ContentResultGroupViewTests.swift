import Testing
@testable import Alas

struct ContentResultGroupViewTests {
    @Test func lineNumberLabelUsesRawDigitsWithoutGrouping() {
        #expect(ContentResultGroupView.lineNumberLabel(for: 1_080) == "1080")
    }
}
