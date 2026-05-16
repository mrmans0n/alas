import Testing
@testable import Alas

struct GitNameValidatorTests {
    // MARK: - Accepted names
    @Test func acceptsSimpleBranchName() {
        let result = GitNameValidator.validateBranchName("feat-x")
        #expect(result == .valid)
    }

    @Test func acceptsPathStyleBranchName() {
        let result = GitNameValidator.validateBranchName("feature/foo-bar")
        #expect(result == .valid)
    }

    @Test func acceptsBranchWithMultipleSlashes() {
        let result = GitNameValidator.validateBranchName("release/v1/0")
        #expect(result == .valid)
    }

    @Test func acceptsBranchWithHyphens() {
        let result = GitNameValidator.validateBranchName("bug-fix-correct")
        #expect(result == .valid)
    }

    @Test func acceptsBranchWithUnderscores() {
        let result = GitNameValidator.validateBranchName("bug_fix_correct")
        #expect(result == .valid)
    }

    @Test func acceptsBranchWithNumbers() {
        let result = GitNameValidator.validateBranchName("v1.2.3")
        #expect(result == .valid)
    }

    // MARK: - Rejected names
    @Test func rejectsEmptyName() {
        let result = GitNameValidator.validateBranchName("")
        #expect(result == .invalid("Name cannot be empty."))
    }

    @Test func rejectsWhitespaceOnlyName() {
        let result = GitNameValidator.validateBranchName("   ")
        #expect(result == .invalid("Name cannot contain spaces."))
    }

    @Test func rejectsNameWithSpaces() {
        let result = GitNameValidator.validateBranchName("bad name")
        #expect(result == .invalid("Name cannot contain spaces."))
    }

    @Test func rejectsLeadingSpace() {
        let result = GitNameValidator.validateBranchName(" leading")
        #expect(result == .invalid("Name cannot contain spaces."))
    }

    @Test func rejectsTrailingSpace() {
        let result = GitNameValidator.validateBranchName("trailing ")
        #expect(result == .invalid("Name cannot contain spaces."))
    }

    @Test func rejectsDotComponent() {
        let result = GitNameValidator.validateBranchName("feature/.secret")
        #expect(result == .invalid("Path components cannot start or end with '.'."))
    }

    @Test func rejectsDotDotComponent() {
        let result = GitNameValidator.validateBranchName("feature/..")
        #expect(result == .invalid("Name cannot contain '.' or '..' as a path component."))
    }

    @Test func rejectsPathTraversal() {
        let result = GitNameValidator.validateBranchName("../escape")
        #expect(result == .invalid("Name cannot contain '.' or '..' as a path component."))
    }

    @Test func rejectsLeadingSlash() {
        let result = GitNameValidator.validateBranchName("/leading")
        #expect(result == .invalid("Name cannot start or end with '/' ."))
    }

    @Test func rejectsTrailingSlash() {
        let result = GitNameValidator.validateBranchName("trailing/")
        #expect(result == .invalid("Name cannot start or end with '/' ."))
    }

    @Test func rejectDoubleSlash() {
        let result = GitNameValidator.validateBranchName("feature//double")
        #expect(result == .invalid("Name cannot contain consecutive '/' ."))
    }

    @Test func rejectsTilde() {
        let result = GitNameValidator.validateBranchName("fix~backup")
        #expect(result == .invalid("Name contains unsupported characters."))
    }

    @Test func rejectsCaret() {
        let result = GitNameValidator.validateBranchName("v1^2")
        #expect(result == .invalid("Name contains unsupported characters."))
    }

    @Test func rejectsColon() {
        let result = GitNameValidator.validateBranchName("feat:new")
        #expect(result == .invalid("Name contains unsupported characters."))
    }

    @Test func rejectsBackslash() {
        let result = GitNameValidator.validateBranchName("feat\\new")
        #expect(result == .invalid("Name contains unsupported characters."))
    }

    @Test func rejectsQuestionMark() {
        let result = GitNameValidator.validateBranchName("what?")
        #expect(result == .invalid("Name contains unsupported characters."))
    }

    @Test func rejectsAsterisk() {
        let result = GitNameValidator.validateBranchName("feat/*")
        #expect(result == .invalid("Name contains unsupported characters."))
    }

    @Test func rejectsAtCurly() {
        let result = GitNameValidator.validateBranchName("stash@{1}")
        #expect(result == .invalid("Name cannot contain '@{' ."))
    }

    @Test func rejectsLeadingDashComponent() {
        let result = GitNameValidator.validateBranchName("feature/-dash")
        #expect(result == .invalid("Path components cannot start with '-' ."))
    }

    @Test func rejectsDotLock() {
        let result = GitNameValidator.validateBranchName("fix.lock")
        #expect(result == .invalid("Name cannot end with '.lock' ."))
    }

    @Test func rejectsVeryLongName() {
        let result = GitNameValidator.validateBranchName(String(repeating: "a", count: 251))
        #expect(result == .invalid("Name is too long (max 250 characters)."))
    }

    // MARK: - Worktree name alias
    @Test func worktreeNameDelegatesToBranchValidator() {
        let result = GitNameValidator.validateWorktreeName("feature/foo")
        #expect(result == .valid)
    }
}
