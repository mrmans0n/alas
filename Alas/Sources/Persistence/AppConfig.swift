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

/// How the built-in "alas" MCP server is delivered to local ACP sessions.
/// stdio (default) is spawned by the agent harness; http is served by a
/// supervised `alas mcp --http` process the app manages, for harnesses that
/// restrict stdio MCP servers by policy.
enum AlasMCPTransport: String, Codable, Equatable {
    case stdio
    case http
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
    var remote: Remote = .init()
    var recentProjectIds: [String] = []
    var recentWorktreeIdsByProject: [String: [String]] = [:]
    var recentWorktreeRefs: [RepoSelectorRecents.RecentWorktreeRef] = []
    var collapsedProjectIds: [String] = []
    var sidebarChromeOverrides: [String: SidebarChromeOverride] = [:]
    var shortcutOverrides: [String: ShortcutBinding?] = [:]

    struct Remote: Codable, Equatable {
        var enabled: Bool = false
        var port: UInt16 = 0          // 0 = OS-assigned
        var allowedHosts: [String] = []
        var preferredAdvertisedHost: String? = nil

        init(
            enabled: Bool = false,
            port: UInt16 = 0,
            allowedHosts: [String] = [],
            preferredAdvertisedHost: String? = nil
        ) {
            self.enabled = enabled
            self.port = port
            self.allowedHosts = allowedHosts
            self.preferredAdvertisedHost = preferredAdvertisedHost
        }

        enum CodingKeys: String, CodingKey {
            case enabled, port, allowedHosts, preferredAdvertisedHost
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
            port = (try? c.decode(UInt16.self, forKey: .port)) ?? 0
            allowedHosts = (try? c.decode([String].self, forKey: .allowedHosts)) ?? []
            preferredAdvertisedHost = try? c.decodeIfPresent(String.self, forKey: .preferredAdvertisedHost)
        }
    }

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
        var fetchRemoteBeforeCreate: Bool
        var defaultOrdering: WorktreeSortMode

        enum CodingKeys: String, CodingKey {
            case rootPath, pathTemplate, branchPrefix, baseBranch,
                 trackUpstream, deleteBranchOnRemove, autoFetch,
                 fetchIntervalMinutes, pruneStale, fetchRemoteBeforeCreate,
                 defaultOrdering
        }

        init(
            rootPath: String,
            pathTemplate: String,
            branchPrefix: String,
            baseBranch: String,
            trackUpstream: Bool,
            deleteBranchOnRemove: Bool,
            autoFetch: Bool,
            fetchIntervalMinutes: Int,
            pruneStale: Bool,
            fetchRemoteBeforeCreate: Bool = false,
            defaultOrdering: WorktreeSortMode = .lastUpdateDesc
        ) {
            self.rootPath = rootPath
            self.pathTemplate = pathTemplate
            self.branchPrefix = branchPrefix
            self.baseBranch = baseBranch
            self.trackUpstream = trackUpstream
            self.deleteBranchOnRemove = deleteBranchOnRemove
            self.autoFetch = autoFetch
            self.fetchIntervalMinutes = fetchIntervalMinutes
            self.pruneStale = pruneStale
            self.fetchRemoteBeforeCreate = fetchRemoteBeforeCreate
            self.defaultOrdering = defaultOrdering
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rootPath = try c.decode(String.self, forKey: .rootPath)
            pathTemplate = try c.decode(String.self, forKey: .pathTemplate)
            branchPrefix = try c.decode(String.self, forKey: .branchPrefix)
            baseBranch = try c.decode(String.self, forKey: .baseBranch)
            trackUpstream = try c.decode(Bool.self, forKey: .trackUpstream)
            deleteBranchOnRemove = try c.decode(Bool.self, forKey: .deleteBranchOnRemove)
            autoFetch = try c.decode(Bool.self, forKey: .autoFetch)
            fetchIntervalMinutes = try c.decode(Int.self, forKey: .fetchIntervalMinutes)
            pruneStale = try c.decode(Bool.self, forKey: .pruneStale)
            fetchRemoteBeforeCreate = (try? c.decode(Bool.self, forKey: .fetchRemoteBeforeCreate)) ?? false
            defaultOrdering = (try? c.decode(WorktreeSortMode.self, forKey: .defaultOrdering)) ?? .lastUpdateDesc
        }
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
        var confirmCloseTabs: Bool
        /// When true, every interactive pane is wrapped in `zmx attach <name>`
        /// so the shell (and any running agents) survives app quit/relaunch.
        /// When false, panes launch as plain shells and die with the app.
        var keepSessionsAlive: Bool

