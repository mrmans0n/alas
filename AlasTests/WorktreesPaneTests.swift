import Testing
@testable import Alas

struct WorktreesPaneTests {
    @Test func persistsValidBranchPrefix() {
        #expect(WorktreesPane.persistableBranchPrefix("feature/") == "feature/")
        #expect(WorktreesPane.persistableBranchPrefix("nacho") == "nacho")
    }

    @Test func persistsEmptyBranchPrefix() {
        #expect(WorktreesPane.persistableBranchPrefix("") == "")
    }

    @Test func rejectsInvalidBranchPrefixWithoutPersisting() {
        #expect(WorktreesPane.persistableBranchPrefix("feature name/") == nil)
        #expect(WorktreesPane.persistableBranchPrefix("feature//") == nil)
        #expect(WorktreesPane.persistableBranchPrefix("-feature") == nil)
    }
}
