import Foundation

public struct SidebarChromeOverride: Codable, Equatable, Sendable {
    public var backgroundOpacity: Double  // 0...1
    public var textContrast: Double       // 0...1

    public static let bundledDefaults: [String: SidebarChromeOverride] = [
        "cool-slate": SidebarChromeOverride(backgroundOpacity: 0.25, textContrast: 0.15),
        "light":      SidebarChromeOverride(backgroundOpacity: 0.25, textContrast: 0.15),
    ]

    public static let zero = SidebarChromeOverride(backgroundOpacity: 0, textContrast: 0)

    public init(backgroundOpacity: Double, textContrast: Double) {
        self.backgroundOpacity = backgroundOpacity
        self.textContrast = textContrast
    }
}

/// Per-theme tint layered over the chat and terminal materials. A light and a
/// dark theme need different amounts of theme color to stay readable.
public struct ContentMaterialOverride: Codable, Equatable, Sendable {
    public var chatBackgroundOpacity: Double      // 0...1
    public var terminalBackgroundOpacity: Double  // 0...1

    public static let bundledDefaults: [String: ContentMaterialOverride] = [
        "cool-slate": ContentMaterialOverride(chatBackgroundOpacity: 0.2, terminalBackgroundOpacity: 0.5),
        "light":      ContentMaterialOverride(chatBackgroundOpacity: 0.2, terminalBackgroundOpacity: 0.5),
    ]

    public static let zero = ContentMaterialOverride(chatBackgroundOpacity: 0, terminalBackgroundOpacity: 0)

    public init(chatBackgroundOpacity: Double, terminalBackgroundOpacity: Double) {
        self.chatBackgroundOpacity = chatBackgroundOpacity
        self.terminalBackgroundOpacity = terminalBackgroundOpacity
    }
}

/// How the built-in "alas" MCP server is delivered to local ACP sessions.
/// stdio (default) is spawned by the agent harness; http is served by a
/// supervised `alas mcp --http` process the app manages, for harnesses that
/// restrict stdio MCP servers by policy.
public enum AlasMCPTransport: String, Codable, Equatable, Sendable {
    case stdio
    case http
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var themeId: String
    public var accent: String
    public var matchSystemTheme: Bool
    public var sidebarMaterial: SidebarMaterialChoice
    public var sidebarWidth: Double
    public var rightPaneWidth: Double
    public var rightPaneVisible: Bool
    public var sidebarVisible: Bool
    public var commitDetailSplitRatio: Double
    public var general: General
    public var worktrees: Worktrees
    public var terminal: Terminal
    public var harness: Harness
    public var code: Code
    public var markdown: Markdown
    public var changes: Changes
    public var agents: Agents
    public var files: Files
    public var remote: Remote = .init()
    public var nextPromptSuggestionsEnabled: Bool = false
    public var sessionSummariesEnabled: Bool = false
    public var runFailureBriefsEnabled: Bool = true
    public var localTextModelEnabled: Bool = false
    public var issueWorktreeNameSuggestionsEnabled: Bool = true
    /// Gate for plugins. Off: nothing is scanned, loaded or run. On, a plugin still runs only once approved.
    public var pluginsEnabled: Bool = true
    public var recentProjectIds: [String] = []
    public var recentWorktreeIdsByProject: [String: [String]] = [:]
    public var recentWorktreeRefs: [RepoSelectorRecents.RecentWorktreeRef] = []
    public var collapsedProjectIds: [String] = []
    public var sidebarChromeOverrides: [String: SidebarChromeOverride] = [:]
    public var contentMaterialOverrides: [String: ContentMaterialOverride] = [:]
    public var shortcutOverrides: [String: ShortcutBinding?] = [:]
    public var repositoryCloneRootPath: String = ""

    public struct Remote: Codable, Equatable, Sendable {
        public var enabled: Bool = false
        public var keepAwake: Bool = false
        public var port: UInt16 = 0          // 0 = OS-assigned
        public var allowedHosts: [String] = []
        public var preferredAdvertisedHost: String? = nil
        /// Browser origins allowed to pair with and connect to this Mac, in
        /// addition to private-network and Host-allowlisted origins.
        public var allowedOrigins: [String] = []
        /// Stable identity advertised in the WebSocket `hello`. Empty until
        /// `ensureServerId()` assigns one.
        public var serverId: String = ""
        /// Name advertised in `hello`. Empty means "use the computer name".
        public var displayName: String = ""
        /// Advertise this Mac on the local network with Bonjour and browse for
        /// other Alas instances there.
        public var discoverable: Bool = false
        /// Front the server with `tailscale serve` at `https://<MagicDNS name>`.
        public var tailscaleServe: Bool = false
        /// With `tailscaleServe`, listen on loopback only so the server is
        /// reachable solely through Tailscale Serve.
        public var tailscaleOnly: Bool = false

        /// Effective bind mode: "Tailscale only" means nothing without Serve.
        public var listensOnLoopbackOnly: Bool { tailscaleServe && tailscaleOnly }

        /// Port to bind. A stable default keeps a paired phone's URL valid
        /// across restarts (config 0 means "use the default").
        public var preferredPort: UInt16 { port != 0 ? port : 8765 }

