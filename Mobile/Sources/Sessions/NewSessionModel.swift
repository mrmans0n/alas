import AlasRemoteKit
import Foundation
import Observation

/// State behind the new-session sheet: picks a host, then either a worktree
/// that exists or a branch to create one from, and asks the host to start the
/// session. Mirrors the web client's flow (app.js, worktree-creation.js).
@MainActor @Observable
final class NewSessionModel {
    typealias Mode = RemoteNewSession.WorktreeMode

    static let connectionLostMessage = "Connection lost while creating the worktree."
    private static let offlineMessage = "Connection lost. Reconnect and try again."

    private(set) var hostID: UUID?
    var mode: Mode = .existing
    private(set) var phase = RemoteNewSession.Phase.editing

    private(set) var worktrees: [RemoteWorktreeOption]?
    private(set) var agents: [RemoteAgentOption]?
    private(set) var projects: [RemoteProjectOption]?
    private(set) var branches: RemoteNewSession.Branches?
    var filter = ""
    var selectedWorktreeId: String?
    private(set) var projectId: String?
    var base: String?
    var branch = ""
    private(set) var agentId: String?
    var modelId: String?
    var effortId: String?
    /// A repo hook the host holds the create for, until the user answers.
    var pendingHook: PeerRepoHook?
    /// The connection dropped mid-create: the worktree may or may not exist.
    private(set) var outcomeUnknown = false
    private var sessionsReloaded = false
    private var worktreesReloaded = false

    @ObservationIgnored private let hub: HostHub
    @ObservationIgnored private let onCreated: (SessionRoute) -> Void
    @ObservationIgnored private var listener: ListenerToken?
    @ObservationIgnored private var recoveredWorktreeId: String?
    @ObservationIgnored private var modeChosen = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var watchGeneration = 0
    @ObservationIgnored private var hostWasOnline = false

    init(hub: HostHub, onCreated: @escaping (SessionRoute) -> Void) {
        self.hub = hub
        self.onCreated = onCreated
    }

    /// Joins the first online host and loads its lists. Kept out of `init` because SwiftUI may
    /// construct a throwaway model each time the presenting view re-evaluates.
    func start() {
        guard !started else { return }
        started = true
        select(host: onlineHosts.first?.id)
    }

    var onlineHosts: [PairedHost] { hub.hosts.filter { hub.state(of: $0.id) == .online } }
    var isCreating: Bool { phase == .creating }

    var error: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Cancel and swipe-down stay off while a create is in flight or its outcome is unknown.
    var isLocked: Bool { isCreating || (outcomeUnknown && !canRetry) }

    /// After a disconnect mid-create, until the host has re-sent both lists.
    var canRetry: Bool { outcomeUnknown && sessionsReloaded && worktreesReloaded }

