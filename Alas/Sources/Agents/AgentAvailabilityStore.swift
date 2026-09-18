import Foundation
import Observation

enum AgentAvailabilityState: Equatable {
    case loading
    case available([AgentDefinition])
    case failed(String)

    var agents: [AgentDefinition] {
        guard case .available(let agents) = self else { return [] }
        return agents
    }
}

@MainActor
@Observable
final class AgentAvailabilityStore {
    typealias Probe = @Sendable (String, String, [AgentDefinition]) async throws -> ProcessResult
    typealias Now = @MainActor () -> Date
    typealias RefreshScheduler = @MainActor (
        TimeInterval,
        @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>

    static let successfulProbeTTL: TimeInterval = 30

    struct Key: Hashable {
        let host: String
        let worktreePath: String?
    }

    private(set) var states: [Key: AgentAvailabilityState] = [:]
    private(set) var generation = 0
    @ObservationIgnored private var inFlight: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadedAt: [Key: Date] = [:]
    @ObservationIgnored private var refreshTasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let now: Now
    @ObservationIgnored private let refreshScheduler: RefreshScheduler

    init(
        probe: @escaping Probe = AgentAvailabilityStore.remoteProbe,
        now: @escaping Now = { Date() },
        refreshScheduler: @escaping RefreshScheduler = AgentAvailabilityStore.defaultRefreshScheduler
    ) {
        self.probe = probe
        self.now = now
        self.refreshScheduler = refreshScheduler
    }

    func state(
        target: AgentExecutionTarget,
        worktreePath: String,
        localAgents: [AgentDefinition]
    ) -> AgentAvailabilityState {
        switch target {
        case .local:
            .available(localAgents)
        case .ssh(let host):
            states[Key(host: host, worktreePath: worktreePath)]
                ?? states[Key(host: host, worktreePath: nil)]
                ?? .loading
        }
    }

    func load(
        target: AgentExecutionTarget,
        worktreePath: String,
        candidates: [AgentDefinition]
    ) async {
        guard case .ssh(let host) = target else { return }
        let key = cacheKey(host: host, worktreePath: worktreePath, candidates: candidates)

        if let task = inFlight[key] {
            await task.value
            return
        }
        if let state = states[key] {
            guard shouldRefresh(state: state, key: key) else { return }
            states[key] = nil
            loadedAt[key] = nil
        }

        states[key] = .loading
        let probe = probe
        let task = Task { @MainActor [weak self] in
            let state = await Self.probeState(
                host: host,
                worktreePath: worktreePath,
                candidates: candidates,
                probe: probe
            )
            guard !Task.isCancelled, let self else { return }
            self.states[key] = state
            let loadedAt = self.now()
            self.loadedAt[key] = loadedAt
            self.inFlight[key] = nil
            if case .available = state {
                self.scheduleSuccessfulRefresh(
                    key: key,
                    target: .ssh(host: host),
                    worktreePath: worktreePath,
                    candidates: candidates,
                    loadedAt: loadedAt
                )
            } else {
                self.refreshTasks[key]?.cancel()
                self.refreshTasks[key] = nil
            }
        }
        inFlight[key] = task
        await task.value
    }

    func retry(
        target: AgentExecutionTarget,
        worktreePath: String,
        candidates: [AgentDefinition]
    ) async {
        guard case .ssh(let host) = target else { return }
        let key = cacheKey(host: host, worktreePath: worktreePath, candidates: candidates)
        inFlight[key]?.cancel()
        inFlight[key] = nil
        refreshTasks[key]?.cancel()
        refreshTasks[key] = nil
        states[key] = nil
        await load(target: target, worktreePath: worktreePath, candidates: candidates)
    }

    func loadRetryingFailure(
        target: AgentExecutionTarget,
        worktreePath: String,
        candidates: [AgentDefinition]
    ) async {
        await load(target: target, worktreePath: worktreePath, candidates: candidates)
        guard case .ssh(let host) = target else { return }
        let key = cacheKey(host: host, worktreePath: worktreePath, candidates: candidates)
        guard case .failed = states[key] else { return }
        await retry(target: target, worktreePath: worktreePath, candidates: candidates)
    }

    func invalidate(target: AgentExecutionTarget, worktreePath: String) {
        guard case .ssh(let host) = target else { return }
        let keys = Set(states.keys.filter { $0.host == host } + inFlight.keys.filter { $0.host == host })
        for key in keys {
            invalidate(key)
        }
        generation += 1
    }

    func invalidateAll() {
        inFlight.values.forEach { $0.cancel() }
        refreshTasks.values.forEach { $0.cancel() }
        inFlight = [:]
        refreshTasks = [:]
        states = [:]
        loadedAt = [:]
        generation += 1
    }

    private func invalidate(_ key: Key) {
        inFlight[key]?.cancel()
        inFlight[key] = nil
        refreshTasks[key]?.cancel()
        refreshTasks[key] = nil
        states[key] = nil
        loadedAt[key] = nil
    }

    private func scheduleSuccessfulRefresh(
        key: Key,
        target: AgentExecutionTarget,
        worktreePath: String,
        candidates: [AgentDefinition],
        loadedAt: Date
    ) {
        refreshTasks[key]?.cancel()
        let scheduler = refreshScheduler
        refreshTasks[key] = scheduler(Self.successfulProbeTTL) { [weak self] in
            guard let self else { return }
            await self.refreshSuccessfulAvailabilityIfCurrent(
                key: key,
                target: target,
                worktreePath: worktreePath,
                candidates: candidates,
                loadedAt: loadedAt
            )
        }
    }

    private func refreshSuccessfulAvailabilityIfCurrent(
        key: Key,
        target: AgentExecutionTarget,
        worktreePath: String,
        candidates: [AgentDefinition],
        loadedAt expectedLoadedAt: Date
    ) async {
        guard loadedAt[key] == expectedLoadedAt, case .available = states[key] else { return }
        refreshTasks[key] = nil
        states[key] = nil
        loadedAt[key] = nil
        await load(target: target, worktreePath: worktreePath, candidates: candidates)
    }

    private func shouldRefresh(state: AgentAvailabilityState, key: Key) -> Bool {
        guard case .available = state, let loaded = loadedAt[key] else { return false }
        return now().timeIntervalSince(loaded) >= Self.successfulProbeTTL
    }

    private func cacheKey(
        host: String,
        worktreePath: String,
        candidates: [AgentDefinition]
    ) -> Key {
        Key(
            host: host,
            worktreePath: candidates.contains(where: Self.usesWorktreeRelativeBinary)
                ? worktreePath
                : nil
        )
    }

    private static func usesWorktreeRelativeBinary(_ agent: AgentDefinition) -> Bool {
        let binary = agent.configuredBinary
        return binary.contains("/")
            && !binary.hasPrefix("/")
            && !binary.hasPrefix("~/")
    }

    private static func probeState(
        host: String,
        worktreePath: String,
        candidates: [AgentDefinition],
        probe: Probe
    ) async -> AgentAvailabilityState {
        do {
            let result = try await probe(host, worktreePath, candidates)
            guard result.exitCode == 0 else {
                return .failed("Could not check agents on \(host).")
            }
            let availableIDs = RemoteAgentProbe.availableAgentIDs(stdout: result.stdout, agents: candidates)
            return .available(candidates.filter { availableIDs.contains($0.id) })
        } catch {
            return .failed("Could not check agents on \(host).")
        }
    }

    private static func remoteProbe(
        host: String,
        worktreePath: String,
        agents: [AgentDefinition]
    ) async throws -> ProcessResult {
        try await RemoteExec.run(
            host: host,
            cwd: nil,
            command: RemoteAgentProbe.command(agents: agents, workingDirectory: worktreePath)
        )
    }

    private static func defaultRefreshScheduler(
        delay: TimeInterval,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await action()
        }
    }
}
