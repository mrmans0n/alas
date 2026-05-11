import Testing
@testable import Alas

struct ChangeSummaryVisibilityTests {
    @Test func hidesEmptyChangeSummary() {
        #expect(shouldShowChangeSummary(additions: 0, deletions: 0) == false)
    }

    @Test func showsChangeSummaryWhenEitherCountIsPresent() {
        #expect(shouldShowChangeSummary(additions: 3, deletions: 0))
        #expect(shouldShowChangeSummary(additions: 0, deletions: 5))
        #expect(shouldShowChangeSummary(additions: 3, deletions: 5))
    }
}
