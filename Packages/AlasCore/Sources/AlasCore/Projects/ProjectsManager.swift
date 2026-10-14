import Foundation
import Observation

public struct ProjectUpdate: Equatable, Sendable {
    public var name: String
    public var icon: ProjectIcon
    public var startupScripts: ProjectStartupScripts = .defaults
    /// `nil` means this update does not change the project's MCP configuration.
    public var mcpServers: [ProjectMCPServer]?
    /// Nil leaves naming unchanged; a blank string resets to the global default.
    public var worktreeBranchTemplate: String?

    public init(
        name: String,
        icon: ProjectIcon,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer]? = nil,
        worktreeBranchTemplate: String? = nil
    ) {
        self.name = name
        self.icon = icon
        self.startupScripts = startupScripts
        self.mcpServers = mcpServers
        self.worktreeBranchTemplate = worktreeBranchTemplate
    }

    public init(
        name: String,
        color: String,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer]? = nil,
        worktreeBranchTemplate: String? = nil
    ) {
        self.init(
            name: name,
            icon: ProjectIcon.default(color: color),
            startupScripts: startupScripts,
            mcpServers: mcpServers,
            worktreeBranchTemplate: worktreeBranchTemplate
        )
    }
}

public enum WorktreeOperationState: Equatable, Sendable {
    case creating
    /// Claimed the moment the delete confirmation goes up, before the user
    /// has answered it — not tied to any async preflight work. `NSAlert`'s
    /// `runModal()` blocks the call stack but its nested run loop still
    /// pumps other main-actor work, so without this claim a scheduled run
    /// or issue-triggered session could be admitted into the worktree while
    /// the user is still deciding, then keep writing straight through the
    /// staging/audit window that follows a confirmed delete.
    case preparingDelete
    /// Carries the project that owns the claim: a worktree id is its path, and
    /// the same path can exist under more than one host's project, so the id
    /// alone cannot say which checkout is being removed.
    case deleting(projectId: String)
    /// Archive is stopping everything in the worktree before hiding it.
    case archiving(projectId: String)
    /// The raw GG policy is retry metadata only; AppState removes its effective
    /// optimistic overlay before entering this state.
    case createFailed(
        projectId: String,
        message: String,
        base: String,
        ggWorktreeMode: GGWorktreeMode,
        launchSurface: WorktreeLaunchSurface,
        issueAttachment: IssueAttachment?,
        /// A retry must also refuse existing branches and name it later.
        namesBranchFromFirstPrompt: Bool = false
    )
    case launchFailed(projectId: String, message: String, launchSurface: WorktreeLaunchSurface)
    case deleteFailed(message: String)
}

extension WorktreeOperationState {
    /// Whether a worktree in `state` may be claimed for an archive or a
    /// deletion: nothing holds it, or a failed delete is waiting for retry.
    public static func admitsLifecycleOperation(_ state: WorktreeOperationState?) -> Bool {
        switch state {
        case nil, .deleteFailed: true
        default: false
        }
    }

    /// Whether this claim keeps new terminals, agent sessions and runs out of
    /// the worktree: it is being created, or a delete is being confirmed or
    /// carried out. Failed operations no longer hold the worktree.
    public var blocksAdmission: Bool {
        switch self {
        case .creating, .preparingDelete, .deleting, .archiving: true
        case .createFailed, .launchFailed, .deleteFailed: false
        }
    }
}

/// Identity of a worktree claim inside a specific project. A worktree id is
/// its path, so the project is part of the claim's identity: two projects
/// (typically one per SSH host) can list a checkout at the same path.
public struct WorktreeOperationKey: Hashable, Sendable {
    public var projectId: String
    public var worktreeId: String

    public init(projectId: String, worktreeId: String) {
        self.projectId = projectId
        self.worktreeId = worktreeId
    }
}

@Observable
@MainActor
public final class ProjectsManager {
    public private(set) var projects: [ProjectConfig]
    public private(set) var worktreesByProject: [String: [Worktree]] = [:]
    /// Keyed by project *and* worktree id: a worktree id is its own path, and
    /// two projects (typically one per SSH host) can list a checkout at the
    /// same path. Keying by id alone would let one project's claim overwrite
    /// the other's, so cancelling a delete on one host would silently reopen
    /// admission for a worktree the other host is still removing.
    public private(set) var worktreeOperationStates: [WorktreeOperationKey: WorktreeOperationState] = [:]
    /// Who opened each claim through `claimOperation`. Any other write to a
    /// claim drops its token.
    @ObservationIgnored private var claimTokens: [WorktreeOperationKey: (token: UUID, replaced: WorktreeOperationState?)] = [:]
    public private(set) var worktreeRefreshFailures: Set<String> = []
    /// Rows a project lists but does not show because another local project
    /// owns the same directory: `[losing projectId][worktree id] = winner`.
    /// A worktree id is its path, so only one project may hold it.
    public private(set) var worktreeIdConflicts: [String: [String: String]] = [:]
    /// The rows behind `worktreeIdConflicts`, kept so a loser gets its row
    /// back the moment the winner lets go of it.
    private var shadowedRows: [String: [String: Worktree]] = [:]
    /// Ids whose owning project changed since `takeOwnershipChangedIds()` was
    /// last called, so state keyed by project can be rebuilt for them.
    private var ownershipChangedIds: Set<String> = []

    public func takeOwnershipChangedIds() -> Set<String> {
        defer { ownershipChangedIds = [] }
        return ownershipChangedIds
    }

    private let git = GitService()
    private let worktreeSvc = WorktreeService()

    /// Source of the global default sort mode. `AppState` rebinds this after
    /// its stored properties are initialized so it can capture `self` weakly;
    /// tests inject a fixed value via the convenience `defaultOrdering:` init.
    private var defaultOrderingSource: () -> AppConfig.WorktreeSortMode = { .manual }

