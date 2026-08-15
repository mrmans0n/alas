import Foundation
import Testing
@testable import Alas

struct IssueSuggestionLoaderTests {
    @Test func loadsOnlyOriginWhenMultipleSupportedRemotesExist() async throws {
        let provider = FakeProvider(kind: .github, suggestions: [Self.issue42])
        let loader = Self.loader(
            remotes: [
                GitRemote(name: "upstream", url: "git@gitlab.com:acme/upstream.git"),
                GitRemote(name: "origin", url: "git@github.com:acme/alas.git"),
            ],
            providers: [provider]
        )

        let result = try await loader.suggestions(projectID: Self.project.id, limit: 50)

        #expect(result == [Self.issue42])
        #expect(await provider.requestedRemotes.map(\.remoteName) == ["origin"])
    }

    @Test func throwsMalformedOutputWhenProjectIsUnknown() async {
        let loader = Self.loader(remotes: [], providers: [])

        await #expect(throws: CodeHostProviderError.malformedOutput(
            "The selected project is no longer available."
        )) {
            try await loader.suggestions(projectID: "unknown")
        }
    }

    @Test func throwsMalformedOutputWhenProjectHasNoSupportedRemote() async {
        let provider = FakeProvider(kind: .github)
        let loader = Self.loader(
            remotes: [GitRemote(name: "origin", url: "git@example.com:acme/alas.git")],
            providers: [provider]
        )

        await #expect(throws: CodeHostProviderError.malformedOutput(
            "The selected project has no supported code host remote."
        )) {
            try await loader.suggestions(projectID: Self.project.id)
        }
    }

    @Test func throwsCLIMissingWhenProviderIsUnavailable() async {
        let provider = FakeProvider(kind: .github, isAvailable: false)
        let loader = Self.loader(remotes: [Self.origin], providers: [provider])

        await #expect(throws: CodeHostProviderError.cliMissing("fake-host")) {
            try await loader.suggestions(projectID: Self.project.id)
        }
    }

    @Test func throwsUnauthenticatedWhenProviderIsNotAuthenticated() async {
        let provider = FakeProvider(kind: .github, isAuthenticated: false)
        let loader = Self.loader(remotes: [Self.origin], providers: [provider])

        await #expect(throws: CodeHostProviderError.unauthenticated("github.com")) {
            try await loader.suggestions(projectID: Self.project.id)
        }
    }

    @Test func forwardsRequestedLimitToProvider() async throws {
        let provider = FakeProvider(kind: .github, suggestions: [Self.issue42])
        let loader = Self.loader(remotes: [Self.origin], providers: [provider])

        let result = try await loader.suggestions(projectID: Self.project.id, limit: 7)

        #expect(result == [Self.issue42])
        #expect(await provider.requestedLimits == [7])
    }

    @Test func doesNotFallThroughWhenPreferredRemoteFails() async {
        let provider = FakeProvider(
            kind: .github,
            error: CodeHostProviderError.commandFailed(command: "fake-host", stderr: "failed")
        )
        let loader = Self.loader(
            remotes: [
                GitRemote(name: "backup", url: "git@github.com:acme/backup.git"),
                Self.origin,
            ],
            providers: [provider]
        )

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "fake-host", stderr: "failed"
        )) {
            try await loader.suggestions(projectID: Self.project.id)
        }
        #expect(await provider.requestedRemotes.map(\.remoteName) == ["origin"])
    }

    private static let project = ProjectConfig(
        id: "alas",
        name: "Alas",
        path: "/tmp/alas",
        color: "blue",
        addedAt: .distantPast
    )

    private static let origin = GitRemote(name: "origin", url: "git@github.com:acme/alas.git")

    private static let issue42 = CodeHostIssueSuggestion(
        provider: .github,
        number: 42,
        title: "Fix sync",
        canonicalURL: URL(string: "https://github.com/acme/alas/issues/42")!,
        createdAt: .distantPast
    )

    private static func loader(
        remotes: [GitRemote],
        providers: [any CodeHostIssueProviding]
    ) -> IssueSuggestionLoader {
        IssueSuggestionLoader(environment: .init(
            projects: { [Self.project] },
            remotes: { _ in remotes },
            providers: CodeHostIssueProviderRegistry(providers)
        ))
    }

    private actor RequestedIssueCalls {
        private(set) var remotes: [CodeHostRemote] = []
        private(set) var limits: [Int] = []

        func record(remote: CodeHostRemote, limit: Int) {
            remotes.append(remote)
            limits.append(limit)
        }
    }

    private struct FakeProvider: CodeHostIssueProviding {
        let kind: CodeHostKind
        let executable = "fake-host"
        let isAvailable: Bool
        let isAuthenticated: Bool
        let suggestions: [CodeHostIssueSuggestion]
        let error: Error?
        private let calls = RequestedIssueCalls()

        init(
            kind: CodeHostKind,
            isAvailable: Bool = true,
            isAuthenticated: Bool = true,
            suggestions: [CodeHostIssueSuggestion] = [],
            error: Error? = nil
        ) {
            self.kind = kind
            self.isAvailable = isAvailable
            self.isAuthenticated = isAuthenticated
            self.suggestions = suggestions
            self.error = error
        }

        var requestedRemotes: [CodeHostRemote] {
            get async { await calls.remotes }
        }

        var requestedLimits: [Int] {
            get async { await calls.limits }
        }

        func isAvailable(cwd: URL) async -> Bool { isAvailable }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { isAuthenticated }

        func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> CodeHostIssueSnapshot {
            throw CodeHostProviderError.malformedOutput("Fake provider does not resolve issues.")
        }

        func openIssues(remote: CodeHostRemote, limit: Int, cwd: URL) async throws -> [CodeHostIssueSuggestion] {
            await calls.record(remote: remote, limit: limit)
            if let error { throw error }
            return suggestions
        }
    }
}
