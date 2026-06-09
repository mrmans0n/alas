import Testing
@testable import Alas

@Suite("ACPSelectChip metrics")
struct ACPSelectChipMetricsTests {
    @Test("selector chips do not reserve a leading color indicator")
    func selectorChipsDoNotReserveLeadingColorIndicator() {
        #expect(ACPSelectChipMetrics.leadingIndicatorDiameter == 0)
    }

    @Test("label and chevron keep compact spacing")
    func labelAndChevronKeepCompactSpacing() {
        #expect(ACPSelectChipMetrics.labelChevronSpacing == 5)
    }
}
