import Foundation

// MARK: - ProjectStartupScriptMode
/// How a project's per-repository startup script combines with the global default.
enum ProjectStartupScriptMode: String, Codable, Equatable, CaseIterable {
    case useGlobal
    case appendToGlobal
    case overrideGlobal
    case disabled
}

// MARK: - ProjectStartupScripts
/// Per-repository startup-script configuration for terminal session open,
/// worktree creation, and worktree agent override.
/// Global settings in `AppConfig.Terminal` act as defaults.
struct ProjectStartupScripts: Codable, Equatable {
    var sessionOpenMode: ProjectStartupScriptMode
    var sessionOpenScript: String
    var worktreeCreateMode: ProjectStartupScriptMode
    var worktreeCreateScript: String
    var worktreeAgentMode: ProjectStartupScriptMode
    var worktreeAgentId: String?
    var worktreeAgentUseBypassPermissions: Bool

    static let defaults = ProjectStartupScripts(
        sessionOpenMode: .useGlobal,
        sessionOpenScript: "",
        worktreeCreateMode: .useGlobal,
        worktreeCreateScript: ""
    )

    enum CodingKeys: String, CodingKey {
        case sessionOpenMode, sessionOpenScript,
             worktreeCreateMode, worktreeCreateScript,
             worktreeAgentMode, worktreeAgentId,
             worktreeAgentUseBypassPermissions
    }

    init(
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

    init(from decoder: Decoder) throws {
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
struct ProjectsFile: Codable, Equatable {
    var version: Int = 1
    var projects: [ProjectConfig]
}

// MARK: - ProjectConfig
struct ProjectConfig: Codable, Equatable, Identifiable {
    let id: String           // UUID string
    var name: String         // display name, defaulting to the repo directory name
    var path: String         // absolute repo path
    var icon: ProjectIcon
    var color: String {      // legacy compatibility mirror
        get { icon.color }
        set { icon = icon.withColor(newValue) }
    }
    var addedAt: Date
    var hiddenWorktreePaths: [String] = []
    var worktreeOrder: [String] = []
    var cachedWorktrees: [Worktree] = []
    /// Explicit signal that the user dragged worktrees into a custom order.
    /// When `false`, the global default sort mode applies regardless of any
    /// legacy `worktreeOrder` left on disk. Set to `true` by drag reorders;
    /// cleared by "Reset Sort to Default".
    var worktreeOrderIsManual: Bool = false
    var startupScripts: ProjectStartupScripts = .defaults
    var mcpServers: [ProjectMCPServer] = []
    /// Per-project "open after create" preference. `nil` = use global default (true).
    var worktreeOpenAfterCreate: Bool?
    /// Per-project launcher mode preference. `nil` = use global default.
    var worktreeDefaultLauncherMode: AppConfig.LauncherMode?
    /// Typed successor to the legacy launch fields. Nil keeps old files and
    /// callers behaviorally identical; decoding derives its effective value.
    var worktreeLaunchPreference: CreationLaunchPreference?
    /// SSH destination when this project lives on another machine.
    var host: String?
    /// Per-project stacked-diffs (gg) mode. Defaults to `.auto`.
    var ggMode: GGProjectMode = .auto
    /// Sparse per-worktree overrides. Missing entries inherit project policy.
    var ggWorktreeModes: [String: GGWorktreeMode] = [:]
    /// Sparse Issue attachments, keyed by worktree ID.
    var issueAttachments: [String: IssueAttachment] = [:]

    enum CodingKeys: String, CodingKey {
        case id, name, path, color, icon, addedAt, hiddenWorktreePaths, worktreeOrder,
             cachedWorktrees, worktreeOrderIsManual, startupScripts,
             mcpServers, worktreeOpenAfterCreate, worktreeDefaultLauncherMode, worktreeLaunchPreference, host, ggMode,
             ggWorktreeModes, issueAttachments
    }

    init(
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
        host: String? = nil,
        ggMode: GGProjectMode = .auto,
        ggWorktreeModes: [String: GGWorktreeMode] = [:],
        issueAttachments: [String: IssueAttachment] = [:]
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
        self.host = host
        self.ggMode = ggMode
        self.ggWorktreeModes = ggWorktreeModes
        self.issueAttachments = issueAttachments
    }

    // Tolerant decode: older projects.json files predate hiddenWorktreePaths
    // and startupScripts, so fall back to known defaults.
    init(from decoder: Decoder) throws {
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
        if worktreeLaunchPreference == nil,
           worktreeOpenAfterCreate != nil || worktreeDefaultLauncherMode != nil {
            worktreeLaunchPreference = .init(
                openAfterCreate: worktreeOpenAfterCreate,
                launcherMode: worktreeDefaultLauncherMode
            )
        }
        host = try? c.decode(String.self, forKey: .host)
        ggMode = (try? c.decode(GGProjectMode.self, forKey: .ggMode)) ?? .auto
        ggWorktreeModes = (try? c.decode([String: GGWorktreeMode].self, forKey: .ggWorktreeModes)) ?? [:]
        issueAttachments = (try? c.decode([String: IssueAttachment].self, forKey: .issueAttachments)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
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
        try c.encodeIfPresent(host, forKey: .host)
        try c.encode(ggMode, forKey: .ggMode)
        let sparseGGWorktreeModes = ggWorktreeModes.filter { $0.value != .inherit }
        if !sparseGGWorktreeModes.isEmpty {
            try c.encode(sparseGGWorktreeModes, forKey: .ggWorktreeModes)
        }
        if !issueAttachments.isEmpty {
            try c.encode(issueAttachments, forKey: .issueAttachments)
        }
    }

    var effectiveWorktreeLaunchPreference: CreationLaunchPreference {
        worktreeLaunchPreference ?? .init(
            openAfterCreate: worktreeOpenAfterCreate,
            launcherMode: worktreeDefaultLauncherMode
        )
    }

    mutating func setWorktreeLaunchPreference(_ preference: CreationLaunchPreference) {
        worktreeLaunchPreference = preference
        worktreeOpenAfterCreate = preference.openAfterCreate
        worktreeDefaultLauncherMode = preference.launcherMode
    }
}