        enum CodingKeys: String, CodingKey {
            case shell, workingDirectory, startupScript, worktreeCreateScript,
                 inheritParentEnv, fontFamily, fontSize, cursorStyle, cursorBlink,
                 scrollbackLines, bell, syncTabTitleWithTerminalTitle,
                 confirmCloseTabs, keepSessionsAlive
        }

        init(
            shell: String,
            workingDirectory: String,
            startupScript: String,
            worktreeCreateScript: String,
            inheritParentEnv: Bool,
            fontFamily: String,
            fontSize: Int,
            cursorStyle: String,
            cursorBlink: Bool,
            scrollbackLines: Int,
            bell: String,
            syncTabTitleWithTerminalTitle: Bool,
            confirmCloseTabs: Bool = false,
            keepSessionsAlive: Bool = true
        ) {
            self.shell = shell
            self.workingDirectory = workingDirectory
            self.startupScript = startupScript
            self.worktreeCreateScript = worktreeCreateScript
            self.inheritParentEnv = inheritParentEnv
            self.fontFamily = fontFamily
            self.fontSize = fontSize
            self.cursorStyle = cursorStyle
            self.cursorBlink = cursorBlink
            self.scrollbackLines = scrollbackLines
            self.bell = bell
            self.syncTabTitleWithTerminalTitle = syncTabTitleWithTerminalTitle
            self.confirmCloseTabs = confirmCloseTabs
            self.keepSessionsAlive = keepSessionsAlive
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shell = try c.decode(String.self, forKey: .shell)
            workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
            startupScript = try c.decode(String.self, forKey: .startupScript)
            worktreeCreateScript = try c.decode(String.self, forKey: .worktreeCreateScript)
            inheritParentEnv = try c.decode(Bool.self, forKey: .inheritParentEnv)
            fontFamily = try c.decode(String.self, forKey: .fontFamily)
            fontSize = try c.decode(Int.self, forKey: .fontSize)
            cursorStyle = try c.decode(String.self, forKey: .cursorStyle)
            cursorBlink = try c.decode(Bool.self, forKey: .cursorBlink)
            scrollbackLines = try c.decode(Int.self, forKey: .scrollbackLines)
            bell = try c.decode(String.self, forKey: .bell)
            syncTabTitleWithTerminalTitle = (try? c.decode(Bool.self, forKey: .syncTabTitleWithTerminalTitle)) ?? false
            confirmCloseTabs = (try? c.decode(Bool.self, forKey: .confirmCloseTabs)) ?? false
            keepSessionsAlive = (try? c.decode(Bool.self, forKey: .keepSessionsAlive)) ?? true
        }
    }

    struct Harness: Codable, Equatable {
        var notifyOnFinish: Bool
        var notifyOnAwaiting: Bool
        var dismissedHookInstallNudges: [String]
        var dismissedACPSetupNudges: [String]
        var confirmCloseChatTabs: Bool
        /// When true (default): ⏎ submits with .auto intent, ⌥⏎ steers.
        /// When false: the two are inverted — ⏎ steers, ⌥⏎ queues. The
        /// label in Settings is "Send on ⏎, queue on ⌥⏎ while busy".
        var acpSendOnEnter: Bool
        /// When true, newly created chat sessions start with auto-run enabled
        /// (the agent runs tools without asking). Seeds the per-session value
        /// only; the composer bolt still wins afterward. Default: false.
        var acpAutoRunByDefault: Bool
        /// When true (default), every local ACP session gets the built-in
        /// "alas" MCP server exposing CLI actions (open, worktrees, review).
        var exposeAlasMCP: Bool
        /// How the built-in "alas" MCP server is delivered. Default: stdio.
        var alasMCPTransport: AlasMCPTransport

        enum CodingKeys: String, CodingKey {
            case notifyOnFinish, notifyOnAwaiting,
                 dismissedHookInstallNudges, dismissedACPSetupNudges,
                 confirmCloseChatTabs, acpSendOnEnter, acpAutoRunByDefault,
                 exposeAlasMCP, alasMCPTransport
        }

        init(notifyOnFinish: Bool = true, notifyOnAwaiting: Bool = true,
             dismissedHookInstallNudges: [String] = [],
             dismissedACPSetupNudges: [String] = [],
             confirmCloseChatTabs: Bool = false,
             acpSendOnEnter: Bool = true,
             acpAutoRunByDefault: Bool = false,
             exposeAlasMCP: Bool = true,
             alasMCPTransport: AlasMCPTransport = .stdio)
        {
            self.notifyOnFinish = notifyOnFinish
            self.notifyOnAwaiting = notifyOnAwaiting
            self.dismissedHookInstallNudges = dismissedHookInstallNudges
            self.dismissedACPSetupNudges = dismissedACPSetupNudges
            self.confirmCloseChatTabs = confirmCloseChatTabs
            self.acpSendOnEnter = acpSendOnEnter
            self.acpAutoRunByDefault = acpAutoRunByDefault
            self.exposeAlasMCP = exposeAlasMCP
            self.alasMCPTransport = alasMCPTransport
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notifyOnFinish = (try? c.decode(Bool.self, forKey: .notifyOnFinish)) ?? true
            notifyOnAwaiting = (try? c.decode(Bool.self, forKey: .notifyOnAwaiting)) ?? true
            dismissedHookInstallNudges = (try? c.decode([String].self, forKey: .dismissedHookInstallNudges)) ?? []
            dismissedACPSetupNudges = (try? c.decode([String].self, forKey: .dismissedACPSetupNudges)) ?? []
            confirmCloseChatTabs = (try? c.decode(Bool.self, forKey: .confirmCloseChatTabs)) ?? false
            acpSendOnEnter = (try? c.decode(Bool.self, forKey: .acpSendOnEnter)) ?? true
            acpAutoRunByDefault = (try? c.decode(Bool.self, forKey: .acpAutoRunByDefault)) ?? false
            exposeAlasMCP = (try? c.decode(Bool.self, forKey: .exposeAlasMCP)) ?? true
            alasMCPTransport = (try? c.decode(AlasMCPTransport.self, forKey: .alasMCPTransport)) ?? .stdio
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
        var showInvisibleCharacters: Bool = false
        var showSpaces: Bool = true
        var showTabs: Bool = true
        var showLineEndings: Bool = true
        var showWarningCharacters: Bool = true
        var warningCharacters: [WarningCharacter] = WarningCharacter.defaults

        enum CodingKeys: String, CodingKey {
            case fontFamily, fontSize, formatOnSave, showLineNumbers,
                 languageServers, dismissedInstallNudges, userDefinedRecipes,
                 showInvisibleCharacters, showSpaces, showTabs, showLineEndings,
                 showWarningCharacters, warningCharacters
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
        var reviewRequestPrompt: String
        /// Workspace-level "fix every merge conflict in this repo"
        /// prompt fed to the agent CWD'd at the worktree. The agent
        /// uses its own filesystem tools to enumerate + reconcile.
        var mergeBulkResolvePrompt: String
        /// Single-file resolve template — the instructions portion
        /// only. The three sides (LOCAL/BASE/REMOTE/MERGED) are
        /// appended verbatim by `MergeAgent`. `{filePath}` and
        /// `{language}` are substituted; anything else passes through.
        var mergeSingleResolvePrompt: String
        /// How the Commits section chooses its comparison base.
        /// - `auto` (default): compare against `origin/<base>` (falls back to
        ///   local `<base>`); stable across rebases.
        /// - `branchUpstream`: compare against the branch's own `@{u}`.
        /// - `manual`: compare against the per-worktree selected base branch.
        enum ChangesComparisonMode: String, Codable {
            case auto
            case branchUpstream
            case manual
        }
        var comparisonMode: ChangesComparisonMode
        var diffLayoutMode: DiffLayoutMode
        var diffShowWhitespace: Bool
        /// Master switch for the gg stacked-diffs integration. On by
        /// default — without gg installed the later gates hide all UI.
        var stackedDiffsEnabled: Bool = true

        enum CodingKeys: String, CodingKey {
            case aiToolId, prompt, reviewRequestPrompt, mergeBulkResolvePrompt,
                 mergeSingleResolvePrompt, comparisonMode,
                 diffLayoutMode, diffShowWhitespace, stackedDiffsEnabled
        }
    }

    /// Legacy key retained only so `AppConfig.init(from:)` can migrate
    /// pre-`comparisonMode` configs; no stored property backs it.
    private enum LegacyChangesKey: String, CodingKey {
        case trackUpstreamForCommits
    }

    struct Agents: Codable, Equatable {
        var builtinState: [String: BuiltinAgentState]
        var custom: [AgentDefinition]
        var worktreeAutoLaunch: WorktreeAutoLaunch
        /// Which surface the ⌥⌘T launcher opens on by default —
        /// terminal tab or ACP chat. The user can flip with the
        /// segmented control inside the launcher; this just picks the
        /// starting mode.
        var defaultLauncherMode: LauncherMode
        var chatFontFamily: String
        var chatFontSize: Int

        enum CodingKeys: String, CodingKey {
            case builtinState, custom, worktreeAutoLaunch, defaultLauncherMode,
                 chatFontFamily, chatFontSize
        }
    }

    enum LauncherMode: String, Codable, Equatable, CaseIterable {
        case terminal, acp
    }

    enum WorktreeSortMode: String, Codable, Equatable, CaseIterable {
        case manual
        case creationDesc
        case creationAsc
        case lastUpdateDesc
        case lastUpdateAsc
        case branchAsc
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
            pruneStale: false,
            fetchRemoteBeforeCreate: false,
            defaultOrdering: .lastUpdateDesc
        ),
        terminal: Terminal(
            shell: "/bin/zsh",
            workingDirectory: "worktreeRoot",
            startupScript: "",
            worktreeCreateScript: "",
            inheritParentEnv: true,
            fontFamily: "JetBrainsMono Nerd Font",
            fontSize: 13,
            cursorStyle: "beam",
            cursorBlink: true,
            scrollbackLines: 10000,
            bell: "visual",
            syncTabTitleWithTerminalTitle: false,
            confirmCloseTabs: false,
            keepSessionsAlive: true
        ),
        harness: Harness(notifyOnFinish: true, notifyOnAwaiting: true),
        code: Code(
            fontFamily: "JetBrainsMono Nerd Font",
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
            reviewRequestPrompt: AppConfig.defaultReviewRequestPrompt,
            mergeBulkResolvePrompt: AppConfig.defaultMergeBulkResolvePrompt,
            mergeSingleResolvePrompt: AppConfig.defaultMergeSingleResolvePrompt,
            comparisonMode: .auto,
            diffLayoutMode: .split,
            diffShowWhitespace: false
        ),
        agents: Agents(
            builtinState: [:],
            custom: [],
            worktreeAutoLaunch: WorktreeAutoLaunch(
                agentId: nil,
                useBypassPermissions: false
            ),
            defaultLauncherMode: .terminal,
            chatFontFamily: "",
            chatFontSize: 13
        ),
        files: Files(showIgnored: true),
        recentProjectIds: [],
        recentWorktreeIdsByProject: [:],
        recentWorktreeRefs: [],
        collapsedProjectIds: [],
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

    static let defaultReviewRequestPrompt = """
    You are writing a pull request title and description for the committed branch changes shown below.

    Output format — strict:
      Line 1: concise PR title, no trailing period.
      Line 2: blank.
      Line 3+: Markdown body with exactly these sections:
               ## Summary
               - 1-3 bullets describing the user-visible or reviewer-relevant changes.

               ## Testing
               - Bullets describing verification performed.
               - Use "Not run (not provided)." only when no testing signal is present.

    Use the branch diff and commit subjects as source material. Do not mention uncommitted working tree changes as implemented work. Do not include preamble, code fences, or extra headings.
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
             remote,
             recentProjectIds, recentWorktreeIdsByProject, recentWorktreeRefs,
             collapsedProjectIds,
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
            let fontFamily = (try? termContainer.decode(String.self, forKey: .fontFamily)) ?? "JetBrainsMono Nerd Font"
            let fontSize = (try? termContainer.decode(Int.self, forKey: .fontSize)) ?? 13
            let cursorStyle = (try? termContainer.decode(String.self, forKey: .cursorStyle)) ?? "beam"
            let cursorBlink = (try? termContainer.decode(Bool.self, forKey: .cursorBlink)) ?? true
            let scrollbackLines = (try? termContainer.decode(Int.self, forKey: .scrollbackLines)) ?? 10000
            let bell = (try? termContainer.decode(String.self, forKey: .bell)) ?? "visual"
            let syncTabTitleWithTerminalTitle = (try? termContainer.decode(Bool.self, forKey: .syncTabTitleWithTerminalTitle)) ?? false
            let confirmCloseTabs = (try? termContainer.decode(Bool.self, forKey: .confirmCloseTabs)) ?? false
            let keepSessionsAlive = (try? termContainer.decode(Bool.self, forKey: .keepSessionsAlive)) ?? true
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
                syncTabTitleWithTerminalTitle: syncTabTitleWithTerminalTitle,
                confirmCloseTabs: confirmCloseTabs,
                keepSessionsAlive: keepSessionsAlive
            )
        } else {
            terminal = Terminal(
                shell: "/bin/zsh",
                workingDirectory: "worktreeRoot",
                startupScript: "",
                worktreeCreateScript: "",
                inheritParentEnv: true,
                fontFamily: "JetBrainsMono Nerd Font",
                fontSize: 13,
                cursorStyle: "beam",
                cursorBlink: true,
                scrollbackLines: 10000,
                bell: "visual",
                syncTabTitleWithTerminalTitle: false,
                confirmCloseTabs: false,
                keepSessionsAlive: true
            )
        }
        harness = try c.decode(Harness.self, forKey: .harness)
        if let codeContainer = try? c.nestedContainer(keyedBy: AppConfig.Code.CodingKeys.self, forKey: .code) {
            let fontFamily = (try? codeContainer.decode(String.self, forKey: .fontFamily)) ?? "JetBrainsMono Nerd Font"
            let rawSize = (try? codeContainer.decode(Int.self, forKey: .fontSize)) ?? 13
            let fontSize = max(8, min(64, rawSize))
            let formatOnSave = (try? codeContainer.decode(Bool.self, forKey: .formatOnSave)) ?? false
            let showLineNumbers = (try? codeContainer.decode(Bool.self, forKey: .showLineNumbers)) ?? true
            let servers = (try? codeContainer.decode([LanguageServerConfig].self, forKey: .languageServers)) ?? []
            let dismissed = (try? codeContainer.decode([String].self, forKey: .dismissedInstallNudges)) ?? []
            let userRecipes = (try? codeContainer.decode([String: [InstallRecipe]].self, forKey: .userDefinedRecipes)) ?? [:]
            let showInvisibleCharacters = (try? codeContainer.decode(Bool.self, forKey: .showInvisibleCharacters)) ?? false
            let showSpaces = (try? codeContainer.decode(Bool.self, forKey: .showSpaces)) ?? true
            let showTabs = (try? codeContainer.decode(Bool.self, forKey: .showTabs)) ?? true
            let showLineEndings = (try? codeContainer.decode(Bool.self, forKey: .showLineEndings)) ?? true
            let showWarningCharacters = (try? codeContainer.decode(Bool.self, forKey: .showWarningCharacters)) ?? true
            let warningCharacters: [WarningCharacter]
            if var warnings = try? codeContainer.nestedUnkeyedContainer(forKey: .warningCharacters) {
                var decoded: [WarningCharacter] = []
                while !warnings.isAtEnd {
                    if let decoder = try? warnings.superDecoder(), let warning = try? WarningCharacter(from: decoder) {
                        decoded.append(warning)
                    }
                }
                warningCharacters = WarningCharacter.sanitized(decoded)
            } else {
                warningCharacters = WarningCharacter.defaults
            }
            code = Code(
                fontFamily: fontFamily,
                fontSize: fontSize,
                formatOnSave: formatOnSave,
                showLineNumbers: showLineNumbers,
                languageServers: servers,
                dismissedInstallNudges: dismissed,
                userDefinedRecipes: userRecipes,
                showInvisibleCharacters: showInvisibleCharacters,
                showSpaces: showSpaces,
                showTabs: showTabs,
                showLineEndings: showLineEndings,
                showWarningCharacters: showWarningCharacters,
                warningCharacters: warningCharacters
            )
        } else {
            code = Code(
                fontFamily: "JetBrainsMono Nerd Font",
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
            let reviewRequestPrompt = (try? changesContainer.decode(String.self, forKey: .reviewRequestPrompt))
                ?? AppConfig.defaultReviewRequestPrompt
            let bulkResolve = (try? changesContainer.decode(String.self, forKey: .mergeBulkResolvePrompt))
                ?? AppConfig.defaultMergeBulkResolvePrompt
            let singleResolve = (try? changesContainer.decode(String.self, forKey: .mergeSingleResolvePrompt))
                ?? AppConfig.defaultMergeSingleResolvePrompt
            let legacyTrackUpstream: Bool? = {
                guard let legacy = try? c.nestedContainer(keyedBy: LegacyChangesKey.self, forKey: .changes) else { return nil }
                return try? legacy.decode(Bool.self, forKey: .trackUpstreamForCommits)
            }()
            let comparisonMode: Changes.ChangesComparisonMode = {
                if let explicit = try? changesContainer.decode(Changes.ChangesComparisonMode.self, forKey: .comparisonMode) {
                    return explicit
                }
                return (legacyTrackUpstream == true) ? .branchUpstream : .auto
            }()
            let diffLayoutMode = (try? changesContainer.decode(DiffLayoutMode.self, forKey: .diffLayoutMode)) ?? .split
            let diffShowWhitespace = (try? changesContainer.decode(Bool.self, forKey: .diffShowWhitespace)) ?? false
            changes = Changes(
                aiToolId: toolId,
                prompt: prompt,
                reviewRequestPrompt: reviewRequestPrompt,
                mergeBulkResolvePrompt: bulkResolve,
                mergeSingleResolvePrompt: singleResolve,
                comparisonMode: comparisonMode,
                diffLayoutMode: diffLayoutMode,
                diffShowWhitespace: diffShowWhitespace
            )
            changes.stackedDiffsEnabled =
                (try? changesContainer.decode(Bool.self, forKey: .stackedDiffsEnabled)) ?? true
        } else {
            changes = Changes(
                aiToolId: "none",
                prompt: AppConfig.defaultCommitPrompt,
                reviewRequestPrompt: AppConfig.defaultReviewRequestPrompt,
                mergeBulkResolvePrompt: AppConfig.defaultMergeBulkResolvePrompt,
                mergeSingleResolvePrompt: AppConfig.defaultMergeSingleResolvePrompt,
                comparisonMode: .auto,
                diffLayoutMode: .split,
                diffShowWhitespace: false
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
            let defaultMode = (try? agentsContainer.decode(
                LauncherMode.self, forKey: .defaultLauncherMode
            )) ?? .terminal
            let chatFontFamily = (try? agentsContainer.decode(
                String.self, forKey: .chatFontFamily
            )) ?? ""
            let rawChatFontSize = (try? agentsContainer.decode(
                Int.self, forKey: .chatFontSize
            )) ?? 13
            let chatFontSize = max(8, min(64, rawChatFontSize))
            agents = Agents(
                builtinState: state,
                custom: custom,
                worktreeAutoLaunch: autoLaunch,
                defaultLauncherMode: defaultMode,
                chatFontFamily: chatFontFamily,
                chatFontSize: chatFontSize
            )
        } else {
            agents = Agents(
                builtinState: [:],
                custom: [],
                worktreeAutoLaunch: WorktreeAutoLaunch(
                    agentId: nil, useBypassPermissions: false
                ),
                defaultLauncherMode: .terminal,
                chatFontFamily: "",
                chatFontSize: 13
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
        // Older configs predate `remote`; default to disabled so they still load.
        remote = (try? c.decodeIfPresent(Remote.self, forKey: .remote)) ?? .init()
        recentProjectIds = (try? c.decode([String].self, forKey: .recentProjectIds)) ?? []
        recentWorktreeIdsByProject =
            (try? c.decode([String: [String]].self, forKey: .recentWorktreeIdsByProject)) ?? [:]
        recentWorktreeRefs =
            (try? c.decode([RepoSelectorRecents.RecentWorktreeRef].self, forKey: .recentWorktreeRefs)) ?? []
        collapsedProjectIds =
            (try? c.decode([String].self, forKey: .collapsedProjectIds)) ?? []
        sidebarChromeOverrides =
            (try? c.decode([String: SidebarChromeOverride].self, forKey: .sidebarChromeOverrides)) ?? [:]
        shortcutOverrides =
            (try? c.decode([String: ShortcutBinding?].self, forKey: .shortcutOverrides)) ?? [:]
        migrateLegacyFindAndReplaceShortcutOverride()
        migrateLegacyAgentLauncherShortcutOverrides()
        removeShortcutOverridesCollidingWithReservedBindings()
        // Last: it must see the final override set.
        unbindNewAgentLauncherDefaultsClaimedByOverrides()
    }
}

private extension AppConfig {
    mutating func migrateLegacyFindAndReplaceShortcutOverride() {
        let legacyKey = ShortcutAction.findAndReplace.rawValue
        let replaceKey = ShortcutAction.replaceInEditor.rawValue
        guard let legacyOverride = shortcutOverrides[legacyKey],
              !shortcutOverrides.keys.contains(replaceKey) else { return }
        if legacyOverride == ShortcutAction.findAndReplace.defaultBinding {
            shortcutOverrides.removeValue(forKey: legacyKey)
            return
        }
        shortcutOverrides.updateValue(legacyOverride, forKey: replaceKey)
        shortcutOverrides.removeValue(forKey: legacyKey)
    }

    /// `launchAgentTerminal`/`launchAgentChat` were split into three actions:
    /// `launchAgent` (surface picker), `launchAgentInTerminal` and
    /// `launchAgentInChat`. Carry any custom binding over to the action that
    /// kept its meaning; an override that merely restated the old default is
    /// dropped so the new defaults apply.
    mutating func migrateLegacyAgentLauncherShortcutOverrides() {
        let renames: [(legacyKey: String, legacyDefault: ShortcutBinding, action: ShortcutAction)] = [
            ("launchAgentTerminal",
             .init(key: "t", modifiers: [.command, .option]),
             .launchAgent),
            ("launchAgentChat",
             .init(key: "t", modifiers: [.command, .option, .shift]),
             .launchAgentInChat),
        ]
        for (legacyKey, legacyDefault, action) in renames {
            guard let legacyOverride = shortcutOverrides[legacyKey] else { continue }
            shortcutOverrides.removeValue(forKey: legacyKey)
            guard legacyOverride != legacyDefault,
                  !shortcutOverrides.keys.contains(action.rawValue) else { continue }
            shortcutOverrides.updateValue(legacyOverride, forKey: action.rawValue)
        }
    }

    /// The split actions introduce defaults (⌘⌥⇧C, and ⌘⌥⇧T for the terminal
    /// half) that an older config may already have assigned to something else
    /// — legal at the time, since `conflict(for:excluding:)` only guards
    /// interactive assignment in Settings, never decode. Without an override
    /// of their own the new actions would silently claim the same chord and
    /// both menu items would register it. Leave the user's binding alone and
    /// start the new action explicitly unbound; Settings can restore its
    /// default once the chord is free.
    mutating func unbindNewAgentLauncherDefaultsClaimedByOverrides() {
        for action in [ShortcutAction.launchAgentInTerminal, .launchAgentInChat] {
            guard !shortcutOverrides.keys.contains(action.rawValue) else { continue }
            let isClaimed = shortcutOverrides.contains { key, override in
                key != action.rawValue && override == action.defaultBinding
            }
            guard isClaimed else { continue }
            shortcutOverrides.updateValue(nil, forKey: action.rawValue)
        }
    }

    mutating func removeShortcutOverridesCollidingWithReservedBindings() {
        let reserved = Set(ShortcutAction.reservedBindings)
        for (key, override) in shortcutOverrides {
            guard let binding = override, reserved.contains(binding) else { continue }
            shortcutOverrides.removeValue(forKey: key)
        }
    }
}

extension AppConfig {
    func sidebarChromeOverride(forThemeId themeId: String) -> SidebarChromeOverride {
        if let saved = sidebarChromeOverrides[themeId] { return saved }
        return SidebarChromeOverride.bundledDefaults[themeId] ?? .zero
    }
}
