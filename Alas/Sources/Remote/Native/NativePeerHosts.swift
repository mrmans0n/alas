import Foundation
import Observation

/// Paired Macs' worktrees, followed over the host channel of each online
/// peer that serves it (`host.v1` and `host.events.v1`). Peers without it
/// keep the session-derived grouping.
@MainActor
@Observable
final class NativePeerHosts {
    /// Visible worktrees by peer `serverId`. A key exists only for a peer
    /// whose channel holds a snapshot.
    private(set) var worktrees: [String: [PeerHostWorktree]] = [:]
    /// Archived worktrees, keyed like `worktrees`.
    private(set) var archivedWorktrees: [String: [PeerHostWorktree]] = [:]
    /// Each peer's latest run per (worktree, script), keyed like `worktrees`.
    private(set) var runs: [String: [RunRecord]] = [:]
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Fired with the peer's `serverId` when its runs changed, so a run's
    /// console can be listed without waiting for the next poll.
    @ObservationIgnored var onRunsChanged: (@MainActor (_ serverId: String) -> Void)?

    private let send: @MainActor (_ serverId: String, HostClientMessage) -> Void
    private let supports: @MainActor (_ serverId: String, _ capability: String) -> Bool
    let confirm: @MainActor (PeerWorktreeRemoval.Confirmation, _ peerName: String) async -> Bool
    let showError: @MainActor (_ title: String, _ message: String) -> Void
    /// Shows a notice a peer's agent sent, with the peer's server id.
    private let notice: @MainActor (_ serverId: String, HostNotice) -> Void
    private let timeout: Duration
    @ObservationIgnored private var channels: [String: PeerHostChannel] = [:]

    init(
        send: @escaping @MainActor (_ serverId: String, HostClientMessage) -> Void,
        supports: @escaping @MainActor (_ serverId: String, _ capability: String) -> Bool,
        confirm: @escaping @MainActor (PeerWorktreeRemoval.Confirmation, _ peerName: String) async -> Bool = { _, _ in false },
        showError: @escaping @MainActor (_ title: String, _ message: String) -> Void = { _, _ in },
        notice: @escaping @MainActor (_ serverId: String, HostNotice) -> Void = { _, _ in },
        timeout: Duration = PeerHostChannel.defaultTimeout
    ) {
        self.send = send
        self.supports = supports
        self.confirm = confirm
        self.showError = showError
        self.notice = notice
        self.timeout = timeout
    }

    /// Reconciles with the peers whose links currently carry sessions. A
    /// channel that is not subscribed, because its snapshot or resync
    /// failed, connects again here.
    func peersChanged(online: Set<String>) {
        for (serverId, channel) in channels where !online.contains(serverId) || !servesHostChannel(serverId) {
            channels[serverId] = nil
            channel.disconnect() // its onChange drops `worktrees[serverId]`
        }
        for serverId in online where servesHostChannel(serverId) {
            let channel = channels[serverId] ?? makeChannel(serverId)
            guard !channel.isSubscribed, !channel.isConnecting else { continue }
            // ponytail: unthrottled retry, once per refresh (each session-list or
            // availability change); add a failure counter with backoff if a peer
            // that keeps refusing the snapshot or subscribe shows up.
            Task { await channel.connect() }
        }
    }

    func receive(serverId: String, _ message: HostServerMessage) {
        channels[serverId]?.receive(message)
    }

    func stop() {
        let stopped = channels.values
        channels = [:]
        worktrees = [:]
        archivedWorktrees = [:]
        runs = [:]
        for channel in stopped {
            channel.onChange = nil
            channel.disconnect()
        }
    }

    /// Whether `serverId`'s worktrees can be read over its host channel.
    func canRead(serverId: String) -> Bool {
        channels[serverId]?.isSubscribed == true && supports(serverId, HostProtocolCapability.worktreesReadV1)
    }

    /// The reply a session in `worktree` would get for `read`. Nil when the
    /// host cannot be read, refused, or did not answer in time.
    func read(_ read: HostWorktreeRead, in worktree: PeerHostWorktree, serverId: String) async -> RemoteServerMessage? {
        guard canRead(serverId: serverId), let channel = channels[serverId] else { return nil }
        guard case .worktreeRead(let reply) = await channel.request(.readWorktree(worktree: Self.ref(worktree), read: read)) else {
            return nil
        }
        return reply
    }

    /// Whether `serverId` serves its worktrees' Run tab.
    func servesRuns(serverId: String) -> Bool {
        runs[serverId] != nil && supports(serverId, HostProtocolCapability.runsScriptsV1)
    }

    /// The scripts `worktree`'s Run tab lists on the host. Nil when the host
    /// does not serve runs, refused, or did not answer.
    func runScripts(in worktree: PeerHostWorktree, serverId: String) async -> [HostRunScript]? {
        guard servesRuns(serverId: serverId), let channel = channels[serverId] else { return nil }
        guard case .runScripts(let scripts) = await channel.request(.listRunScripts(worktree: Self.ref(worktree))) else { return nil }
        return scripts
    }

