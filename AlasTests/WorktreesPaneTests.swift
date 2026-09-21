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

    @Test func surfacesErrorForPersistedInvalidPrefixWithoutADraft() {
        #expect(WorktreesPane.branchPrefixValidationMessage(draft: nil, persisted: "feature name/") != nil)
    }

    @Test func surfacesNoErrorForValidPersistedPrefixWithoutADraft() {
        #expect(WorktreesPane.branchPrefixValidationMessage(draft: nil, persisted: "feature/") == nil)
    }

    @Test func draftErrorTakesPrecedenceOverPersistedValue() {
        #expect(WorktreesPane.branchPrefixValidationMessage(draft: "feature name/", persisted: "feature/") != nil)
    }
}
