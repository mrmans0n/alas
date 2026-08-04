import Foundation
import Testing
@testable import Alas

struct MissionPromptBuilderTests {
    @Test func manualSourceBranchUsesOnlyPrefixAndTitle() {
        #expect(MissionBranchName.make(
            displayReference: nil,
            title: "Fix login timeout",
            prefix: "nacho/"
        ) == "nacho/fix-login-timeout")
    }

    @Test func manualSourcePromptUsesWorkItemTerminology() {
        let source = MissionFixtures.manualSource(
            url: "https://jira.example.com/browse/ALAS-123?view=full",
            title: "Fix login timeout",
            body: "Sessions expire during refresh."
        )
        let prompt = MissionPromptBuilder.build(source: source)

        #expect(prompt.contains("Implement the linked work item."))
        #expect(prompt.contains("## Work item context"))
        #expect(prompt.contains("**Source:** jira.example.com"))
        #expect(prompt.contains("**URL:** https://jira.example.com/browse/ALAS-123?view=full"))
        #expect(!prompt.localizedCaseInsensitiveContains("issue #"))
    }

    @Test func branchNameUsesConfiguredPrefixAndSanitizedTitle() {
        #expect(MissionBranchName.make(
            issueNumber: 1842,
            title: "Fix offline sync conflicts!",
            prefix: "feature/"
        ) == "feature/1842-fix-offline-sync-conflicts")
    }

    @Test func branchNameStripsDiacriticsAndUsesEmptyTitleFallback() {
        #expect(MissionBranchName.make(issueNumber: 9, title: "  Réparer l’API  ", prefix: "fix/") == "fix/9-reparer-l-api")
        #expect(MissionBranchName.make(issueNumber: 9, title: "---", prefix: "fix/") == "fix/9-issue")
    }

    @Test func promptContainsStableStructuredContext() {
        let issue = MissionFixtures.issue(number: 1842, title: "Fix parser crash")
        let prompt = MissionPromptBuilder.build(snapshot: issue)

        #expect(prompt.contains("Implement GitHub work item #1842."))
        #expect(prompt.contains("## Work item context"))
        #expect(prompt.contains("**URL:** https://github.com/acme/alas/issues/1842"))
        #expect(prompt.contains("**Labels:** bug, parser"))
        #expect(prompt.contains("The parser crashes for malformed input."))
    }
}