    var visibleWorktrees: [RemoteWorktreeOption] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let all = worktrees ?? []
        guard !query.isEmpty else { return all }
        return all.filter { option in
            [option.projectName, option.worktreeName, option.branch, option.path, option.comparisonRef ?? ""]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private var currentProjectId: String? {
        mode == .new ? projectId : worktrees?.first { $0.id == selectedWorktreeId }?.projectId
    }

    var availableAgents: [RemoteAgentOption] {
        RemoteNewSession.agents(agents ?? [], projectId: currentProjectId)
    }

    var selectedAgent: RemoteAgentOption? { availableAgents.first { $0.id == agentId } }
    var chips: RemoteNewSession.ChipVisibility? { RemoteNewSession.chipVisibility(for: selectedAgent) }

    var branchNames: [String] {
        if case .loaded(let names, _) = branches { return names }
        return []
    }

    var branchError: String? { branch.isEmpty ? nil : RemoteBranchName.validationMessage(branch) }

    var canCreate: Bool {
        guard !isCreating, !outcomeUnknown, agentId != nil else { return false }
        switch mode {
        case .existing:
            return selectedWorktreeId != nil
        case .new:
            guard projectId != nil, let base, branchNames.contains(base)
            else { return false }
            return RemoteBranchName.validationMessage(branch) == nil
        }
    }

    // MARK: - Selection

    func select(host: UUID?) {
        guard host != hostID || listener == nil else { return }
        hostID = host
        listener = nil
        watchGeneration += 1
        worktrees = nil
        agents = nil
        projects = nil
        branches = nil
        selectedWorktreeId = nil
        projectId = nil
        base = nil
        agentId = nil
        modelId = nil
        effortId = nil
        modeChosen = false
        phase = .editing
        outcomeUnknown = false
        guard let host else { return }
        listener = hub.addListener(host) { [weak self] message in self?.receive(message) }
        hostWasOnline = hub.state(of: host) == .online
        watchHost(generation: watchGeneration)
        loadLists()
    }

    func setMode(_ newMode: Mode) {
        modeChosen = true
        mode = newMode
        if newMode == .new, projects == nil { send(.listProjects) }
        reconcileAgent()
    }

    func selectWorktree(_ id: String) {
        selectedWorktreeId = id
        reconcileAgent()
    }

    func selectProject(_ id: String) {
        guard id != projectId else { return }
        projectId = id
        branches = nil
        base = nil
        send(.listBranches(projectId: id))
        reconcileAgent()
    }

    func retryBranches() {
        guard let projectId else { return }
        branches = nil
        send(.listBranches(projectId: projectId))
    }

    func selectAgent(_ id: String) {
        guard id != agentId else { return }
        agentId = id
        modelId = nil
        effortId = nil
    }

    // MARK: - Creating

    func create() {
        guard canCreate, let agentId else { return }
        switch mode {
        case .existing:
            guard let selectedWorktreeId else { return }
            send(.createSession(worktreeId: selectedWorktreeId, agentId: agentId, modelId: modelId, effortId: effortId),
                 creating: true)
        case .new:
            sendWorktreeSession(consent: .ask)
        }
    }

    func answerHook(_ consent: RepoHookConsent?) {
        guard let hook = pendingHook else { return }
        pendingHook = nil
        switch consent {
        case .skip: sendWorktreeSession(consent: .skip)
        case .approve: sendWorktreeSession(consent: .approve(hash: hook.hash))
        default: phase = .editing
        }
    }

    /// Back to editing once both lists are fresh, so the user can see whether the worktree exists.
    func retry() {
        guard canRetry else { return }
        outcomeUnknown = false
        phase = .editing
    }

    private func sendWorktreeSession(consent: RepoHookConsent) {
        guard let projectId, let base, let agentId else { return }
        send(.createWorktreeSession(projectId: projectId, base: base, branch: branch, agentId: agentId,
                                    modelId: modelId, effortId: effortId, repoHook: consent), creating: true)
    }

    // MARK: - Wire

    private func send(_ message: PhoneClientMessage, creating: Bool = false) {
        guard let hostID else { return }
        if creating {
            guard hub.state(of: hostID) == .online else {
                phase = .failed(Self.offlineMessage)
                return
            }
            phase = .creating
        }
        hub.send(message, to: hostID)
    }

    private func loadLists() {
        send(.listWorktrees)
        send(.listAgents)
    }

    private func receive(_ message: PhoneServerMessage) {
        switch message {
        case .worktreeList(let all):
            worktrees = all
            worktreesReloaded = true
            if !modeChosen {
                modeChosen = true
                mode = RemoteNewSession.defaultWorktreeMode(for: all)
                if mode == .new, projects == nil { send(.listProjects) }
            }
            if let recovered = recoveredWorktreeId, all.contains(where: { $0.id == recovered }) {
                selectedWorktreeId = recovered
            } else {
                selectedWorktreeId = RemoteNewSession.preselectedWorktreeId(in: all, selectedWorktreeId: selectedWorktreeId)
            }
            reconcileAgent()
        case .agentList(let all):
            agents = all
            reconcileAgent()
        case .projectList(let all):
            projects = all
            if projectId == nil, let first = all.first { selectProject(first.id) }
        case .branchList(let id, let names, let preferred) where id == projectId:
            branches = .loaded(names: names, preferredBase: preferred)
            base = RemoteNewSession.preselectedBase(in: branches)
        case .branchListFailed(let id, let failure) where id == projectId:
            branches = .failed(failure)
        case .sessionList:
            sessionsReloaded = true
        case .sessionCreated(let session), .worktreeSessionCreated(let session):
            guard isCreating, let hostID else { return }
            phase = .editing
            hub.send(.listSessions, to: hostID)
            onCreated(SessionRoute(hostID: hostID, sessionId: session.id))
        case .createSessionFailed(let failure):
            guard isCreating else { return }
            phase = .failed(failure)
        case .worktreeSessionCreationFailed(let stage, let failure, let worktreeId):
            guard isCreating else { return }
            phase = .failed(failure)
            // The worktree exists without its session: offer it instead of creating a second one.
            if stage == .session, let worktreeId, !worktreeId.isEmpty {
                recoveredWorktreeId = worktreeId
                selectedWorktreeId = worktreeId
                mode = .existing
                send(.listWorktrees)
                reconcileAgent()
            }
        case .worktreeSessionNeedsRepoHookApproval(let hook):
            guard isCreating else { return }
            pendingHook = hook
        default:
            break
        }
    }

    /// Keeps the agent on one that can run in the current repo, else the default.
    private func reconcileAgent() {
        let available = availableAgents
        if let agentId, available.contains(where: { $0.id == agentId }) { return }
        agentId = RemoteNewSession.preselectedAgentId(in: available)
        modelId = nil
        effortId = nil
    }

    /// Reloads what is open when the host comes back, and records an in-flight create as unknown when it drops.
    /// (Not `Observations`: Swift 6.3.3, in CI's Xcode 26.6, crashes compiling that closure.)
    private func watchHost(generation: Int) {
        guard generation == watchGeneration, let hostID else { return }
        let online = withObservationTracking {
            hub.state(of: hostID) == .online
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchHost(generation: generation) }
        }
        defer { hostWasOnline = online }
        if online, !hostWasOnline {
            // The host forgot every request it was asked while away; ask again for what is still loading.
            loadLists()
            if mode == .new, projects == nil { send(.listProjects) }
            if let projectId, branches == nil { send(.listBranches(projectId: projectId)) }
        } else if !online, hostWasOnline, isCreating {
            pendingHook = nil
            if mode == .new {
                outcomeUnknown = true
                sessionsReloaded = false
                worktreesReloaded = false
                phase = .failed(Self.connectionLostMessage)
            } else {
                phase = .failed(Self.offlineMessage)
            }
        }
    }
}
