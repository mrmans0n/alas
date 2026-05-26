import Foundation

struct SidebarChromeOverride: Codable, Equatable {
    var backgroundOpacity: Double  // 0...1
    var textContrast: Double       // 0...1

    static let bundledDefaults: [String: SidebarChromeOverride] = [
        "cool-slate": SidebarChromeOverride(backgroundOpacity: 0.25, textContrast: 0.15),
        "light":      SidebarChromeOverride(backgroundOpacity: 0.25, textContrast: 0.15),
    ]

    static let zero = SidebarChromeOverride(backgroundOpacity: 0, textContrast: 0)
}

struct AppConfig: Codable, Equatable {
    var themeId: String
    var accent: String
    var matchSystemTheme: Bool
    var sidebarMaterial: SidebarMaterialChoice
    var sidebarWidth: Double
    var rightPaneWidth: Double
    var rightPaneVisible: Bool
    var sidebarVisible: Bool
    var commitDetailSplitRatio: Double
    var general: General
    var worktrees: Worktrees
    var terminal: Terminal
    var harness: Harness
    var code: Code
    var markdown: Markdown
    var changes: Changes
    var agents: Agents
    var files: Files
    var recentProjectIds: [String] = []
    var recentWorktreeIdsByProject: [String: [String]] = [:]
    var recentWorktreeRefs: [RepoSelectorRecents.RecentWorktreeRef] = []
    var sidebarChromeOverrides: [String: SidebarChromeOverride] = [:]
    var shortcutOverrides: [String: ShortcutBinding?] = [:]

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
        var syncTabTitleWithTerminalTitle: Bool

