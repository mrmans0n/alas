import Combine
import Foundation

/// Per-worktree cache behind reference chips: resolves the code host remote
/// once, then looks up each `#N` / `!N` at most once per `staleAfter`.
/// Composer and transcript share one store per worktree through `Registry`.
@MainActor
final class ACPUpstreamReferenceStore: ObservableObject {
    struct Environment: Sendable {
        var remotes: @Sendable (URL) async throws -> [GitRemote]
        var providers: CodeHostProviderRegistry
        var now: @Sendable () -> Date

        static var live: Environment {
            Environment(
                remotes: { try await GitService().remotes(worktreePath: $0) },
                providers: .live(),
                now: { Date() }
            )
        }
    }

    enum Entry: Equatable {
        case idle
        case loading
        case loaded(CodeHostReferenceSummary)
        case failed(CodeHostReferenceFailure)
    }

    /// One shared classification of the CLI's availability/auth state,
    /// cached for `staleAfter` so N concurrently failing lookups run the
    /// `isAvailable`/`isAuthenticated` probe at most once between them,
    /// and a cached `cliMissing`/`unauthenticated` verdict skips the
    /// `gh`/`glab` process entirely on the next lookup.
    private enum CLIProbeVerdict: Equatable {
        case ok
        case cliMissing(executable: String)
        case unauthenticated(executable: String, host: String)

        var failure: CodeHostReferenceFailure? {
            switch self {
            case .ok: nil
            case .cliMissing(let executable): .cliMissing(executable: executable)
            case .unauthenticated(let executable, let host): .unauthenticated(executable: executable, host: host)
            }
        }
    }

    @MainActor
    final class Registry {
        private var stores: [String: ACPUpstreamReferenceStore] = [:]

        func store(for worktreeRoot: URL) -> ACPUpstreamReferenceStore {
            let root = worktreeRoot.standardizedFileURL
            if let existing = stores[root.path] { return existing }
            let store = ACPUpstreamReferenceStore(worktreeRoot: root)
            stores[root.path] = store
            return store
        }
    }

    static let staleAfter: TimeInterval = 300
    /// Caps simultaneous `gh`/`glab` processes: a message referencing many
    /// PRs/issues at once must not fork one subprocess per reference.
    private static let maxConcurrentLoads = 4

    let worktreeRoot: URL
    @Published private(set) var remote: CodeHostRemote?
    @Published private(set) var remoteResolved = false
    /// Bumps on every entry change so chips and open cards repaint.
    @Published private(set) var revision: UInt64 = 0

    private let environment: Environment
    private var entries: [CodeHostReference: (entry: Entry, at: Date)] = [:]
    private var loads: [CodeHostReference: Task<Void, Never>] = [:]
    private var remoteTask: Task<Void, Never>?
    private var activeLoadCount = 0
    private var loadSlotWaiters: [CheckedContinuation<Void, Never>] = []
    private var cliProbe: (verdict: CLIProbeVerdict, at: Date)?
    private var cliProbeTask: Task<CLIProbeVerdict, Never>?

    init(worktreeRoot: URL, environment: Environment = .live) {
        self.worktreeRoot = worktreeRoot
        self.environment = environment
    }

    var hostKind: CodeHostKind? { remote?.kind }

    /// Idempotent while a resolution is in flight. Only `git remote -v` runs
    /// here; CLI availability and auth are checked lazily when a lookup
    /// fails. A failed `git remote -v` (a locked repo, a transient error)
    /// leaves `remote`/`remoteResolved` untouched and clears the in-flight
    /// task, so the NEXT call retries instead of giving up for the store's
    /// lifetime. A successful call that finds no supported host also clears
    /// the task once done — `remote` stays `nil`, but `remoteResolved`
    /// becomes `true` and a later call (e.g. `attachUpstreamReferences` on
    /// each composer attach) re-runs the cheap `git remote -v` again, which
    /// picks up a remote added after this worktree first opened.
    func resolveRemote() {
        guard remoteTask == nil else { return }
        let root = worktreeRoot
        let environment = environment
        remoteTask = Task { [weak self] in
            do {
                let remotes = try await environment.remotes(root)
                let detected = CodeHostRemoteDetector.detect(
                    from: remotes,
                    supportedKinds: environment.providers.supportedKinds
                )
                guard let self else { return }
                self.remote = detected
                self.remoteResolved = true
                self.remoteTask = nil
            } catch {
                self?.remoteTask = nil
            }
        }
    }

    func waitForRemote() async {
        await remoteTask?.value
    }

    func entry(for reference: CodeHostReference) -> Entry {
        entries[reference]?.entry ?? .idle
    }

    /// The fetched kind, or on GitLab the kind the sigil already implies.
    /// `nil` means the chip draws neutral gray.
    func resolvedKind(for reference: CodeHostReference) -> CodeHostReferenceSummary.Kind? {
        if case .loaded(let summary) = entry(for: reference) { return summary.kind }
        guard remote?.kind == .gitlab else { return nil }
        return reference.sigil == .bang ? .reviewRequest : .issue
    }

    func url(for reference: CodeHostReference) -> URL? {
        if case .loaded(let summary) = entry(for: reference) { return summary.url }
        return remote.map { reference.webURL(on: $0) }
    }