        public init(
            enabled: Bool = false,
            keepAwake: Bool = false,
            port: UInt16 = 0,
            allowedHosts: [String] = [],
            preferredAdvertisedHost: String? = nil,
            allowedOrigins: [String] = [],
            serverId: String = "",
            displayName: String = "",
            discoverable: Bool = false,
            tailscaleServe: Bool = false,
            tailscaleOnly: Bool = false
        ) {
            self.enabled = enabled
            self.keepAwake = keepAwake
            self.port = port
            self.allowedHosts = allowedHosts
            self.preferredAdvertisedHost = preferredAdvertisedHost
            self.allowedOrigins = allowedOrigins
            self.serverId = serverId
            self.displayName = displayName
            self.discoverable = discoverable
            self.tailscaleServe = tailscaleServe
            self.tailscaleOnly = tailscaleOnly
        }

        public enum CodingKeys: String, CodingKey, Sendable {
            case enabled, keepAwake, port, allowedHosts, preferredAdvertisedHost
            case allowedOrigins, serverId, displayName, discoverable
            case tailscaleServe, tailscaleOnly
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
            keepAwake = (try? c.decode(Bool.self, forKey: .keepAwake)) ?? false
            port = (try? c.decode(UInt16.self, forKey: .port)) ?? 0
            allowedHosts = (try? c.decode([String].self, forKey: .allowedHosts)) ?? []
            preferredAdvertisedHost = try? c.decodeIfPresent(String.self, forKey: .preferredAdvertisedHost)
            allowedOrigins = (try? c.decode([String].self, forKey: .allowedOrigins)) ?? []
            serverId = (try? c.decode(String.self, forKey: .serverId)) ?? ""
            displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
            discoverable = (try? c.decode(Bool.self, forKey: .discoverable)) ?? false
            tailscaleServe = (try? c.decode(Bool.self, forKey: .tailscaleServe)) ?? false
            tailscaleOnly = (try? c.decode(Bool.self, forKey: .tailscaleOnly)) ?? false
        }

        /// Assigns a fresh UUID when `serverId` is empty. Returns true when it changed.
        @discardableResult
        public mutating func ensureServerId() -> Bool {
            guard serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            serverId = UUID().uuidString
            return true
        }
    }

    public struct General: Codable, Equatable, Sendable {
        public var launchAtLogin: Bool
        public var closeToTray: Bool
        public var confirmQuit: Bool
        public var autoUpdate: Bool
        public var updateChannel: String
        public var crashReports: Bool
        public var usageAnalytics: Bool

        public init(launchAtLogin: Bool, closeToTray: Bool, confirmQuit: Bool, autoUpdate: Bool, updateChannel: String, crashReports: Bool, usageAnalytics: Bool) {
            self.launchAtLogin = launchAtLogin
            self.closeToTray = closeToTray
            self.confirmQuit = confirmQuit
            self.autoUpdate = autoUpdate
            self.updateChannel = updateChannel
            self.crashReports = crashReports
            self.usageAnalytics = usageAnalytics
        }
    }

    public struct Worktrees: Codable, Equatable, Sendable {
        public var rootPath: String
        public var pathTemplate: String
        public var branchPrefix: String
        /// Nil preserves the legacy branch prefix behavior.
        public var branchTemplate: String?
        public var baseBranch: String
        public var trackUpstream: Bool
        public var deleteBranchOnRemove: Bool
        public var autoFetch: Bool
        public var fetchIntervalMinutes: Int
        public var pruneStale: Bool
        public var fetchRemoteBeforeCreate: Bool
        public var defaultOrdering: WorktreeSortMode
        /// Days a worktree must sit untouched before cleanup considers it idle.
        public var cleanupIdleDays: Int

        public enum CodingKeys: String, CodingKey, Sendable {
            case rootPath, pathTemplate, branchPrefix, branchTemplate, baseBranch,
                 trackUpstream, deleteBranchOnRemove, autoFetch,
                 fetchIntervalMinutes, pruneStale, fetchRemoteBeforeCreate,
                 defaultOrdering, cleanupIdleDays
        }

        public init(
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
            defaultOrdering: WorktreeSortMode = .lastUpdateDesc,
            cleanupIdleDays: Int = 3,
            branchTemplate: String? = nil
        ) {
            self.rootPath = rootPath
            self.pathTemplate = pathTemplate
            self.branchPrefix = branchPrefix
            self.branchTemplate = branchTemplate
            self.baseBranch = baseBranch
            self.trackUpstream = trackUpstream
            self.deleteBranchOnRemove = deleteBranchOnRemove
            self.autoFetch = autoFetch
            self.fetchIntervalMinutes = fetchIntervalMinutes
            self.pruneStale = pruneStale
            self.fetchRemoteBeforeCreate = fetchRemoteBeforeCreate
            self.defaultOrdering = defaultOrdering
            self.cleanupIdleDays = cleanupIdleDays
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rootPath = try c.decode(String.self, forKey: .rootPath)
            pathTemplate = try c.decode(String.self, forKey: .pathTemplate)
            branchPrefix = try c.decode(String.self, forKey: .branchPrefix)
            branchTemplate = try? c.decode(String.self, forKey: .branchTemplate)
            baseBranch = try c.decode(String.self, forKey: .baseBranch)
            trackUpstream = try c.decode(Bool.self, forKey: .trackUpstream)
            deleteBranchOnRemove = try c.decode(Bool.self, forKey: .deleteBranchOnRemove)
            autoFetch = try c.decode(Bool.self, forKey: .autoFetch)
            fetchIntervalMinutes = try c.decode(Int.self, forKey: .fetchIntervalMinutes)
            pruneStale = try c.decode(Bool.self, forKey: .pruneStale)
            fetchRemoteBeforeCreate = (try? c.decode(Bool.self, forKey: .fetchRemoteBeforeCreate)) ?? false
            defaultOrdering = (try? c.decode(WorktreeSortMode.self, forKey: .defaultOrdering)) ?? .lastUpdateDesc
            cleanupIdleDays = (try? c.decode(Int.self, forKey: .cleanupIdleDays)) ?? 3
        }
    }

