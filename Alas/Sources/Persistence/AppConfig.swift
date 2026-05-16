import Foundation

struct AppConfig: Codable, Equatable {
    var themeId: String
    var accent: String
    var density: String          // compact | comfortable | spacious
    var matchSystemTheme: Bool
    var sidebarMaterial: SidebarMaterialChoice
    var sidebarWidth: Double
    var rightPaneWidth: Double
    var rightPaneVisible: Bool
    var commitDetailSplitRatio: Double
    var general: General
    var worktrees: Worktrees
    var terminal: Terminal
    var harness: Harness
    var code: Code
    var markdown: Markdown
    var changes: Changes
    var agents: Agents

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
        var notifyOnAwaiting: Bool

        enum CodingKeys: String, CodingKey {
            case notifyOnFinish, notifyOnAwaiting
        }

        init(notifyOnFinish: Bool, notifyOnAwaiting: Bool) {
            self.notifyOnFinish = notifyOnFinish
            self.notifyOnAwaiting = notifyOnAwaiting
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notifyOnFinish = (try? c.decode(Bool.self, forKey: .notifyOnFinish)) ?? true
            notifyOnAwaiting = (try? c.decode(Bool.self, forKey: .notifyOnAwaiting)) ?? true
        }
    }

    struct Code: Codable, Equatable {
        var fontFamily: String      // "" = system monospaced fallback
        var fontSize: Int           // clamped [8, 64] on decode/write
        var languageServers: [LanguageServerConfig]
        var dismissedInstallNudges: [String]
        var userDefinedRecipes: [String: [InstallRecipe]]

        enum CodingKeys: String, CodingKey {
            case fontFamily, fontSize, languageServers, dismissedInstallNudges, userDefinedRecipes
        }
    }

    struct Markdown: Codable, Equatable {
        var defaultViewMode: MarkdownViewMode

        enum CodingKeys: String, CodingKey {
            case defaultViewMode
        }
    }

    struct Changes: Codable, Equatable {
        var aiToolId: String   // "claude" | "codex" | "cursor-agent" | "pi" | "none"
        var prompt: String

        enum CodingKeys: String, CodingKey {
            case aiToolId, prompt
        }
    }

    struct Agents: Codable, Equatable {
        var builtinState: [String: BuiltinAgentState]
        var custom: [AgentDefinition]
        var worktreeAutoLaunch: WorktreeAutoLaunch

        enum CodingKeys: String, CodingKey {
            case builtinState, custom, worktreeAutoLaunch
        }
    }

    struct WorktreeAutoLaunch: Codable, Equatable {
        var agentId: String?
        var useBypassPermissions: Bool

        enum CodingKeys: String, CodingKey {
            case agentId, useBypassPermissions
        }
    }

    static let defaults = AppConfig(
        themeId: "cool-slate",
        accent: "teal",
        density: "comfortable",
        matchSystemTheme: false,
        sidebarMaterial: .appKitSidebar,
        sidebarWidth: 244,
        rightPaneWidth: 320,
        rightPaneVisible: true,
        commitDetailSplitRatio: 0.32,
        general: General(
            launchAtLogin: false, closeToTray: true, confirmQuit: true,
            autoUpdate: true, updateChannel: "Stable",
            crashReports: false, usageAnalytics: false
        ),
        worktrees: Worktrees(
            rootPath: "~/.alas/worktrees",
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
        harness: Harness(notifyOnFinish: true, notifyOnAwaiting: true),
        code: Code(
            fontFamily: "SF Mono",
            fontSize: 13,
            languageServers: [],
            dismissedInstallNudges: [],
            userDefinedRecipes: [:]
        ),
        markdown: Markdown(defaultViewMode: .editor),
        changes: Changes(aiToolId: "none", prompt: AppConfig.defaultCommitPrompt),
        agents: Agents(
            builtinState: [:],
            custom: [],
            worktreeAutoLaunch: WorktreeAutoLaunch(
                agentId: nil,
                useBypassPermissions: false
            )
        )
    )
}

