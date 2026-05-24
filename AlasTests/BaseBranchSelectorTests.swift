import Testing
@testable import Alas

struct BaseBranchSelectorTests {
    @Test func smartListOrdersMainlinesFirst() {
        let branches = ["feature/x", "main", "origin/main", "develop"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            current: "origin/main",
            upstream: "origin/feature-x",
            recent: []
        )
        #expect(result.first == "main")
        #expect(result[1] == "origin/main")
        #expect(result[2] == "develop")
    }

    @Test func smartListIncludesUpstreamWhenNotMainline() {
        let branches = ["main", "origin/feature-x"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            current: "origin/main",
            upstream: "origin/feature-x",
            recent: []
        )
        #expect(result.contains("origin/feature-x"))
    }

    @Test func smartListDedupesUpstreamThatIsAlsoMainline() {
        let branches = ["main", "origin/main"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            current: "origin/main",
            upstream: "origin/main",
            recent: []
        )
        #expect(result.filter { $0 == "origin/main" }.count == 1)
    }

    @Test func smartListCapsRecentAtThree() {
        let branches = ["main", "a", "b", "c", "d"]
        let result = BaseBranchSelector.smartList(
            branches: branches,
            current: "main",
            upstream: nil,
            recent: ["a", "b", "c", "d"]
        )
        let recentSection = result.drop(while: { $0 != "a" }).prefix(4)
        #expect(recentSection.count == 3)
    }

    @Test func smartListHandlesEmptyInput() {
        let result = BaseBranchSelector.smartList(
            branches: [],
            current: nil,
            upstream: nil,
            recent: []
        )
        #expect(result.isEmpty)
    }
}
