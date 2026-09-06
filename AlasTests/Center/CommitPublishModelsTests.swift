import Foundation
import Testing
@testable import Alas

struct CommitPublishModelsTests {
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
