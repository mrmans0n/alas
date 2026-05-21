import Foundation
import Testing
@testable import Alas

struct GitRefNameInputFilterTests {
    @Test func editingBlocksCharactersThatCannotAppearInGitRefs() {
        let filtered = GitRefNameInputFilter.branchName.sanitize(
            "feat bad~name^with:chars?and*glob[set]\\tail\n",
            mode: .editing
        )

        #expect(filtered == "featbadnamewithcharsandglobset]tail")
    }

    @Test func editingBlocksInvalidSingleCharacterInsertion() {
        let filtered = GitRefNameInputFilter.branchName.applyingReplacement(
            to: "feature/login",
            range: NSRange(location: "feature".count, length: 0),
            replacement: ":"
        )

        #expect(filtered == "feature/login")
    }

    @Test func editingBlocksLeadingDashInsertion() {
        let filtered = GitRefNameInputFilter.branchName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "-"
        )

        #expect(filtered == "")
    }

    @Test func pasteStripsLeadingDashesOnlyFromFirstPathComponent() {
        let filtered = GitRefNameInputFilter.branchName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "-feature/-login"
        )

        #expect(filtered == "feature/-login")
        #expect(GitNameValidator.validateBranchName(filtered) == .valid)
    }

    @Test func pastePreservesValidDashPrefixedNestedPathComponents() {
        let filtered = GitRefNameInputFilter.branchName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "feature/-dash"
        )

        #expect(filtered == "feature/-dash")
        #expect(GitNameValidator.validateBranchName(filtered) == .valid)
    }

    @Test func editingAllowsSlashSeparatorsWhileTyping() {
        let filtered = GitRefNameInputFilter.branchName.applyingReplacement(
            to: "feature",
            range: NSRange(location: "feature".count, length: 0),
            replacement: "/"
        )

        #expect(filtered == "feature/")
    }

    @Test func pasteCannotLeaveInvalidBranchNameSequences() {
        let filtered = GitRefNameInputFilter.branchName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "/bad name//..hidden/@{1}/fix.lock/trailing."
        )

        #expect(filtered == "badname/hidden/@1}/fix/trailing")
        #expect(GitNameValidator.validateBranchName(filtered) == .valid)
    }

    @Test func pastePreservesTrailingSlashForBranchPrefix() {
        let filtered = GitRefNameInputFilter.branchPrefix.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "feature//bad name/"
        )

        #expect(filtered == "feature/badname/")
        #expect(GitNameValidator.validateBranchPrefix(filtered) == .valid)
    }

    @Test func pasteDropsTrailingSlashForBranchNames() {
        let filtered = GitRefNameInputFilter.branchName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "feature/login/"
        )

        #expect(filtered == "feature/login")
        #expect(GitNameValidator.validateBranchName(filtered) == .valid)
    }

    @Test func refNamePreservesBareDashCommitIsh() {
        let filtered = GitRefNameInputFilter.refName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "-"
        )

        #expect(filtered == "-")
    }

    @Test func refNamePreservesPreviousCheckoutRevisionSyntax() {
        let filtered = GitRefNameInputFilter.refName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "@{-1}"
        )

        #expect(filtered == "@{-1}")
    }

    @Test func refNamePreservesCommonCommitIshOperators() {
        let filtered = GitRefNameInputFilter.refName.applyingReplacement(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "main~1^{commit}"
        )

        #expect(filtered == "main~1^{commit}")
    }
}
