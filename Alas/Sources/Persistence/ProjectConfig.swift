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
/// Per-repository startup-script configuration for terminal session open and
/// worktree creation. Global settings in `AppConfig.Terminal` act as defaults.
struct ProjectStartupScripts: Codable, Equatable {
    var sessionOpenMode: ProjectStartupScriptMode
    var sessionOpenScript: String
    var worktreeCreateMode: ProjectStartupScriptMode
    var worktreeCreateScript: String

    static let defaults = ProjectStartupScripts(
        sessionOpenMode: .useGlobal,
        sessionOpenScript: "",
        worktreeCreateMode: .useGlobal,
        worktreeCreateScript: ""
    )
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
    var startupScripts: ProjectStartupScripts = .defaults

    enum CodingKeys: String, CodingKey {
        case id, name, path, color, addedAt, hiddenWorktreePaths, worktreeOrder, startupScripts
    }

    init(
        id: String,
        name: String,
        path: String,
        color: String,
        addedAt: Date,
        hiddenWorktreePaths: [String] = [],
        worktreeOrder: [String] = [],
        startupScripts: ProjectStartupScripts = .defaults
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.addedAt = addedAt
        self.hiddenWorktreePaths = hiddenWorktreePaths
        self.worktreeOrder = worktreeOrder
        self.startupScripts = startupScripts
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
        startupScripts = (try? c.decode(ProjectStartupScripts.self, forKey: .startupScripts))
            ?? .defaults
    }
}
