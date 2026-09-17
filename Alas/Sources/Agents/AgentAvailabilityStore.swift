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

    struct Key: Hashable {
        let host: String
        let worktreePath: String?
    }

    private(set) var states: [Key: AgentAvailabilityState] = [:]
    @ObservationIgnored private var inFlight: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private let probe: Probe

    init(probe: @escaping Probe = AgentAvailabilityStore.remoteProbe) {
        self.probe = probe
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
        guard states[key] == nil else { return }

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
            self.inFlight[key] = nil
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
        states[key] = nil
        await load(target: target, worktreePath: worktreePath, candidates: candidates)
    }

    func invalidate(target: AgentExecutionTarget, worktreePath: String) {
        guard case .ssh(let host) = target else { return }
        invalidate(Key(host: host, worktreePath: nil))
        invalidate(Key(host: host, worktreePath: worktreePath))
    }

    func invalidateAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        states = [:]
    }

    private func invalidate(_ key: Key) {
        inFlight[key]?.cancel()
        inFlight[key] = nil
        states[key] = nil
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
}
