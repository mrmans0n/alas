import Foundation
import Testing
@testable import Alas

struct ProjectAvatarPresetProviderTests {
    @Test func githubRemoteMapsToOwnerAvatarURL() throws {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )

        let candidate = try #require(ProjectAvatarPresetProvider.candidate(for: remote))
        #expect(candidate.label == "GitHub avatar: mrmans0n")
        #expect(candidate.url == URL(string: "https://github.com/mrmans0n.png?size=256")!)
    }

    @Test func gitlabRemoteMapsToNamespaceAvatarURL() throws {
        let remote = CodeHostRemote(
            kind: .gitlab,
            host: "gitlab.com",
            owner: "group/subgroup",
            repository: "repo",
            remoteName: "origin",
            webURL: URL(string: "https://gitlab.com/group/subgroup/repo")!
        )

        let candidate = try #require(ProjectAvatarPresetProvider.candidate(for: remote))
        #expect(candidate.label == "GitLab avatar: group/subgroup")
        #expect(candidate.url.absoluteString.contains("https://gitlab.com/api/v4/groups/"))
        #expect(candidate.url.absoluteString.contains("group%2Fsubgroup"))
    }
}
