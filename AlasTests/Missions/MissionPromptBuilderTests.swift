import Foundation
import Testing
@testable import Alas

struct MissionPromptBuilderTests {
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

        #expect(prompt.contains("Implement GitHub issue #1842."))
        #expect(prompt.contains("## Issue context"))
        #expect(prompt.contains("**URL:** https://github.com/acme/alas/issues/1842"))
        #expect(prompt.contains("**Labels:** bug, parser"))
        #expect(prompt.contains("The parser crashes for malformed input."))
    }
}