    public struct Terminal: Codable, Equatable, Sendable {
        public var shell: String
        public var workingDirectory: String     // worktreeRoot | repoRoot | lastUsed
        public var startupScript: String
        public var worktreeCreateScript: String
        public var inheritParentEnv: Bool
        public var fontFamily: String
        public var fontSize: Int
        public var cursorStyle: String          // block | beam | underline
        public var cursorBlink: Bool
        public var scrollbackLines: Int
        public var bell: String                 // off | visual | sound
        public var syncTabTitleWithTerminalTitle: Bool
        public var confirmCloseTabs: Bool
        /// When true, every interactive pane is wrapped in `zmx attach <name>`
        /// so the shell (and any running agents) survives app quit/relaunch.
        /// When false, panes launch as plain shells and die with the app.
        public var keepSessionsAlive: Bool
        /// Material behind terminal panes. `.none` keeps the opaque theme
        /// background; any other choice makes Ghostty's default background
        /// transparent so the material shows through.
        public var backgroundMaterial: SidebarMaterialChoice

        public enum CodingKeys: String, CodingKey, Sendable {
            case shell, workingDirectory, startupScript, worktreeCreateScript,
                 inheritParentEnv, fontFamily, fontSize, cursorStyle, cursorBlink,
                 scrollbackLines, bell, syncTabTitleWithTerminalTitle,
                 confirmCloseTabs, keepSessionsAlive, backgroundMaterial
        }

        public init(
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
            keepSessionsAlive: Bool = true,
            backgroundMaterial: SidebarMaterialChoice = .none
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
            self.backgroundMaterial = backgroundMaterial
        }

        public init(from decoder: Decoder) throws {
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
            syncTabTitleWithTerminalTitle = (try? c.decode(Bool.self, forKey: .syncTabTitleWithTerminalTitle)) ?? true
            confirmCloseTabs = (try? c.decode(Bool.self, forKey: .confirmCloseTabs)) ?? false
            keepSessionsAlive = (try? c.decode(Bool.self, forKey: .keepSessionsAlive)) ?? true
            backgroundMaterial = SidebarMaterialChoice.centerPaneMaterial(
                try? c.decode(SidebarMaterialChoice.self, forKey: .backgroundMaterial)
            )
        }
    }

    public struct Harness: Codable, Equatable, Sendable {
        public var notifyOnFinish: Bool
        public var notifyOnAwaiting: Bool
        /// Seconds a delegated child may stay blocked on a human decision
        /// before its parent is woken. The parent always gets a passive
        /// notice immediately. 0 disables escalation. Default: 30.
        public var acpDelegatedBlockerEscalationSeconds: Int
        public var dismissedHookInstallNudges: [String]
        public var confirmCloseChatTabs: Bool
        /// When true (default): ⏎ submits with .auto intent, ⌥⏎ steers.
        /// When false: ⏎ steers and ⌥⏎ queues. The busy send button follows
        /// the same preference. Kept under its original key for compatibility.
        public var acpSendOnEnter: Bool
        /// When true, newly created chat sessions start with auto-run enabled
        /// (the agent runs tools without asking). Seeds the per-session value
        /// only; the composer bolt still wins afterward. Default: false.
        public var acpAutoRunByDefault: Bool
        /// Generate an on-device title when the ACP agent does not provide one.
        /// Default: true; users can opt out in Chat settings.
        public var acpLocalTitlesEnabled: Bool
        /// Schedule a resume when a provider usage limit stops a session.
        public var acpAutoResumeAfterUsageLimit: Bool
        /// After a restart, resend prompts whose delivery the dead connection
        /// left uncertain and ask an interrupted turn to continue. Default: false.
        public var acpContinueInterruptedSessions: Bool
        public var acpShowMinimap: Bool
        /// When true, the chat transcript groups consecutive thinking and
        /// finished tool calls into an expandable activity row.
        /// The active tool call always stays visible. Default: false.
        public var acpCollapseFinishedToolCalls: Bool
        /// When true (default), every local ACP session gets the built-in
        /// "alas" MCP server exposing CLI actions (open, worktrees, review).
        public var exposeAlasMCP: Bool
        /// How the built-in "alas" MCP server is delivered. Default: stdio.
        public var alasMCPTransport: AlasMCPTransport
        /// Language used for composer dictation, as a locale identifier
        /// (e.g. "en_US"). Empty (the default) means detect automatically
        /// from the app locale and the user's preferred languages.
        public var acpDictationLocale: String

        public enum CodingKeys: String, CodingKey, Sendable {
            case notifyOnFinish, notifyOnAwaiting, acpDelegatedBlockerEscalationSeconds,
                 dismissedHookInstallNudges,
                 confirmCloseChatTabs, acpSendOnEnter, acpAutoRunByDefault, acpLocalTitlesEnabled, acpShowMinimap,
                 acpAutoResumeAfterUsageLimit, acpContinueInterruptedSessions, acpCollapseFinishedToolCalls,
                 exposeAlasMCP, alasMCPTransport, acpDictationLocale
        }

