import Foundation
import Testing
@testable import Alas

struct WorktreeBranchNameTests {
    @Test(arguments: [
        ("feature/", nil, nil, "feature/Fix/Auth"),
        ("", nil, nil, "Fix/Auth"),
        ("feature/", "global/{name}", nil, "global/fix-auth"),
        ("feature/", nil, "project/{name}", "project/fix-auth"),
        ("feature/", "global/{name}", " project/{name} ", "project/fix-auth"),
        ("feature/", "global/{name}", " \n ", "global/fix-auth"),
        ("feature/", " \n ", "", "feature/Fix/Auth"),
    ] as [(String, String?, String?, String)])
    func projectTemplateOverridesGlobalWithLegacyPrefixFallback(prefix: String, global: String?, project: String?, expected: String) {
        #expect(WorktreeBranchName.compose(
            name: "Fix/Auth", prefix: prefix, globalTemplate: global, projectTemplate: project
        ) == expected)
    }

    @Test func worktreeTemplatesUseScheduledExpansionAndSanitization() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 0)
        let branch = WorktreeBranchName.compose(
            name: "Login Fix!", prefix: "ignored/", globalTemplate: "..//fix.lock/{name}-{date}-{time}",
            now: now, calendar: calendar
        )
        #expect(branch == "fix/login-fix-19700101-0000")
        #expect(GitNameValidator.validateBranchName(branch) == .valid)
    }

    @Test(arguments: ["", " \n "])
    func emptyNameCannotCreateABranchEvenWithALiteralTemplate(name: String) {
        #expect(WorktreeBranchName.compose(
            name: name, prefix: "feature/", globalTemplate: "fixed-{date}", projectTemplate: "fixed"
        ).isEmpty)
    }
}
