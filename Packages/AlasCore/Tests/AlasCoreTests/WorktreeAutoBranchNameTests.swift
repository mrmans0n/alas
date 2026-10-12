import Testing
import Foundation
@testable import AlasCore

struct WorktreeAutoBranchNameTests {
    @Test func placeholderSkipsTakenNamesAndNumbersWhenEveryPickCollides() {
        var generator = SystemRandomNumberGenerator()
        let free = WorktreeAutoBranchName.placeholder(isTaken: { $0.hasPrefix("a") }, using: &generator)
        #expect(!free.hasPrefix("a"))
        #expect(free.split(separator: "-").count == 2)

        let numbered = WorktreeAutoBranchName.placeholder(isTaken: { !$0.hasSuffix("-3") }, using: &generator)
        #expect(numbered.hasSuffix("-3"))

        // A destination that ignores the name rejects every pick; the search
        // must still end.
        let exhausted = WorktreeAutoBranchName.placeholder(isTaken: { _ in true }, using: &generator)
        #expect(exhausted.split(separator: "-").count == 2)
    }

    @Test(arguments: [
        ("Please fix the login timeout when offline", "fix-login-timeout-when"),
        ("Add OAuth2 support to the API client", "add-oauth2-support-api"),
        ("Can you rename `fooBar()` to bar?", "rename-foobar-bar"),
    ])
    func fallbackUsesTheFirstMeaningfulWords(source: String, expected: String) {
        #expect(WorktreeAutoBranchName.fallbackName(source: source) == expected)
    }

    @Test(arguments: ["123 456", "the of and", "¿¿ !!"])
    func fallbackRejectsRequestsWithoutWords(source: String) {
        #expect(WorktreeAutoBranchName.fallbackName(source: source) == nil)
    }

    @Test(arguments: [
        (#"{"name": "fix-offline-sync"}"#, "fix-offline-sync"),
        ("```json\n{\"name\": \"fix-offline-sync\"}\n```", "fix-offline-sync"),
        ("Here you go:\n{\"name\": \"fix-offline-sync\"}", "fix-offline-sync"),
    ])
    func providerOutputToleratesWrapping(output: String, expected: String) {
        #expect(WorktreeAutoBranchName.parseProviderOutput(output) == expected)
    }

    @Test(arguments: ["fix-offline-sync", "{\"name\": \"Fix Offline\"}", "{\"name\": \"a\"} and {\"name\": \"b\"}"])
    func providerOutputStillRejectsAnythingButOneName(output: String) {
        #expect(WorktreeAutoBranchName.parseProviderOutput(output) == nil)
    }
}
