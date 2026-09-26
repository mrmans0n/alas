import Foundation
@testable import Alas

/// Counts calls across the provider's Sendable boundary.
actor ReferenceCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A code host provider whose only real behaviour is `referenceSummary`.
struct StubReferenceProvider: CodeHostProvider {
    let kind: CodeHostKind
    let capabilities: CodeHostProviderCapabilities = .readOnly
    var available = true
    var authenticated = true
    let calls = ReferenceCallCounter()
    /// Counts calls to `isAvailable`/`isAuthenticated` separately, so a
    /// test can assert the CLI/auth probe ran once and was shared across
    /// several concurrently failing lookups, not re-run per failure.
    let availabilityCalls = ReferenceCallCounter()
    let authenticationCalls = ReferenceCallCounter()
    var respond: @Sendable (CodeHostReference) async throws -> CodeHostReferenceSummary = { reference in
        UpstreamReferenceFixtures.summary(.reviewRequest, reference.number)
    }

    init(kind: CodeHostKind = .github) {
        self.kind = kind
    }

    func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary {
        await calls.increment()
        return try await respond(reference)
    }

    func isAvailable(cwd: URL) async -> Bool {
        await availabilityCalls.increment()
        return available
    }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
        await authenticationCalls.increment()
        return authenticated
    }
    func currentReviewRequest(
        remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL
    ) async throws -> ReviewRequest? { nil }
    func createReviewRequest(
        remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String,
        title: String, body: String, isDraft: Bool, cwd: URL
    ) async throws -> URL { remote.webURL }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func rerunFailedChecks(
        remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL
    ) async throws {}
}

final class UpstreamReferenceTestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
}

enum UpstreamReferenceFixtures {
    static func summary(
        _ kind: CodeHostReferenceSummary.Kind,
        _ number: Int,
        state: CodeHostReferenceSummary.State = .open
    ) -> CodeHostReferenceSummary {
        CodeHostReferenceSummary(
            kind: kind, number: number, title: "Title \(number)", state: state, author: "mrmans0n",
            createdAt: Date(timeIntervalSince1970: 1_789_827_200), updatedAt: nil,
            closedAt: nil, mergedAt: nil,
            url: URL(string: "https://github.com/mrmans0n/alas/pull/\(number)")!
        )
    }

    /// A store whose remote has already resolved to github.com or gitlab.com.
    @MainActor
    static func store(
        host: CodeHostKind = .github,
        provider: StubReferenceProvider? = nil,
        clock: UpstreamReferenceTestClock = UpstreamReferenceTestClock()
    ) async -> ACPUpstreamReferenceStore {
        let url = host == .github ? "git@github.com:mrmans0n/alas.git" : "git@gitlab.com:platform/alas.git"
        let store = ACPUpstreamReferenceStore(
            worktreeRoot: URL(fileURLWithPath: "/tmp/alas"),
            environment: .init(
                remotes: { _ in [GitRemote(name: "origin", url: url)] },
                providers: CodeHostProviderRegistry(providers: [host: provider ?? StubReferenceProvider(kind: host)]),
                now: { clock.now }
            )
        )
        store.resolveRemote()
        await store.waitForRemote()
        return store
    }
}
