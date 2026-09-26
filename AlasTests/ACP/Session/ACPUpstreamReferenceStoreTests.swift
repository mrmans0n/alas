import Foundation
import Testing
@testable import Alas

// @MainActor: ACPUpstreamReferenceStore is a @MainActor class.
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

    @Test("a failed remote resolution does not stick; the next call retries")
    func resolveRemoteRetriesAfterFailure() async {
        actor CallCount {
            private(set) var count = 0
            func increment() -> Int {
                count += 1
                return count
            }
        }
        struct RemotesError: Error {}
        let calls = CallCount()
        let store = ACPUpstreamReferenceStore(
            worktreeRoot: URL(fileURLWithPath: "/tmp/alas-retry"),
            environment: .init(
                remotes: { _ in
                    let attempt = await calls.increment()
                    if attempt == 1 { throw RemotesError() }
                    return [GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")]
                },
                providers: .live(),
                now: { Date() }
            )
        )

        store.resolveRemote()
        await store.waitForRemote()
        #expect(store.remote == nil)
        #expect(!store.remoteResolved)

        store.resolveRemote()
        await store.waitForRemote()
        #expect(store.remote?.kind == .github)
        #expect(store.remoteResolved)
        #expect(await calls.count == 2)
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

    @Test("at most four lookups run concurrently; the rest queue behind them")
    func concurrencyIsCapped() async {
        actor Gate {
            private var inFlight = 0
            private var peakInFlight = 0
            private var released = false
            private var reachedFour: CheckedContinuation<Void, Never>?
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func enter() {
                inFlight += 1
                peakInFlight = max(peakInFlight, inFlight)
                if inFlight == 4, let reachedFour {
                    self.reachedFour = nil
                    reachedFour.resume()
                }
            }

            func exit() { inFlight -= 1 }

            func waitUntilFourInFlight() async {
                if inFlight >= 4 { return }
                await withCheckedContinuation { reachedFour = $0 }
            }

            func waitForRelease() async {
                guard !released else { return }
                await withCheckedContinuation { releaseWaiters.append($0) }
            }

            func releaseAll() {
                released = true
                releaseWaiters.forEach { $0.resume() }
                releaseWaiters.removeAll()
            }

            func currentInFlight() -> Int { inFlight }
            func maxInFlight() -> Int { peakInFlight }
        }

        let gate = Gate()
        var provider = StubReferenceProvider()
        provider.respond = { reference in
            await gate.enter()
            await gate.waitForRelease()
            await gate.exit()
            return UpstreamReferenceFixtures.summary(.reviewRequest, reference.number)
        }
        let store = await UpstreamReferenceFixtures.store(provider: provider)

        for number in 1...6 {
            store.ensureLoaded(CodeHostReference(sigil: .hash, number: number))
        }
        await gate.waitUntilFourInFlight()

        #expect(await gate.currentInFlight() == 4)
        #expect(await provider.calls.count == 4)

        await gate.releaseAll()
        await store.waitForPendingLoads()

        #expect(await provider.calls.count == 6)
        #expect(await gate.maxInFlight() == 4)
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

        // The CLI/auth probe is cached, so three different references
        // failing in turn share one `isAvailable` probe rather than
        // re-running it per failure.
        var repeatedlyMissing = StubReferenceProvider()
        repeatedlyMissing.available = false
        repeatedlyMissing.respond = { _ in throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: "") }
        let d = await UpstreamReferenceFixtures.store(provider: repeatedlyMissing)
        for number in [21, 22, 23] {
            d.ensureLoaded(CodeHostReference(sigil: .hash, number: number))
            await d.waitForPendingLoads()
        }
        #expect(d.entry(for: CodeHostReference(sigil: .hash, number: 21)) == .failed(.cliMissing(executable: "gh")))
        #expect(d.entry(for: CodeHostReference(sigil: .hash, number: 22)) == .failed(.cliMissing(executable: "gh")))
        #expect(d.entry(for: CodeHostReference(sigil: .hash, number: 23)) == .failed(.cliMissing(executable: "gh")))
        #expect(await repeatedlyMissing.availabilityCalls.count == 1)
        // The second and third references never even reach the CLI: the
        // cached verdict short-circuits before `referenceSummary` runs.
        #expect(await repeatedlyMissing.calls.count == 1)
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
