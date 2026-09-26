import Foundation
import Testing
@testable import Alas

struct NewWorktreeIssueStateTests {
    @Test func matchingIssueSelectsItsRepositorySeedsBranchAndRequestsChat() {
        var state = NewWorktreeIssueState()
        let draft = Self.draft(projectID: "repo-b", branchSeed: "feature/42-fix-sync")

        let effects = state.attach(draft, currentLaunch: Self.terminalLaunch)

        #expect(state.draft == draft)
        #expect(effects == NewWorktreeIssueAttachEffects(
            preferredProjectID: "repo-b",
            branchSeed: "feature/42-fix-sync",
            shouldSelectChat: true
        ))
    }

    @Test func unmatchedURLPreservesRepositoryWhileSeedingBranchAndRequestingChat() {
        var state = NewWorktreeIssueState()

        let effects = state.attach(
            Self.draft(projectID: nil, branchSeed: "feature/external-issue"),
            currentLaunch: Self.terminalLaunch
        )

        #expect(effects.preferredProjectID == nil)
        #expect(effects.branchSeed == "feature/external-issue")
        #expect(effects.shouldSelectChat)
    }

    @Test func editingReplacesDraftWithoutRecapturingLaunchPreference() {
        var state = NewWorktreeIssueState()
        let original = Self.draft(projectID: "repo-a", branchSeed: "feature/42-original", prompt: "Original")
        let edited = Self.draft(projectID: "repo-b", branchSeed: "feature/42-edited", prompt: "Edited")

        _ = state.attach(original, currentLaunch: Self.terminalLaunch)
        _ = state.attach(edited, currentLaunch: Self.chatLaunch)

        #expect(state.draft == edited)
        #expect(state.remove() == Self.terminalLaunch)
    }

    @Test func removingAfterManualLaunchChangePreservesCurrentLaunchChoice() {
        var state = NewWorktreeIssueState()
        _ = state.attach(Self.draft(), currentLaunch: Self.terminalLaunch)

        state.recordLaunchPreferenceChangeAfterAttach()

        #expect(state.remove() == nil)
    }

    @Test func removingReturnsCapturedLaunchPreferenceAndClearsOnlyIssueState() {
        var state = NewWorktreeIssueState()
        _ = state.attach(Self.draft(), currentLaunch: Self.terminalLaunch)

        let restoredLaunch = state.remove()

        #expect(restoredLaunch == Self.terminalLaunch)
        #expect(state.draft == nil)
        #expect(state.remove() == nil)
    }

    @Test(arguments: [
        // (createsGGStack, expected branch, expected stack name)
        (false, "42-offline-conflicts", ""),
        (true, "", "42-offline-conflicts"),
    ])
    func nameSuggestionReplacesOnlyTheTitleOfTheUntouchedSeed(
        createsGGStack: Bool, expectedBranch: String, expectedStack: String
    ) throws {
        var state = NewWorktreeIssueState()
        _ = state.attach(Self.draft(branchSeed: "42-fix-sync"), currentLaunch: Self.terminalLaunch)
        let started = state.beginNameSuggestion()
        let request = try #require(started)

        let names = state.completeNameSuggestion(
            request.id,
            semanticName: "offline-conflicts",
            branch: createsGGStack ? "" : "42-fix-sync",
            stackName: createsGGStack ? "42-fix-sync" : ""
        )

        #expect(names?.branch == expectedBranch)
        #expect(names?.stackName == expectedStack)
    }

    @Test(arguments: [false, true])
    func nameSuggestionKeepsANameTheUserEditedEvenAfterRestoringTheSeed(createsGGStack: Bool) throws {
        var state = NewWorktreeIssueState()
        _ = state.attach(Self.draft(branchSeed: "42-fix-sync"), currentLaunch: Self.terminalLaunch)
        let started = state.beginNameSuggestion()
        let request = try #require(started)

        // The user types, then undoes back to the exact seed.
        state.recordUserNameEdit()
        let names = state.completeNameSuggestion(
            request.id,
            semanticName: "offline-conflicts",
            branch: createsGGStack ? "" : "42-fix-sync",
            stackName: createsGGStack ? "42-fix-sync" : ""
        )

        #expect(names == nil)
    }

    @Test func missingSemanticNameKeepsTheSeed() throws {
        var state = NewWorktreeIssueState()
        _ = state.attach(Self.draft(branchSeed: "42-fix-sync"), currentLaunch: Self.terminalLaunch)
        let started = state.beginNameSuggestion()
        let request = try #require(started)

        #expect(state.completeNameSuggestion(
            request.id, semanticName: nil, branch: "42-fix-sync", stackName: ""
        ) == nil)
    }

    @Test func laterAttachOrRemovalMakesAPendingNameSuggestionStale() throws {
        var state = NewWorktreeIssueState()
        _ = state.attach(Self.draft(branchSeed: "42-fix-sync"), currentLaunch: Self.terminalLaunch)
        let firstRequest = state.beginNameSuggestion()
        let first = try #require(firstRequest)

        _ = state.attach(Self.draft(branchSeed: "42-fix-sync"), currentLaunch: Self.terminalLaunch)
        #expect(state.completeNameSuggestion(
            first.id, semanticName: "offline-conflicts", branch: "42-fix-sync", stackName: ""
        ) == nil)

        let secondRequest = state.beginNameSuggestion()
        let second = try #require(secondRequest)
        _ = state.remove()
        #expect(state.completeNameSuggestion(
            second.id, semanticName: "offline-conflicts", branch: "42-fix-sync", stackName: ""
        ) == nil)
    }

    private static let terminalLaunch = NewWorktreeLaunchPreference(
        openAfterCreate: true,
        launchMode: .terminal,
        persistableLaunchMode: .terminal,
        launchAgentID: "amp"
    )

    private static let chatLaunch = NewWorktreeLaunchPreference(
        openAfterCreate: true,
        launchMode: .acp,
        persistableLaunchMode: .acp,
        launchAgentID: "claude"
    )

    private static func draft(
        projectID: String? = "repo-a",
        branchSeed: String = "feature/42-fix-sync",
        prompt: String = "Fix the issue."
    ) -> AttachedIssueDraft {
        AttachedIssueDraft(
            source: IssueSnapshot(
                identity: .init(providerID: .github, stableID: "github.com/acme/repo#42"),
                canonicalURL: URL(string: "https://github.com/acme/repo/issues/42")!,
                providerLabel: "GitHub",
                displayReference: "#42",
                repositoryLocator: .init(
                    provider: .github,
                    host: "github.com",
                    repositorySlug: "acme/repo"
                ),
                title: "Fix sync",
                body: "Issue context",
                state: .open,
                labels: [],
                assignees: [],
                providerUpdatedAt: nil,
                capturedAt: .distantPast,
                refreshError: nil,
                contentOrigin: .provider,
                isEditable: false,
                isRefreshable: true
            ),
            projectID: projectID,
            branchSeed: branchSeed,
            prompt: prompt
        )
    }
}
