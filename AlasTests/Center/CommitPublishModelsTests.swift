import Foundation
import Testing
@testable import Alas

struct CommitPublishModelsTests {
    @Test func composerOffersCommitAndCreateWithEitherPreferredAction() {
        for preferred in [DraftCommitPreferredAction.commit, .publish] {
            let presentation = CommitPublishPresentation(
                subject: "Subject", hasStaged: true, preferredAction: preferred,
                availability: .review(snapshot: publishSnapshot())
            )
            #expect(presentation.commit.label == "Commit")
            #expect(presentation.commit.isEnabled)
            #expect(presentation.publish?.label == "Commit & PR")
            #expect(presentation.publish?.isEnabled == true)
            #expect(presentation.preferredActionPosition == (preferred == .commit ? .leading : .trailing))
            #expect(presentation.draftToggleLabel == "Draft PR")
            #expect(presentation.draftToggleEnabled)
        }
    }

    @Test func composerUsesExistingRequestAndGGLabels() {
        let push = CommitPublishPresentation(subject: "Subject", hasStaged: true,
            availability: .review(snapshot: publishSnapshot(hasRequest: true)))
        #expect(push.publish?.label == "Commit & push")
        #expect(push.draftToggleLabel == nil)
        let sync = CommitPublishPresentation(subject: "Subject", hasStaged: true, availability: .gg())
        #expect(sync.publish?.label == "Commit & sync")
        #expect(sync.publish?.isEnabled == true)
        #expect(sync.draftToggleLabel == nil)
    }

    @Test func initialActionsRequireSubjectAndStagedChanges() {
        for (subject, hasStaged) in [(" \n", true), ("Subject", false), ("", false)] {
            let presentation = CommitPublishPresentation(subject: subject, hasStaged: hasStaged,
                availability: .review(snapshot: publishSnapshot()))
            #expect(!presentation.commit.isEnabled)
            #expect(presentation.publish?.isEnabled == false)
            #expect(!presentation.commit.help.isEmpty)
        }
    }

    @Test func loadingProviderRetainsItsReviewRequestTerminology() {
        let remote = CodeHostRemote(kind: .gitlab, host: "gitlab.com", owner: "owner", repository: "repo",
            remoteName: "origin", webURL: URL(string: "https://gitlab.com/owner/repo")!)
        let presentation = CommitPublishPresentation(subject: "Subject", hasStaged: true,
            availability: .review(snapshot: nil, supportedRemote: remote))
        #expect(presentation.publish?.label == "Commit & MR")
        #expect(presentation.publish?.isEnabled == false)
        #expect(presentation.draftToggleLabel == "Draft MR")
    }

    @Test func retryDoesNotRequireStagedChangesOrCurrentProviderAvailability() {
        for (phase, label) in [(CommitPublishPhase.push, "Retry push"), (.createReviewRequest, "Retry create MR"), (.sync, "Retry sync")] {
            let checkpoint = presentationCheckpoint(phase: phase)
            let presentation = CommitPublishPresentation(subject: "", hasStaged: false, checkpoint: checkpoint)
            #expect(presentation.publish?.label == label)
            #expect(presentation.publish?.isEnabled == true)
            #expect(!presentation.commit.isEnabled)
            #expect(presentation.preferredActionPosition == .trailing)
            #expect(presentation.editorDisabled)
            #expect(presentation.mutationsDisabled)
            #expect(!presentation.draftToggleEnabled)
        }
    }

    @Test func busyDisablesBothActionsIncludingRetry() {
        for activity in [CommitPublishActivity.idle, .committing, .pushing, .creatingReviewRequest, .syncing] {
            for checkpoint in [nil, presentationCheckpoint(phase: .push)] {
                let presentation = CommitPublishPresentation(subject: "Subject", hasStaged: true,
                    busy: true, activity: activity, checkpoint: checkpoint,
                    availability: .review(snapshot: publishSnapshot()))
                #expect(!presentation.commit.isEnabled)
                #expect(presentation.publish?.isEnabled == false)
                #expect(!presentation.draftToggleEnabled)
                #expect(presentation.mutationsDisabled)
            }
        }
    }

