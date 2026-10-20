import Foundation
import os
import AlasFoundation

private let projectConfigLogger = Logger(subsystem: "io.nlopez.alas", category: "project-config")

public enum ProjectAgentSelection: Hashable, Sendable {
    case global
    case none
    case agent(String)
}

// MARK: - ProjectStartupScriptMode
/// How a project's per-repository startup script combines with the global default.
public enum ProjectStartupScriptMode: String, Codable, Equatable, CaseIterable, Sendable {
    case useGlobal
    case appendToGlobal
    case overrideGlobal
    case disabled
    public var usesInheritedScripts: Bool {
        switch self {
        case .useGlobal, .appendToGlobal:
            true
        case .overrideGlobal, .disabled:
            false
        }
    }
}

// MARK: - ProjectStartupScripts
/// Per-repository startup-script configuration for terminal session open,
/// worktree creation, and worktree agent override.
/// Global settings in `AppConfig.Terminal` act as defaults.
public struct ProjectStartupScripts: Codable, Equatable, Sendable {
    public var sessionOpenMode: ProjectStartupScriptMode
    public var sessionOpenScript: String
    public var worktreeCreateMode: ProjectStartupScriptMode
    public var worktreeCreateScript: String
    public var worktreeAgentMode: ProjectStartupScriptMode
    public var worktreeAgentId: String?
    public var worktreeAgentUseBypassPermissions: Bool

    /// A picker-friendly projection of the existing persisted agent policy.
    public var agentSelection: ProjectAgentSelection {
        get {
            switch worktreeAgentMode {
            case .useGlobal: .global
            case .disabled: .none
            case .overrideGlobal, .appendToGlobal:
                worktreeAgentId.map(ProjectAgentSelection.agent) ?? .none
            }
        }
        set {
            switch newValue {
            case .global:
                worktreeAgentMode = .useGlobal
            case .none:
                worktreeAgentMode = .disabled
            case .agent(let id):
                worktreeAgentMode = .overrideGlobal
                worktreeAgentId = id
            }
        }
    }

    /// `useGlobal` resolves repo-first: a team-defined default agent beats
    /// the user's global one unless the project sets its own override.
    public func defaultAgentID(repoDefaultAgent: String?, globalAgentID: String?) -> String? {
        switch worktreeAgentMode {
        case .useGlobal: repoDefaultAgent ?? globalAgentID
        case .disabled: nil
        case .overrideGlobal, .appendToGlobal: worktreeAgentId
        }
    }

    /// Historical shim for callers without repo context.
    public func defaultAgentID(globalAgentID: String?) -> String? {
        defaultAgentID(repoDefaultAgent: nil, globalAgentID: globalAgentID)
    }

    public static let defaults = ProjectStartupScripts(
        sessionOpenMode: .useGlobal,
        sessionOpenScript: "",
        worktreeCreateMode: .useGlobal,
        worktreeCreateScript: ""
    )

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionOpenMode, sessionOpenScript,
             worktreeCreateMode, worktreeCreateScript,
             worktreeAgentMode, worktreeAgentId,
             worktreeAgentUseBypassPermissions
    }

    public init(
        sessionOpenMode: ProjectStartupScriptMode,
        sessionOpenScript: String,
        worktreeCreateMode: ProjectStartupScriptMode,
        worktreeCreateScript: String,
        worktreeAgentMode: ProjectStartupScriptMode = .useGlobal,
        worktreeAgentId: String? = nil,
        worktreeAgentUseBypassPermissions: Bool = false
    ) {
        self.sessionOpenMode = sessionOpenMode
        self.sessionOpenScript = sessionOpenScript
        self.worktreeCreateMode = worktreeCreateMode
        self.worktreeCreateScript = worktreeCreateScript
        self.worktreeAgentMode = worktreeAgentMode
        self.worktreeAgentId = worktreeAgentId
        self.worktreeAgentUseBypassPermissions = worktreeAgentUseBypassPermissions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionOpenMode = try c.decode(ProjectStartupScriptMode.self, forKey: .sessionOpenMode)
        sessionOpenScript = try c.decode(String.self, forKey: .sessionOpenScript)
        worktreeCreateMode = try c.decode(ProjectStartupScriptMode.self, forKey: .worktreeCreateMode)
        worktreeCreateScript = try c.decode(String.self, forKey: .worktreeCreateScript)
        worktreeAgentMode = (try? c.decode(ProjectStartupScriptMode.self, forKey: .worktreeAgentMode)) ?? .useGlobal
        worktreeAgentId = try? c.decode(String.self, forKey: .worktreeAgentId)
        worktreeAgentUseBypassPermissions = (try? c.decode(Bool.self, forKey: .worktreeAgentUseBypassPermissions)) ?? false
    }
}

