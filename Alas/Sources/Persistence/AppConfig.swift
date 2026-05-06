import Foundation

struct AppConfig: Codable, Equatable {
    var themeId: String
    var accent: String
    var density: String          // compact | comfortable | spacious
    var matchSystemTheme: Bool
    var sidebarWidth: Double
    var rightPaneWidth: Double
    var rightPaneVisible: Bool
    var general: General
    var worktrees: Worktrees
    var terminal: Terminal
    var harness: Harness
    var code: Code

    struct General: Codable, Equatable {
        var launchAtLogin: Bool
        var closeToTray: Bool
        var confirmQuit: Bool
        var autoUpdate: Bool
        var updateChannel: String
        var crashReports: Bool
        var usageAnalytics: Bool
    }

    struct Worktrees: Codable, Equatable {
        var rootPath: String
        var pathTemplate: String
        var branchPrefix: String
        var baseBranch: String
        var trackUpstream: Bool
        var deleteBranchOnRemove: Bool
        var autoFetch: Bool
        var fetchIntervalMinutes: Int
        var pruneStale: Bool
    }

    struct Terminal: Codable, Equatable {
        var shell: String
        var workingDirectory: String     // worktreeRoot | repoRoot | lastUsed
        var startupScript: String
        var worktreeCreateScript: String
        var inheritParentEnv: Bool
        var fontFamily: String
        var fontSize: Int
        var cursorStyle: String          // block | beam | underline
        var cursorBlink: Bool
        var scrollbackLines: Int
        var bell: String                 // off | visual | sound
    }

    struct Harness: Codable, Equatable {
        var notifyOnFinish: Bool
    }

    struct Code: Codable, Equatable {
        var languageServers: [LanguageServerConfig]
    }

    static let defaults = AppConfig(
        themeId: "cool-slate",
        accent: "teal",
        density: "comfortable",
        matchSystemTheme: false,
        sidebarWidth: 244,
        rightPaneWidth: 320,
        rightPaneVisible: true,
        general: General(
            launchAtLogin: false, closeToTray: true, confirmQuit: true,
            autoUpdate: true, updateChannel: "Stable",
            crashReports: false, usageAnalytics: false
        ),
        worktrees: Worktrees(
            rootPath: "~/code/.worktrees",
            pathTemplate: "{worktreeRoot}/{repo}/{branch}",
            branchPrefix: "feature/",
            baseBranch: "main",
            trackUpstream: true,
            deleteBranchOnRemove: true,
            autoFetch: true,
            fetchIntervalMinutes: 5,
            pruneStale: false
        ),
        terminal: Terminal(
            shell: "/bin/zsh",
            workingDirectory: "worktreeRoot",
            startupScript: "",
            worktreeCreateScript: "",
            inheritParentEnv: true,
            fontFamily: "JetBrains Mono",
            fontSize: 13,
            cursorStyle: "beam",
            cursorBlink: true,
            scrollbackLines: 10000,
            bell: "visual"
        ),
        harness: Harness(notifyOnFinish: true),
        code: Code(languageServers: [])
    )
}

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case themeId, accent, density, matchSystemTheme,
             sidebarWidth, rightPaneWidth, rightPaneVisible,
             general, worktrees, terminal, harness, code
    }

    // Custom decode tolerates older config files that predate `code`.
    // Swift still synthesizes encode(to:) automatically.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        themeId = try c.decode(String.self, forKey: .themeId)
        accent = try c.decode(String.self, forKey: .accent)
        density = try c.decode(String.self, forKey: .density)
        matchSystemTheme = try c.decode(Bool.self, forKey: .matchSystemTheme)
        sidebarWidth = try c.decode(Double.self, forKey: .sidebarWidth)
        rightPaneWidth = try c.decode(Double.self, forKey: .rightPaneWidth)
        rightPaneVisible = try c.decode(Bool.self, forKey: .rightPaneVisible)
        general = try c.decode(General.self, forKey: .general)
        worktrees = try c.decode(Worktrees.self, forKey: .worktrees)
        terminal = try c.decode(Terminal.self, forKey: .terminal)
        harness = try c.decode(Harness.self, forKey: .harness)
        code = (try c.decodeIfPresent(Code.self, forKey: .code)) ?? Code(languageServers: [])
    }
}