    @Test func activityLabelsFollowCapturedProvider() {
        let presentation = CommitPublishPresentation(subject: "Subject", hasStaged: false,
            busy: true, activity: .creatingReviewRequest, checkpoint: presentationCheckpoint(phase: .createReviewRequest))
        #expect(presentation.publish?.label == "Creating MR...")
        #expect(presentation.activityText == "Creating MR...")
        let committing = CommitPublishPresentation(subject: "Subject", hasStaged: true,
            busy: true, activity: .committing, availability: .gg())
        #expect(committing.commit.label == "Committing...")
        #expect(committing.publish?.label == "Committing...")
    }

    @Test func publishedAmendOnlyBlocksPublish() {
        let presentation = CommitPublishPresentation(subject: "Subject", hasStaged: true, amend: true,
            availability: .review(snapshot: publishSnapshot(), amend: true, amendProbe: .published))
        #expect(presentation.commit.label == "Amend")
        #expect(presentation.commit.isEnabled)
        #expect(presentation.publish?.isEnabled == false)
        #expect(presentation.publish?.help == "This commit is already published. Commit locally or turn off Amend before publishing.")
    }

    @Test func unsupportedHostHidesPublishButSupportedBlockerKeepsItVisible() {
        let unsupported = CommitPublishPresentation(subject: "Subject", hasStaged: true,
            preferredAction: .publish, availability: .review(snapshot: publishSnapshot(supported: false)))
        #expect(unsupported.publish == nil)
        #expect(unsupported.preferredActionPosition == .leading)
        let blocked = CommitPublishPresentation(subject: "Subject", hasStaged: true,
            availability: .review(snapshot: publishSnapshot(authenticated: false)))
        #expect(blocked.publish?.label == "Commit & PR")
        #expect(blocked.publish?.isEnabled == false)
        #expect(blocked.commit.isEnabled)
    }

    private func presentationCheckpoint(phase: CommitPublishPhase) -> CommitPublishCheckpoint {
        CommitPublishCheckpoint(commitSHA: "abc", baseRef: "main", commitTitle: "abc Subject",
            subject: "Subject", body: "", destination: phase == .sync ? .gg() : .review(.init(
                provider: .gitlab, host: "gitlab.com", owner: "owner", repository: "repo",
                repositorySlug: "owner/repo", remoteName: "origin", webURL: URL(string: "https://gitlab.com/owner/repo")!,
                branch: "feature", upstreamBranch: nil, headOwner: nil, baseBranch: "main",
                reviewRequestExisted: false, createAsDraft: true)), nextPhase: phase)
    }

    @Test func actionLabelsDescribeActivityAndCreationRetry() {
        #expect(CommitPublishActivity.idle.actionLabel(reviewRequestLabel: "PR") == nil)
        #expect(CommitPublishActivity.committing.actionLabel(reviewRequestLabel: "PR") == "Committing...")
        #expect(CommitPublishActivity.pushing.actionLabel(reviewRequestLabel: "PR") == "Pushing...")
        #expect(CommitPublishActivity.creatingReviewRequest.actionLabel(reviewRequestLabel: "PR") == "Creating PR...")
        #expect(CommitPublishActivity.creatingReviewRequest.actionLabel(reviewRequestLabel: "MR") == "Creating MR...")
        #expect(CommitPublishActivity.syncing.actionLabel(reviewRequestLabel: "PR") == "Syncing...")
        #expect(CommitPublishPhase.createReviewRequest.retryLabel(reviewRequestLabel: "PR") == "Retry create PR")
        #expect(CommitPublishPhase.push.retryLabel(reviewRequestLabel: "PR") == "Retry push")
        #expect(CommitPublishPhase.sync.retryLabel(reviewRequestLabel: "PR") == "Retry sync")
    }

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
            destination: .gg(),
            nextPhase: .sync
        )

        let data = try JSONEncoder().encode(checkpoint)

        #expect(try JSONDecoder().decode(CommitPublishCheckpoint.self, from: data) == checkpoint)
    }

    @Test func checkpointDefaultsMissingGGRecoveryFlagToFalse() throws {
        let data = """
        {
          "baseRef": "main",
          "body": "Body",
          "commitSHA": "def456",
          "commitTitle": "def456 Subject",
          "destination": { "gg": {} },
          "nextPhase": "sync",
          "subject": "Subject"
        }
        """.data(using: .utf8)!

        let checkpoint = try JSONDecoder().decode(CommitPublishCheckpoint.self, from: data)

        #expect(checkpoint.commitSHA == "def456")
        #expect(checkpoint.destination == .gg())
        #expect(!checkpoint.allowsGGRecoveryHeadReconciliation)
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
