import Foundation
import Testing
@testable import Alas

struct CommitPublishModelsTests {
    @Test func supportedHostOffersCreateOrPush() {
        let create = CommitPublishAvailability.review(snapshot: publishSnapshot())
        #expect(create?.label == "Commit & PR")
        #expect(create?.disabledReason == nil)
        #expect(create?.showsDraftToggle == true)
        let push = CommitPublishAvailability.review(snapshot: publishSnapshot(hasRequest: true, capabilities: .readOnly))
        #expect(push?.label == "Commit & push")
        #expect(push?.disabledReason == nil)
        #expect(push?.showsDraftToggle == false)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(supported: false)) == nil)
    }

    @Test func publicationRequiresLoadedAuthenticatedCapableProvider() {
        #expect(CommitPublishAvailability.review(snapshot: nil, supportedRemote: publishRemote)?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), isRefreshing: true)?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(available: false))?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(authenticated: false))?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(capabilities: .readOnly))?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), lastError: "Refresh failed")?.disabledReason == "Refresh failed")
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), mutationDisabledReason: "Busy")?.disabledReason == "Busy")
    }

    @Test func publicationBlocksBaseBranchAndOutdatedLocalState() {
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(branch: "main"))?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(branch: "main", base: "origin/main"))?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), currentBranch: "other")?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), currentBaseBranch: "other")?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(upstreamAhead: 1, needsPush: false))?.disabledReason != nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(upstreamAhead: 1, needsPush: true))?.disabledReason != nil)
    }

    @Test func amendPublicationRequiresExplicitUnpublishedResult() {
        for probe in [CommitPublishAmendProbe.loading, .published, .failed("Probe failed")] {
            #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), amend: true, amendProbe: probe)?.disabledReason != nil)
        }
        for result in [HeadPublicationState.noUpstream, .unpublished] {
            #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), amend: true, amendProbe: .init(result))?.disabledReason == nil)
        }
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), amendProbe: .published)?.disabledReason == nil)
        #expect(CommitPublishAvailability.review(snapshot: publishSnapshot(), amend: true, amendProbe: .failed("Probe failed"))?.disabledReason == "Probe failed")
    }

    private var publishRemote: CodeHostRemote {
        CodeHostRemote(kind: .github, host: "github.com", owner: "owner", repository: "repo", remoteName: "origin", webURL: URL(string: "https://github.com/owner/repo")!)
    }

    private func publishSnapshot(
        hasRequest: Bool = false, supported: Bool = true,
        available: Bool = true, authenticated: Bool = true,
        capabilities: CodeHostProviderCapabilities = .githubCLI,
        branch: String = "feature", base: String = "main",
        upstreamAhead: Int = 0, needsPush: Bool = false
    ) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: ReviewLoopLocalState(branchName: branch, headSHA: "abc", baseBranch: base,
                hasWorkingTreeChanges: true, hasStagedChanges: true, aheadCommitCount: 0,
                hasUpstream: true, upstreamAheadCommitCount: upstreamAhead, needsPush: needsPush),
            remote: supported ? publishRemote : nil,
            reviewRequest: hasRequest ? .placeholder(remote: publishRemote, number: 1) : nil,
            providerAvailable: available, providerAuthenticated: authenticated,
            providerCapabilities: capabilities, errorMessage: nil
        )
    }

    @Test func reviewCheckpointRoundTripsEveryCapturedField() throws {
        let checkpoint = CommitPublishCheckpoint(
            commitSHA: "abc123",
            baseRef: "main",
            commitTitle: "abc123 Subject",
            subject: "Subject",
            body: "Body",
            destination: .review(.init(
                provider: .github,
                host: "github.com",
                owner: "owner",
                repository: "repo",
                repositorySlug: "owner/repo",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/owner/repo")!,
                branch: "feature",
                upstreamBranch: nil,
                headOwner: nil,
                baseBranch: "main",
                reviewRequestExisted: false,
                createAsDraft: true
            )),
            nextPhase: .push
        )

        let data = try JSONEncoder().encode(checkpoint)

        #expect(try JSONDecoder().decode(CommitPublishCheckpoint.self, from: data) == checkpoint)
    }

    @Test func ggCheckpointRoundTrips() throws {
        let checkpoint = CommitPublishCheckpoint(
            commitSHA: "def456",
            baseRef: "main",
            commitTitle: "def456 Subject",
            subject: "Subject",
            body: "Body",
            destination: .gg,
            nextPhase: .sync
        )

        let data = try JSONEncoder().encode(checkpoint)

        #expect(try JSONDecoder().decode(CommitPublishCheckpoint.self, from: data) == checkpoint)
    }

    @Test func everyPublishPhaseRoundTrips() throws {
        for phase in [
            CommitPublishPhase.push,
            .createReviewRequest,
            .sync,
        ] {
            let data = try JSONEncoder().encode(phase)
            #expect(try JSONDecoder().decode(CommitPublishPhase.self, from: data) == phase)
        }
    }

    @Test func reviewTargetRestoresCapturedSelfHostedRemote() {
        let target = CommitPublishReviewTarget(
            provider: .gitlab,
            host: "gitlab.example.com",
            owner: "team",
            repository: "project",
            repositorySlug: "team/project",
            remoteName: "gitlab",
            webURL: URL(string: "https://gitlab.example.com/team/project")!,
            branch: "feature",
            upstreamBranch: "gitlab/feature",
            headOwner: "fork-owner",
            baseBranch: "main",
            reviewRequestExisted: true,
            createAsDraft: false
        )

        #expect(target.remote == CodeHostRemote(
            kind: .gitlab,
            host: "gitlab.example.com",
            owner: "team",
            repository: "project",
            remoteName: "gitlab",
            webURL: URL(string: "https://gitlab.example.com/team/project")!
        ))
    }

    @Test func preferredTrailingActionReceivesBaseShortcut() {
        let pair = CommitComposerActionPair.shortcuts(
            preferred: .trailing,
            base: .init(key: "return", modifiers: [.command])
        )

        #expect(pair.leading == .init(key: "return", modifiers: [.command, .shift]))
        #expect(pair.trailing == .init(key: "return", modifiers: [.command]))
    }

    @Test func preferredLeadingActionReceivesBaseShortcut() {
        let pair = CommitComposerActionPair.shortcuts(
            preferred: .leading,
            base: .init(key: "j", modifiers: [.command, .shift])
        )

        #expect(pair.leading == .init(key: "j", modifiers: [.command, .shift]))
        #expect(pair.trailing == .init(key: "j", modifiers: [.command]))
    }

    @Test func subtleActionBadgeUsesThemeForegroundColors() {
        #expect(CommitComposerActionEmphasis.subtle.badgeStyle == .init(
            foreground: .theme("fg"),
            foregroundOpacity: 1,
            background: .theme("fg"),
            backgroundOpacity: 0.12
        ))
    }

    @Test func actionPairResolvesShortcutAtEachPosition() {
        let pair = CommitComposerActionPair.shortcuts(
            preferred: .trailing,
            base: .init(key: "return", modifiers: [.command])
        )

        #expect(pair.shortcut(at: .leading) == .init(key: "return", modifiers: [.command, .shift]))
        #expect(pair.shortcut(at: .trailing) == .init(key: "return", modifiers: [.command]))
    }
}