        public init(notifyOnFinish: Bool = true, notifyOnAwaiting: Bool = true,
             acpDelegatedBlockerEscalationSeconds: Int = 30,
             dismissedHookInstallNudges: [String] = [],
             confirmCloseChatTabs: Bool = false,
             acpSendOnEnter: Bool = true,
             acpAutoRunByDefault: Bool = false,
             acpLocalTitlesEnabled: Bool = true,
             acpAutoResumeAfterUsageLimit: Bool = true,
             acpContinueInterruptedSessions: Bool = false,
             acpShowMinimap: Bool = false,
             acpCollapseFinishedToolCalls: Bool = true,
             exposeAlasMCP: Bool = true,
             alasMCPTransport: AlasMCPTransport = .stdio,
             acpDictationLocale: String = "")
        {
            self.notifyOnFinish = notifyOnFinish
            self.notifyOnAwaiting = notifyOnAwaiting
            self.acpDelegatedBlockerEscalationSeconds = acpDelegatedBlockerEscalationSeconds
            self.dismissedHookInstallNudges = dismissedHookInstallNudges
            self.confirmCloseChatTabs = confirmCloseChatTabs
            self.acpSendOnEnter = acpSendOnEnter
            self.acpAutoRunByDefault = acpAutoRunByDefault
            self.acpLocalTitlesEnabled = acpLocalTitlesEnabled
            self.acpAutoResumeAfterUsageLimit = acpAutoResumeAfterUsageLimit
            self.acpContinueInterruptedSessions = acpContinueInterruptedSessions
            self.acpShowMinimap = acpShowMinimap
            self.acpCollapseFinishedToolCalls = acpCollapseFinishedToolCalls
            self.exposeAlasMCP = exposeAlasMCP
            self.alasMCPTransport = alasMCPTransport
            self.acpDictationLocale = acpDictationLocale
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notifyOnFinish = (try? c.decode(Bool.self, forKey: .notifyOnFinish)) ?? true
            notifyOnAwaiting = (try? c.decode(Bool.self, forKey: .notifyOnAwaiting)) ?? true
            acpDelegatedBlockerEscalationSeconds =
                (try? c.decode(Int.self, forKey: .acpDelegatedBlockerEscalationSeconds)) ?? 30
            dismissedHookInstallNudges = (try? c.decode([String].self, forKey: .dismissedHookInstallNudges)) ?? []
            confirmCloseChatTabs = (try? c.decode(Bool.self, forKey: .confirmCloseChatTabs)) ?? false
            acpSendOnEnter = (try? c.decode(Bool.self, forKey: .acpSendOnEnter)) ?? true
            acpAutoRunByDefault = (try? c.decode(Bool.self, forKey: .acpAutoRunByDefault)) ?? false
            acpLocalTitlesEnabled = (try? c.decode(Bool.self, forKey: .acpLocalTitlesEnabled)) ?? true
            acpAutoResumeAfterUsageLimit = (try? c.decode(Bool.self, forKey: .acpAutoResumeAfterUsageLimit)) ?? true
            acpContinueInterruptedSessions =
                (try? c.decode(Bool.self, forKey: .acpContinueInterruptedSessions)) ?? false
            acpShowMinimap = (try? c.decode(Bool.self, forKey: .acpShowMinimap)) ?? false
            acpCollapseFinishedToolCalls = (try? c.decode(Bool.self, forKey: .acpCollapseFinishedToolCalls)) ?? true
            exposeAlasMCP = (try? c.decode(Bool.self, forKey: .exposeAlasMCP)) ?? true
            alasMCPTransport = (try? c.decode(AlasMCPTransport.self, forKey: .alasMCPTransport)) ?? .stdio
            acpDictationLocale = (try? c.decode(String.self, forKey: .acpDictationLocale)) ?? ""
        }
    }

    public struct Code: Codable, Equatable, Sendable {
        public var fontFamily: String      // "" = system monospaced fallback
        public var fontSize: Int           // clamped [8, 64] on decode/write
        public var formatOnSave: Bool
        public var showLineNumbers: Bool
        public var languageServers: [LanguageServerConfig]
        public var dismissedInstallNudges: [String]
        public var userDefinedRecipes: [String: [InstallRecipe]]
        public var showMinimap: Bool = true
        public var showInvisibleCharacters: Bool = false
        public var showSpaces: Bool = true
        public var showTabs: Bool = true
        public var showLineEndings: Bool = true
        public var showWarningCharacters: Bool = true
        public var warningCharacters: [WarningCharacter] = WarningCharacter.defaults
        public var inlayHints = InlayHintSettings()
        public var inlayHintsByLanguage: [String: InlayHintSettings] = [:]
        public var codeThemeFamily: String = "default"

        public func inlayHints(for language: String) -> InlayHintSettings {
            inlayHintsByLanguage[language] ?? inlayHints
        }

        public mutating func toggleInlayHints(for language: String) {
            var settings = inlayHints(for: language)
            settings.enabled.toggle()
            inlayHintsByLanguage[language] = settings
        }

        public enum CodingKeys: String, CodingKey, Sendable {
            case fontFamily, fontSize, formatOnSave, showLineNumbers, showMinimap,
                 languageServers, dismissedInstallNudges, userDefinedRecipes,
                 showInvisibleCharacters, showSpaces, showTabs, showLineEndings,
                 showWarningCharacters, warningCharacters, inlayHints, inlayHintsByLanguage,
                 codeThemeFamily
        }

