import Foundation

extension AlasHost {
    /// Sessions an agent's session delegates work to, with the coordinator's
    /// rules on which sessions a caller may reach.
    public var delegation: DelegationAPI { DelegationAPI(core: core) }
}

/// Every verb acts for the calling session, `HostCaller.session`, which must
/// be a loaded ACP session; the coordinator decides which of its relatives,
/// forks and attached sessions it may read, message or stop.
@MainActor
public struct DelegationAPI {
    let core: AlasCoreContext

    /// The agents the caller can delegate to in its worktree or `worktree`.
    public func agents(worktree: String?, caller: HostCaller) async -> AlasCLIResponse {
        guard let origin = origin(of: caller) else { return Self.noOrigin }
        return await core.orchestration.discoverAgents(origin: origin, worktree: worktree)
    }

    /// The caller's parent and children.
    public func list(caller: HostCaller) async -> AlasCLIResponse {
        guard let origin = origin(of: caller) else { return Self.noOrigin }
        return await core.orchestration.list(origin: origin)
    }

    /// Starts a child of the caller with `request`'s prompt.
    public func create(_ request: ACPDelegatedSessionNewRequest, caller: HostCaller) async -> AlasCLIResponse {
        guard let origin = origin(of: caller) else { return Self.noOrigin }
        return await core.orchestration.create(origin: origin, request: request)
    }

    /// Sends a message between the caller and its parent or child.
    public func send(_ request: ACPDelegatedSessionMessageRequest, caller: HostCaller) async -> AlasCLIResponse {
        guard let origin = origin(of: caller) else { return Self.noOrigin }
        return await core.orchestration.send(origin: origin, request: request)
    }

    /// Reads, searches, waits on or interrupts a session the caller may reach.
    public func perform(_ action: ACPDelegatedSessionAction, caller: HostCaller) async -> AlasCLIResponse {
        guard let origin = origin(of: caller) else { return Self.noOrigin }
        return await core.orchestration.perform(origin: origin, action)
    }

    private func origin(of caller: HostCaller) -> ACPOrchestrationSessionOrigin? {
        guard case .session(let id) = caller else { return nil }
        caller.log("delegation", id)
        return core.acpSessionLocation(id)?.origin
    }

    private static let noOrigin = AlasCLIResponse.error("session commands require an originating ACP session")
}
