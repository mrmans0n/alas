import Testing
@testable import Alas

struct GitNameValidatorTests {
    // MARK: - Branch names

    @Test("Accepts valid branch name", arguments: [
        "feat-x",              // simple
        "feature/foo-bar",     // path style
        "release/v1/0",        // multiple slashes
        "bug-fix-correct",     // hyphens
        "bug_fix_correct",     // underscores
        "v1.2.3",              // numbers and dots
        "foo./bar",            // intermediate component ending in '.'
        "user@branch",         // '@' inside a component
        "feature/{foo}",       // braces without '@'
        "feature/-dash",       // hyphen starting a non-first component
    ])
    func acceptsBranchName(_ name: String) {
        #expect(GitNameValidator.validateBranchName(name) == .valid)
    }

    @Test("Rejects invalid branch name", arguments: [
        ("", "Name cannot be empty."),
        ("   ", "Name cannot contain spaces."),
        ("bad name", "Name cannot contain spaces."),
        (" leading", "Name cannot contain spaces."),
        ("trailing ", "Name cannot contain spaces."),
        ("feature/.secret", "Path components cannot start with '.'."),
        ("foo/bar.", "Name cannot end with '.'."),
        ("feature/..", "Name cannot contain '.' or '..' as a path component."),
        ("../escape", "Name cannot contain '.' or '..' as a path component."),
        ("/leading", "Name cannot start or end with '/' ."),
        ("trailing/", "Name cannot start or end with '/' ."),
        ("feature//double", "Name cannot contain consecutive '/' ."),
        ("fix~backup", "Name contains unsupported characters."),
        ("v1^2", "Name contains unsupported characters."),
        ("feat:new", "Name contains unsupported characters."),
        ("feat\\new", "Name contains unsupported characters."),
        ("what?", "Name contains unsupported characters."),
        ("feat/*", "Name contains unsupported characters."),
        ("feature/[wip]", "Name contains unsupported characters."),
        ("stash@{1}", "Name cannot contain '@{' ."),
        ("@", "'@' is not a valid branch name."),
        ("-dash", "Name cannot start with '-' ."),
        ("fix.lock", "Name cannot end with '.lock' ."),
        (String(repeating: "a", count: 251), "Name is too long (max 250 characters)."),
    ])
    func rejectsBranchName(_ name: String, message: String) {
        #expect(GitNameValidator.validateBranchName(name) == .invalid(message))
    }

    // MARK: - Worktree name alias

    @Test func worktreeNameDelegatesToBranchValidator() {
        let result = GitNameValidator.validateWorktreeName("feature/foo")
        #expect(result == .valid)
    }

    // MARK: - Branch prefix validation

    @Test("Accepts valid branch prefix", arguments: [
        "feature/",
        "feature",       // no trailing slash
        "",              // empty prefix
        "release/v1/",   // nested with trailing slash
    ])
    func acceptsBranchPrefix(_ prefix: String) {
        #expect(GitNameValidator.validateBranchPrefix(prefix) == .valid)
    }

    @Test("Rejects invalid branch prefix", arguments: [
        ("/", "Prefix cannot be '/' only."),
        ("feature//", "Prefix cannot contain consecutive '/'."),
        ("bad name/", "Name cannot contain spaces."),
        ("../", "Name cannot contain '.' or '..' as a path component."),
    ])
    func rejectsBranchPrefix(_ prefix: String, message: String) {
        #expect(GitNameValidator.validateBranchPrefix(prefix) == .invalid(message))
    }
}
