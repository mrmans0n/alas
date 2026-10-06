import Foundation
import Testing
@testable import Alas

struct IssuePromptBuilderTests {
    @Test func manualSourceBranchUsesOnlyTitleSlug() {
        #expect(IssueBranchName.make(
            displayReference: nil,
            title: "Fix login timeout"
        ) == "fix-login-timeout")
    }

    @Test func emptyDisplayReferenceUsesOnlyTitleSlug() {
        #expect(IssueBranchName.make(
            displayReference: "",
            title: "Fix login timeout"
        ) == "fix-login-timeout")
    }

    @Test func emptyManualSourceTitleYieldsEmptySeed() {
        #expect(IssueBranchName.make(
            displayReference: nil,
            title: "---"
        ).isEmpty)
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

    @Test func branchNameJoinsReferenceAndSanitizedTitle() {
        #expect(IssueBranchName.make(
            displayReference: "#1842",
            title: "Fix offline sync conflicts!"
        ) == "1842-fix-offline-sync-conflicts")
    }

    @Test func branchNameStripsDiacritics() {
        #expect(IssueBranchName.make(
            displayReference: "ALAS-9",
            title: "  Réparer l’API  "
        ) == "alas-9-reparer-l-api")
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

    private static var githubSource: IssueSnapshot {
        .init(codeHostIssue: CodeHostIssueSnapshot(
            identity: .init(provider: .github, host: "github.com", repositorySlug: "acme/alas", number: 1842),
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/1842")!,
            title: "Fix parser crash",
            body: "The parser crashes for malformed input.",
            state: .open,
            labels: ["bug"],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: .distantPast,
            refreshError: nil
        ))
    }

    @Test func genericPromptIsUnchanged() {
        let prompt = IssuePromptBuilder.build(source: Self.githubSource, kind: nil)

        #expect(prompt.hasPrefix("""
        Implement GitHub issue #1842.
        Inspect the attached issue context, keep the change focused, add regression coverage, and verify the result.

        ## Issue context
        """))
    }

    @Test(arguments: [
        (IssueKind.bug, "Fix GitHub issue #1842.", "Reproduce the problem first"),
        (.enhancement, "Implement GitHub issue #1842.", "Confirm the scope and acceptance criteria"),
        (.research, "Investigate GitHub issue #1842.", "Do not change code unless asked."),
        (.docs, "Update documentation for GitHub issue #1842.", "No build or test run is needed."),
        (.chore, "Handle GitHub issue #1842.", "No behavior change is intended."),
    ])
    func kindChangesOnlyTheInstructions(kind: IssueKind, opening: String, instruction: String) {
        let generic = IssuePromptBuilder.build(source: Self.githubSource)
        let prompt = IssuePromptBuilder.build(source: Self.githubSource, kind: kind)
        let lines = prompt.components(separatedBy: "\n")

        #expect(lines[0] == opening)
        #expect(lines[1].contains(instruction))
        #expect(prompt.components(separatedBy: "## Issue context").last
            == generic.components(separatedBy: "## Issue context").last)
    }

    @Test func manualSourceUsesKindVerb() {
        let source = IssueSnapshot(
            identity: .init(providerID: .manual, stableID: "https://example.com/t/1"),
            canonicalURL: URL(string: "https://example.com/t/1")!,
            providerLabel: "example.com",
            displayReference: nil,
            repositoryLocator: nil,
            title: "Investigate slow startup",
            body: "",
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

        #expect(IssuePromptBuilder.openingLine(for: source, kind: .research) == "Investigate the linked issue.")
        #expect(IssuePromptBuilder.openingLine(for: source) == "Implement the linked issue.")
    }
}