        enum CodingKeys: String, CodingKey {
            case shell, workingDirectory, startupScript, worktreeCreateScript,
                 inheritParentEnv, fontFamily, fontSize, cursorStyle, cursorBlink,
                 scrollbackLines, bell, syncTabTitleWithTerminalTitle
        }
    }

    struct Harness: Codable, Equatable {
        var notifyOnFinish: Bool
        var notifyOnAwaiting: Bool
        var dismissedHookInstallNudges: [String]

        enum CodingKeys: String, CodingKey {
            case notifyOnFinish, notifyOnAwaiting, dismissedHookInstallNudges
        }

        init(notifyOnFinish: Bool, notifyOnAwaiting: Bool, dismissedHookInstallNudges: [String] = []) {
            self.notifyOnFinish = notifyOnFinish
            self.notifyOnAwaiting = notifyOnAwaiting
            self.dismissedHookInstallNudges = dismissedHookInstallNudges
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notifyOnFinish = (try? c.decode(Bool.self, forKey: .notifyOnFinish)) ?? true
            notifyOnAwaiting = (try? c.decode(Bool.self, forKey: .notifyOnAwaiting)) ?? true
            dismissedHookInstallNudges = (try? c.decode([String].self, forKey: .dismissedHookInstallNudges)) ?? []
        }
    }

    struct Code: Codable, Equatable {
        var fontFamily: String      // "" = system monospaced fallback
        var fontSize: Int           // clamped [8, 64] on decode/write
        var formatOnSave: Bool
        var showLineNumbers: Bool
        var languageServers: [LanguageServerConfig]
        var dismissedInstallNudges: [String]
        var userDefinedRecipes: [String: [InstallRecipe]]

        enum CodingKeys: String, CodingKey {
            case fontFamily, fontSize, formatOnSave, showLineNumbers,
                 languageServers, dismissedInstallNudges, userDefinedRecipes
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
        /// Workspace-level "fix every merge conflict in this repo"
        /// prompt fed to the agent CWD'd at the worktree. The agent
        /// uses its own filesystem tools to enumerate + reconcile.
        var mergeBulkResolvePrompt: String
        /// Single-file resolve template — the instructions portion
        /// only. The three sides (LOCAL/BASE/REMOTE/MERGED) are
        /// appended verbatim by `MergeAgent`. `{filePath}` and
        /// `{language}` are substituted; anything else passes through.
        var mergeSingleResolvePrompt: String

        enum CodingKeys: String, CodingKey {
            case aiToolId, prompt, mergeBulkResolvePrompt, mergeSingleResolvePrompt
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

    struct Files: Codable, Equatable {
        var showIgnored: Bool

        enum CodingKeys: String, CodingKey {
            case showIgnored
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
        matchSystemTheme: false,
        sidebarMaterial: .appKitSidebar,
        sidebarWidth: 244,
        rightPaneWidth: 320,
        rightPaneVisible: true,
        sidebarVisible: true,
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
            bell: "visual",
            syncTabTitleWithTerminalTitle: false
        ),
        harness: Harness(notifyOnFinish: true, notifyOnAwaiting: true),
        code: Code(
            fontFamily: "SF Mono",
            fontSize: 13,
            formatOnSave: false,
            showLineNumbers: true,
            languageServers: [],
            dismissedInstallNudges: [],
            userDefinedRecipes: [:]
        ),
        markdown: Markdown(defaultViewMode: .editor),
        changes: Changes(
            aiToolId: "none",
            prompt: AppConfig.defaultCommitPrompt,
            mergeBulkResolvePrompt: AppConfig.defaultMergeBulkResolvePrompt,
            mergeSingleResolvePrompt: AppConfig.defaultMergeSingleResolvePrompt
        ),
        agents: Agents(
            builtinState: [:],
            custom: [],
            worktreeAutoLaunch: WorktreeAutoLaunch(
                agentId: nil,
                useBypassPermissions: false
            )
        ),
        files: Files(showIgnored: true),
        recentProjectIds: [],
        recentWorktreeIdsByProject: [:],
        recentWorktreeRefs: [],
        sidebarChromeOverrides: SidebarChromeOverride.bundledDefaults,
        shortcutOverrides: [:]
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

    static let defaultMergeBulkResolvePrompt = """
    You are resolving every Git merge conflict in this workspace.

    Procedure:
    1. Run `git status` to list conflicted files (entries marked UU, AA, AU, UA).
    2. For each text conflict, read the file. Use the surrounding code,
       tests, and related files for context — that's the whole point of
       doing this in-workspace rather than file-by-file in isolation.
    3. Reconcile LOCAL and REMOTE intent into the smallest correct merged
       file. Remove ALL conflict markers (<<<<<<<, |||||||, =======,
       >>>>>>>) and any zdiff3 BASE blocks. Write the resolved file back.
    4. For binary files, assume LOCAL (ours) is the source of truth: run
       `git checkout --ours -- <path>` to drop the remote side.
    5. Stage each resolved file with `git add <path>`.

    Skip:
    - Delete-side conflicts (deleted by us / deleted by them / both deleted)
      — the user picks Keep ours / theirs / deleted in the UI.

    Do NOT commit. Do NOT abort or continue the in-progress merge / rebase
    / cherry-pick — the user drives those from the UI after reviewing.

    When done, print a short summary: which files you resolved and which
    you skipped or couldn't reconcile, with one line per file.
    """

    static let defaultMergeSingleResolvePrompt = """
    You are resolving a Git merge conflict in {filePath}.
    Language: {language}
    Reconcile LOCAL and REMOTE intent into the smallest correct merged file.
    Output ONLY the resolved file contents — no conflict markers, no prose,
    no markdown fences, no commentary.
    """
}

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case themeId, accent, matchSystemTheme,
             sidebarMaterial, sidebarWidth, rightPaneWidth, rightPaneVisible, sidebarVisible,
             commitDetailSplitRatio,
             general, worktrees, terminal, harness, code, markdown, changes,
             agents,
             files,
             recentProjectIds, recentWorktreeIdsByProject, recentWorktreeRefs,
             sidebarChromeOverrides,
             shortcutOverrides
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
        matchSystemTheme = try c.decode(Bool.self, forKey: .matchSystemTheme)
        sidebarMaterial = (try? c.decode(SidebarMaterialChoice.self, forKey: .sidebarMaterial)) ?? .appKitFullScreenUI
        sidebarWidth = try c.decode(Double.self, forKey: .sidebarWidth)
        rightPaneWidth = try c.decode(Double.self, forKey: .rightPaneWidth)
        rightPaneVisible = try c.decode(Bool.self, forKey: .rightPaneVisible)
        sidebarVisible = (try? c.decode(Bool.self, forKey: .sidebarVisible)) ?? true
        commitDetailSplitRatio = (try? c.decode(Double.self, forKey: .commitDetailSplitRatio)) ?? 0.32
        general = try c.decode(General.self, forKey: .general)
        worktrees = try c.decode(Worktrees.self, forKey: .worktrees)
        if let termContainer = try? c.nestedContainer(keyedBy: AppConfig.Terminal.CodingKeys.self, forKey: .terminal) {
            let shell = (try? termContainer.decode(String.self, forKey: .shell)) ?? "/bin/zsh"
            let workingDirectory = (try? termContainer.decode(String.self, forKey: .workingDirectory)) ?? "worktreeRoot"
            let startupScript = (try? termContainer.decode(String.self, forKey: .startupScript)) ?? ""
            let worktreeCreateScript = (try? termContainer.decode(String.self, forKey: .worktreeCreateScript)) ?? ""
            let inheritParentEnv = (try? termContainer.decode(Bool.self, forKey: .inheritParentEnv)) ?? true
            let fontFamily = (try? termContainer.decode(String.self, forKey: .fontFamily)) ?? "JetBrains Mono"
            let fontSize = (try? termContainer.decode(Int.self, forKey: .fontSize)) ?? 13
            let cursorStyle = (try? termContainer.decode(String.self, forKey: .cursorStyle)) ?? "beam"
            let cursorBlink = (try? termContainer.decode(Bool.self, forKey: .cursorBlink)) ?? true
            let scrollbackLines = (try? termContainer.decode(Int.self, forKey: .scrollbackLines)) ?? 10000
            let bell = (try? termContainer.decode(String.self, forKey: .bell)) ?? "visual"
            let syncTabTitleWithTerminalTitle = (try? termContainer.decode(Bool.self, forKey: .syncTabTitleWithTerminalTitle)) ?? false
            terminal = Terminal(
                shell: shell,
                workingDirectory: workingDirectory,
                startupScript: startupScript,
                worktreeCreateScript: worktreeCreateScript,
                inheritParentEnv: inheritParentEnv,
                fontFamily: fontFamily,
                fontSize: fontSize,
                cursorStyle: cursorStyle,
                cursorBlink: cursorBlink,
                scrollbackLines: scrollbackLines,
                bell: bell,
                syncTabTitleWithTerminalTitle: syncTabTitleWithTerminalTitle
            )
        } else {
            terminal = Terminal(
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
                bell: "visual",
                syncTabTitleWithTerminalTitle: false
            )
        }
        harness = try c.decode(Harness.self, forKey: .harness)
        if let codeContainer = try? c.nestedContainer(keyedBy: AppConfig.Code.CodingKeys.self, forKey: .code) {
            let fontFamily = (try? codeContainer.decode(String.self, forKey: .fontFamily)) ?? "SF Mono"
            let rawSize = (try? codeContainer.decode(Int.self, forKey: .fontSize)) ?? 13
            let fontSize = max(8, min(64, rawSize))
            let formatOnSave = (try? codeContainer.decode(Bool.self, forKey: .formatOnSave)) ?? false
            let showLineNumbers = (try? codeContainer.decode(Bool.self, forKey: .showLineNumbers)) ?? true
            let servers = (try? codeContainer.decode([LanguageServerConfig].self, forKey: .languageServers)) ?? []
            let dismissed = (try? codeContainer.decode([String].self, forKey: .dismissedInstallNudges)) ?? []
            let userRecipes = (try? codeContainer.decode([String: [InstallRecipe]].self, forKey: .userDefinedRecipes)) ?? [:]
            code = Code(
                fontFamily: fontFamily,
                fontSize: fontSize,
                formatOnSave: formatOnSave,
                showLineNumbers: showLineNumbers,
                languageServers: servers,
                dismissedInstallNudges: dismissed,
                userDefinedRecipes: userRecipes
            )
        } else {
            code = Code(
                fontFamily: "SF Mono",
                fontSize: 13,
                formatOnSave: false,
                showLineNumbers: true,
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
            let bulkResolve = (try? changesContainer.decode(String.self, forKey: .mergeBulkResolvePrompt))
                ?? AppConfig.defaultMergeBulkResolvePrompt
            let singleResolve = (try? changesContainer.decode(String.self, forKey: .mergeSingleResolvePrompt))
                ?? AppConfig.defaultMergeSingleResolvePrompt
            changes = Changes(
                aiToolId: toolId,
                prompt: prompt,
                mergeBulkResolvePrompt: bulkResolve,
                mergeSingleResolvePrompt: singleResolve
            )
        } else {
            changes = Changes(
                aiToolId: "none",
                prompt: AppConfig.defaultCommitPrompt,
                mergeBulkResolvePrompt: AppConfig.defaultMergeBulkResolvePrompt,
                mergeSingleResolvePrompt: AppConfig.defaultMergeSingleResolvePrompt
            )
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
        if let filesContainer = try? c.nestedContainer(
            keyedBy: AppConfig.Files.CodingKeys.self, forKey: .files
        ) {
            let showIgnored = (try? filesContainer.decode(Bool.self, forKey: .showIgnored)) ?? true
            files = Files(showIgnored: showIgnored)
        } else {
            files = Files(showIgnored: true)
        }
        recentProjectIds = (try? c.decode([String].self, forKey: .recentProjectIds)) ?? []
        recentWorktreeIdsByProject =
            (try? c.decode([String: [String]].self, forKey: .recentWorktreeIdsByProject)) ?? [:]
        recentWorktreeRefs =
            (try? c.decode([RepoSelectorRecents.RecentWorktreeRef].self, forKey: .recentWorktreeRefs)) ?? []
        sidebarChromeOverrides =
            (try? c.decode([String: SidebarChromeOverride].self, forKey: .sidebarChromeOverrides)) ?? [:]
        shortcutOverrides =
            (try? c.decode([String: ShortcutBinding?].self, forKey: .shortcutOverrides)) ?? [:]
    }
}

extension AppConfig {
    func sidebarChromeOverride(forThemeId themeId: String) -> SidebarChromeOverride {
        if let saved = sidebarChromeOverrides[themeId] { return saved }
        return SidebarChromeOverride.bundledDefaults[themeId] ?? .zero
    }
}
