import Testing
@testable import Alas

struct FollowRevisionPrefillTests {
    @Test func derivesHeadForDisplayedTip() {
        #expect(FollowRevisionPrefill.expression(
            displayedSHA: "tip",
            firstParentSHAs: ["tip", "parent"]
        ) == "HEAD")
    }

    @Test func derivesHeadOffsetForDisplayedAncestor() {
        #expect(FollowRevisionPrefill.expression(
            displayedSHA: "grandparent",
            firstParentSHAs: ["tip", "parent", "grandparent"]
        ) == "HEAD~2")
    }

    @Test func leavesUnrelatedDisplayedCommitBlank() {
        #expect(FollowRevisionPrefill.expression(
            displayedSHA: "side-commit",
            firstParentSHAs: ["tip", "parent", "grandparent"]
        ) == nil)
    }
}