        public init(fontFamily: String, fontSize: Int, formatOnSave: Bool, showLineNumbers: Bool, languageServers: [LanguageServerConfig], dismissedInstallNudges: [String], userDefinedRecipes: [String: [InstallRecipe]], showMinimap: Bool = true, showInvisibleCharacters: Bool = false, showSpaces: Bool = true, showTabs: Bool = true, showLineEndings: Bool = true, showWarningCharacters: Bool = true, warningCharacters: [WarningCharacter] = WarningCharacter.defaults, inlayHints: InlayHintSettings = InlayHintSettings(), inlayHintsByLanguage: [String: InlayHintSettings] = [:], codeThemeFamily: String = "default") {
            self.fontFamily = fontFamily
            self.fontSize = fontSize
            self.formatOnSave = formatOnSave
            self.showLineNumbers = showLineNumbers
            self.languageServers = languageServers
            self.dismissedInstallNudges = dismissedInstallNudges
            self.userDefinedRecipes = userDefinedRecipes
            self.showMinimap = showMinimap
            self.showInvisibleCharacters = showInvisibleCharacters
            self.showSpaces = showSpaces
            self.showTabs = showTabs
            self.showLineEndings = showLineEndings
            self.showWarningCharacters = showWarningCharacters
            self.warningCharacters = warningCharacters
            self.inlayHints = inlayHints
            self.inlayHintsByLanguage = inlayHintsByLanguage
            self.codeThemeFamily = codeThemeFamily
        }
    }

    public struct Markdown: Codable, Equatable, Sendable {
        public var defaultViewMode: MarkdownViewMode

        public enum CodingKeys: String, CodingKey, Sendable {
            case defaultViewMode
        }

        public init(defaultViewMode: MarkdownViewMode) {
            self.defaultViewMode = defaultViewMode
        }
    }

    public struct Changes: Codable, Equatable, Sendable {
        /// Agent id for AI features, `automaticAIToolID`, or `disabledAIToolID`.
        public var aiToolId: String
        public var prompt: String
        public var reviewRequestPrompt: String
        /// Workspace-level "fix every merge conflict in this repo"
        /// prompt fed to the agent CWD'd at the worktree. The agent
        /// uses its own filesystem tools to enumerate + reconcile.
        public var mergeBulkResolvePrompt: String
        /// Single-file resolve template — the instructions portion
        /// only. The three sides (LOCAL/BASE/REMOTE/MERGED) are
        /// appended verbatim by `MergeAgent`. `{filePath}` and
        /// `{language}` are substituted; anything else passes through.
        public var mergeSingleResolvePrompt: String
        /// How the Commits section chooses its comparison base.
        /// - `auto` (default): compare against `origin/<base>` (falls back to
        ///   local `<base>`); stable across rebases.
        /// - `branchUpstream`: compare against the branch's own `@{u}`.
        /// - `manual`: compare against the per-worktree selected base branch.
        public enum ChangesComparisonMode: String, Codable, Sendable {
            case auto
            case branchUpstream
            case manual
        }
        public var comparisonMode: ChangesComparisonMode
        public var diffLayoutMode: DiffLayoutMode
        public var diffShowWhitespace: Bool
        /// Master switch for the gg stacked-diffs integration. On by
        /// default — without gg installed the later gates hide all UI.
        public var stackedDiffsEnabled: Bool = true
        /// Defaults for newly bound PR shepherd records (Settings > Changes).
        public var shepherd: ShepherdDefaults = .init()

        public enum CodingKeys: String, CodingKey, Sendable {
            case aiToolId, prompt, reviewRequestPrompt, mergeBulkResolvePrompt,
                 mergeSingleResolvePrompt, comparisonMode,
                 diffLayoutMode, diffShowWhitespace, stackedDiffsEnabled, shepherd
        }

        public init(aiToolId: String, prompt: String, reviewRequestPrompt: String, mergeBulkResolvePrompt: String, mergeSingleResolvePrompt: String, comparisonMode: ChangesComparisonMode, diffLayoutMode: DiffLayoutMode, diffShowWhitespace: Bool, stackedDiffsEnabled: Bool = true) {
            self.aiToolId = aiToolId
            self.prompt = prompt
            self.reviewRequestPrompt = reviewRequestPrompt
            self.mergeBulkResolvePrompt = mergeBulkResolvePrompt
            self.mergeSingleResolvePrompt = mergeSingleResolvePrompt
            self.comparisonMode = comparisonMode
            self.diffLayoutMode = diffLayoutMode
            self.diffShowWhitespace = diffShowWhitespace
            self.stackedDiffsEnabled = stackedDiffsEnabled
        }

        /// Use the first available agent that fits the feature.
        public static let automaticAIToolID = ""
        /// AI features off, chosen explicitly in Settings → Changes.
        public static let disabledAIToolID = "off"

        /// Before Automatic existed, "none" was both the default and the
        /// explicit opt-out, so a stored "none" cannot be told apart from an
        /// untouched default. It decodes as Automatic; opting out again is
        /// stored as `disabledAIToolID`.
        static func migratedAIToolID(_ stored: String?) -> String {
            guard let stored, stored != "none" else { return automaticAIToolID }
            return stored
        }
    }

    /// Legacy key retained only so `AppConfig.init(from:)` can migrate
    /// pre-`comparisonMode` configs; no stored property backs it.
    private enum LegacyChangesKey: String, CodingKey {
        case trackUpstreamForCommits
    }

