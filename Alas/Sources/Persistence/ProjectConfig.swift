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
    var color: String        // hex string, e.g. "#5fb7c4"
    var addedAt: Date
    var hiddenWorktreePaths: [String] = []
    var worktreeOrder: [String] = []
    /// Explicit signal that the user dragged worktrees into a custom order.
    /// When `false`, the global default sort mode applies regardless of any
    /// legacy `worktreeOrder` left on disk. Set to `true` by drag reorders;
    /// cleared by "Reset Sort to Default".
    var worktreeOrderIsManual: Bool = false
    var startupScripts: ProjectStartupScripts = .defaults
    /// Per-project "open after create" preference. `nil` = use global default (true).
    var worktreeOpenAfterCreate: Bool?
    /// Per-project launcher mode preference. `nil` = use global default.
    var worktreeDefaultLauncherMode: AppConfig.LauncherMode?

    enum CodingKeys: String, CodingKey {
        case id, name, path, color, addedAt, hiddenWorktreePaths, worktreeOrder,
             worktreeOrderIsManual, startupScripts,
             worktreeOpenAfterCreate, worktreeDefaultLauncherMode
    }

    init(
        id: String,
        name: String,
        path: String,
        color: String,
        addedAt: Date,
        hiddenWorktreePaths: [String] = [],
        worktreeOrder: [String] = [],
        worktreeOrderIsManual: Bool = false,
        startupScripts: ProjectStartupScripts = .defaults,
        worktreeOpenAfterCreate: Bool? = nil,
        worktreeDefaultLauncherMode: AppConfig.LauncherMode? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.addedAt = addedAt
        self.hiddenWorktreePaths = hiddenWorktreePaths
        self.worktreeOrder = worktreeOrder
        self.worktreeOrderIsManual = worktreeOrderIsManual
        self.startupScripts = startupScripts
        self.worktreeOpenAfterCreate = worktreeOpenAfterCreate
        self.worktreeDefaultLauncherMode = worktreeDefaultLauncherMode
    }

    // Tolerant decode: older projects.json files predate hiddenWorktreePaths
    // and startupScripts, so fall back to known defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        color = try c.decode(String.self, forKey: .color)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        hiddenWorktreePaths = (try? c.decode([String].self, forKey: .hiddenWorktreePaths)) ?? []
        worktreeOrder = (try? c.decode([String].self, forKey: .worktreeOrder)) ?? []
        worktreeOrderIsManual = (try? c.decode(Bool.self, forKey: .worktreeOrderIsManual)) ?? false
        startupScripts = (try? c.decode(ProjectStartupScripts.self, forKey: .startupScripts))
            ?? .defaults
        worktreeOpenAfterCreate = try? c.decode(Bool.self, forKey: .worktreeOpenAfterCreate)
        worktreeDefaultLauncherMode = try? c.decode(AppConfig.LauncherMode.self, forKey: .worktreeDefaultLauncherMode)
    }
}
