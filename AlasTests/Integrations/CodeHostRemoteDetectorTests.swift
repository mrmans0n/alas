import Foundation
import Testing
@testable import Alas

struct CodeHostRemoteDetectorTests {
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

    @Test func unsupportedLocalPathReturnsNil() {
        let remote = CodeHostRemoteDetector.detect(from: [
            GitRemote(name: "origin", url: "../alas.git"),
        ])

        #expect(remote == nil)
    }
}