    public struct Agents: Codable, Equatable, Sendable {
        public var builtinState: [String: BuiltinAgentState]
        public var custom: [AgentDefinition]
        /// Agents installed from the ACP registry (Settings → Agents).
        public var registry: [ACPRegistryInstalledAgent] = []
        public var worktreeAutoLaunch: WorktreeAutoLaunch
        /// Which surface the ⌥⌘T launcher opens on by default —
        /// terminal tab or ACP chat. The user can flip with the
        /// segmented control inside the launcher; this just picks the
        /// starting mode.
        public var defaultLauncherMode: LauncherMode
        public var chatFontFamily: String
        public var chatFontSize: Int
        /// Material behind agent chat. `.none` keeps the opaque theme gradient.
        public var chatBackgroundMaterial: SidebarMaterialChoice

        public enum CodingKeys: String, CodingKey, Sendable {
            case builtinState, custom, registry, worktreeAutoLaunch, defaultLauncherMode,
                 chatFontFamily, chatFontSize, chatBackgroundMaterial
        }

        public init(builtinState: [String: BuiltinAgentState], custom: [AgentDefinition], registry: [ACPRegistryInstalledAgent] = [], worktreeAutoLaunch: WorktreeAutoLaunch, defaultLauncherMode: LauncherMode, chatFontFamily: String, chatFontSize: Int, chatBackgroundMaterial: SidebarMaterialChoice = .none) {
            self.builtinState = builtinState
            self.custom = custom
            self.registry = registry
            self.worktreeAutoLaunch = worktreeAutoLaunch
            self.defaultLauncherMode = defaultLauncherMode
            self.chatFontFamily = chatFontFamily
            self.chatFontSize = chatFontSize
            self.chatBackgroundMaterial = chatBackgroundMaterial
        }
    }

    public enum LauncherMode: String, Codable, Equatable, CaseIterable, Sendable {
        case terminal, acp
    }

    public enum WorktreeSortMode: String, Codable, Equatable, CaseIterable, Sendable {
        case manual
        case creationDesc
        case creationAsc
        case lastUpdateDesc
        case lastUpdateAsc
        case branchAsc
    }

    public struct Files: Codable, Equatable, Sendable {
        public var showIgnored: Bool
        /// Height of the Files-tab bookmarks drawer, in points. Nil until
        /// the user drags the divider; the drawer then picks its default
        /// from the pane height.
        public var bookmarksPaneHeight: Double?
        public var bookmarksCollapsed: Bool = false

        public enum CodingKeys: String, CodingKey, Sendable {
            case showIgnored, bookmarksPaneHeight, bookmarksCollapsed
        }

        public init(showIgnored: Bool, bookmarksPaneHeight: Double? = nil, bookmarksCollapsed: Bool = false) {
            self.showIgnored = showIgnored
            self.bookmarksPaneHeight = bookmarksPaneHeight
            self.bookmarksCollapsed = bookmarksCollapsed
        }
    }

    public struct WorktreeAutoLaunch: Codable, Equatable, Sendable {
        public var agentId: String?
        public var useBypassPermissions: Bool

        public enum CodingKeys: String, CodingKey, Sendable {
            case agentId, useBypassPermissions
        }

        public init(agentId: String? = nil, useBypassPermissions: Bool) {
            self.agentId = agentId
            self.useBypassPermissions = useBypassPermissions
        }
    }

    public static let defaults = AppConfig(
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
            syncTabTitleWithTerminalTitle: true,
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
            aiToolId: Changes.automaticAIToolID,
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
            defaultLauncherMode: .acp,
            chatFontFamily: "",
            chatFontSize: 13
        ),
        files: Files(showIgnored: true, bookmarksPaneHeight: nil),
        nextPromptSuggestionsEnabled: false,
        sessionSummariesEnabled: false,
        localTextModelEnabled: false,
        issueWorktreeNameSuggestionsEnabled: true,
        pluginsEnabled: true,
        recentProjectIds: [],
        recentWorktreeIdsByProject: [:],
        recentWorktreeRefs: [],
        collapsedProjectIds: [],
        sidebarChromeOverrides: SidebarChromeOverride.bundledDefaults,
        contentMaterialOverrides: ContentMaterialOverride.bundledDefaults,
        shortcutOverrides: [:]
    )

    public init(themeId: String, accent: String, matchSystemTheme: Bool, sidebarMaterial: SidebarMaterialChoice, sidebarWidth: Double, rightPaneWidth: Double, rightPaneVisible: Bool, sidebarVisible: Bool, commitDetailSplitRatio: Double, general: General, worktrees: Worktrees, terminal: Terminal, harness: Harness, code: Code, markdown: Markdown, changes: Changes, agents: Agents, files: Files, remote: Remote = .init(), nextPromptSuggestionsEnabled: Bool = false, sessionSummariesEnabled: Bool = false, runFailureBriefsEnabled: Bool = true, localTextModelEnabled: Bool = false, issueWorktreeNameSuggestionsEnabled: Bool = true, pluginsEnabled: Bool = true, recentProjectIds: [String] = [], recentWorktreeIdsByProject: [String: [String]] = [:], recentWorktreeRefs: [RepoSelectorRecents.RecentWorktreeRef] = [], collapsedProjectIds: [String] = [], sidebarChromeOverrides: [String: SidebarChromeOverride] = [:], contentMaterialOverrides: [String: ContentMaterialOverride] = [:], shortcutOverrides: [String: ShortcutBinding?] = [:], repositoryCloneRootPath: String = "") {
        self.themeId = themeId
        self.accent = accent
        self.matchSystemTheme = matchSystemTheme
        self.sidebarMaterial = sidebarMaterial
        self.sidebarWidth = sidebarWidth
        self.rightPaneWidth = rightPaneWidth
        self.rightPaneVisible = rightPaneVisible
        self.sidebarVisible = sidebarVisible
        self.commitDetailSplitRatio = commitDetailSplitRatio
        self.general = general
        self.worktrees = worktrees
        self.terminal = terminal
        self.harness = harness
        self.code = code
        self.markdown = markdown
        self.changes = changes
        self.agents = agents
        self.files = files
        self.remote = remote
        self.nextPromptSuggestionsEnabled = nextPromptSuggestionsEnabled
        self.sessionSummariesEnabled = sessionSummariesEnabled
        self.runFailureBriefsEnabled = runFailureBriefsEnabled
        self.localTextModelEnabled = localTextModelEnabled
        self.issueWorktreeNameSuggestionsEnabled = issueWorktreeNameSuggestionsEnabled
        self.pluginsEnabled = pluginsEnabled
        self.recentProjectIds = recentProjectIds
        self.recentWorktreeIdsByProject = recentWorktreeIdsByProject
        self.recentWorktreeRefs = recentWorktreeRefs
        self.collapsedProjectIds = collapsedProjectIds
        self.sidebarChromeOverrides = sidebarChromeOverrides
        self.contentMaterialOverrides = contentMaterialOverrides
        self.shortcutOverrides = shortcutOverrides
        self.repositoryCloneRootPath = repositoryCloneRootPath
    }
}