    public init(
        persistedProjects: [ProjectConfig],
        defaultOrdering: @escaping () -> AppConfig.WorktreeSortMode = { .manual }
    ) {
        var projectIDs = Set<String>()
        self.projects = persistedProjects.filter { projectIDs.insert($0.id).inserted }
        self.defaultOrderingSource = defaultOrdering
    }

    /// Replace the live source of the global default sort mode. The closure is
    /// evaluated lazily on every sort, so a single wire-up at app launch suffices
    /// to keep ordering current as the user toggles the setting — but a *re-sort
    /// of already-sorted lists* is therefore not implicit. Callers must invoke
    /// `reapplyOrderingForAllProjects()` after a config change to propagate the
    /// new mode to lists that were already sorted.
    public func setDefaultOrdering(_ source: @escaping () -> AppConfig.WorktreeSortMode) {
        self.defaultOrderingSource = source
    }

    public func addProject(
        path: URL,
        displayName: String,
        icon: ProjectIcon,
        host: String? = nil,
        kind: ProjectKind = .git,
        id: String = UUID().uuidString,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer] = [],
        worktreeBranchTemplate: String? = nil,
        approvedRepoHookHashes: [String] = []
    ) async throws -> ProjectConfig {
        let storedPath: String
        if let host {
            guard RemotePath.isValidHost(host) else {
                throw NSError(domain: "ProjectsManager", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid SSH host: \"\(host)\""])
            }
            try await RemoteRepoValidator.validate(host: host, path: path.path, kind: kind)
            storedPath = RemotePath.virtual(host: host, realPath: path.path)
        } else {
            guard !RemotePath.isReserved(path.path) else { throw RemotePath.reservedForRemoteError(path.path) }
            storedPath = path.path
            if kind == .folder {
                guard Self.isDirectory(path.path) else {
                    throw NSError(domain: "ProjectsManager", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Not a directory: \(path.path)"])
                }
            } else if try await !git.isGitRepository(path) {
                throw NSError(domain: "ProjectsManager", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Not a git repository: \(path.path)"])
            }
        }
        // Validation suspended, so another add may have taken this id since
        // the caller last looked.
        guard !projects.contains(where: { $0.id == id }) else {
            throw ProjectCreationError.projectAlreadyExists
        }
        // Worktree ids are paths, so two projects at one directory would
        // share row ids that selection, tabs, and sessions key on. Remote ids
        // are namespaced per host, so only projects on the same host (or both
        // local) can collide.
        let storedID = canonical(URL(fileURLWithPath: storedPath))
        if let existing = projects.first(where: { project in
            project.host == host
                && (canonical(URL(fileURLWithPath: project.path)) == storedID
                    || worktreesByProject[project.id, default: []].contains { $0.id == storedID })
        }) {
            throw NSError(domain: "ProjectsManager", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "\(path.path) is already part of \"\(existing.name)\"."])
        }
        let project = ProjectConfig(
            id: id,
            name: displayName,
            path: storedPath,
            color: icon.color,
            addedAt: Date(),
            icon: icon,
            startupScripts: startupScripts,
            mcpServers: mcpServers,
            worktreeBranchTemplate: WorktreeBranchName.normalizedTemplate(worktreeBranchTemplate),
            host: host,
            kind: kind,
            approvedRepoHookHashes: approvedRepoHookHashes
        )
        projects.append(project)
        return project
    }

    public func addProject(
        path: URL,
        displayName: String,
        color: String,
        id: String = UUID().uuidString
    ) async throws -> ProjectConfig {
        try await addProject(
            path: path,
            displayName: displayName,
            icon: ProjectIcon.default(color: color),
            id: id
        )
    }

    /// Returns the projects that got back rows they had lost to this one, so
    /// the caller can refresh and persist them.
    @discardableResult
    public func removeProject(id: String) -> Set<String> {
        let released = Set(worktreesByProject[id, default: []].map(\.id))
        projects.removeAll { $0.id == id }
        worktreesByProject.removeValue(forKey: id)
        worktreeIdConflicts.removeValue(forKey: id)
        shadowedRows.removeValue(forKey: id)
        worktreeOperationStates = worktreeOperationStates.filter { $0.key.projectId != id }
        return restoreRows(releasedBy: id, ids: released)
    }

    public func updateProject(id: String, update: ProjectUpdate) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = update.name
        projects[idx].icon = update.icon
        projects[idx].color = update.icon.color
        projects[idx].startupScripts = update.startupScripts
        if let mcpServers = update.mcpServers {
            projects[idx].mcpServers = mcpServers
        }
        if let template = update.worktreeBranchTemplate {
            projects[idx].worktreeBranchTemplate = WorktreeBranchName.normalizedTemplate(template)
        }
    }

    /// Sets the per-project stacked-diffs mode. Callers persist via
    /// `AppState.saveProjects()`.
    public func setGGMode(projectId: String, mode: GGProjectMode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].ggMode = mode
    }

    public func ggWorktreeMode(projectId: String, worktreeId: String) -> GGWorktreeMode {
        projects.first(where: { $0.id == projectId })?.ggWorktreeModes[worktreeId] ?? .inherit
    }

    public func setGGWorktreeMode(projectId: String, worktreeId: String, mode: GGWorktreeMode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        if mode == .inherit {
            projects[idx].ggWorktreeModes.removeValue(forKey: worktreeId)
        } else {
            projects[idx].ggWorktreeModes[worktreeId] = mode
        }
    }

    // MARK: - Files-tab bookmarks

    public func fileBookmarks(projectId: String) -> [String] {
        projects.first(where: { $0.id == projectId })?.fileBookmarks ?? []
    }

    /// Adds or removes a Files-tab bookmark. Callers persist via
    /// `AppState.saveProjects()`.
    public func toggleFileBookmark(projectId: String, path: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].fileBookmarks = FileBookmarks.toggled(path, in: projects[idx].fileBookmarks)
    }

    public func toggleFileBookmark(projectId: String, node: FileTreeNode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].fileBookmarks = FileBookmarks.toggled(node, in: projects[idx].fileBookmarks)
    }

    public func removeFileBookmark(projectId: String, path: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].fileBookmarks = FileBookmarks.removing(path, from: projects[idx].fileBookmarks)
    }

    public func removeFileBookmark(projectId: String, node: FileTreeNode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].fileBookmarks = FileBookmarks.removing(node, from: projects[idx].fileBookmarks)
    }

    public func removeFileBookmark(projectId: String, bookmark: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].fileBookmarks = FileBookmarks.removingBookmark(bookmark, from: projects[idx].fileBookmarks)
    }

    public func removeGGWorktreeMode(projectId: String, worktreeId: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].ggWorktreeModes.removeValue(forKey: worktreeId)
    }

    /// Records a per-user trust decision for a repo-defined MCP server,
    /// keyed by `RepoMCPTrust.hash(for:)`. Callers persist via
    /// `AppState.saveProjects()`.
    public func setRepoMCPTrust(projectId: String, hash: String, state: RepoMCPTrustState) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].repoMCPTrust[hash] = state
    }

    /// The recorded trust decision for a repo-defined MCP server's exact
    /// config, or nil when no decision exists yet.
    public func repoMCPTrustState(projectId: String, for server: ProjectMCPServer) -> RepoMCPTrustState? {
        projects.first(where: { $0.id == projectId })?
            .repoMCPTrust[RepoMCPTrust.hash(for: server)]
    }

    public func isRepoHookApproved(projectId: String, hash: String) -> Bool {
        projects.first(where: { $0.id == projectId })?.approvedRepoHookHashes.contains(hash) == true
    }

    /// Records an approval for the exact repository hook contents. Returns
    /// whether persistent project configuration changed.
    @discardableResult
    public func approveRepoHook(projectId: String, hash: String) -> Bool {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }),
              !projects[idx].approvedRepoHookHashes.contains(hash)
        else {
            return false
        }
        projects[idx].approvedRepoHookHashes.append(hash)
        return true
    }

    @discardableResult
    public func revokeRepoHookApproval(projectId: String, hash: String) -> Bool {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }),
              projects[idx].approvedRepoHookHashes.contains(hash)
        else {
            return false
        }
        projects[idx].approvedRepoHookHashes.removeAll { $0 == hash }
        return true
    }

    /// Enables/disables a repo-defined MCP server for this project by name.
    /// Callers persist via `AppState.saveProjects()`.
    public func setRepoMCPServerDisabled(projectId: String, name: String, disabled: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        if disabled {
            if !projects[idx].disabledRepoMCPServers.contains(name) {
                projects[idx].disabledRepoMCPServers.append(name)
            }
        } else {
            projects[idx].disabledRepoMCPServers.removeAll { $0 == name }
        }
    }

    public func issueAttachment(projectId: String, worktreeId: String) -> IssueAttachment? {
        projects.first(where: { $0.id == projectId })?.issueAttachments[worktreeId]
    }

    public func setIssueAttachment(projectId: String, worktreeId: String, attachment: IssueAttachment) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].issueAttachments[worktreeId] = attachment
    }

    public func removeIssueAttachment(projectId: String, worktreeId: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].issueAttachments.removeValue(forKey: worktreeId)
    }

    public func pendingAutoBranchName(projectId: String, worktreeId: String) -> String? {
        projects.first(where: { $0.id == projectId })?.pendingAutoBranchNames[worktreeId]
    }

    public func setPendingAutoBranchName(projectId: String, worktreeId: String, placeholder: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].pendingAutoBranchNames[worktreeId] = placeholder
    }

    public func removePendingAutoBranchName(projectId: String, worktreeId: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].pendingAutoBranchNames.removeValue(forKey: worktreeId)
    }

    public func reorderProject(fromIndex: Int, toIndex: Int) {
        guard projects.indices.contains(fromIndex),
              projects.indices.contains(toIndex),
              fromIndex != toIndex
        else { return }

        let moving = projects.remove(at: fromIndex)
        let clampedDestination = min(toIndex, projects.count)
        projects.insert(moving, at: clampedDestination)
    }

    public func reorderProject(movingId: String, destinationId: String) {
        guard let fromIndex = projects.firstIndex(where: { $0.id == movingId }),
              let toIndex = projects.firstIndex(where: { $0.id == destinationId }),
              fromIndex != toIndex
        else { return }
        reorderProject(fromIndex: fromIndex, toIndex: toIndex)
    }

    public func moveProjectToEnd(id: String) {
        guard let fromIndex = projects.firstIndex(where: { $0.id == id }),
              fromIndex != projects.count - 1
        else { return }
        let moving = projects.remove(at: fromIndex)
        projects.append(moving)
    }

    public func worktrees(projectId: String) -> [Worktree] {
        worktreesByProject[projectId] ?? []
    }

    /// The claim open for this exact worktree, looked up by project *and* id.
    /// Both are needed: a worktree id is its own path, and two projects
    /// (typically one per SSH host) can list a checkout at the same path.
    public func operationState(forWorktreeId worktreeId: String, projectId: String) -> WorktreeOperationState? {
        worktreeOperationStates[WorktreeOperationKey(projectId: projectId, worktreeId: worktreeId)]
    }

    /// The claim for a worktree value, which carries both halves of the key.
    public func operationState(for worktree: Worktree) -> WorktreeOperationState? {
        operationState(forWorktreeId: worktree.id, projectId: worktree.projectId)
    }

    /// Opens or clears a claim for a worktree value.
    @_spi(Testing) public func setOperationState(for worktree: Worktree, state: WorktreeOperationState?) {
        setOperationState(forWorktreeId: worktree.id, projectId: worktree.projectId, state: state)
    }

    /// Opens `state` as a claim only the returned token releases. Equal
    /// states are not enough to tell operations apart: a worktree deleted,
    /// recreated at the same path and deleted again gets the same claim, and
    /// the first deletion must not release the second one's.
    @_spi(Testing) public func claimOperation(_ state: WorktreeOperationState, for worktree: Worktree) -> UUID {
        let replaced = operationState(for: worktree)
        setOperationState(for: worktree, state: state)
        let token = UUID()
        claimTokens[WorktreeOperationKey(projectId: worktree.projectId, worktreeId: worktree.id)] = (token, replaced)
        return token
    }

    /// Whether the claim on `worktree` is still the one `token` opened.
    public func holdsClaim(_ token: UUID, for worktree: Worktree) -> Bool {
        let key = WorktreeOperationKey(projectId: worktree.projectId, worktreeId: worktree.id)
        return claimTokens[key]?.token == token && worktreeOperationStates[key] != nil
    }

    /// Gives up the claim `token` opened, for an operation that did not go
    /// ahead: the state it replaced (such as a failed delete awaiting retry)
    /// comes back. The token is dropped even when a refresh already cleared
    /// the claim, and then nothing is restored.
    @_spi(Testing) public func releaseOperation(_ token: UUID, for worktree: Worktree) {
        let key = WorktreeOperationKey(projectId: worktree.projectId, worktreeId: worktree.id)
        guard let claim = claimTokens[key], claim.token == token else { return }
        let restored = worktreeOperationStates[key] == nil ? nil : claim.replaced
        setOperationState(for: worktree, state: restored)
    }

    /// Ends the claim `token` opened, for an operation that ran: cleared, or
    /// left as `state` (such as a failure to retry), which no claim holds.
    @_spi(Testing) public func finishOperation(_ token: UUID, for worktree: Worktree, leaving state: WorktreeOperationState? = nil) {
        let key = WorktreeOperationKey(projectId: worktree.projectId, worktreeId: worktree.id)
        guard claimTokens[key]?.token == token else { return }
        setOperationState(for: worktree, state: state)
    }

    /// Moves the claim `token` holds to another stage of its operation,
    /// keeping the token and the state it replaced.
    @_spi(Testing) public func updateClaim(_ token: UUID, to state: WorktreeOperationState, for worktree: Worktree) {
        let key = WorktreeOperationKey(projectId: worktree.projectId, worktreeId: worktree.id)
        guard let claim = claimTokens[key], claim.token == token, worktreeOperationStates[key] != nil else { return }
        worktreeOperationStates[key] = state
    }

    /// Whether new terminals, agent sessions and runs may start in `worktree`.
    public func admitsNewWork(in worktree: Worktree) -> Bool {
        operationState(for: worktree)?.blocksAdmission != true
    }

    /// Whether new work may start at the worktree id under any project. Used
    /// where only the id is stable: a same-path checkout can move between
    /// projects while its sessions keep running.
    public func admitsNewWork(worktreeId: String) -> Bool {
        !worktreeOperationStates.contains { $0.key.worktreeId == worktreeId && $0.value.blocksAdmission }
    }

    /// Every claim currently open, keyed by project and worktree id.
    public func operationStatesSnapshot() -> [WorktreeOperationKey: WorktreeOperationState] {
        worktreeOperationStates
    }

    @_spi(Testing) public func setOperationState(forWorktreeId worktreeId: String, projectId: String, state: WorktreeOperationState?) {
        let key = WorktreeOperationKey(projectId: projectId, worktreeId: worktreeId)
        claimTokens.removeValue(forKey: key)
        if let state {
            worktreeOperationStates[key] = state
        } else {
            worktreeOperationStates.removeValue(forKey: key)
        }
    }

    public func insertOptimisticWorktree(_ worktree: Worktree) {
        let projectId = worktree.projectId
        storeRows(listedRows(projectId: projectId).filter { $0.id != worktree.id } + [worktree], projectId: projectId)
    }

    /// Which local project keeps a directory two projects both list.
    public enum RowOwnership: Sendable {
        public struct Claimant: Equatable, Sendable {
            public var projectId: String
            public var isFolder: Bool
            public var addedAt: Date

            public init(projectId: String, isFolder: Bool, addedAt: Date) {
                self.projectId = projectId
                self.isFolder = isFolder
                self.addedAt = addedAt
            }
        }

        /// Pure and order-independent, so it does not matter which project
        /// refreshes first: a git row beats a folder row, and between two
        /// projects of the same kind the earlier-added one wins.
        public static func winner(_ a: Claimant, _ b: Claimant) -> String {
            if a.isFolder != b.isFolder { return a.isFolder ? b.projectId : a.projectId }
            if a.addedAt != b.addedAt { return a.addedAt < b.addedAt ? a.projectId : b.projectId }
            return min(a.projectId, b.projectId)
        }
    }

    /// One "Also in X" line per row this project lost to another project.
    public static func alsoInNotes(
        conflicts: [String: String],
        rows: [String: Worktree],
        projects: [ProjectConfig]
    ) -> [String] {
        conflicts.keys.sorted().compactMap { id in
            guard let owner = projects.first(where: { $0.id == conflicts[id] }) else { return nil }
            let title = rows[id]?.title ?? URL(fileURLWithPath: id).lastPathComponent
            return "\(title) · Also in \(owner.name)"
        }
    }

    public func alsoInNotes(projectId: String) -> [String] {
        Self.alsoInNotes(
            conflicts: worktreeIdConflicts[projectId] ?? [:],
            rows: shadowedRows[projectId] ?? [:],
            projects: projects
        )
    }

    /// Every row the project lists, including the ones it lost to another
    /// project. This is the input `storeRows` expects.
    private func listedRows(projectId: String) -> [Worktree] {
        worktreesByProject[projectId, default: []] + (shadowedRows[projectId]?.values.map { $0 } ?? [])
    }

    /// The only way rows enter `worktreesByProject`. `rows` is everything the
    /// project lists; a row whose directory another local project wins under
    /// `RowOwnership` is kept aside as a conflict instead of shown, so a
    /// worktree id resolves to exactly one project. Returns whether the
    /// persisted worktree order changed.
    @discardableResult
    private func storeRows(_ rows: [Worktree], projectId: String) -> Bool {
        let previousIds = Set(worktreesByProject[projectId, default: []].map(\.id))
        var kept: [Worktree] = []
        var conflicts: [String: String] = [:]
        var shadowed: [String: Worktree] = [:]
        var displaced: Set<String> = []
        if let project = projects.first(where: { $0.id == projectId }), project.host == nil {
            for row in rows {
                guard let holder = projects.first(where: { other in
                    other.id != projectId && other.host == nil
                        && worktreesByProject[other.id, default: []].contains { $0.id == row.id }
                }) else {
                    kept.append(row)
                    continue
                }
                if RowOwnership.winner(Self.claimant(project), Self.claimant(holder)) == projectId {
                    kept.append(row)
                    yieldRow(row.id, from: holder.id, to: projectId)
                    displaced.insert(holder.id)
                } else {
                    conflicts[row.id] = holder.id
                    shadowed[row.id] = row
                }
            }
        } else {
            kept = rows
        }
        worktreesByProject[projectId] = kept
        worktreeIdConflicts[projectId] = conflicts.isEmpty ? nil : conflicts
        shadowedRows[projectId] = shadowed.isEmpty ? nil : shadowed
        let orderChanged = applyWorktreeOrdering(projectId: projectId)
        for holderId in displaced {
            applyWorktreeOrdering(projectId: holderId)
        }
        restoreRows(releasedBy: projectId, ids: previousIds.subtracting(kept.map(\.id)))
        return orderChanged
    }

    private static func claimant(_ project: ProjectConfig) -> RowOwnership.Claimant {
        RowOwnership.Claimant(projectId: project.id, isFolder: project.isFolder, addedAt: project.addedAt)
    }

    private func yieldRow(_ id: String, from loserId: String, to winnerId: String) {
        guard let row = worktreesByProject[loserId]?.first(where: { $0.id == id }) else { return }
        worktreesByProject[loserId]?.removeAll { $0.id == id }
        worktreeIdConflicts[loserId, default: [:]][id] = winnerId
        shadowedRows[loserId, default: [:]][id] = row
        ownershipChangedIds.insert(id)
        // Projects that already lost this row to the displaced owner now lose
        // it to the final one, so restoring never has to follow a chain.
        for (otherId, lost) in worktreeIdConflicts where lost[id] == loserId {
            worktreeIdConflicts[otherId]?[id] = winnerId
        }
    }

    /// Hands rows the winner no longer holds back to the projects that lost
    /// them, running the precedence rule again. Returns those projects.
    @discardableResult
    private func restoreRows(releasedBy winnerId: String, ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let losers = worktreeIdConflicts.filter { loserId, lost in
            loserId != winnerId && lost.contains { ids.contains($0.key) && $0.value == winnerId }
        }.keys
        for loserId in losers {
            let restored = worktreeIdConflicts[loserId, default: [:]].filter { ids.contains($0.key) && $0.value == winnerId }
            ownershipChangedIds.formUnion(restored.keys)
            // A shadowed row's directory may have been removed meanwhile (for
            // example by `git worktree remove`), and a folder project has no
            // watcher to notice, so only restore rows that still exist.
            let live = worktreesByProject[loserId, default: []]
            let shadowed = (shadowedRows[loserId]?.values.map { $0 } ?? [])
                .filter { FileManager.default.fileExists(atPath: $0.path.path) }
            storeRows(live + shadowed, projectId: loserId)
        }
        return Set(losers)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The single row of a folder project. Built without touching git or the
    /// filesystem so refreshes stay stable and never persist churn.
    public static func folderWorktree(for project: ProjectConfig) -> Worktree {
        let path = URL(fileURLWithPath: project.path)
        return Worktree(
            id: Worktree.makeId(path: path),
            projectId: project.id,
            name: project.name,
            branch: "",
            path: path,
            isMainWorktree: true,
            status: .clean,
            lastActivity: project.addedAt
        )
    }

    public func populateConfiguredProjectWorktreesForRecovery() {
        for project in projects where worktreesByProject[project.id, default: []].isEmpty {
            let cachedWorktrees = project.cachedWorktrees.filter {
                project.host != nil || FileManager.default.fileExists(atPath: $0.path.path)
            }
            if !cachedWorktrees.isEmpty {
                // Older builds could persist a directory under two projects;
                // the precedence rule filters those duplicates here.
                storeRows(cachedWorktrees, projectId: project.id)
                continue
            }
            let path = URL(fileURLWithPath: project.path)
            guard project.host != nil || FileManager.default.fileExists(atPath: path.path) else { continue }
            if project.isFolder {
                insertOptimisticWorktree(Self.folderWorktree(for: project))
                continue
            }
            let branch = WorktreeService.localBranchName(forWorktreeAt: path) ?? ""
            insertOptimisticWorktree(Worktree(
                id: Worktree.makeId(path: path),
                projectId: project.id,
                name: branch.isEmpty ? project.name : branch,
                branch: branch,
                path: path,
                isMainWorktree: true,
                status: .clean,
                lastActivity: WorktreeService.lastActivity(forWorktreeAt: path) ?? Date()
            ))
        }
    }

    public func removeOptimisticWorktree(id: String, projectId: String) {
        if worktreesByProject[projectId] != nil {
            storeRows(listedRows(projectId: projectId).filter { $0.id != id }, projectId: projectId)
        }
        worktreeOperationStates.removeValue(forKey: WorktreeOperationKey(projectId: projectId, worktreeId: id))
    }

    /// Drops a row that is known to be gone — the removal itself already
    /// succeeded — together with the per-worktree project metadata a
    /// successful refresh reconciles away with it (`cachedWorktrees`, hidden
    /// paths, gg modes, issue attachments, remote host registration). Used
    /// when the refresh that normally does that could not run; without it a
    /// hosted project's deleted row would be restored from `cachedWorktrees`
    /// at startup recovery. Callers persist via `saveProjects()`.
    public func dropRemovedWorktree(id: String, projectId: String) {
        let removedRows = worktreesByProject[projectId, default: []].filter { $0.id == id }
        let removedPaths = Set(removedRows.map { canonical($0.path) })
        removeOptimisticWorktree(id: id, projectId: projectId)
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].cachedWorktrees.removeAll { $0.id == id }
        projects[idx].hiddenWorktreePaths.removeAll { removedPaths.contains($0) }
        projects[idx].ggWorktreeModes.removeValue(forKey: id)
        projects[idx].issueAttachments.removeValue(forKey: id)
        projects[idx].pendingAutoBranchNames.removeValue(forKey: id)
    }

    public func visibleWorktrees(projectId: String) -> [Worktree] {
        let hidden = hiddenSet(projectId: projectId)
        return worktrees(projectId: projectId).filter { !hidden.contains(canonical($0.path)) }
    }

    public func archivedWorktrees(projectId: String) -> [Worktree] {
        let hidden = hiddenSet(projectId: projectId)
        return worktrees(projectId: projectId).filter { hidden.contains(canonical($0.path)) }
    }

    public func visibleMainWorktree(projectId: String) -> Worktree? {
        guard let project = projects.first(where: { $0.id == projectId }) else { return nil }
        return visibleWorktrees(projectId: projectId).first { isMainWorktree($0, project: project) }
    }

    public func resetWorktreeOrder(projectId: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let wasManual = projects[idx].worktreeOrderIsManual || !projects[idx].worktreeOrder.isEmpty
        guard wasManual else { return }
        projects[idx].worktreeOrder = []
        projects[idx].worktreeOrderIsManual = false
        applyWorktreeOrdering(projectId: projectId)
    }

    /// Re-sort every project's worktree list using the current effective sort
    /// mode. Invoke after mutating `config.worktrees.defaultOrdering` (or
    /// `setDefaultOrdering`) — otherwise the change only affects subsequent
    /// sort triggers (worktree add/remove, refresh), not the lists already
    /// rendered. Returns `true` if any project's persisted `worktreeOrder`
    /// actually changed (e.g. orphan ids dropped during normalization), so
    /// callers can decide whether to persist.
    @discardableResult
    public func reapplyOrderingForAllProjects() -> Bool {
        var changed = false
        for project in projects {
            if applyWorktreeOrdering(projectId: project.id) {
                changed = true
            }
        }
        return changed
    }

    public func reorderWorktree(projectId: String, fromIndex: Int, toIndex: Int) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectId }),
              var rows = worktreesByProject[projectId],
              rows.indices.contains(fromIndex)
        else { return }

        applyWorktreeOrdering(projectId: projectId)
        rows = worktreesByProject[projectId, default: []]
        guard rows.indices.contains(fromIndex),
              !isMainWorktree(rows[fromIndex], project: projects[projectIndex])
        else { return }

        let moving = rows.remove(at: fromIndex)
        let clampedDestination = min(max(toIndex, 1), rows.count)
        rows.insert(moving, at: clampedDestination)

        worktreesByProject[projectId] = rows
        projects[projectIndex].worktreeOrderIsManual = true
        projects[projectIndex].worktreeOrder = normalizedWorktreeOrder(
            rows.map(\.id),
            rows: rows,
            project: projects[projectIndex]
        )
        applyWorktreeOrdering(projectId: projectId)
    }

    public func reorderWorktree(projectId: String, movingId: String, destinationId: String) {
        applyWorktreeOrdering(projectId: projectId)
        let rows = worktreesByProject[projectId, default: []]
        guard let fromIndex = rows.firstIndex(where: { $0.id == movingId }),
              let toIndex = rows.firstIndex(where: { $0.id == destinationId })
        else { return }

        reorderWorktree(projectId: projectId, fromIndex: fromIndex, toIndex: toIndex)
    }

    public func isWorktreeHidden(projectId: String, path: URL) -> Bool {
        hiddenSet(projectId: projectId).contains(canonical(path))
    }

    public func setWorktreeLaunchDefaults(projectId: String, openAfterCreate: Bool, launcherMode: AppConfig.LauncherMode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].setWorktreeLaunchPreference(.init(
            openAfterCreate: openAfterCreate,
            launcherMode: launcherMode
        ))
    }

    @_spi(Testing) public func setWorktreeHidden(projectId: String, path: URL, hidden: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let key = canonical(path)
        var paths = projects[idx].hiddenWorktreePaths
        if hidden {
            if !paths.contains(key) { paths.append(key) }
        } else {
            paths.removeAll { $0 == key }
        }
        projects[idx].hiddenWorktreePaths = paths
    }

    /// Refresh the live worktree list and reconcile per-worktree persisted
    /// configuration. Returns `true` when the caller should persist changes.
    @discardableResult
    public func refreshWorktrees(projectId: String) async throws -> Bool {
        do {
            let changed = try await refreshWorktreesImpl(projectId: projectId)
            worktreeRefreshFailures.remove(projectId)
            return changed
        } catch {
            worktreeRefreshFailures.insert(projectId)
            throw error
        }
    }

    public func worktreeDiscoverySucceeded(projectId: String) -> Bool {
        !worktreeRefreshFailures.contains(projectId)
    }

    private func refreshWorktreesImpl(projectId: String) async throws -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        let configuredURL = URL(fileURLWithPath: project.path)
        let url: URL
        // gg clean can remove the linked worktree stored as the project path.
        // Query from another cached checkout so the deleted row can be reconciled.
        if project.isFolder {
            url = configuredURL
        } else if project.host == nil,
           !FileManager.default.fileExists(atPath: configuredURL.path),
           let survivingWorktree = worktreesByProject[projectId, default: []].first(where: {
               FileManager.default.fileExists(atPath: $0.path.path)
           }) {
            url = survivingWorktree.path
        } else {
            url = configuredURL
        }
        // A deleted local folder fails like a deleted repository, so stale
        // project cleanup can find it.
        if project.isFolder, project.host == nil, !Self.isDirectory(configuredURL.path) {
            throw NSError(domain: "ProjectsManager", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Folder no longer exists: \(configuredURL.path)"])
        }
        let trees = project.isFolder
            ? [Self.folderWorktree(for: project)]
            : try await worktreeSvc.list(repoPath: url, projectId: projectId)
        let anchorChanged = url.standardizedFileURL != configuredURL.standardizedFileURL

        // Reconcile optimistic rows: preserve creating rows until the owner
        // task completes, while still replacing them with real rows when
        // they appear in git.
        let previous = worktreesByProject[projectId, default: []]
        let previousById = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let liveIds = Set(trees.map(\.id))
        var reconciled = trees
        var clearedOperationKeys: [WorktreeOperationKey] = []
        var resolvedCreateModes: [String: GGWorktreeMode] = [:]
        for (key, opState) in Array(worktreeOperationStates) {
            // Only this project's claims are reconciled by this project's
            // refresh; another project's row at the same path is untouched.
            guard key.projectId == projectId else { continue }
            let id = key.worktreeId
            guard previousById[id] != nil || liveIds.contains(id) else { continue }
            switch opState {
            case .creating:
                if !liveIds.contains(id) {
                    // Still pending; keep the optimistic row visible.
                    if let optimistic = previousById[id] {
                        reconciled.append(optimistic)
                    }
                }
            case .preparingDelete:
                // A worktree removed externally (another terminal, git
                // worktree prune) while its confirmation was still pending
                // leaves nothing to ever clear the claim otherwise:
                // confirming looks the worktree up by id, fails, and
                // returns before touching operation state; cancelling only
                // clears it when the state still matches `.preparingDelete`
                // for a *live* worktree. Recreating a worktree at the same
                // path reuses the id, so an uncleared claim would block its
                // new incarnation from session admission forever.
                if !liveIds.contains(id) {
                    clearedOperationKeys.append(key)
                }
            case .deleting, .archiving:
                // If the row is gone from git, the operation has nothing left to claim.
                if !liveIds.contains(id) {
                    clearedOperationKeys.append(key)
                }
            case .createFailed(_, _, _, let ggWorktreeMode, _, _, _):
                if liveIds.contains(id) {
                    // Worktree exists in git — transient failure is resolved; clear state.
                    clearedOperationKeys.append(key)
                    resolvedCreateModes[id] = ggWorktreeMode
                } else if let existing = previousById[id] {
                    // Preserve failed rows so they remain visible for retry/removal.
                    reconciled.append(existing)
                }
            case .launchFailed:
                if !liveIds.contains(id) {
                    clearedOperationKeys.append(key)
                }
            case .deleteFailed:
                // If git still sees the worktree, keep it visible with the failed
                // state so the user can retry or remove. If the worktree is gone
                // (user fixed it externally), clear the ghost state.
                if !liveIds.contains(id) {
                    clearedOperationKeys.append(key)
                }
            }
        }
        for key in clearedOperationKeys {
            worktreeOperationStates.removeValue(forKey: key)
        }
        let orderChanged = storeRows(reconciled, projectId: projectId)
        // Only rows this project owns are cached, so a lost directory is not
        // restored under it at startup.
        let stored = worktreesByProject[projectId, default: []]

        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        if anchorChanged {
            projects[idx].path = url.path
        }
        let live = Set(trees.map { canonical($0.path) })
        let before = projects[idx].hiddenWorktreePaths.count
        projects[idx].hiddenWorktreePaths.removeAll { !live.contains($0) }
        let reconciledIds = Set(reconciled.map(\.id))
        let previousGGWorktreeModes = projects[idx].ggWorktreeModes
        let previousIssueAttachments = projects[idx].issueAttachments
        let previousPendingAutoBranchNames = projects[idx].pendingAutoBranchNames
        let previousCachedWorktrees = projects[idx].cachedWorktrees
        projects[idx].cachedWorktrees = stored
        for (id, mode) in resolvedCreateModes {
            if mode == .inherit {
                projects[idx].ggWorktreeModes.removeValue(forKey: id)
            } else {
                projects[idx].ggWorktreeModes[id] = mode
            }
        }
        projects[idx].ggWorktreeModes = projects[idx].ggWorktreeModes.filter {
            reconciledIds.contains($0.key)
        }
        projects[idx].issueAttachments = projects[idx].issueAttachments.filter {
            reconciledIds.contains($0.key)
        }
        projects[idx].pendingAutoBranchNames = projects[idx].pendingAutoBranchNames.filter {
            reconciledIds.contains($0.key)
        }
        return anchorChanged
            || orderChanged
            || projects[idx].cachedWorktrees != previousCachedWorktrees
            || projects[idx].hiddenWorktreePaths.count != before
            || projects[idx].ggWorktreeModes != previousGGWorktreeModes
            || projects[idx].issueAttachments != previousIssueAttachments
            || projects[idx].pendingAutoBranchNames != previousPendingAutoBranchNames
    }

    /// Refresh every project. Returns `true` when at least one project's
    /// persisted configuration changed, so the caller can save it.
    @discardableResult
    public func refreshAll() async -> Bool {
        var changed = false
        for project in projects {
            if let didGC = try? await refreshWorktrees(projectId: project.id) {
                changed = changed || didGC
            }
        }
        return changed
    }

    /// Fast-path branch label update. Patches `branch` (and `name`, since
    /// name == branch in the current model) for any worktree whose
    /// canonicalized path matches a key in `branchByWorktreePath`. Worktrees
    /// not present in the map are left alone.
    ///
    /// Skips rows whose operation state is `.creating` or `.createFailed`:
    /// those rows show the user's intended branch name, not whatever git
    /// has on disk yet. Delete-operation rows are still updated — they
    /// correspond to real git worktrees, so git's branch is still the truth.
    @discardableResult
    public func applyHeadUpdates(projectId: String, branchByWorktreePath: [URL: String]) -> Set<String> {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectId }),
              !branchByWorktreePath.isEmpty
        else { return [] }
        let lookup: [String: String] = Dictionary(uniqueKeysWithValues:
            branchByWorktreePath.map { (canonical($0.key), $0.value) }
        )
        var changed = false
        var changedPaths: Set<String> = []
        func canUpdate(_ worktree: Worktree) -> Bool {
            if let op = operationState(forWorktreeId: worktree.id, projectId: projectId) {
                switch op {
                case .creating, .createFailed: return false
                case .preparingDelete, .deleting, .archiving, .launchFailed, .deleteFailed: return true
                }
            }
            return true
        }
        if var rows = worktreesByProject[projectId], !rows.isEmpty {
            for i in rows.indices {
                let key = canonical(rows[i].path)
                guard let newBranch = lookup[key], canUpdate(rows[i]) else { continue }
                if rows[i].branch != newBranch || rows[i].name != newBranch {
                    rows[i].branch = newBranch
                    rows[i].name = newBranch
                    changed = true
                    changedPaths.insert(rows[i].path.path)
                }
            }
            if changed {
                worktreesByProject[projectId] = rows
                applyWorktreeOrdering(projectId: projectId)
            }
        }
        var cachedRows = projects[projectIndex].cachedWorktrees
        var cachedChanged = false
        for i in cachedRows.indices {
            let key = canonical(cachedRows[i].path)
            guard let newBranch = lookup[key], canUpdate(cachedRows[i]) else { continue }
            if cachedRows[i].branch != newBranch || cachedRows[i].name != newBranch {
                cachedRows[i].branch = newBranch
                cachedRows[i].name = newBranch
                cachedChanged = true
                changedPaths.insert(cachedRows[i].path.path)
            }
        }
        if cachedChanged {
            projects[projectIndex].cachedWorktrees = cachedRows
        }
        return changedPaths
    }

    private func hiddenSet(projectId: String) -> Set<String> {
        guard let project = projects.first(where: { $0.id == projectId }) else { return [] }
        return Set(project.hiddenWorktreePaths)
    }

    private func canonical(_ url: URL) -> String {
        Worktree.makeId(path: url)
    }

    @discardableResult
    private func applyWorktreeOrdering(projectId: String) -> Bool {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectId }),
              let rows = worktreesByProject[projectId]
        else { return false }

        let project = projects[projectIndex]
        let ordered = sortedWorktrees(rows, project: project)
        worktreesByProject[projectId] = ordered

        let normalized = normalizedWorktreeOrder(project.worktreeOrder, rows: ordered, project: project)
        if projects[projectIndex].worktreeOrder != normalized {
            projects[projectIndex].worktreeOrder = normalized
            return true
        }
        return false
    }

    private func sortedWorktrees(_ rows: [Worktree], project: ProjectConfig) -> [Worktree] {
        let effectiveMode: AppConfig.WorktreeSortMode =
            project.worktreeOrderIsManual ? .manual : defaultOrderingSource()

        // Partition main first; main is always pinned at position 0.
        var main: [Worktree] = []
        var others: [Worktree] = []
        for row in rows {
            if isMainWorktree(row, project: project) { main.append(row) } else { others.append(row) }
        }

        let sortedOthers: [Worktree]
        switch effectiveMode {
        case .manual:
            let order = normalizedWorktreeOrder(project.worktreeOrder, rows: rows, project: project)
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            sortedOthers = others.sorted { lhs, rhs in
                let lhsRank = rank[lhs.id]
                let rhsRank = rank[rhs.id]
                if let lhsRank, let rhsRank, lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhsRank != nil { return true }
                if rhsRank != nil { return false }
                return lhs.id < rhs.id
            }
        case .creationDesc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
        case .creationAsc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
        case .lastUpdateDesc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
        case .lastUpdateAsc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity < rhs.lastActivity }
                return lhs.id < rhs.id
            }
        case .branchAsc:
            sortedOthers = others.sorted { lhs, rhs in
                let lb = lhs.branch.localizedLowercase
                let rb = rhs.branch.localizedLowercase
                if lb != rb { return lb < rb }
                return lhs.id < rhs.id
            }
        }

        return main + sortedOthers
    }

    private func normalizedWorktreeOrder(
        _ order: [String],
        rows: [Worktree],
        project: ProjectConfig
    ) -> [String] {
        // Empty input means "follow default" — keep it empty so callers can
        // distinguish manual-mode (non-empty) from auto-mode (empty).
        if order.isEmpty { return [] }

        let nonMainIds = Set(rows.filter { !isMainWorktree($0, project: project) }.map(\.id))
        var seen: Set<String> = []
        var normalized: [String] = []

        for id in order where nonMainIds.contains(id) && !seen.contains(id) {
            normalized.append(id)
            seen.insert(id)
        }

        for row in rows where nonMainIds.contains(row.id) && !seen.contains(row.id) {
            normalized.append(row.id)
            seen.insert(row.id)
        }

        return normalized
    }

    /// Whether `worktree` is the project's primary on-disk checkout (the main
    /// worktree) rather than a feature worktree. Reuses the same path
    /// comparison the sort logic uses to pin main at position 0.
    public func isMain(_ worktree: Worktree, in project: ProjectConfig) -> Bool {
        isMainWorktree(worktree, project: project)
    }

    private func isMainWorktree(_ worktree: Worktree, project: ProjectConfig) -> Bool {
        worktree.isMainWorktree
            ?? (canonical(worktree.path) == canonical(URL(fileURLWithPath: project.path)))
    }
}
