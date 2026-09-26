import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP upstream reference store")
struct ACPUpstreamReferenceStoreTests {
    private let ref = CodeHostReference(sigil: .hash, number: 12)

    @Test("resolves the remote, or resolves to nil when the repo has no supported host")
    func remoteResolution() async {
        let github = await UpstreamReferenceFixtures.store()
        #expect(github.hostKind == .github)
        #expect(github.remoteResolved)

        let none = ACPUpstreamReferenceStore(
            worktreeRoot: URL(fileURLWithPath: "/tmp/none"),
            environment: .init(remotes: { _ in [] }, providers: .live(), now: { Date() })
        )
        none.resolveRemote()
        await none.waitForRemote()
        #expect(none.remote == nil)
        #expect(none.remoteResolved)
    }

    @Test("concurrent loads share one lookup and publish the loaded summary")
    func sharedLoad() async {
        let provider = StubReferenceProvider()
        let store = await UpstreamReferenceFixtures.store(provider: provider)
        let revisionBefore = store.revision

        store.ensureLoaded(ref)
        store.ensureLoaded(ref)
        #expect(store.entry(for: ref) == .loading)
        await store.waitForPendingLoads()

        #expect(await provider.calls.count == 1)
        #expect(store.entry(for: ref) == .loaded(UpstreamReferenceFixtures.summary(.reviewRequest, 12)))
        #expect(store.resolvedKind(for: ref) == .reviewRequest)
        #expect(store.revision > revisionBefore)
    }

    @Test("a result is reused for five minutes, then refreshed on the next request")
    func staleRefresh() async {
        let provider = StubReferenceProvider()
        let clock = UpstreamReferenceTestClock()
        let store = await UpstreamReferenceFixtures.store(provider: provider, clock: clock)

        store.ensureLoaded(ref)
        await store.waitForPendingLoads()
        clock.now += 299
        store.ensureLoaded(ref)
        await store.waitForPendingLoads()
        #expect(await provider.calls.count == 1)

        clock.now += 2
        store.ensureLoaded(ref)
        // A stale result stays visible while it refreshes.
        #expect(store.entry(for: ref) != .loading)
        await store.waitForPendingLoads()
        #expect(await provider.calls.count == 2)
    }

    @Test("failures map to not found, missing CLI, and unauthenticated")
    func failures() async {
        var notFound = StubReferenceProvider()
        notFound.respond = { _ in
            throw CodeHostIssueProviderError.notFound(provider: .github, repositorySlug: "mrmans0n/alas", number: 12)
        }
        let a = await UpstreamReferenceFixtures.store(provider: notFound)
        a.ensureLoaded(ref)
        await a.waitForPendingLoads()
        #expect(a.entry(for: ref) == .failed(.notFound(repository: "github.com/mrmans0n/alas")))

        var missing = StubReferenceProvider()
        missing.available = false
        missing.respond = { _ in throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: "") }
        let b = await UpstreamReferenceFixtures.store(provider: missing)
        b.ensureLoaded(ref)
        await b.waitForPendingLoads()
        #expect(b.entry(for: ref) == .failed(.cliMissing(executable: "gh")))

        var loggedOut = StubReferenceProvider()
        loggedOut.authenticated = false
        loggedOut.respond = { _ in throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: "") }
        let c = await UpstreamReferenceFixtures.store(provider: loggedOut)
        c.ensureLoaded(ref)
        await c.waitForPendingLoads()
        #expect(c.entry(for: ref) == .failed(.unauthenticated(executable: "gh", host: "github.com")))
    }

    @Test("GitLab chips know their kind from the sigil before any lookup")
    func gitLabKindFromSigil() async {
        let store = await UpstreamReferenceFixtures.store(host: .gitlab)
        #expect(store.resolvedKind(for: CodeHostReference(sigil: .bang, number: 3)) == .reviewRequest)
        #expect(store.resolvedKind(for: CodeHostReference(sigil: .hash, number: 3)) == .issue)
        let github = await UpstreamReferenceFixtures.store()
        #expect(github.resolvedKind(for: ref) == nil)
    }

    @Test("the registry hands out one store per standardized worktree path")
    func registry() {
        let registry = ACPUpstreamReferenceStore.Registry()
        let a = registry.store(for: URL(fileURLWithPath: "/tmp/alas/"))
        let b = registry.store(for: URL(fileURLWithPath: "/tmp/./alas"))
        let c = registry.store(for: URL(fileURLWithPath: "/tmp/other"))
        #expect(a === b)
        #expect(a !== c)
    }
}