extension AppConfig {
    public static let defaultCommitPrompt = """
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

    public static let defaultReviewRequestPrompt = """
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

    public static let defaultMergeBulkResolvePrompt = """
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

    public static let defaultMergeSingleResolvePrompt = """
    You are resolving a Git merge conflict in {filePath}.
    Language: {language}
    Reconcile LOCAL and REMOTE intent into the smallest correct merged file.
    Output ONLY the resolved file contents — no conflict markers, no prose,
    no markdown fences, no commentary.
    """
}

extension AppConfig {
    public enum CodingKeys: String, CodingKey, Sendable {
        case themeId, accent, matchSystemTheme,
             sidebarMaterial, sidebarWidth, rightPaneWidth, rightPaneVisible, sidebarVisible,
             commitDetailSplitRatio,
             general, worktrees, terminal, harness, code, markdown, changes,
             agents,
             files,
             remote,
             nextPromptSuggestionsEnabled,
             sessionSummariesEnabled,
             runFailureBriefsEnabled,
             localTextModelEnabled,
             issueWorktreeNameSuggestionsEnabled,
             pluginsEnabled,
             recentProjectIds, recentWorktreeIdsByProject, recentWorktreeRefs,
             collapsedProjectIds,
             sidebarChromeOverrides,
             contentMaterialOverrides,
             shortcutOverrides,
             repositoryCloneRootPath
    }

    // Custom decode tolerates older config files that predate `code`.
    // Swift still synthesizes encode(to:) automatically.
    public init(from decoder: Decoder) throws {
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
            let syncTabTitleWithTerminalTitle = (try? termContainer.decode(Bool.self, forKey: .syncTabTitleWithTerminalTitle)) ?? true
            let confirmCloseTabs = (try? termContainer.decode(Bool.self, forKey: .confirmCloseTabs)) ?? false
            let keepSessionsAlive = (try? termContainer.decode(Bool.self, forKey: .keepSessionsAlive)) ?? true
            let backgroundMaterial = SidebarMaterialChoice.centerPaneMaterial(
                try? termContainer.decode(SidebarMaterialChoice.self, forKey: .backgroundMaterial)
            )
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
                keepSessionsAlive: keepSessionsAlive,
                backgroundMaterial: backgroundMaterial
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
                syncTabTitleWithTerminalTitle: true,
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
                showMinimap: (try? codeContainer.decode(Bool.self, forKey: .showMinimap)) ?? true,
                showInvisibleCharacters: showInvisibleCharacters,
                showSpaces: showSpaces,
                showTabs: showTabs,
                showLineEndings: showLineEndings,
                showWarningCharacters: showWarningCharacters,
                warningCharacters: warningCharacters,
                inlayHints: (try? codeContainer.decode(InlayHintSettings.self, forKey: .inlayHints)) ?? .init(),
                inlayHintsByLanguage: (try? codeContainer.decode([String: InlayHintSettings].self, forKey: .inlayHintsByLanguage)) ?? [:],
                codeThemeFamily: (try? codeContainer.decode(String.self, forKey: .codeThemeFamily)) ?? "default"
            )
            code.migrateLegacyYAMLNudgeState()
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
            let toolId = Changes.migratedAIToolID(try? changesContainer.decode(String.self, forKey: .aiToolId))
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
            changes.shepherd =
                (try? changesContainer.decode(ShepherdDefaults.self, forKey: .shepherd)) ?? .init()
        } else {
            changes = Changes(
                aiToolId: Changes.automaticAIToolID,
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
            let registry = (try? agentsContainer.decode(
                [ACPRegistryInstalledAgent].self, forKey: .registry
            )) ?? []
            let autoLaunch = (try? agentsContainer.decode(
                WorktreeAutoLaunch.self, forKey: .worktreeAutoLaunch
            )) ?? WorktreeAutoLaunch(agentId: nil, useBypassPermissions: false)
            let defaultMode = (try? agentsContainer.decode(
                LauncherMode.self, forKey: .defaultLauncherMode
            )) ?? .acp
            let chatFontFamily = (try? agentsContainer.decode(
                String.self, forKey: .chatFontFamily
            )) ?? ""
            let rawChatFontSize = (try? agentsContainer.decode(
                Int.self, forKey: .chatFontSize
            )) ?? 13
            let chatFontSize = max(8, min(64, rawChatFontSize))
            let chatBackgroundMaterial = SidebarMaterialChoice.centerPaneMaterial(try? agentsContainer.decode(
                SidebarMaterialChoice.self, forKey: .chatBackgroundMaterial
            ))
            agents = Agents(
                builtinState: state,
                custom: custom,
                registry: registry,
                worktreeAutoLaunch: autoLaunch,
                defaultLauncherMode: defaultMode,
                chatFontFamily: chatFontFamily,
                chatFontSize: chatFontSize,
                chatBackgroundMaterial: chatBackgroundMaterial
            )
        } else {
            agents = Agents(
                builtinState: [:],
                custom: [],
                worktreeAutoLaunch: WorktreeAutoLaunch(
                    agentId: nil, useBypassPermissions: false
                ),
                defaultLauncherMode: .acp,
                chatFontFamily: "",
                chatFontSize: 13
            )
        }
        if let filesContainer = try? c.nestedContainer(
            keyedBy: AppConfig.Files.CodingKeys.self, forKey: .files
        ) {
            let showIgnored = (try? filesContainer.decode(Bool.self, forKey: .showIgnored)) ?? true
            files = Files(
                showIgnored: showIgnored,
                bookmarksPaneHeight: try? filesContainer.decode(Double.self, forKey: .bookmarksPaneHeight),
                bookmarksCollapsed: (try? filesContainer.decode(Bool.self, forKey: .bookmarksCollapsed)) ?? false
            )
        } else {
            files = Files(showIgnored: true, bookmarksPaneHeight: nil)
        }
        // Older configs predate `remote`; default to disabled so they still load.
        remote = (try? c.decodeIfPresent(Remote.self, forKey: .remote)) ?? .init()
        nextPromptSuggestionsEnabled = (try? c.decode(Bool.self, forKey: .nextPromptSuggestionsEnabled)) ?? false
        sessionSummariesEnabled = (try? c.decode(Bool.self, forKey: .sessionSummariesEnabled)) ?? false
        runFailureBriefsEnabled = (try? c.decode(Bool.self, forKey: .runFailureBriefsEnabled)) ?? true
        let priorModelConsent = nextPromptSuggestionsEnabled || sessionSummariesEnabled
        localTextModelEnabled =
            (try? c.decode(Bool.self, forKey: .localTextModelEnabled)) ?? priorModelConsent
        issueWorktreeNameSuggestionsEnabled =
            (try? c.decode(Bool.self, forKey: .issueWorktreeNameSuggestionsEnabled))
            ?? (harness.acpLocalTitlesEnabled || priorModelConsent)
        pluginsEnabled = (try? c.decode(Bool.self, forKey: .pluginsEnabled)) ?? true
        recentProjectIds = (try? c.decode([String].self, forKey: .recentProjectIds)) ?? []
        recentWorktreeIdsByProject =
            (try? c.decode([String: [String]].self, forKey: .recentWorktreeIdsByProject)) ?? [:]
        recentWorktreeRefs =
            (try? c.decode([RepoSelectorRecents.RecentWorktreeRef].self, forKey: .recentWorktreeRefs)) ?? []
        collapsedProjectIds =
            (try? c.decode([String].self, forKey: .collapsedProjectIds)) ?? []
        sidebarChromeOverrides =
            (try? c.decode([String: SidebarChromeOverride].self, forKey: .sidebarChromeOverrides)) ?? [:]
        contentMaterialOverrides =
            (try? c.decode([String: ContentMaterialOverride].self, forKey: .contentMaterialOverrides)) ?? [:]
        shortcutOverrides =
            (try? c.decode([String: ShortcutBinding?].self, forKey: .shortcutOverrides)) ?? [:]
        repositoryCloneRootPath =
            (try? c.decode(String.self, forKey: .repositoryCloneRootPath)) ?? ""
        migrateLegacyFindAndReplaceShortcutOverride()
        migrateLegacyAgentLauncherShortcutOverrides()
        removeShortcutOverridesCollidingWithReservedBindings()
        // Last: it must see the final override set.
        unbindNewActionDefaultsClaimedByOverrides()
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

    /// Actions added after the first release ship defaults an older config may
    /// already have assigned to something else — legal at the time, since
    /// `conflict(for:excluding:)` only guards interactive assignment in
    /// Settings, never decode. Without an override of their own the new
    /// actions would silently claim the same chord and both menu items would
    /// register it. Leave the user's binding alone and start the new action
    /// explicitly unbound; Settings can restore its default once the chord is
    /// free.
    ///
    /// Covers the agent-launcher split (⌘⌥⇧C, ⌘⌥⇧T) and the right pane's rail
    /// tabs (⌘⌃1–4).
    mutating func unbindNewActionDefaultsClaimedByOverrides() {
        let newActions: [ShortcutAction] = [
            .launchAgentInTerminal, .launchAgentInChat,
            .rightPaneChangesTab, .rightPaneFilesTab, .rightPaneAgentTab, .rightPaneRunTab, .rightPaneSchedulesTab,
        ]
        for action in newActions {
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
    public func sidebarChromeOverride(forThemeId themeId: String) -> SidebarChromeOverride {
        if let saved = sidebarChromeOverrides[themeId] { return saved }
        return SidebarChromeOverride.bundledDefaults[themeId] ?? .zero
    }

    public func contentMaterialOverride(forThemeId themeId: String) -> ContentMaterialOverride {
        if let saved = contentMaterialOverrides[themeId] { return saved }
        return ContentMaterialOverride.bundledDefaults[themeId] ?? .zero
    }
}