    func ensureLoaded(_ reference: CodeHostReference) {
        guard let remote,
              let provider = environment.providers.provider(for: remote.kind),
              loads[reference] == nil
        else { return }
        if let cached = entries[reference],
           environment.now().timeIntervalSince(cached.at) < Self.staleAfter {
            return
        }
        if entries[reference] == nil {
            set(reference, .loading)
        }
        let root = worktreeRoot
        // The task is created (and occupies `loads[reference]`) immediately,
        // so a second `ensureLoaded` call for the same reference is still
        // deduplicated even while this one is queued behind the concurrency
        // cap below — only the actual `gh`/`glab` process is deferred.
        loads[reference] = Task { [weak self] in
            await self?.acquireLoadSlot()
            guard let self else { return }
            // A cached, still-fresh cliMissing/unauthenticated verdict
            // means this lookup can never succeed right now — skip the
            // `gh`/`glab` process entirely instead of relaunching it only
            // to hit the same failure.
            if let precomputed = self.cachedCLIFailure() {
                self.releaseLoadSlot()
                self.loads[reference] = nil
                guard self.remote == remote else { return }
                self.set(reference, .failed(precomputed))
                return
            }
            let outcome: Entry
            do {
                outcome = .loaded(try await provider.referenceSummary(remote: remote, reference: reference, cwd: root))
            } catch {
                outcome = .failed(await self.classifyFailure(error, provider: provider, remote: remote, cwd: root))
            }
            self.releaseLoadSlot()
            self.loads[reference] = nil
            guard self.remote == remote else { return }
            self.set(reference, outcome)
        }
    }

    private func cachedCLIFailure() -> CodeHostReferenceFailure? {
        guard let cliProbe, environment.now().timeIntervalSince(cliProbe.at) < Self.staleAfter else { return nil }
        return cliProbe.verdict.failure
    }

    /// Blocks until fewer than `maxConcurrentLoads` lookups are in flight.
    /// Returns immediately when a slot is free.
    private func acquireLoadSlot() async {
        guard activeLoadCount >= Self.maxConcurrentLoads else {
            activeLoadCount += 1
            return
        }
        await withCheckedContinuation { loadSlotWaiters.append($0) }
        // A queued waiter's slot was handed off directly by `releaseLoadSlot`
        // without ever decrementing `activeLoadCount`, so it's already
        // occupying a slot once resumed — no increment here.
    }

    /// Releases this call's slot. If another lookup is queued, its slot is
    /// handed off directly (the count is left unchanged) rather than freed
    /// and re-claimed, which would let two `ensureLoaded` calls race for the
    /// same just-freed slot and briefly exceed the cap.
    private func releaseLoadSlot() {
        if !loadSlotWaiters.isEmpty {
            loadSlotWaiters.removeFirst().resume()
        } else {
            activeLoadCount -= 1
        }
    }

    func waitForPendingLoads() async {
        while let task = loads.values.first {
            await task.value
        }
    }

    private func set(_ reference: CodeHostReference, _ entry: Entry) {
        entries[reference] = (entry, environment.now())
        revision &+= 1
    }

    /// Classifies one lookup's failure. An error the provider already
    /// labeled `cliMissing`/`unauthenticated` is trusted directly (and
    /// cached). Anything else asks `cliProbeVerdict`, which runs the actual
    /// `isAvailable`/`isAuthenticated` probe at most once per `staleAfter`
    /// and shares one in-flight probe across every call racing to classify
    /// a failure at the same time.
    private func classifyFailure(
        _ error: Error,
        provider: any CodeHostProvider,
        remote: CodeHostRemote,
        cwd: URL
    ) async -> CodeHostReferenceFailure {
        let executable = remote.kind.cliExecutable
        if case CodeHostIssueProviderError.notFound = error {
            return .notFound(repository: "\(remote.host)/\(remote.repositorySlug)")
        }
        if let error = error as? CodeHostProviderError {
            switch error {
            case .cliMissing:
                cacheCLIProbe(.cliMissing(executable: executable))
                return .cliMissing(executable: executable)
            case .unauthenticated(let host):
                cacheCLIProbe(.unauthenticated(executable: executable, host: host))
                return .unauthenticated(executable: executable, host: host)
            default: break
            }
        }
        switch await cliProbeVerdict(provider: provider, remote: remote, cwd: cwd) {
        case .cliMissing(let executable): return .cliMissing(executable: executable)
        case .unauthenticated(let executable, let host): return .unauthenticated(executable: executable, host: host)
        case .ok: return .other(error.localizedDescription)
        }
    }

    /// Runs `isAvailable`/`isAuthenticated` at most once per `staleAfter`
    /// window. A fresh cached verdict returns immediately; an in-flight
    /// probe is awaited rather than duplicated, so several references
    /// failing at once (e.g. the CLI just became unauthenticated) share
    /// one pair of probe calls instead of one pair each.
    private func cliProbeVerdict(
        provider: any CodeHostProvider,
        remote: CodeHostRemote,
        cwd: URL
    ) async -> CLIProbeVerdict {
        if let cliProbe, environment.now().timeIntervalSince(cliProbe.at) < Self.staleAfter {
            return cliProbe.verdict
        }
        if let cliProbeTask {
            return await cliProbeTask.value
        }
        let executable = remote.kind.cliExecutable
        let task = Task<CLIProbeVerdict, Never> {
            if !(await provider.isAvailable(cwd: cwd)) {
                return .cliMissing(executable: executable)
            }
            if !(await provider.isAuthenticated(remote: remote, cwd: cwd)) {
                return .unauthenticated(executable: executable, host: remote.host)
            }
            return .ok
        }
        cliProbeTask = task
        let verdict = await task.value
        cacheCLIProbe(verdict)
        cliProbeTask = nil
        return verdict
    }

    private func cacheCLIProbe(_ verdict: CLIProbeVerdict) {
        cliProbe = (verdict, environment.now())
    }
}
