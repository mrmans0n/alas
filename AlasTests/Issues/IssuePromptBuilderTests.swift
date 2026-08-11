import Foundation
import Testing
@testable import Alas

struct IssuePromptBuilderTests {
    @Test func manualSourceBranchUsesOnlyPrefixAndTitle() {
        #expect(IssueBranchName.make(
            displayReference: nil,
            title: "Fix login timeout",
            prefix: "nacho/"
        ) == "nacho/fix-login-timeout")
    }

    @Test func emptyDisplayReferenceUsesOnlyTitleSlug() {
        #expect(IssueBranchName.make(
            displayReference: "",
            title: "Fix login timeout",
            prefix: "nacho/"
        ) == "nacho/fix-login-timeout")
    }

    @Test func emptyManualSourceTitleDoesNotUseIssueFallback() {
        #expect(IssueBranchName.make(
            displayReference: nil,
            title: "---",
            prefix: "nacho/"
        ) == "nacho/")
    }

    @Test func manualSourcePromptUsesIssueTerminology() {
        let source = IssueSnapshot(
            identity: .init(providerID: .manual, stableID: "https://jira.example.com/browse/ALAS-123?view=full"),
            canonicalURL: URL(string: "https://jira.example.com/browse/ALAS-123?view=full")!,
            providerLabel: "jira.example.com",
            displayReference: "ALAS-123",
            repositoryLocator: nil,
            title: "Fix login timeout",
            body: "Sessions expire during refresh.",
            state: .unknown,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: .distantPast,
            refreshError: nil,
            contentOrigin: .manual,
            isEditable: true,
            isRefreshable: false
        )
        let prompt = IssuePromptBuilder.build(source: source)

        #expect(prompt.contains("Implement the linked issue."))
        #expect(prompt.contains("Inspect the attached issue context"))
        #expect(prompt.contains("## Issue context"))
        #expect(prompt.contains("**Source:** jira.example.com"))
        #expect(prompt.contains("**URL:** https://jira.example.com/browse/ALAS-123?view=full"))
        #expect(!prompt.localizedCaseInsensitiveContains("work item"))
    }

    @Test func branchNameUsesConfiguredPrefixAndSanitizedTitle() {
        #expect(IssueBranchName.make(
            issueNumber: 1842,
            title: "Fix offline sync conflicts!",
            prefix: "feature/"
        ) == "feature/1842-fix-offline-sync-conflicts")
    }

    @Test func branchNameStripsDiacriticsAndUsesEmptyTitleFallback() {
        #expect(IssueBranchName.make(issueNumber: 9, title: "  Réparer l’API  ", prefix: "fix/") == "fix/9-reparer-l-api")
        #expect(IssueBranchName.make(issueNumber: 9, title: "---", prefix: "fix/") == "fix/9-issue")
    }

    @Test func promptContainsStableStructuredContext() {
        let issue = CodeHostIssueSnapshot(
            identity: .init(provider: .github, host: "github.com", repositorySlug: "acme/alas", number: 1842),
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/1842")!,
            title: "Fix parser crash",
            body: "The parser crashes for malformed input.",
            state: .open,
            labels: ["bug", "parser"],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: .distantPast,
            refreshError: nil
        )
        let prompt = IssuePromptBuilder.build(source: .init(codeHostIssue: issue))

        #expect(prompt.contains("Implement GitHub issue #1842."))
        #expect(prompt.contains("Inspect the attached issue context"))
        #expect(prompt.contains("## Issue context"))
        #expect(prompt.contains("**URL:** https://github.com/acme/alas/issues/1842"))
        #expect(prompt.contains("**Labels:** bug, parser"))
        #expect(prompt.contains("The parser crashes for malformed input."))
        #expect(!prompt.localizedCaseInsensitiveContains("work item"))
    }
}
