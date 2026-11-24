import AlasRemoteKit
import Foundation
import Observation

/// A machine the sheet can start a session on, already set to one of its
/// projects and that project's most recent worktree there: what a project
/// header's New session button opens with.
struct NewSessionPreset: Equatable {
    let hostID: UUID
    let projectId: String
    /// The project's name on that machine, which a host too old to send
    /// option project ids is matched by.
    let projectName: String
    let worktreeId: String?
}

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
    var useBranchNaming = true
    private(set) var createdRoute: SessionRoute?
    private(set) var agentId: String?
    var modelId: String?
    var effortId: String?
    /// A repo hook the host holds the create for, until the user answers.
    private(set) var pendingHook: PeerRepoHook?
    /// The connection dropped mid-create: the worktree may or may not exist.
    private(set) var outcomeUnknown = false
    private var sessionsReloaded = false
    private var worktreesReloaded = false

    @ObservationIgnored private let hub: HostHub
    /// The machines to prefer, in order, each with its project to start in.
    @ObservationIgnored private let presets: [NewSessionPreset]
    /// The current machine's preset still has to pick its worktree.
    @ObservationIgnored private var presetPending = false
    /// The filter the preset typed, cleared again when the machine changes.
    @ObservationIgnored private var presetFilter: String?
    @ObservationIgnored private var listener: ListenerToken?
    @ObservationIgnored private var recoveredWorktreeId: String?
    @ObservationIgnored private var modeChosen = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var watchGeneration = 0
    @ObservationIgnored private var hostWasOnline = false

    init(hub: HostHub, presets: [NewSessionPreset] = []) {
        self.hub = hub
        self.presets = presets
    }

    /// Keeps the project header's machine selected while it reconnects. For a project
    /// on several machines prefer an online one, or the first online machine for a global create.
    func start() {
        guard !started else { return }
        started = true
        let online = onlineHosts.map(\.id)
        let preferred = presets.first { online.contains($0.hostID) } ?? presets.first
        select(host: preferred?.hostID ?? online.first)
    }

    private var preset: NewSessionPreset? { presets.first { $0.hostID == hostID } }
    private var presetProjectId: String? { preset?.projectId }

    var onlineHosts: [PairedHost] { hub.hosts.filter { hub.state(of: $0.id) == .online } }
    var machineOptions: [PairedHost] {
        hub.hosts.filter { $0.id == hostID || hub.state(of: $0.id) == .online }
    }
    var showsMachine: Bool { !presets.isEmpty || machineOptions.count > 1 || !hostIsOnline }
    var hostIsOnline: Bool { hostID.map { hub.state(of: $0) == .online } ?? false }
    var hostName: String? { hub.hosts.first { $0.id == hostID }?.name }
    var hostIcon: PeerIcon { hub.hosts.first { $0.id == hostID }?.icon ?? .laptop }
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

    var branchNaming: RemoteWorktreeBranchNaming? { projects?.first { $0.id == projectId }?.branchNaming }

    var branchPreview: String? {
        guard !branch.isEmpty, let branchNaming else { return nil }
        return branchNaming.compose(name: branch, enabled: useBranchNaming)
    }

    var branchError: String? {
        guard !branch.isEmpty else { return nil }
        guard let branchPreview else { return RemoteBranchName.validationMessage(branch) }
        if case .invalid(let message) = GitNameValidator.validateBranchName(branchPreview) { return message }
        return nil
    }

    /// Left empty, the branch is named from the session's first prompt.
    var namesBranchFromFirstPrompt: Bool {
        branch.isEmpty && hostID.map { hub.supports(HostProtocolCapability.worktreesAutoBranchNameV1, on: $0) } == true
    }

    var canCreate: Bool {
        guard hostIsOnline, !isCreating, !outcomeUnknown, agentId != nil else { return false }
        switch mode {
        case .existing:
            return selectedWorktreeId != nil
        case .new:
            guard projectId != nil, let base, branchNames.contains(base)
            else { return false }
            return namesBranchFromFirstPrompt || (!branch.isEmpty && branchError == nil)
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
        useBranchNaming = true
        agentId = nil
        modelId = nil
        effortId = nil
        modeChosen = false
        if let presetFilter, filter == presetFilter { filter = "" }
        presetFilter = nil
        presetPending = presetProjectId != nil
        phase = .editing
        outcomeUnknown = false
        guard let host else { return }
        listener = hub.addListener(host) { [weak self] message in self?.receive(message) }
        hostWasOnline = hub.state(of: host) == .online
        watchHost(generation: watchGeneration)
        if hostWasOnline { loadLists() }
    }

    func setMode(_ newMode: Mode) {
        modeChosen = true
        mode = newMode
        if newMode == .new, projects == nil { send(.listProjects) }
        reconcileAgent()
    }

    func selectWorktree(_ id: String) {
        recoveredWorktreeId = nil
        selectedWorktreeId = id
        reconcileAgent()
    }

    func selectProject(_ id: String) {
        guard id != projectId else { return }
        projectId = id
        branches = nil
        base = nil
        useBranchNaming = true
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
                                    modelId: modelId, effortId: effortId, repoHook: consent,
                                    useBranchNaming: branchNaming?.appliesRule == true && !useBranchNaming && !branch.isEmpty ? false : nil),
             creating: true)
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
            // The preset's most recent worktree, with the list narrowed to its project. The
            // list is in the host's sidebar order, main first, so its head is not the newest.
            if presetPending, let preset {
                presetPending = false
                if let target = all.first(where: { $0.id == preset.worktreeId })
                    ?? RemoteNewSession.worktrees(all, projectId: preset.projectId, repoName: preset.projectName).first {
                    selectedWorktreeId = target.id
                    if filter.isEmpty {
                        filter = target.projectName
                        presetFilter = target.projectName
                    }
                }
            }
            if !modeChosen {
                modeChosen = true
                mode = RemoteNewSession.defaultWorktreeMode(for: all)
                if mode == .new, projects == nil { send(.listProjects) }
            }
            // Applied once: a later list must not pull the selection back from the user's own choice.
            if let recovered = recoveredWorktreeId, all.contains(where: { $0.id == recovered }) {
                selectedWorktreeId = recovered
                recoveredWorktreeId = nil
            } else {
                selectedWorktreeId = RemoteNewSession.preselectedWorktreeId(in: all, selectedWorktreeId: selectedWorktreeId)
            }
            reconcileAgent()
        case .agentList(let all):
            agents = all
            reconcileAgent()
        case .projectList(let all):
            // A Machine checkout is listed under its local project, which creates on the host.
            let primaries = all.filter { $0.linkedProjectId == nil }
            projects = primaries
            if projectId == nil, let first = primaries.first(where: { $0.id == presetProjectId }) ?? primaries.first {
                selectProject(first.id)
            }
        case .branchList(let id, let names, let preferred) where id == projectId:
            branches = .loaded(names: names, preferredBase: preferred)
            base = RemoteNewSession.preselectedBase(in: branches)
        case .branchListFailed(let id, let failure) where id == projectId:
            branches = .failed(failure)
        case .sessionList:
            sessionsReloaded = true
        case .sessionCreated(let session) where mode == .existing,
             .worktreeSessionCreated(let session) where mode == .new:
            guard isCreating, let hostID else { return }
            phase = .editing
            hub.send(.listSessions, to: hostID)
            createdRoute = SessionRoute(hostID: hostID, sessionId: session.id)
        case .createSessionFailed(let failure):
            guard isCreating, mode == .existing else { return }
            phase = .failed(failure)
        case .worktreeSessionCreationFailed(let stage, let failure, let worktreeId):
            guard isCreating, mode == .new else { return }
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
            guard isCreating, mode == .new else { return }
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
