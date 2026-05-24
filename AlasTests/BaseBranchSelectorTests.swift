import Testing
@testable import Alas

struct BaseBranchSelectorTests {
    @Test func isSelectedUsesCurrentRefWhenAvailable() {
        #expect(BaseBranchSelector.isSelected(row: "origin/feature", baseBranch: "main", currentRef: "origin/feature"))
        #expect(!BaseBranchSelector.isSelected(row: "main", baseBranch: "main", currentRef: "origin/feature"))
    }

    @Test func isSelectedFallsBackToBaseBranch() {
        #expect(BaseBranchSelector.isSelected(row: "main", baseBranch: "main", currentRef: nil))
        #expect(!BaseBranchSelector.isSelected(row: "origin/feature", baseBranch: "main", currentRef: nil))
    }

    @Test func smartListOrdersMainlinesFirst() {
        let branches = ["feature/x", "main", "origin/main", "develop"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            currentRef: "origin/main",
            upstream: "origin/feature-x",
            recent: []
        )
        #expect(result.first == "main")
        #expect(result[1] == "origin/main")
        #expect(result[2] == "develop")
    }

    @Test func smartListDoesNotPromoteNestedBranchesNamedMain() {
        let result = BaseBranchSelector.smartList(
            branches: ["origin/release/main", "origin/main", "feature/main"],
            currentRef: nil,
            upstream: nil,
            recent: []
        )
        #expect(result == ["origin/main", "origin/release/main", "feature/main"])
    }

    @Test func smartListIncludesUpstreamWhenNotMainline() {
        let branches = ["main", "origin/feature-x"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            currentRef: "origin/main",
            upstream: "origin/feature-x",
            recent: []
        )
        #expect(result.contains("origin/feature-x"))
    }

    @Test func smartListDedupesUpstreamThatIsAlsoMainline() {
        let branches = ["main", "origin/main"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            currentRef: "origin/main",
            upstream: "origin/main",
            recent: []
        )
        #expect(result == ["main", "origin/main"])
    }

    @Test func smartListDedupesRecentAgainstMainlines() {
        let branches = ["main", "origin/main", "a"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            currentRef: "origin/main",
            upstream: "origin/main",
            recent: ["main", "a"]
        )
        #expect(result == ["main", "origin/main", "a"])
    }

    @Test func smartListDedupesRecentInternally() {
        let branches = ["main", "a"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            currentRef: "main",
            upstream: nil,
            recent: ["a", "a", "b"]
        )
        #expect(result == ["main", "b", "a"])
    }

    @Test func smartListSkipsAbsentMainlines() {
        let branches = ["main", "origin/main"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            currentRef: "origin/main",
            upstream: nil,
            recent: []
        )
        #expect(result == ["main", "origin/main"])
    }

    @Test func smartListCapsRecentAtThree() {
        let branches = ["main", "a", "b", "c", "d"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            currentRef: "main",
            upstream: nil,
            recent: ["a", "b", "c", "d"]
        )
        #expect(result == ["main", "d", "c", "b", "a"])
    }

    @Test func smartListOrdersRecentNewestFirst() {
        let result = BaseBranchSelector.smartList(
            branches: ["main", "release/old", "release/current", "release/new"],
            currentRef: "main",
            upstream: nil,
            recent: ["release/old", "release/current", "release/new"]
        )
        #expect(result.prefix(4) == ["main", "release/new", "release/current", "release/old"])
    }

    @Test func smartListHandlesEmptyInput() {
        let result = BaseBranchSelector.smartList(
            branches: [],
            currentRef: nil,
            upstream: nil,
            recent: []
        )
        #expect(result.isEmpty)
    }

    @Test func smartListIncludesCurrentRefWhenAbsentFromShortlist() {
        let result = BaseBranchSelector.smartList(
            branches: ["main", "origin/main"],
            currentRef: "release/2026.1",
            upstream: nil,
            recent: []
        )
        #expect(result == ["main", "origin/main", "release/2026.1"])
    }

    @Test func smartListKeepsNonSmartBranchesSearchable() {
        let result = BaseBranchSelector.smartList(
            branches: ["main", "release/2026.1", "hotfix/payment"],
            currentRef: "main",
            upstream: nil,
            recent: []
        )
        #expect(result == ["main", "release/2026.1", "hotfix/payment"])
    }
}
