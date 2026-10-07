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
        "", "   ", "bad name", " leading", "trailing ",
        "feature/.secret", "foo/bar.", "feature/..", "../escape",
        "/leading", "trailing/", "feature//double",
        "fix~backup", "v1^2", "feat:new", "feat\\new", "what?",
        "feat/*", "feature/[wip]", "stash@{1}", "@", "-dash", "fix.lock",
        String(repeating: "a", count: 251),
    ])
    func rejectsBranchName(_ name: String) {
        #expect(GitNameValidator.validateBranchName(name) != .valid)
    }

    @Test("Normalizes characters entered in a branch-name field", arguments: [
        ("my feature a", "my-feature-a"),
        ("fix~one^two:three?four*five[six\\seven", "fixonetwothreefourfivesixseven"),
        ("feature/\u{0000}name\u{007f}", "feature/name"),
        ("feature/naïve-修正", "feature/naïve-修正"),
    ])
    func normalizesBranchNameInput(_ input: String, expected: String) {
        #expect(GitNameValidator.normalizedBranchNameInput(input) == expected)
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
        "/", "feature//", "bad name/", "../",
    ])
    func rejectsBranchPrefix(_ prefix: String) {
        #expect(GitNameValidator.validateBranchPrefix(prefix) != .valid)
    }
}