// MARK: - ProjectsFile
public struct ProjectsFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var projects: [ProjectConfig]

    public init(version: Int = 1, projects: [ProjectConfig]) {
        self.version = version
        self.projects = projects
    }
}

// MARK: - ProjectKind
/// A `.folder` project is a plain directory: one synthesized row, no git.
public enum ProjectKind: String, Codable, Equatable, Sendable {
    case git, folder
}

// MARK: - ProjectConfig
public struct ProjectConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: String           // UUID string
    public var name: String         // display name, defaulting to the repo directory name
    public var path: String         // absolute repo path
    public var icon: ProjectIcon
    public var color: String {      // legacy compatibility mirror
        get { icon.color }
        set { icon = icon.withColor(newValue) }
    }
    public var addedAt: Date
    public var hiddenWorktreePaths: [String] = []
    public var worktreeOrder: [String] = []
    public var cachedWorktrees: [Worktree] = []
    /// Explicit signal that the user dragged worktrees into a custom order.
    /// When `false`, the global default sort mode applies regardless of any
    /// legacy `worktreeOrder` left on disk. Set to `true` by drag reorders;
    /// cleared by "Reset Sort to Default".
    public var worktreeOrderIsManual: Bool = false
    public var startupScripts: ProjectStartupScripts = .defaults
    public var mcpServers: [ProjectMCPServer] = []
    /// Per-project "open after create" preference. `nil` = use global default (true).
    public var worktreeOpenAfterCreate: Bool?
    /// Per-project launcher mode preference. `nil` = use global default.
    public var worktreeDefaultLauncherMode: AppConfig.LauncherMode?
    /// Typed successor to the legacy launch fields. Nil keeps old files and
    /// callers behaviorally identical; decoding derives its effective value.
    public var worktreeLaunchPreference: CreationLaunchPreference?
    /// Nil inherits the global worktree branch template.
    public var worktreeBranchTemplate: String?
    /// SSH destination when this project lives on another machine.
    public var host: String?
    /// Omitted from disk for `.git`, so git projects encode exactly as before.
    public var kind: ProjectKind = .git
    public var isFolder: Bool { kind == .folder }
    /// Per-project stacked-diffs (gg) mode. Defaults to `.auto`.
    public var ggMode: GGProjectMode = .auto
    /// Sparse per-worktree overrides. Missing entries inherit project policy.
    public var ggWorktreeModes: [String: GGWorktreeMode] = [:]
    /// Sparse Issue attachments, keyed by worktree ID.
    public var issueAttachments: [String: IssueAttachment] = [:]
    /// Worktrees created without a name, keyed by worktree ID, mapped to the
    /// temporary branch they were created on. The first chat prompt renames
    /// that branch; the entry is dropped once renamed or no longer applicable.
    public var pendingAutoBranchNames: [String: String] = [:]
    /// Files-tab bookmarks, as worktree-relative paths in the order the
    /// user added them. Repo-level on purpose: every worktree of the
    /// project shares one list.
    public var fileBookmarks: [String] = []
    /// Per-user trust decisions for repo-defined MCP servers, keyed by
    /// `RepoMCPTrust.hash(for:)`.
    public var repoMCPTrust: [String: RepoMCPTrustState] = [:]
    /// Names of repo-defined MCP servers the user disabled without replacing
    /// them with an app-level server of the same name.
    public var disabledRepoMCPServers: [String] = []
    /// SHA-256 hashes of exact repository hook bytes approved for this project.
    public var approvedRepoHookHashes: [String] = []
    /// Worktree ids renamed to virtual ones (legacy real path → virtual)
    /// whose stores have not all migrated yet. Persisted as
    /// `pendingLegacyWorktreeIDs` (omitted when empty) so a failed store move
    /// is retried on the next launch even after this file is re-saved with
    /// the virtual ids; cleared once a migration run fully succeeds.
    public var legacyWorktreeIDs: [String: String] = [:]
    /// Project-level PR shepherd rules. A `.alas/shepherd.local.md` or
    /// `.alas/shepherd.md` file in the worktree overrides them completely.
    public var shepherd: ProjectShepherdSettings?

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, name, path, color, icon, addedAt, hiddenWorktreePaths, worktreeOrder,
             cachedWorktrees, worktreeOrderIsManual, startupScripts,
             mcpServers, worktreeOpenAfterCreate, worktreeDefaultLauncherMode, worktreeLaunchPreference, worktreeBranchTemplate, host, kind, ggMode,
             ggWorktreeModes, issueAttachments, pendingAutoBranchNames, fileBookmarks,
             repoMCPTrust, disabledRepoMCPServers, approvedRepoHookHashes, pendingLegacyWorktreeIDs,
             shepherd
    }

    public init(
        id: String,
        name: String,
        path: String,
        color: String,
        addedAt: Date,
        icon: ProjectIcon? = nil,
        hiddenWorktreePaths: [String] = [],
        worktreeOrder: [String] = [],
        cachedWorktrees: [Worktree] = [],
        worktreeOrderIsManual: Bool = false,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer] = [],
        worktreeOpenAfterCreate: Bool? = nil,
        worktreeDefaultLauncherMode: AppConfig.LauncherMode? = nil,
        worktreeLaunchPreference: CreationLaunchPreference? = nil,
        worktreeBranchTemplate: String? = nil,
        host: String? = nil,
        kind: ProjectKind = .git,
        ggMode: GGProjectMode = .auto,
        ggWorktreeModes: [String: GGWorktreeMode] = [:],
        issueAttachments: [String: IssueAttachment] = [:],
        fileBookmarks: [String] = [],
        repoMCPTrust: [String: RepoMCPTrustState] = [:],
        disabledRepoMCPServers: [String] = [],
        approvedRepoHookHashes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon ?? ProjectIcon.default(color: color)
        self.addedAt = addedAt
        self.hiddenWorktreePaths = hiddenWorktreePaths
        self.worktreeOrder = worktreeOrder
        self.cachedWorktrees = cachedWorktrees
        self.worktreeOrderIsManual = worktreeOrderIsManual
        self.startupScripts = startupScripts
        self.mcpServers = mcpServers
        self.worktreeOpenAfterCreate = worktreeOpenAfterCreate
        self.worktreeDefaultLauncherMode = worktreeDefaultLauncherMode
        self.worktreeLaunchPreference = worktreeLaunchPreference
        self.worktreeBranchTemplate = worktreeBranchTemplate
        self.host = host
        self.kind = kind
        self.ggMode = ggMode
        self.ggWorktreeModes = ggWorktreeModes
        self.issueAttachments = issueAttachments
        self.fileBookmarks = fileBookmarks
        self.repoMCPTrust = repoMCPTrust
        self.disabledRepoMCPServers = disabledRepoMCPServers
        self.approvedRepoHookHashes = approvedRepoHookHashes
    }

    // Tolerant decode: older projects.json files predate hiddenWorktreePaths
    // and startupScripts, so fall back to known defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        let decodedColor = try c.decode(String.self, forKey: .color)
        let decodedIcon = (try? ProjectIcon.decode(
            from: c.superDecoder(forKey: .icon),
            fallbackColor: decodedColor
        ))
            ?? ProjectIcon.default(color: decodedColor)
        icon = decodedIcon
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        hiddenWorktreePaths = (try? c.decode([String].self, forKey: .hiddenWorktreePaths)) ?? []
        worktreeOrder = (try? c.decode([String].self, forKey: .worktreeOrder)) ?? []
        cachedWorktrees = (try? c.decode([Worktree].self, forKey: .cachedWorktrees)) ?? []
        worktreeOrderIsManual = (try? c.decode(Bool.self, forKey: .worktreeOrderIsManual)) ?? false
        startupScripts = (try? c.decode(ProjectStartupScripts.self, forKey: .startupScripts))
            ?? .defaults
        mcpServers = (try? c.decode([ProjectMCPServer].self, forKey: .mcpServers)) ?? []
        worktreeOpenAfterCreate = try? c.decode(Bool.self, forKey: .worktreeOpenAfterCreate)
        worktreeDefaultLauncherMode = try? c.decode(AppConfig.LauncherMode.self, forKey: .worktreeDefaultLauncherMode)
        worktreeLaunchPreference = try? c.decode(CreationLaunchPreference.self, forKey: .worktreeLaunchPreference)
        worktreeBranchTemplate = try? c.decode(String.self, forKey: .worktreeBranchTemplate)
        if worktreeLaunchPreference == nil,
           worktreeOpenAfterCreate != nil || worktreeDefaultLauncherMode != nil {
            worktreeLaunchPreference = .init(
                openAfterCreate: worktreeOpenAfterCreate,
                launcherMode: worktreeDefaultLauncherMode
            )
        }
        host = try? c.decode(String.self, forKey: .host)
        kind = (try? c.decode(ProjectKind.self, forKey: .kind)) ?? .git
        ggMode = (try? c.decode(GGProjectMode.self, forKey: .ggMode)) ?? .auto
        ggWorktreeModes = (try? c.decode([String: GGWorktreeMode].self, forKey: .ggWorktreeModes)) ?? [:]
        issueAttachments = (try? c.decode([String: IssueAttachment].self, forKey: .issueAttachments)) ?? [:]
        pendingAutoBranchNames = (try? c.decode([String: String].self, forKey: .pendingAutoBranchNames)) ?? [:]
        fileBookmarks = (try? c.decode([String].self, forKey: .fileBookmarks)) ?? []
        repoMCPTrust = (try? c.decode([String: RepoMCPTrustState].self, forKey: .repoMCPTrust)) ?? [:]
        disabledRepoMCPServers = (try? c.decode([String].self, forKey: .disabledRepoMCPServers)) ?? []
        approvedRepoHookHashes = (try? c.decode([String].self, forKey: .approvedRepoHookHashes)) ?? []
        legacyWorktreeIDs = (try? c.decode([String: String].self, forKey: .pendingLegacyWorktreeIDs)) ?? [:]
        shepherd = try? c.decodeIfPresent(ProjectShepherdSettings.self, forKey: .shepherd)
        if let host {
            if RemotePath.isValidHost(host) {
                virtualizeLegacyRemotePaths(host: host)
            } else {
                // Fail closed: a remote project must never fall back to local
                // path semantics (a same-path local repo would be operated
                // on), and the raw host must never reach ssh. The placeholder
                // never resolves, so the project stays visible but unavailable.
                let projectID = id
                projectConfigLogger.warning(
                    "Remote project \(projectID, privacy: .public) has an invalid ssh host \(host, privacy: .private); it is unavailable until re-added"
                )
                self.host = RemotePath.unavailableHost
                virtualizeLegacyRemotePaths(host: RemotePath.unavailableHost, replacing: host)
            }
        } else if RemotePath.isReserved(path) || cachedWorktrees.contains(where: { RemotePath.isReserved($0.path.path) }) {
            // A local project inside the reserved namespace would be routed
            // to an ssh host named after its next path component. Fail closed
            // the same way: it becomes unavailable, never local or remote.
            let (projectID, projectPath) = (id, path)
            projectConfigLogger.warning(
                "Local project \(projectID, privacy: .public) at \(projectPath, privacy: .private) is inside the reserved remote namespace; it is unavailable until re-added"
            )
            host = RemotePath.unavailableHost
            virtualizeLegacyRemotePaths(host: RemotePath.unavailableHost, wrappingReserved: true)
        }
    }

    /// Remote projects saved before virtual paths stored real remote paths.
    /// Move every path and worktree-id-keyed field under the host's virtual
    /// namespace; already-virtual values are left alone, except those under
    /// `replacedHost`, which move to `host`. With `wrappingReserved`, a local
    /// path inside the reserved namespace is itself the real path to wrap.
    private mutating func virtualizeLegacyRemotePaths(
        host: String,
        replacing replacedHost: String? = nil,
        wrappingReserved: Bool = false
    ) {
        let anchor = RemotePath.virtual(host: host, realPath: "/")
        var renamed: [String: String] = [:]
        func v(_ old: String) -> String {
            let new: String
            if wrappingReserved, old.hasPrefix("/"), RemotePath.split(old)?.host != host {
                new = RemotePath.virtual(host: host, realPath: old)
            } else {
                let real = RemotePath.split(old).flatMap { $0.host == replacedHost ? $0.realPath : nil } ?? old
                new = RemotePath.virtualizing(real, like: anchor)
            }
            if new != old { renamed[old] = new }
            return new
        }
        path = v(path)
        hiddenWorktreePaths = hiddenWorktreePaths.map(v)
        worktreeOrder = worktreeOrder.map(v)
        cachedWorktrees = cachedWorktrees.map { wt in
            Worktree(
                id: v(wt.id), projectId: wt.projectId, name: wt.name, branch: wt.branch,
                path: URL(fileURLWithPath: v(wt.path.path)), isMainWorktree: wt.isMainWorktree,
                status: wt.status, lastActivity: wt.lastActivity, createdAt: wt.createdAt,
                lineageID: wt.lineageID, addedLines: wt.addedLines, deletedLines: wt.deletedLines
            )
        }
        // A key present in both forms keeps the already-virtual (newer) value.
        func vKeys<Value>(_ dict: [String: Value]) -> [String: Value] {
            var out: [String: Value] = [:]
            for (key, value) in dict {
                let new = v(key)
                if new == key || out[new] == nil { out[new] = value }
            }
            return out
        }
        ggWorktreeModes = vKeys(ggWorktreeModes)
        issueAttachments = vKeys(issueAttachments)
        pendingAutoBranchNames = vKeys(pendingAutoBranchNames)
        legacyWorktreeIDs.merge(renamed) { _, new in new }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(icon.color, forKey: .color)
        try c.encode(icon, forKey: .icon)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(hiddenWorktreePaths, forKey: .hiddenWorktreePaths)
        try c.encode(worktreeOrder, forKey: .worktreeOrder)
        try c.encode(cachedWorktrees, forKey: .cachedWorktrees)
        try c.encode(worktreeOrderIsManual, forKey: .worktreeOrderIsManual)
        try c.encode(startupScripts, forKey: .startupScripts)
        try c.encode(mcpServers, forKey: .mcpServers)
        try c.encodeIfPresent(worktreeOpenAfterCreate, forKey: .worktreeOpenAfterCreate)
        try c.encodeIfPresent(worktreeDefaultLauncherMode, forKey: .worktreeDefaultLauncherMode)
        try c.encodeIfPresent(worktreeLaunchPreference, forKey: .worktreeLaunchPreference)
        try c.encodeIfPresent(worktreeBranchTemplate, forKey: .worktreeBranchTemplate)
        try c.encodeIfPresent(host, forKey: .host)
        if kind != .git {
            try c.encode(kind, forKey: .kind)
        }
        try c.encode(ggMode, forKey: .ggMode)
        let sparseGGWorktreeModes = ggWorktreeModes.filter { $0.value != .inherit }
        if !sparseGGWorktreeModes.isEmpty {
            try c.encode(sparseGGWorktreeModes, forKey: .ggWorktreeModes)
        }
        if !issueAttachments.isEmpty {
            try c.encode(issueAttachments, forKey: .issueAttachments)
        }
        if !pendingAutoBranchNames.isEmpty {
            try c.encode(pendingAutoBranchNames, forKey: .pendingAutoBranchNames)
        }
        if !fileBookmarks.isEmpty {
            try c.encode(fileBookmarks, forKey: .fileBookmarks)
        }
        if !repoMCPTrust.isEmpty {
            try c.encode(repoMCPTrust, forKey: .repoMCPTrust)
        }
        if !disabledRepoMCPServers.isEmpty {
            try c.encode(disabledRepoMCPServers, forKey: .disabledRepoMCPServers)
        }
        let approvedRepoHookHashes = Array(Set(approvedRepoHookHashes)).sorted()
        if !approvedRepoHookHashes.isEmpty {
            try c.encode(approvedRepoHookHashes, forKey: .approvedRepoHookHashes)
        }
        if !legacyWorktreeIDs.isEmpty {
            try c.encode(legacyWorktreeIDs, forKey: .pendingLegacyWorktreeIDs)
        }
        if let shepherd, !shepherd.isEmpty {
            try c.encode(shepherd, forKey: .shepherd)
        }
    }

    public var effectiveWorktreeLaunchPreference: CreationLaunchPreference {
        worktreeLaunchPreference ?? .init(
            openAfterCreate: worktreeOpenAfterCreate,
            launcherMode: worktreeDefaultLauncherMode
        )
    }

    public mutating func setWorktreeLaunchPreference(_ preference: CreationLaunchPreference) {
        worktreeLaunchPreference = preference
        worktreeOpenAfterCreate = preference.openAfterCreate
        worktreeDefaultLauncherMode = preference.launcherMode
    }
}
