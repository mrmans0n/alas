import Foundation
import Testing
@testable import Alas

struct CodeHostRemoteDetectorTests {
    @Test func parsedKindClassifiesUnknownEnterpriseHost() {
        let remote = CodeHostRemoteDetector.detect(
            from: [GitRemote(name: "origin", url: "git@github.example.com:mrmans0n/alas.git")],
            matching: .github
        )

        #expect(remote?.kind == .github)
        #expect(remote?.host == "github.example.com")
        #expect(remote?.repositorySlug == "mrmans0n/alas")
    }

    @Test func detectsGitHubHTTPSRemote() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "https://github.com/mrmans0n/alas.git"),
        ])

        #expect(remote == CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        ))
    }

    @Test func detectsGitHubSCPStyleSSHRemoteAndPreservesRemoteName() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "fork", url: "git@github.com:mrmans0n/alas.git"),
        ])

        #expect(remote?.kind == .github)
        #expect(remote?.host == "github.com")
        #expect(remote?.owner == "mrmans0n")
        #expect(remote?.repository == "alas")
        #expect(remote?.remoteName == "fork")
        #expect(remote?.webURL == URL(string: "https://github.com/mrmans0n/alas"))
    }

    @Test func detectsGitHubSSHURLRemote() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "ssh://git@github.com/mrmans0n/alas.git"),
        ])

        #expect(remote?.kind == .github)
        #expect(remote?.host == "github.com")
        #expect(remote?.owner == "mrmans0n")
        #expect(remote?.repository == "alas")
        #expect(remote?.webURL == URL(string: "https://github.com/mrmans0n/alas"))
    }

    @Test func detectsGitHubSCPStyleRemoteWithoutUser() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "github.com:mrmans0n/alas.git"),
        ])

        #expect(remote?.kind == .github)
        #expect(remote?.host == "github.com")
        #expect(remote?.owner == "mrmans0n")
        #expect(remote?.repository == "alas")
        #expect(remote?.webURL == URL(string: "https://github.com/mrmans0n/alas"))
    }

    @Test func detectsSelfHostedGitLabHTTPSRemoteWithNestedGroup() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "https://gitlab.example.com/platform/mobile/alas.git"),
        ])

        #expect(remote?.kind == .gitlab)
        #expect(remote?.host == "gitlab.example.com")
        #expect(remote?.owner == "platform/mobile")
        #expect(remote?.repository == "alas")
        #expect(remote?.remoteName == "origin")
        #expect(remote?.webURL == URL(string: "https://gitlab.example.com/platform/mobile/alas"))
    }

    @Test func detectsGitLabSSHURLRemoteWithNestedGroup() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "ssh://git@gitlab.com/platform/mobile/alas.git"),
        ])

        #expect(remote?.kind == .gitlab)
        #expect(remote?.host == "gitlab.com")
        #expect(remote?.owner == "platform/mobile")
        #expect(remote?.repository == "alas")
        #expect(remote?.webURL == URL(string: "https://gitlab.com/platform/mobile/alas"))
    }

    @Test func rejectsUnsupportedGitLabLikeHost() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "https://gitlab-status.example.com/org/repo.git"),
        ])

        #expect(remote == nil)
    }

    @Test func prefersOriginWhenMultipleSupportedRemotesExist() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "upstream", url: "https://github.com/example/upstream.git"),
            GitRemote(name: "origin", url: "https://github.com/mrmans0n/alas.git"),
        ])

        #expect(remote?.remoteName == "origin")
        #expect(remote?.owner == "mrmans0n")
        #expect(remote?.repository == "alas")
    }

    @Test func detectAllReturnsOriginFirstThenOtherSupportedRemotes() {
        let remotes = CodeHostRemoteDetector.detectAll(from: [
            GitRemote(name: "upstream", url: "https://github.com/mrmans0n/alas.git"),
            GitRemote(name: "origin", url: "https://github.com/nacho/alas.git"),
        ])

        #expect(remotes.map(\.remoteName) == ["origin", "upstream"])
        #expect(remotes.map(\.repositorySlug) == ["nacho/alas", "mrmans0n/alas"])
    }

    @Test func detectAllUsesBaseBranchPreferredRemoteBeforeOrigin() {
        let gitRemotes = [
            GitRemote(name: "origin", url: "https://github.com/nacho/alas.git"),
            GitRemote(name: "upstream", url: "https://github.com/mrmans0n/alas.git"),
        ]
        let preferredRemoteName = CodeHostRemoteDetector.preferredRemoteName(
            forBaseBranch: "upstream/main",
            remotes: gitRemotes
        )

        let remotes = CodeHostRemoteDetector.detectAll(
            from: gitRemotes,
            preferredRemoteName: preferredRemoteName
        )

        #expect(preferredRemoteName == "upstream")
        #expect(remotes.map(\.remoteName) == ["upstream", "origin"])
        #expect(remotes.map(\.repositorySlug) == ["mrmans0n/alas", "nacho/alas"])
    }

    @Test func preferredRemoteOverridesOrigin() {
        let remote = CodeHostRemoteDetector.detect(
            from: [
                GitRemote(name: "origin", url: "https://github.com/nacho/alas.git"),
                GitRemote(name: "upstream", url: "https://github.com/mrmans0n/alas.git"),
            ],
            preferredRemoteName: "upstream"
        )

        #expect(remote?.remoteName == "upstream")
        #expect(remote?.owner == "mrmans0n")
        #expect(remote?.repository == "alas")
    }

    @Test func ignoresPushURLsForReviewRemoteDetection() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "https://github.com/mrmans0n/alas.git"),
            GitRemote(name: "origin", url: "https://github.com/nacho/alas.git", direction: .push),
        ])

        #expect(remote?.owner == "mrmans0n")
    }

    @Test func unsupportedLocalPathReturnsNil() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "../alas.git"),
        ])

        #expect(remote == nil)
    }

    @Test func commitURLUsesGitHubCommitPath() {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )

        #expect(remote.commitURL(sha: "abcdef123") == URL(string: "https://github.com/mrmans0n/alas/commit/abcdef123"))
    }

    @Test func commitURLUsesGitLabCommitPath() {
        let remote = CodeHostRemote(
            kind: .gitlab,
            host: "gitlab.example.com",
            owner: "platform/mobile",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://gitlab.example.com/platform/mobile/alas")!
        )

        #expect(remote.commitURL(sha: "abcdef123") == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/commit/abcdef123"))
    }
}