    func perform(
        _ command: PeerRuns.Command, on row: PeerRuns.Row, in worktree: PeerHostWorktree, serverId: String
    ) async -> PeerRuns.Reply {
        guard servesRuns(serverId: serverId), let channel = channels[serverId] else {
            return .refused(title: "Run Script Failed", message: FederatedSessionsProvider.peerUnavailableMessage)
        }
        return await PeerRuns.perform(command, on: row, in: Self.ref(worktree)) { await channel.request($0) }
    }

    private static func ref(_ worktree: PeerHostWorktree) -> WorktreeRef {
        WorktreeRef(projectID: worktree.snapshot.worktree.projectId, path: worktree.snapshot.worktree.path.path)
    }

    /// Archive and Delete for `worktree`, only on a host that serves them.
    func controls(for worktree: PeerHostWorktree, serverId: String) -> PeerWorktreeControls {
        worktree.controls(lifecycleSupported: supports(serverId, HostProtocolCapability.worktreesLifecycleV1))
    }

    func archive(_ worktree: PeerHostWorktree, serverId: String, peerName: String) {
        remove(worktree, .archive, failureTitle: "Archive Failed", serverId: serverId, peerName: peerName)
    }

    func delete(_ worktree: PeerHostWorktree, keepBranch: Bool, deleteBranchIfMerged: Bool, serverId: String, peerName: String) {
        remove(
            worktree, .delete(keepBranch: keepBranch, deleteBranchIfMerged: deleteBranchIfMerged),
            failureTitle: "Delete Failed", serverId: serverId, peerName: peerName
        )
    }

    /// Whether `serverId` unarchives its archived worktrees.
    func canUnarchive(serverId: String) -> Bool {
        channels[serverId] != nil && supports(serverId, HostProtocolCapability.worktreesLifecycleV1)
    }

    /// The host's events then move the row back; only a refusal is shown here.
    func unarchive(_ worktree: PeerHostWorktree, serverId: String) {
        guard canUnarchive(serverId: serverId), let channel = channels[serverId] else { return }
        let showError = showError
        Task {
            if case .failure(let error) = await channel.request(.unarchiveWorktree(worktree: Self.ref(worktree))) {
                showError("Unarchive Failed", PeerWorktreeRemoval.message(for: error))
            }
        }
    }

    /// Whether `worktree`'s branch can be renamed, on a host that serves it.
    func canRenameBranch(_ worktree: PeerHostWorktree, serverId: String) -> Bool {
        channels[serverId] != nil && supports(serverId, HostProtocolCapability.worktreesRenameBranchV1)
            && worktree.canRenameBranch
    }

    /// The error message for the rename sheet; nil once renamed. The host's
    /// events then relabel the row.
    func renameBranch(_ worktree: PeerHostWorktree, to branch: String, serverId: String) async -> String? {
        guard canRenameBranch(worktree, serverId: serverId), let channel = channels[serverId] else {
            return FederatedSessionsProvider.peerUnavailableMessage
        }
        switch await channel.request(.renameBranch(worktree: Self.ref(worktree), to: branch)) {
        case .done: return nil
        case .failure(let error): return PeerWorktreeRemoval.message(for: error)
        default: return "The host sent an unexpected reply."
        }
    }

    /// The host's events then update or drop the row; only a refusal is shown here.
    private func remove(
        _ worktree: PeerHostWorktree, _ action: PeerWorktreeRemoval.Action, failureTitle: String,
        serverId: String, peerName: String
    ) {
        guard controls(for: worktree, serverId: serverId) == .available, let channel = channels[serverId] else { return }
        let confirm = confirm, showError = showError
        Task {
            let outcome = await PeerWorktreeRemoval.run(
                action, on: worktree.snapshot,
                request: { await channel.request($0, timeout: $1) },
                confirm: { await confirm($0, peerName) }
            )
            if case .refused(let message) = outcome { showError(failureTitle, message) }
        }
    }

    private func servesHostChannel(_ serverId: String) -> Bool {
        supports(serverId, HostProtocolCapability.v1) && supports(serverId, HostProtocolCapability.eventsV1)
    }

    private func makeChannel(_ serverId: String) -> PeerHostChannel {
        let channel = PeerHostChannel(timeout: timeout) { [weak self] in self?.send(serverId, $0) }
        channel.onChange = { [weak self, weak channel] in
            guard let self, let channel else { return }
            worktrees[serverId] = channel.state?.visibleWorktrees()
            archivedWorktrees[serverId] = channel.state?.archivedWorktrees()
            let newRuns = channel.state?.runs
            let runsChanged = runs[serverId] != newRuns
            runs[serverId] = newRuns
            onChange?()
            if runsChanged { onRunsChanged?(serverId) }
        }
        channel.onNotice = { [notice] in notice(serverId, $0) }
        channels[serverId] = channel
        return channel
    }
}