extension AppConfig {
    static let defaultCommitPrompt = """
    You are writing a git commit message for the staged changes shown below.

    Output format — strict:
      Line 1: short imperative subject (≤ 72 chars, no trailing period).
      Line 2: blank.
      Line 3+: optional body, wrapped at ~72 chars, explaining the why
               rather than restating the diff. Bulleted list is fine.

    Match the style of the recent commit subjects in the context header
    (prefixes like `feat:`, `fix:`, etc. if the repo uses them).

    Do not include any preamble, explanation, code fences, or markdown
    headers. Output only the commit message.

    When amending, the previous commit's message is provided — prefer
    refining it over starting from scratch unless the diff has materially
    changed.
    """
}

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case themeId, accent, density, matchSystemTheme,
             sidebarMaterial, sidebarWidth, rightPaneWidth, rightPaneVisible,
             commitDetailSplitRatio,
             general, worktrees, terminal, harness, code, markdown, changes,
             agents
    }

    // Custom decode tolerates older config files that predate `code`.
    // Swift still synthesizes encode(to:) automatically.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawThemeId = try c.decode(String.self, forKey: .themeId)
        // Migrate stale themeIds from versions that shipped warm-amber and
        // neutral. We now ship only cool-slate and light, so anything else
        // collapses to the dark default.
        themeId = (rawThemeId == "warm-amber" || rawThemeId == "neutral") ? "cool-slate" : rawThemeId
        accent = try c.decode(String.self, forKey: .accent)
        density = try c.decode(String.self, forKey: .density)
        matchSystemTheme = try c.decode(Bool.self, forKey: .matchSystemTheme)
        sidebarMaterial = (try? c.decode(SidebarMaterialChoice.self, forKey: .sidebarMaterial)) ?? .appKitFullScreenUI
        sidebarWidth = try c.decode(Double.self, forKey: .sidebarWidth)
        rightPaneWidth = try c.decode(Double.self, forKey: .rightPaneWidth)
        rightPaneVisible = try c.decode(Bool.self, forKey: .rightPaneVisible)
        commitDetailSplitRatio = (try? c.decode(Double.self, forKey: .commitDetailSplitRatio)) ?? 0.32
        general = try c.decode(General.self, forKey: .general)
        worktrees = try c.decode(Worktrees.self, forKey: .worktrees)
        terminal = try c.decode(Terminal.self, forKey: .terminal)
        harness = try c.decode(Harness.self, forKey: .harness)
        if let codeContainer = try? c.nestedContainer(keyedBy: AppConfig.Code.CodingKeys.self, forKey: .code) {
            let fontFamily = (try? codeContainer.decode(String.self, forKey: .fontFamily)) ?? "SF Mono"
            let rawSize = (try? codeContainer.decode(Int.self, forKey: .fontSize)) ?? 13
            let fontSize = max(8, min(64, rawSize))
            let servers = (try? codeContainer.decode([LanguageServerConfig].self, forKey: .languageServers)) ?? []
            let dismissed = (try? codeContainer.decode([String].self, forKey: .dismissedInstallNudges)) ?? []
            let userRecipes = (try? codeContainer.decode([String: [InstallRecipe]].self, forKey: .userDefinedRecipes)) ?? [:]
            code = Code(
                fontFamily: fontFamily,
                fontSize: fontSize,
                languageServers: servers,
                dismissedInstallNudges: dismissed,
                userDefinedRecipes: userRecipes
            )
        } else {
            code = Code(
                fontFamily: "SF Mono",
                fontSize: 13,
                languageServers: [],
                dismissedInstallNudges: [],
                userDefinedRecipes: [:]
            )
        }
        if let mdContainer = try? c.nestedContainer(keyedBy: AppConfig.Markdown.CodingKeys.self, forKey: .markdown) {
            let raw = (try? mdContainer.decode(String.self, forKey: .defaultViewMode)) ?? "editor"
            let mode = MarkdownViewMode(rawValue: raw) ?? .editor
            markdown = Markdown(defaultViewMode: mode)
        } else {
            markdown = Markdown(defaultViewMode: .editor)
        }
        if let changesContainer = try? c.nestedContainer(keyedBy: AppConfig.Changes.CodingKeys.self, forKey: .changes) {
            let toolId = (try? changesContainer.decode(String.self, forKey: .aiToolId)) ?? "none"
            let prompt = (try? changesContainer.decode(String.self, forKey: .prompt)) ?? AppConfig.defaultCommitPrompt
            changes = Changes(aiToolId: toolId, prompt: prompt)
        } else {
            changes = Changes(aiToolId: "none", prompt: AppConfig.defaultCommitPrompt)
        }
        if let agentsContainer = try? c.nestedContainer(
            keyedBy: AppConfig.Agents.CodingKeys.self, forKey: .agents
        ) {
            let state = (try? agentsContainer.decode(
                [String: BuiltinAgentState].self, forKey: .builtinState
            )) ?? [:]
            let custom = (try? agentsContainer.decode(
                [AgentDefinition].self, forKey: .custom
            )) ?? []
            let autoLaunch = (try? agentsContainer.decode(
                WorktreeAutoLaunch.self, forKey: .worktreeAutoLaunch
            )) ?? WorktreeAutoLaunch(agentId: nil, useBypassPermissions: false)
            agents = Agents(
                builtinState: state,
                custom: custom,
                worktreeAutoLaunch: autoLaunch
            )
        } else {
            agents = Agents(
                builtinState: [:],
                custom: [],
                worktreeAutoLaunch: WorktreeAutoLaunch(
                    agentId: nil, useBypassPermissions: false
                )
            )
        }
    }
}
