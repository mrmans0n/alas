import Foundation
import Observation

enum PluginHostState: Equatable, Sendable {
    case loaded
    case activating
    case active
    case deactivating
    case stopped
    case failed(String)
}

struct PluginTraceEntry: Equatable, Sendable {
    enum Direction: Sendable {
        case toPlugin
        case fromPlugin
    }

    let direction: Direction
    let text: String
}

struct PluginLogEntry: Equatable, Sendable {
    let level: String
    let message: String
}

struct PluginTaskRequest: Equatable, Sendable {
    let title: String
    let prompt: String
    let branch: String?
    let agent: String?
}

/// What `prompt/expand` gave: the prompt text, or why there is none, ready to show the user.
enum PluginPromptExpansion: Equatable {
    case text(String)
    case failed(String)
    /// Another expansion for the same session is still waiting; a repeated send is ignored.
    case busy
}

enum PluginTaskStart: Equatable {
    case started(sessionId: String, branch: String)
    case rejected(code: Int, message: String)
}

/// What a plugin may ask Alas to do, already scoped to one project.
@MainActor
struct PluginHostActions {
    var snapshot: () -> PluginWorkspaceSnapshot
    /// Returns false when `id` is not a worktree of this project.
    var switchWorktree: (String) -> Bool
    /// Returns false when `id` is not an active session of this project.
    var focusSession: (String) -> Bool
    /// The session's last agent reply, untruncated; the host bounds it.
    var lastMessage: (String) -> PluginLastMessage
    /// Agents that can be started, in registry order.
    var agents: () -> [PluginAgent]
    /// Returns synchronously; the completion is called once, later, with nil on success or the failure reason.
    var startTask: (PluginTaskRequest, @escaping @MainActor (String?) -> Void) -> PluginTaskStart
    /// Shows `title` and `body`, already bounded and naming the plugin.
    var notify: (_ title: String, _ body: String) -> Void
    /// The latest run of each script in the project's worktrees.
    var runs: () -> [PluginRunState] = { [] }
    /// The pull request state of the project's worktrees whose review loop has loaded.
    var reviews: () -> [PluginReviewState] = { [] }
    /// Queues `text` as a prompt for a live agent session of this project; false when there is none with that id.
    /// Returns nil once the session accepted the prompt, or why it did not.
    var sendToSession: (_ session: String, _ text: String) async -> String? = { _, _ in "unknown session" }
    /// Starts a run script, by its key, in a worktree of this project. Returns why not, or nil.
    var startRun: @MainActor (_ worktree: String, _ script: String) async -> String? = { _, _ in "runs are not available" }
    /// The output of a run of this project.
    var runOutput: @MainActor (_ run: String) async -> PluginRunOutput = { _ in .unknownRun }
    /// Adds a draft review comment, written by `author`, on a line of a file in a worktree of this project.
    /// Returns why not, or nil.
    var addReviewComment: @MainActor (_ comment: PluginReviewCommentParams, _ author: String) async -> String? = { _, _ in
        "review comments are not available"
    }
    /// Where a worktree of this project lives; nil for any other id.
    var worktreeLocation: (_ worktree: String) -> PluginWorktreeLocation? = { _ in nil }

    /// For hosts whose owner is gone: reads nothing and refuses every action.
    static var inert: PluginHostActions {
        PluginHostActions(
            snapshot: { PluginWorkspaceSnapshot(worktrees: []) },
            switchWorktree: { _ in false },
            focusSession: { _ in false },
            lastMessage: { _ in .unknownSession },
            agents: { [] },
            startTask: { _, _ in .rejected(code: -32003, message: "tasks are not available") },
            notify: { _, _ in })
    }
}

enum PluginWorktreeLocation: Equatable, Sendable {
    case local(URL)
    /// `root` is the worktree's real path on `host`.
    case remote(host: String, root: String)
}

/// Runs one plugin in one project.
@MainActor
@Observable
final class PluginHost {
    private static let activateID = JSONRPCID.number(0)
    /// Every request method, with the capability it needs; nil means none.
    private static let methods: [String: PluginCapability?] = [
        "workspace/snapshot": .workspaceRead,
        "worktree/switch": .worktreeSwitch,
        "session/focus": .sessionFocus,
        "session/last_message": .sessionRead,
        "agent/list": .workspaceRead,
        "task/start": .tasksStart,
        "storage/get": nil,
        "storage/set": nil,
        "storage/keys": nil,
        "settings/get": nil,
        "http/fetch": .network,
        "timer/set": .timers,
        "timer/cancel": .timers,
        "session/send": .sessionWrite,
        "run/start": .runsStart,
        "run/output": .runsRead,
        "review/comment": .reviewWrite,
        "process/run": .processExec,
        "process/start": .processExec,
        "process/stop": .processExec,
        "file/read": .filesRead,
        "file/list": .filesRead,
        "file/write": .filesWrite,
        "prompts/set": nil,
    ]
    /// Methods a manifest for an older API does not know.
    private static let api6Methods: Set<String> = [
        "session/send", "run/start", "run/output", "review/comment",
        "process/run", "process/start", "process/stop", "file/read", "file/list", "file/write",
    ]
    private static let api9Methods: Set<String> = ["prompts/set"]
    static let maxProcessesRunning = 2
    static let maxProcessArgs = 32
    static let maxProcessStdinBytes = 256 << 10
    static let processTimeout: Duration = .seconds(600)
    /// Between asking a process to stop and killing it.
    static let processKillGrace: Duration = .seconds(5)
    /// Output the Run tab keeps for a long-running process.
    static let processRunOutputBytes = 64 << 10
    /// Long-running processes listed in the Run tab, exited ones included; the oldest exited go first.
    static let maxProcessRuns = 8
    static let maxRunOutputBytes = 64 * 1024
    static let maxRequestsInFlight = 4
    static let maxPromptBytes = 32 * 1024
    static let maxSecretSubstitutions = 8
    private static let traceLimit = 100
    private static let logLimit = 200
    static let logMessageLimit = 2000
    static let maxRegions = 256
    static let regionIDByteLimit = 64
    static let regionLabelLimit = 200
    private static let logLevels: Set<String> = ["debug", "info", "warn", "error"]
    static let notifyTitleLimit = 80
    static let notifyBodyLimit = 500
    static let notifyInterval: Duration = .seconds(2)
    static let maxFetchesInFlight = 4
    static let maxTimers = 8
    static let timerIDByteLimit = 64
    static let timerSeconds: ClosedRange<Double> = 60...86_400
    static let maxContextBytes = 16 * 1024
    /// How long `prompt/expand` waits for its answer, which may come after the plugin's own requests (API 7).
    static let promptExpandTimeout: Duration = .seconds(30)
    private static let httpMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    let manifest: PluginManifest
    let project: PluginProjectRef
    let grants: Set<PluginCapability>
    private(set) var state: PluginHostState = .loaded
    private(set) var trace: [PluginTraceEntry] = []
    private(set) var log: [PluginLogEntry] = []
    private(set) var frames: [Int: PluginFrame] = [:]
    private(set) var regions: [Int: [PluginRegion]] = [:]
    private(set) var views: [Int: PluginViewNode] = [:]
    /// Panel trees, by the manifest's panel id, and the worktree or run each was last rendered for.
    private(set) var panelViews: [String: PluginViewNode] = [:]
    private(set) var panelPlaces: [String: PluginPanelPlace] = [:]
    /// Badges the plugin put on rows with `decorations/set`. Cleared whenever the instance ends.
    private(set) var decorations: [PluginDecorationKey: [PluginDecoration]] = [:]
    /// Long-running processes this instance started, shown in the Run tab; kept after they exit until the next start.
    private(set) var processRuns: [PluginProcessRun] = []
    /// Slash prompts the instance set with `prompts/set` (API 9), offered beside the manifest's. Cleared when it ends.
    private(set) var runtimePrompts: [PluginPromptContribution] = []
    /// Called after this instance stores a key in plugin-scoped storage (API 9), so the other instances hear of it.
    @ObservationIgnored var pluginStorageSet: (String) -> Void = { _ in }
    /// How many views show each tab, by index. Owned by the UI, so it outlives a restart.
    @ObservationIgnored private var visibleTabs: [Int: Int] = [:]
    /// How many views show each panel in each place. Owned by the UI, so it outlives a restart.
    @ObservationIgnored private var visiblePanels: [PluginPanelPlace: Int] = [:]
    @ObservationIgnored private var lastTick: ContinuousClock.Instant?
    @ObservationIgnored private var deliveriesInFlight = 0
    /// One `task/start` at a time. The generation ties a completion to its own start, so a late,
    /// repeated, or previous-instance completion changes nothing.
    @ObservationIgnored private var taskInFlight = false
    @ObservationIgnored private var taskGeneration = 0
    @ObservationIgnored private var pendingTaskSession: String?
    @ObservationIgnored private var lastNotify: ContinuousClock.Instant?
    @ObservationIgnored private var warnedNotifyNotGranted = false
    /// Bumped whenever an instance starts or ends, so a fetch reply or timer from an earlier one is dropped.
    @ObservationIgnored private var instance = 0
    /// Running fetches by token, so ending the instance can cancel them rather than let them finish unheard.
    @ObservationIgnored private var fetches: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextFetchToken = 0
    /// The latest `panel/visible` or `tab/visible` delivery; each waits for the one before.
    @ObservationIgnored private var visibilityDelivery: Task<Void, Never>?
    /// Requests answered in a later delivery (`run/start`, `run/output`, `review/comment`), by token.
    @ObservationIgnored private var requests: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    /// Running processes of this instance, by run id. Ending the instance stops them.
    @ObservationIgnored private var processes: [String: any PluginProcessHandle] = [:]
    @ObservationIgnored private var nextProcess = 0
    /// With the instance, the lease remote processes are owned by: the helper refuses calls about them under any other.
    @ObservationIgnored private let processLease = UUID().uuidString
    /// Requests Alas sent to the plugin (`prompt/expand`, `context/provide`), waiting for its response, by id.
    @ObservationIgnored private var hostRequests: [Int: CheckedContinuation<Data?, Never>] = [:]
    @ObservationIgnored private var nextHostRequest = 0

    @ObservationIgnored private let source: Data
    @ObservationIgnored private let actions: PluginHostActions
    @ObservationIgnored private let storage: PluginStorage
    /// Shared by every instance of the plugin, in every project (API 9).
    @ObservationIgnored private let pluginStorage: PluginStorage
    @ObservationIgnored private let limits: PluginLimits
    @ObservationIgnored private var runtime: PluginRuntime?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let settings: PluginSettings
    @ObservationIgnored private let transport: any PluginHTTPTransport
    @ObservationIgnored private let launcher: any PluginProcessLauncher
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        manifest: PluginManifest,
        source: Data,
        project: PluginProjectRef,
        grants: Set<PluginCapability>,
        actions: PluginHostActions,
        storage: PluginStorage,
        pluginStorage: PluginStorage,
        settings: PluginSettings,
        transport: any PluginHTTPTransport = PluginURLSessionTransport(),
        launcher: any PluginProcessLauncher = PluginFoundationLauncher(),
        limits: PluginLimits = PluginLimits(),
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.manifest = manifest
        self.source = source
        self.project = project
        self.grants = grants
        self.actions = actions
        self.storage = storage
        self.pluginStorage = pluginStorage
        self.limits = limits
        self.now = now
        self.settings = settings
        self.transport = transport
        self.launcher = launcher
        self.sleep = sleep
    }

    private var isRunning: Bool { state == .activating || state == .active }

    /// Starts a fresh instance. Also used to restart after `stopped` or `failed`.
    func activate() async {
        guard !isRunning, state != .deactivating else { return }
        state = .activating
        trace = []
        log = []
        clearCanvas()
        taskInFlight = false
        taskGeneration += 1
        warnedNotifyNotGranted = false
        endInstance()
        processRuns = []
        do {
            let loaded = try await PluginRuntime.load(
                source: source, limits: limits, tabCount: manifest.tabs.count)
            guard state == .activating else { return }  // deactivated while the script loaded
            runtime = loaded
        } catch {
            guard state == .activating else { return }
            fail(String(describing: error))
            return
        }
        let params = PluginActivateParams(
            api: manifest.api, project: project,
            grants: grants.sorted { $0.rawValue < $1.rawValue })
        await deliver(
            encode(JSONRPCEnvelope(id: Self.activateID, method: "alas/activate", params: params)),
            isActivation: true)
        // A fresh instance learns which of its panels are already on screen.
        let shown = visiblePanels.filter { $0.value > 0 }.keys
            .sorted { ($0.panel, $0.worktree ?? "", $0.run ?? "") < ($1.panel, $1.worktree ?? "", $1.run ?? "") }
        for place in shown {
            guard state == .active else { return }
            await sendPanelVisible(place, true)
        }
        guard manifest.api >= 9 else { return }
        for tab in visibleTabs.keys.sorted() {
            guard state == .active else { return }
            await sendTabVisible(tab, true)
        }
    }

    /// The tree to show for `place`: nil until the plugin renders for that worktree or run, and while it is empty.
    func panelTree(for place: PluginPanelPlace) -> PluginViewNode? {
        guard panelPlaces[place.panel] == place, let root = panelViews[place.panel] else { return nil }
        return root.isEmpty ? nil : root
    }

    /// Each place that shows the panel holds one count; `panel/visible` is sent when the first appears or the last goes.
    /// Counts synchronously, so rapid show and hide calls can never leave a stale count, and delivers each
    /// transition after the previous one, so the plugin sees them in order. Returns the delivery, if any.
    @discardableResult
    func setPanelVisible(_ panel: String, _ visible: Bool) -> Task<Void, Never>? {
        setPanelVisible(PluginPanelPlace(panel: panel), visible)
    }

    /// Counted per place, so a panel shown for one run and then another is reported for each.
    @discardableResult
    func setPanelVisible(_ place: PluginPanelPlace, _ visible: Bool) -> Task<Void, Never>? {
        guard manifest.panels.contains(where: { $0.id == place.panel }) else { return nil }
        let before = visiblePanels[place, default: 0]
        let after = max(0, before + (visible ? 1 : -1))
        visiblePanels[place] = after == 0 ? nil : after
        guard (before == 0) != (after == 0) else { return nil }
        return queueVisibility { await $0.sendPanelVisible(place, visible) }
    }

    /// Each view showing one of the plugin's tabs, canvas or view, holds one count; API 9 plugins get `tab/visible`
    /// when the first appears or the last goes, as for panels. Canvas tabs tick only while one is shown.
    @discardableResult
    func setTabVisible(_ tab: Int, _ visible: Bool) -> Task<Void, Never>? {
        guard manifest.tabs.indices.contains(tab) else { return nil }
        let before = visibleTabs[tab, default: 0]
        let after = max(0, before + (visible ? 1 : -1))
        visibleTabs[tab] = after == 0 ? nil : after
        if !canvasVisible { lastTick = nil }
        guard (before == 0) != (after == 0), manifest.api >= 9 else { return nil }
        return queueVisibility { await $0.sendTabVisible(tab, visible) }
    }

    /// Delivers after the previous visibility change, so the plugin sees them in order.
    private func queueVisibility(_ send: @escaping @MainActor (PluginHost) async -> Void) -> Task<Void, Never>? {
        guard state == .active else { return nil }
        let previous = visibilityDelivery
        let instance = instance
        let delivery = Task { [weak self] in
            await previous?.value
            // Meant for this instance only: a restart in between gets its own report after activating.
            guard let self, self.instance == instance, !Task.isCancelled else { return }
            await send(self)
        }
        visibilityDelivery = delivery
        return delivery
    }

    private func sendTabVisible(_ tab: Int, _ visible: Bool) async {
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "tab/visible", params: PluginTabVisibleParams(tab: tab, visible: visible))))
    }

    /// Another instance of this plugin stored `key` in plugin-scoped storage (API 9).
    func pluginStorageChanged(_ key: String) async {
        guard state == .active, manifest.api >= 9 else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "storage/changed", params: PluginStorageChangedParams(scope: "plugin", key: key))))
    }

    private func sendPanelVisible(_ place: PluginPanelPlace, _ visible: Bool) async {
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "panel/visible",
            params: PluginPanelVisibleParams(panel: place.panel, worktree: place.worktree, run: place.run, visible: visible))))
    }

    func workspaceChanged(_ snapshot: PluginWorkspaceSnapshot) async {
        guard state == .active, grants.contains(.workspaceRead) else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "workspace/changed", params: PluginSnapshotPayload(snapshot: snapshot))))
    }

    /// Runs one of the manifest's commands. Alas builds `target` from the slot the user chose it in.
    func runCommand(_ id: String, target: PluginCommandTarget) async {
        guard state == .active, manifest.commands.contains(where: { $0.id == id }) else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "command/run", params: PluginCommandRunParams(command: id, target: target))))
    }

    /// Sessions with an expansion waiting, so pressing Send again does not ask the plugin twice.
    @ObservationIgnored private var expandingSessions: Set<String> = []

    /// Whether this instance adds context to prompts, so the composer names it.
    var providesContext: Bool { state == .active && grants.contains(.sessionContext) }

    /// Expands one of the manifest's prompts. The answer may come in a later delivery, after the plugin's own
    /// requests, so it waits up to `promptExpandTimeout`.
    func expandPrompt(_ name: String, args: String, session: String) async -> PluginPromptExpansion {
        guard (manifest.prompts + runtimePrompts).contains(where: { $0.name == name }) else { return .failed("Unknown prompt /\(name).") }
        guard args.utf8.count <= Self.maxPromptBytes else { return .failed("The text after /\(name) is longer than 32 KiB.") }
        guard expandingSessions.insert(session).inserted else { return .busy }
        defer { expandingSessions.remove(session) }
        guard let response = await ask(
            "prompt/expand", PluginPromptExpandParams(name: name, args: args, session: session), wait: Self.promptExpandTimeout)
        else { return .failed("\(manifest.name) did not expand /\(name).") }
        if let error = response.error { return .failed("\(manifest.name) could not expand /\(name): \(Self.bounded(error.message))") }
        guard let text = response.result?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("\(manifest.name) expanded /\(name) to nothing.")
        }
        guard text.utf8.count <= Self.maxPromptBytes else { return .failed("\(manifest.name) expanded /\(name) to more than 32 KiB.") }
        return .text(text)
    }

    /// The text the plugin adds to a prompt, or nil. Answered within its own delivery or not at all, so a prompt
    /// never waits on the network; a plugin that runs past the time limit stops, as for any call.
    func provideContext(session: String, worktree: String) async -> String? {
        guard grants.contains(.sessionContext),
              let response = await ask(
                "context/provide", PluginContextProvideParams(session: session, worktree: worktree), wait: nil)
        else { return nil }
        if let error = response.error {
            appendLog("warn", "context/provide failed, so the prompt went without it: \(error.message)")
            return nil
        }
        guard let text = response.result?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.utf8.count <= Self.maxContextBytes else {
            appendLog("warn", "context/provide answered more than 16 KiB, so the prompt went without it")
            return nil
        }
        return text
    }

    /// Sends a request to the plugin and returns its response; nil when the instance ends first, or when none came
    /// within the request's own delivery (`wait` nil) or within `wait`. A malformed response counts as an error.
    private func ask(_ method: String, _ params: some Codable, wait: Duration?) async -> PluginTextResponse? {
        guard state == .active else { return nil }
        nextHostRequest += 1
        let token = nextHostRequest
        let message = encode(JSONRPCEnvelope(id: .number(token), method: method, params: params))
        let sleep = sleep
        let data = await withCheckedContinuation { continuation in
            hostRequests[token] = continuation
            // The deadline runs from the send, so round trips the plugin makes while handling it count against it.
            if let wait {
                Task { [weak self] in
                    try? await sleep(wait)
                    self?.answer(token, nil)
                }
            }
            Task { [weak self] in
                await self?.deliver(message)
                if wait == nil { self?.answer(token, nil) }
            }
        }
        guard let data else { return nil }
        return (try? JSONDecoder().decode(PluginTextResponse.self, from: data))
            ?? PluginTextResponse(error: JSONRPCError(code: -32600, message: "malformed response to \(method)", data: nil))
    }

    private func answer(_ token: Int, _ response: Data?) {
        hostRequests.removeValue(forKey: token)?.resume(returning: response)
    }

    /// Whether the manifest subscribes to an event whose capability was granted.
    var receivesEvents: Bool { manifest.events.contains { grants.contains($0.capability) } }

    /// Sends the events the manifest subscribes to and has the grant for.
    func events(_ events: [PluginEventMessage]) async {
        for event in events where manifest.events.contains(event.event) && grants.contains(event.event.capability) {
            guard state == .active else { return }
            await deliver(encode(JSONRPCEnvelope(id: nil, method: event.event.method, params: event.params)))
        }
    }

    func settingsChanged() async {
        guard state == .active else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "settings/changed", params: PluginSettingsPayload(settings))))
    }

    /// Sends `alas/deactivate`, then drops the instance whatever the plugin does.
    /// Anything the plugin sends back is ignored.
    func deactivate() async {
        endInstance()
        if state == .activating, runtime == nil {  // still loading the script
            state = .stopped
            return
        }
        guard isRunning, let runtime else {
            self.runtime = nil
            return
        }
        state = .deactivating
        let message = encode(JSONRPCEnvelope<PluginEmptyPayload>(id: nil, method: "alas/deactivate", params: nil))
        record(.toPlugin, message)
        _ = try? await runtime.handle(message)
        self.runtime = nil
        state = .stopped
        clearCanvas()
    }

    private func clearCanvas() {
        frames = [:]
        regions = [:]
        views = [:]
        panelViews = [:]
        panelPlaces = [:]
        decorations = [:]
        lastTick = nil
    }

    private var canvasVisible: Bool { visibleTabs.keys.contains { tabIs($0, .canvas) } }

    var isTicking: Bool { state == .active && canvasVisible }

    /// Dropped, not queued, while any delivery is still running, so a slow plugin loses frames instead of lagging.
    func tick(at now: ContinuousClock.Instant) async {
        guard isTicking, deliveriesInFlight == 0 else { return }
        let dt = lastTick.map { max(0, Int(((now - $0) / .milliseconds(1)).rounded())) } ?? 0
        lastTick = now
        await deliver(encode(JSONRPCEnvelope(id: nil, method: "tick", params: PluginTickParams(dt: dt))))
    }

    /// Only regions the plugin declared can be clicked.
    func click(tab: Int, region: String) async {
        guard state == .active, regions[tab]?.contains(where: { $0.id == region }) == true else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "canvas/click", params: PluginClickParams(tab: tab, region: region))))
    }

    /// Only nodes in the tab's current tree can send events.
    func viewEvent(tab: Int, id: String, kind: String, value: String?) async {
        guard state == .active, let root = views[tab], Self.contains(root, id: id) else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "view/event", params: PluginViewEventParams(tab: tab, id: id, kind: kind, value: value))))
    }

    /// Only nodes in the panel's current tree, rendered for the place the event came from, can send events: a click
    /// on a tree the plugin has since rendered for another run or worktree is dropped.
    func viewEvent(place: PluginPanelPlace, id: String, kind: String, value: String?) async {
        guard state == .active, panelPlaces[place.panel] == place, let root = panelViews[place.panel],
              Self.contains(root, id: id)
        else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "view/event",
            params: PluginViewEventParams(
                panel: place.panel, worktree: place.worktree, run: place.run, id: id, kind: kind, value: value))))
    }

    private static func contains(_ node: PluginViewNode, id: String) -> Bool {
        node.id == id || node.children.contains { contains($0, id: id) }
    }

    private func tabIs(_ tab: Int, _ kind: PluginTabContribution.Kind) -> Bool {
        manifest.tabs.indices.contains(tab) && manifest.tabs[tab].kind == kind
    }

    // MARK: - Delivery

    private enum Outcome {
        case none
        case reply(Data)
        case violation(String)
    }

    /// Delivers `first`, then any replies to requests the plugin made, each in
    /// its own `handle` call. Stops as soon as the host leaves the running
    /// states, which drops everything still queued.
    /// The activation response must come from the first call, so an activation
    /// delivery fails as soon as that call's messages are processed without one.
    private func deliver(_ first: Data, isActivation: Bool = false) async {
        deliveriesInFlight += 1
        defer { deliveriesInFlight -= 1 }
        var queue = [first]
        var roundTrips = 0
        while !queue.isEmpty, isRunning, let runtime {
            roundTrips += 1
            guard roundTrips <= limits.maxRoundTripsPerDelivery else {
                fail("plugin exceeded \(limits.maxRoundTripsPerDelivery) round trips in one delivery")
                return
            }
            let message = queue.removeFirst()
            record(.toPlugin, message)
            let delivery: PluginDelivery
            do {
                delivery = try await runtime.handle(message)
            } catch {
                fail(String(describing: error))
                return
            }
            guard isRunning, self.runtime === runtime else { return }
            if let tab = delivery.frames.keys.sorted().first(where: { tabIs($0, .view) }) {
                fail("plugin presented a frame to view tab \(tab)")
                return
            }
            frames.merge(delivery.frames) { _, new in new }
            for data in delivery.messages {
                guard isRunning, self.runtime === runtime else { return }
                record(.fromPlugin, data)
                switch process(data) {
                case .none: break
                case .reply(let reply): queue.append(reply)
                case .violation(let reason):
                    fail(reason)
                    return
                }
            }
            if isActivation, roundTrips == 1, state == .activating {
                fail("plugin did not respond to alas/activate")
                return
            }
        }
    }

    private func process(_ data: Data) -> Outcome {
        guard let header = try? JSONDecoder().decode(PluginIncomingHeader.self, from: data),
              header.jsonrpc == "2.0"
        else { return .violation("plugin sent a malformed message") }
        switch (header.method, header.id) {
        case let (method?, id?):
            // Nothing is acted on for a plugin that has not yet answered activation.
            guard state != .activating else {
                return .violation("plugin sent a request before answering alas/activate")
            }
            // The id is echoed in the reply, so a string id has to be small enough for that reply to fit.
            if case .string(let text) = id, text.utf8.count > limits.maxRequestIDBytes {
                return .violation("plugin sent a request id longer than \(limits.maxRequestIDBytes) bytes")
            }
            // nil: answered in a later delivery.
            guard let reply = handleRequest(method, id: id, data: data) else { return .none }
            // A reply over the limit would stop the plugin (a large stored value, many keys), so refuse instead.
            guard reply.count <= limits.maxMessageBytes else {
                return .reply(errorReply(id, code: -32003, "the result of \(method) is too large"))
            }
            return .reply(reply)
        case let (method?, nil):
            return handleNotification(method, data: data)
        case let (nil, id?):
            // A response carries exactly one of `result` and `error`.
            guard header.hasResult != (header.error != nil) else {
                return .violation("plugin sent a malformed message")
            }
            handleResponse(id: id, error: header.error, data: data)
            return .none
        case (nil, nil):
            return .violation("plugin sent a malformed message")
        }
    }

    private func handleRequest(_ method: String, id: JSONRPCID, data: Data) -> Data? {
        // `methods[method]` is a double optional: unwrap only the lookup, the entry itself may be nil.
        guard let capability = Self.methods[method], manifest.api >= 6 || !Self.api6Methods.contains(method),
              manifest.api >= 9 || !Self.api9Methods.contains(method)
        else {
            return errorReply(id, code: -32601, "method not found: \(method)")
        }
        if let capability, !grants.contains(capability) {
            return errorReply(id, code: -32001, "capability not granted: \(capability.rawValue)")
        }
        switch method {
        case "workspace/snapshot":
            return encode(PluginResponse(
                id: id, result: PluginSnapshotPayload(snapshot: actions.snapshot()), error: nil))
        case "worktree/switch":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginWorktreeSwitchParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            guard actions.switchWorktree(params.id) else {
                return errorReply(id, code: -32003, "unknown worktree \(params.id)")
            }
            return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
        case "session/focus":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginSessionFocusParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            guard actions.focusSession(params.id) else {
                return errorReply(id, code: -32003, "unknown session \(params.id)")
            }
            return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
        case "session/last_message":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginSessionFocusParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            switch actions.lastMessage(params.id) {
            case .unknownSession: return errorReply(id, code: -32003, "unknown session \(params.id)")
            case .none: return encode(PluginResponse(id: id, result: PluginLastMessageResult(message: nil), error: nil))
            case .text(let text):
                return encode(PluginResponse(
                    id: id, result: PluginLastMessageResult(message: PluginLastMessageText.bounded(text)), error: nil))
            }
        case "agent/list":
            return encode(PluginResponse(id: id, result: PluginAgentListResult(agents: actions.agents()), error: nil))
        case "task/start":
            return startTask(id: id, data: data)
        case "storage/get", "storage/set", "storage/keys":
            guard let scope = storageScope(data) else { return errorReply(id, code: -32602, "unknown storage scope") }
            return storageRequest(method, id: id, data: data, scope: scope)
        case "prompts/set":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginPromptsSetParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            let prompts: [PluginPromptContribution]
            do {
                prompts = try PluginManifest.parsePrompts(
                    params.prompts.map { ($0.name, $0.description) }, max: PluginManifest.maxRuntimePrompts)
            } catch {
                return errorReply(id, code: -32602, error.description)
            }
            if let taken = prompts.first(where: { prompt in manifest.prompts.contains { $0.name == prompt.name } }) {
                return errorReply(id, code: -32602, "prompt \"\(taken.name)\" is already in the manifest")
            }
            runtimePrompts = prompts
            return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
        case "settings/get":
            return encode(PluginResponse(id: id, result: PluginSettingsPayload(settings), error: nil))
        case "http/fetch":
            return fetch(id: id, data: data)
        case "timer/set":
            return setTimer(id: id, data: data)
        case "timer/cancel":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginTimerIDParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            timers.removeValue(forKey: params.id)?.cancel()
            return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
        case "session/send":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginSessionSendParams>.self, from: data).params,
                  !params.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  params.text.utf8.count <= Self.maxPromptBytes
            else {
                return errorReply(id, code: -32602, "invalid params for \(method): text must be 1 byte to 32 KiB")
            }
            let actions = self.actions
            return replyLater(id) { [weak self] in
                guard let self else { return Data() }
                if let failure = await actions.sendToSession(params.session, params.text) {
                    return self.errorReply(id, code: -32003, failure)
                }
                return self.encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
            }
        case "run/start":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginRunStartParams>.self, from: data).params,
                  !params.script.isEmpty, params.script.utf8.count <= 1024
            else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            let actions = self.actions
            return replyLater(id) { [weak self] in
                guard let self else { return Data() }
                if let failure = await actions.startRun(params.worktree, params.script) {
                    return self.errorReply(id, code: -32003, failure)
                }
                return self.encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
            }
        case "run/output":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginRunOutputParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            let actions = self.actions
            return replyLater(id) { [weak self] in
                guard let self else { return Data() }
                switch await actions.runOutput(params.run) {
                case .unknownRun: return self.errorReply(id, code: -32003, "unknown run \(params.run)")
                case .notFinished: return self.errorReply(id, code: -32003, "run \(params.run) has not finished")
                case .unavailable:
                    return self.encode(PluginResponse(id: id, result: PluginRunOutputResult(output: nil, truncated: false), error: nil))
                case .text(let text):
                    let tail = PluginRunOutputResult.tail(text, maxBytes: Self.maxRunOutputBytes)
                    return self.encode(PluginResponse(id: id, result: tail, error: nil))
                }
            }
        case "review/comment":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginReviewCommentParams>.self, from: data).params,
                  params.isValid
            else {
                return errorReply(id, code: -32602, "invalid params for \(method): a relative path, a line from 1 and a body of 1 byte to 16 KiB")
            }
            let actions = self.actions
            let author = manifest.name
            return replyLater(id) { [weak self] in
                guard let self else { return Data() }
                if let failure = await actions.addReviewComment(params, author) {
                    return self.errorReply(id, code: -32003, failure)
                }
                return self.encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
            }
        case "process/run", "process/start":
            return startProcess(method, id: id, data: data)
        case "process/stop":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginProcessStopParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            guard processes[params.run] != nil else { return errorReply(id, code: -32003, "no running process \(params.run)") }
            stopProcess(params.run)
            return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
        case "file/read":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginFileParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            return fileReply(id, params.worktree, .read(path: params.path))
        case "file/list":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginFileListParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            return fileReply(id, params.worktree, .list(dir: params.dir ?? ""))
        case "file/write":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginFileWriteParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            return fileReply(id, params.worktree, .write(path: params.path, content: params.content))
        default:
            return errorReply(id, code: -32601, "method not found: \(method)")
        }
    }

    /// The store a storage request's `scope` names (API 9): the project's, the default, or the plugin's own, shared
    /// by its instances in every project. Nil for an unknown scope. Older plugins always get the project's, as before.
    private func storageScope(_ data: Data) -> (store: PluginStorage, isPlugin: Bool)? {
        guard manifest.api >= 9 else { return (storage, false) }
        let params = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["params"] as? [String: Any]
        switch params?["scope"] {
        case nil: return (storage, false)
        case let scope as String where scope == "project": return (storage, false)
        case let scope as String where scope == "plugin": return (pluginStorage, true)
        default: return nil
        }
    }

    private func storageRequest(
        _ method: String, id: JSONRPCID, data: Data, scope: (store: PluginStorage, isPlugin: Bool)
    ) -> Data {
        let storage = scope.store
        switch method {
        case "storage/get":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginStorageKeyParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            guard PluginStorage.isValidKey(params.key) else { return errorReply(id, code: -32602, "invalid storage key") }
            guard storage.isAvailable else { return errorReply(id, code: -32003, "storage unavailable") }
            // Splice the stored bytes in as they are; a typed model would re-type numbers.
            var reply = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
            reply.append(encode(id))
            reply.append(Data(#","result":{"value":"#.utf8))
            reply.append(storage.get(params.key) ?? Data("null".utf8))
            reply.append(Data("}}".utf8))
            return reply
        case "storage/set":
            guard let params = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["params"] as? [String: Any],
                  let key = params["key"] as? String,
                  let value = params["value"]
            else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            // `null` deletes. Anything else is re-serialised, so the store always gets UTF-8.
            var bytes: Data?
            if !(value is NSNull) {
                guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
                    return errorReply(id, code: -32602, "invalid storage value")
                }
                bytes = encoded
            }
            switch storage.set(key, value: bytes) {
            case .stored:
                if scope.isPlugin { pluginStorageSet(key) }
                return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
            case .invalidKey: return errorReply(id, code: -32602, "invalid storage key")
            case .invalidValue: return errorReply(id, code: -32602, "invalid storage value")
            case .full: return errorReply(id, code: -32003, "storage full")
            case .failed: return errorReply(id, code: -32003, "storage unavailable")
            }
        default:
            guard storage.isAvailable else { return errorReply(id, code: -32003, "storage unavailable") }
            return encode(PluginResponse(id: id, result: PluginStorageKeysResult(keys: storage.keys()), error: nil))
        }
    }

    /// The filesystem work runs off the main actor, so a large folder or a slow disk does not stall the app; the
    /// answer comes in a later delivery. A remote request holds an SSH round trip, so it counts as one in flight too.
    private func fileReply(_ id: JSONRPCID, _ worktree: String, _ request: PluginFileRequest) -> Data? {
        let work: @Sendable () async -> Result<PluginFileReply, PluginFilesError>
        switch PluginFiles.route(actions.worktreeLocation(worktree), worktree: worktree, remote: manifest.remote) {
        case .refused(let reason): return errorReply(id, code: -32003, reason)
        case .local(let root):
            work = { await Task.detached(priority: .userInitiated) { PluginFiles.perform(request, in: root) }.value }
        case .remote(let host, let root):
            work = { await PluginFiles.remote(request, host: host, root: root) }
        }
        return replyLater(id) { [weak self] in
            let outcome = await work()
            guard let self else { return Data() }
            switch outcome {
            case .success(let result): return self.encode(PluginResponse(id: id, result: result, error: nil))
            case .failure(let error): return self.errorReply(id, code: -32003, error.message)
            }
        }
    }

    // MARK: - Processes

    /// Runs a command the manifest declares, as declared, with args appended only where it allows them.
    /// `process/run` answers with the output in a later delivery; `process/start` answers with the run at once.
    private func startProcess(_ method: String, id: JSONRPCID, data: Data) -> Data? {
        guard let params = try? JSONDecoder().decode(PluginParams<PluginProcessRunParams>.self, from: data).params else {
            return errorReply(id, code: -32602, "invalid params for \(method)")
        }
        guard let entry = manifest.processes.first(where: { $0.id == params.id }) else {
            return errorReply(id, code: -32602, "unknown process \(params.id)")
        }
        let longRunning = method == "process/start"
        guard entry.longRunning == longRunning else {
            return errorReply(id, code: -32602, "process \(entry.id) is \(entry.longRunning ? "" : "not ")longRunning; use \(entry.longRunning ? "process/start" : "process/run")")
        }
        let args = params.args ?? []
        guard args.isEmpty || entry.appendArgs else { return errorReply(id, code: -32602, "process \(entry.id) takes no args") }
        guard args.count <= Self.maxProcessArgs, args.allSatisfy({ $0.utf8.count <= PluginManifest.maxArgBytes }) else {
            return errorReply(id, code: -32602, "at most \(Self.maxProcessArgs) args of up to 1 KiB each")
        }
        guard (params.stdin?.utf8.count ?? 0) <= Self.maxProcessStdinBytes, !(longRunning && params.stdin != nil) else {
            return errorReply(id, code: -32602, "stdin is up to 256 KiB, and only for process/run")
        }
        let route = PluginFiles.route(actions.worktreeLocation(params.worktree), worktree: params.worktree, remote: manifest.remote)
        switch route {
        case .refused(let reason): return errorReply(id, code: -32003, reason)
        case .remote where longRunning:
            return errorReply(id, code: -32003, "process/start can't run on remote hosts yet; process/run can")
        case .local, .remote: break
        }
        guard processes.count < Self.maxProcessesRunning else {
            return errorReply(id, code: -32003, "at most \(Self.maxProcessesRunning) processes running")
        }
        // Checked before launching, so a refused reply never leaves a process behind.
        guard longRunning || requests.count < Self.maxRequestsInFlight else {
            return errorReply(id, code: -32003, "too many requests in flight")
        }
        let argv = entry.command + args
        // stdout and stderr together, half the message limit, so the reply usually fits as it is; the Run tab keeps
        // the latest output.
        let maxOutput = limits.maxMessageBytes / 2
        let stdin = params.stdin.map { Data($0.utf8) }
        nextProcess += 1
        let run = "p\(nextProcess)"
        let handle: any PluginProcessHandle
        /// A remote process starts in the later delivery: the helper's answer takes a round trip.
        var startRemote: (@Sendable () async throws -> Void)?
        switch route {
        case .local(let directory):
            do {
                handle = try launcher.launch(
                    argv, in: directory, stdin: stdin,
                    keep: longRunning ? .tail : .head, limit: longRunning ? Self.processRunOutputBytes : maxOutput)
            } catch {
                return errorReply(id, code: -32003, "could not start \(entry.id): \(error)")
            }
        case .remote(let host, let root):
            let lease = "\(processLease).\(instance)"
            let remote = RemotePluginProcess(
                host: host, procId: RemotePluginProcess.procId(plugin: manifest.id, project: project.id, lease: lease, run: run),
                lease: lease, keep: .head, limit: maxOutput)
            handle = remote
            // The helper enforces the limit too, and its own kill grace, in case Alas is gone by then.
            startRemote = {
                try await remote.start(
                    argv: argv, cwd: root, stdin: stdin, longRunning: false, limit: maxOutput,
                    timeout: Self.processTimeout)
            }
        case .refused: return nil
        }
        processes[run] = handle
        let instance = instance
        if longRunning {
            processRuns.append(PluginProcessRun(id: run, process: entry.id, worktree: params.worktree, command: argv))
            if processRuns.count > Self.maxProcessRuns, let oldest = processRuns.firstIndex(where: { $0.exit != nil }) {
                processRuns.remove(at: oldest)
            }
            // Not tied to the instance: the Run tab shows the exit even after the plugin stops.
            Task { [weak self] in await self?.follow(run, handle, instance: instance) }
            return encode(PluginResponse(id: id, result: PluginProcessStartResult(run: run), error: nil))
        }
        let sleep = sleep
        return replyLater(id) { [weak self] in
            do {
                try await startRemote?()
            } catch {
                guard let self else { return Data() }
                if self.instance == instance { self.processes[run] = nil }
                return self.errorReply(id, code: -32003, "could not start \(entry.id): \(error)")
            }
            let timeout = Task { () -> Bool in
                do { try await sleep(Self.processTimeout) } catch { return false }
                handle.terminate()
                if (try? await sleep(Self.processKillGrace)) != nil { handle.kill() }
                return true
            }
            var stdout = Data()
            var stderr = Data()
            var truncated = false
            var exit: Int32 = -1
            var stoppedAtLimit = false
            for await event in handle.events {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    let room = max(0, maxOutput - stdout.count - stderr.count)
                    if chunk.count > room { truncated = true }
                    if case .stdout = event { stdout.append(chunk.prefix(room)) } else { stderr.append(chunk.prefix(room)) }
                case .truncated:
                    truncated = true
                case .timedOut:
                    stoppedAtLimit = true
                case .exit(let code):
                    exit = code
                }
            }
            timeout.cancel()
            // A remote helper may reach the limit first: its clock starts before the run is answered here.
            let timedOut = await timeout.value || stoppedAtLimit
            guard let self else { return Data() }
            if self.instance == instance { self.processes[run] = nil }
            return self.processRunReply(
                id, exit: exit, stdout: stdout, stderr: stderr, truncated: truncated, timedOut: timedOut)
        }
    }

    /// The run's result, its output cut until the encoded reply fits in a message: control characters escape to six
    /// bytes, so the raw size does not tell. The exit status always gets through.
    private func processRunReply(
        _ id: JSONRPCID, exit: Int32, stdout: Data, stderr: Data, truncated: Bool, timedOut: Bool
    ) -> Data {
        var stdout = stdout
        var stderr = stderr
        var truncated = truncated
        while true {
            let reply = encode(PluginResponse(id: id, result: PluginProcessRunResult(
                exit: exit, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self),
                truncated: truncated, timedOut: timedOut), error: nil))
            let excess = reply.count - limits.maxMessageBytes
            guard excess > 0, !(stdout.isEmpty && stderr.isEmpty) else { return reply }
            // Cuts the longer stream by its share of the excess, at its own escaping rate, so little more than
            // needed goes and a few passes settle it.
            truncated = true
            let longer = stdout.count >= stderr.count ? stdout : stderr
            let escaped = max(1, encode(String(decoding: longer, as: UTF8.self)).count)
            let kept = longer.prefix(max(0, longer.count - max(1, (longer.count * excess + escaped - 1) / escaped)))
            if stdout.count >= stderr.count { stdout = kept } else { stderr = kept }
        }
    }

    /// Keeps a long-running process's latest output for the Run tab and tells the plugin when it exits.
    private func follow(_ run: String, _ handle: any PluginProcessHandle, instance: Int) async {
        var exit: Int32?
        for await event in handle.events {
            let index = processRuns.firstIndex { $0.id == run }
            switch event {
            case .stdout(let chunk), .stderr(let chunk):
                guard let index else { continue }
                processRuns[index].append(chunk, keeping: Self.processRunOutputBytes)
            case .truncated, .timedOut:
                break
            case .exit(let code):
                exit = code
                if let index { processRuns[index].exit = code }
            }
        }
        guard self.instance == instance else { return }
        processes[run] = nil
        guard let exit, state == .active else { return }
        await deliver(encode(JSONRPCEnvelope(id: nil, method: "process/exited", params: PluginProcessExitedParams(run: run, exit: exit))))
    }

    /// Asks the process to stop and kills it if it has not after the grace period. Also the Run tab's Stop.
    func stopProcess(_ run: String) {
        guard let handle = processes[run] else { return }
        handle.terminate()
        let sleep = sleep
        Task {
            if (try? await sleep(Self.processKillGrace)) != nil { handle.kill() }
        }
    }

    private func startTask(id: JSONRPCID, data: Data) -> Data {
        guard let params = try? JSONDecoder().decode(PluginParams<PluginTaskStartParams>.self, from: data).params,
              !params.title.isEmpty, !params.prompt.isEmpty, params.prompt.utf8.count <= Self.maxPromptBytes
        else {
            return errorReply(id, code: -32602, "invalid params for task/start")
        }
        guard !taskInFlight else { return errorReply(id, code: -32003, "a task is already starting") }
        taskInFlight = true
        taskGeneration += 1
        pendingTaskSession = nil
        let generation = taskGeneration
        let request = PluginTaskRequest(title: params.title, prompt: params.prompt, branch: params.branch, agent: params.agent)
        switch actions.startTask(request, { [weak self] failure in self?.taskSettled(generation: generation, failure: failure) }) {
        case .started(let sessionId, let branch):
            pendingTaskSession = sessionId
            return encode(PluginResponse(id: id, result: PluginTaskStartResult(sessionId: sessionId, branch: branch), error: nil))
        case .rejected(let code, let message):
            taskInFlight = false
            return errorReply(id, code: code, message)
        }
    }

    private func taskSettled(generation: Int, failure: String?) {
        guard generation == taskGeneration, taskInFlight else { return }
        taskInFlight = false
        guard let failure, state == .active, let sessionId = pendingTaskSession else { return }
        let message = encode(JSONRPCEnvelope(
            id: nil, method: "task/failed",
            params: PluginTaskFailedParams(sessionId: sessionId, reason: Self.bounded(failure))))
        Task { await deliver(message) }
    }

    // MARK: - Network and timers

    /// Answers at once only when the request is refused; otherwise the reply comes in a later delivery.
    private func fetch(id: JSONRPCID, data: Data) -> Data? {
        guard let params = try? JSONDecoder().decode(PluginParams<PluginHTTPFetchParams>.self, from: data).params,
              Self.httpMethods.contains(params.method.uppercased()),
              let url = URL(string: params.url)
        else {
            return errorReply(id, code: -32602, "invalid params for http/fetch")
        }
        guard url.scheme?.lowercased() == "https" else { return errorReply(id, code: -32602, "only https URLs can be fetched") }
        guard PluginHTTP.allows(url, hosts: manifest.network), let host = url.host()?.lowercased() else {
            return errorReply(id, code: -32001, "host not allowed: \(url.host() ?? params.url)")
        }
        guard (params.body?.utf8.count ?? 0) <= PluginHTTP.maxBodyBytes else {
            return errorReply(id, code: -32602, "the request body is larger than 512 KiB")
        }
        guard fetches.count < Self.maxFetchesInFlight else { return errorReply(id, code: -32003, "too many requests in flight") }
        var request = URLRequest(url: url, timeoutInterval: PluginHTTP.timeout)
        request.httpMethod = params.method.uppercased()
        request.httpShouldHandleCookies = false
        request.httpBody = params.body.map { Data($0.utf8) }
        // A redirect may only carry a secret to a host that secret allows.
        var redirectHosts = manifest.network
        // Each secret is read from the Keychain once per request, and a request may substitute only a handful,
        // so no header can turn into thousands of synchronous lookups on the main actor.
        var secretValues: [String: String] = [:]
        var substitutions = 0
        for (name, value) in params.headers ?? [:] {
            var resolved = ""
            var rest = value[...]
            while let match = rest.firstMatch(of: /\{\{secret:([^}]*)\}\}/) {
                substitutions += 1
                guard substitutions <= Self.maxSecretSubstitutions else {
                    return errorReply(id, code: -32602, "more than \(Self.maxSecretSubstitutions) secret substitutions in one request")
                }
                let key = String(match.1)
                guard let setting = settings.declaration(key), setting.kind == .secret else {
                    return errorReply(id, code: -32602, "unknown secret \(key)")
                }
                guard setting.hosts.contains(host) else {
                    return errorReply(id, code: -32001, "secret \(key) is not allowed for \(host)")
                }
                guard let secret = secretValues[key] ?? settings.secret(key) else {
                    return errorReply(id, code: -32602, "secret \(key) is not set")
                }
                secretValues[key] = secret
                resolved += rest[..<match.range.lowerBound]
                resolved += secret
                redirectHosts.removeAll { !setting.hosts.contains($0) }
                rest = rest[match.range.upperBound...]
            }
            resolved += rest
            request.setValue(resolved, forHTTPHeaderField: name)
        }
        let token = nextFetchToken
        nextFetchToken += 1
        let instance = instance
        let transport = transport
        fetches[token] = Task { [weak self, request, redirectHosts] in
            let outcome: Result<(Data, HTTPURLResponse), any Error>
            do {
                outcome = .success(try await transport.data(for: request, redirectHosts: redirectHosts))
            } catch {
                outcome = .failure(error)
            }
            await self?.fetchSettled(id: id, token: token, instance: instance, outcome)
        }
        return nil
    }

    private func fetchSettled(
        id: JSONRPCID, token: Int, instance: Int, _ outcome: Result<(Data, HTTPURLResponse), any Error>
    ) async {
        guard instance == self.instance else { return }
        fetches[token] = nil
        guard state == .active else { return }
        let tooLarge = "the response is too large for one message"
        var reply: Data
        switch outcome {
        case .success(let (body, response)):
            guard body.count <= PluginHTTP.maxResponseBodyBytes else {
                reply = errorReply(id, code: -32003, tooLarge)
                break
            }
            guard let text = String(data: body, encoding: .utf8) else {
                reply = errorReply(id, code: -32003, "the response body is not UTF-8 text")
                break
            }
            var headers: [String: String] = [:]
            for case let (name as String, value as String) in response.allHeaderFields { headers[name.lowercased()] = value }
            reply = encode(PluginResponse(
                id: id, result: PluginHTTPFetchResult(status: response.statusCode, headers: headers, body: text), error: nil))
            if reply.count > limits.maxMessageBytes { reply = errorReply(id, code: -32003, tooLarge) }
        case .failure(let error) where error is PluginHTTPBodyTooLarge:
            reply = errorReply(id, code: -32003, tooLarge)
        case .failure(let error):
            reply = errorReply(id, code: -32003, "request failed: \(error.localizedDescription)")
        }
        await deliver(reply)
    }

    private func setTimer(id: JSONRPCID, data: Data) -> Data {
        guard let params = try? JSONDecoder().decode(PluginParams<PluginTimerSetParams>.self, from: data).params,
              (1...Self.timerIDByteLimit).contains(params.id.utf8.count),
              Self.timerSeconds.contains(params.seconds)
        else {
            return errorReply(id, code: -32602, "invalid params for timer/set: seconds must be 60 to 86400")
        }
        guard timers[params.id] != nil || timers.count < Self.maxTimers else {
            return errorReply(id, code: -32003, "at most \(Self.maxTimers) timers")
        }
        timers[params.id]?.cancel()
        let instance = instance
        let sleep = sleep
        let repeats = params.repeats ?? false
        let message = encode(JSONRPCEnvelope(id: nil, method: "timer/fired", params: PluginTimerIDParams(id: params.id)))
        timers[params.id] = Task { [weak self] in
            repeat {
                do { try await sleep(.seconds(params.seconds)) } catch { return }
                guard !Task.isCancelled, let self, self.instance == instance, self.state == .active else { return }
                if !repeats { self.timers[params.id] = nil }
                await self.deliver(message)
            } while repeats
        }
        return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
    }

    /// Answers `id` in a later delivery with what `work` returns, if this instance is still running then. The work
    /// itself is not undone when the instance ends: a run it started keeps running.
    private func replyLater(_ id: JSONRPCID, _ work: @escaping @MainActor () async -> Data) -> Data? {
        guard requests.count < Self.maxRequestsInFlight else { return errorReply(id, code: -32003, "too many requests in flight") }
        let token = nextFetchToken
        nextFetchToken += 1
        let instance = instance
        requests[token] = Task { [weak self] in
            let reply = await work()
            guard let self, self.instance == instance else { return }
            self.requests[token] = nil
            guard self.state == .active, !reply.isEmpty else { return }
            // A reply over the limit would stop the plugin, so it is refused instead, as for an immediate reply.
            await self.deliver(reply.count <= self.limits.maxMessageBytes
                ? reply : self.errorReply(id, code: -32003, "the result is too large"))
        }
        return nil
    }

    /// Drops what belongs to the instance that is ending: its timers and its fetches, which are cancelled, and its
    /// processes, which are stopped. Deferred requests are only forgotten, so work the plugin asked for still
    /// finishes; their replies are discarded.
    private func endInstance() {
        for run in processes.keys { stopProcess(run) }
        processes = [:]
        instance += 1
        for fetch in fetches.values { fetch.cancel() }
        fetches = [:]
        requests = [:]
        for timer in timers.values { timer.cancel() }
        timers = [:]
        visibilityDelivery?.cancel()
        visibilityDelivery = nil
        runtimePrompts = []
        for token in hostRequests.keys { answer(token, nil) }
    }

    /// Notifications never get replies. Bad logs are dropped; bad regions are a protocol violation,
    /// because a plugin that cannot describe its own canvas is broken rather than noisy.
    private func handleNotification(_ method: String, data: Data) -> Outcome {
        switch method {
        case "log":
            if let params = try? JSONDecoder().decode(PluginParams<PluginLogParams>.self, from: data).params,
               Self.logLevels.contains(params.level) {
                appendLog(params.level, params.message)
            }
            return .none
        case "notify":
            notify(data)
            return .none
        case "view/render":
            guard let header = try? JSONDecoder().decode(PluginParams<PluginViewRenderHeader>.self, from: data).params else {
                return .violation("plugin sent a malformed view/render")
            }
            switch (header.tab, header.panel) {
            case (let tab?, nil):
                guard tabIs(tab, .view), header.worktree == nil, header.run == nil else {
                    return .violation("plugin sent view/render to tab \(tab), which is not a view tab")
                }
            case (nil, let panel?):
                guard let location = manifest.panels.first(where: { $0.id == panel })?.location else {
                    return .violation(Self.bounded("plugin sent view/render to panel \"\(panel)\", which it does not declare"))
                }
                // A panel names exactly the context its location has.
                let needs: (worktree: Bool, run: Bool) = switch location {
                case .right, .configure: (false, false)
                case .changesSection: (true, false)
                case .runReportSection: (false, true)
                }
                guard (header.worktree != nil) == needs.worktree, (header.run != nil) == needs.run else {
                    return .violation(Self.bounded(
                        "plugin sent a malformed view/render: panel \"\(panel)\" at \(location.rawValue) "
                            + (needs.worktree ? "needs worktree" : needs.run ? "needs run" : "takes no worktree or run")))
                }
            default:
                return .violation("plugin sent a malformed view/render: needs exactly one of tab and panel")
            }
            // Re-serialised, so the tree decoder always gets UTF-8 whatever encoding the plugin used.
            guard let params = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["params"] as? [String: Any],
                  let root = params["root"],
                  let rootData = try? JSONSerialization.data(withJSONObject: root, options: .fragmentsAllowed)
            else { return .violation("plugin sent a malformed view/render") }
            switch PluginViewTree.decode(rootData, api: manifest.api) {
            case .success(let node):
                if let panel = header.panel {
                    panelViews[panel] = node
                    panelPlaces[panel] = PluginPanelPlace(panel: panel, worktree: header.worktree, run: header.run)
                } else if let tab = header.tab {
                    views[tab] = node
                }
                return .none
            case .failure(let error):
                return .violation(Self.bounded("plugin sent a malformed view/render: \(error.reason)"))
            }
        case "decorations/set" where manifest.api >= 6:
            guard let params = try? JSONDecoder().decode(PluginParams<PluginDecorationSetParams>.self, from: data).params else {
                return .violation("plugin sent a malformed decorations/set")
            }
            let outcome = PluginDecorations.apply(
                params, to: decorations, commands: Set(manifest.commands.map(\.id)),
                inProject: { key in
                    key.slot == .repoRow
                        ? key.target == project.id
                        : actions.snapshot().worktrees.contains { $0.id == (key.worktree ?? key.target) }
                })
            switch outcome {
            case .set(let updated): decorations = updated
            case .dropped(let reason): appendLog("warn", reason)
            case .violation(let reason): return .violation(Self.bounded(reason))
            }
            return .none
        case "canvas/regions":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginRegionsParams>.self, from: data).params,
                  tabIs(params.tab, .canvas),
                  params.regions.allSatisfy({ $0.rect.count == 4 })
            else { return .violation("plugin sent a malformed canvas/regions") }
            regions[params.tab] = params.regions.prefix(Self.maxRegions).map {
                PluginRegion(
                    id: Self.prefix($0.id, utf8Bytes: Self.regionIDByteLimit),
                    label: String(String.UnicodeScalarView($0.label.unicodeScalars.prefix(Self.regionLabelLimit))),
                    rect: $0.rect)
            }
            return .none
        default:
            return .none
        }
    }

    /// A notification, not a request, so a refused one is dropped rather than answered.
    private func notify(_ data: Data) {
        guard grants.contains(.notify) else {
            if !warnedNotifyNotGranted {
                warnedNotifyNotGranted = true
                appendLog("warn", "notify dropped: capability not granted: notify")
            }
            return
        }
        guard let params = try? JSONDecoder().decode(PluginParams<PluginNotifyParams>.self, from: data).params else { return }
        let time = now()
        if let lastNotify, time - lastNotify < Self.notifyInterval { return }
        lastNotify = time
        let title = String(String.UnicodeScalarView(params.title.unicodeScalars.prefix(Self.notifyTitleLimit)))
        actions.notify(
            "\(manifest.name): \(title)",
            String(String.UnicodeScalarView((params.body ?? "").unicodeScalars.prefix(Self.notifyBodyLimit))))
    }

    private static func prefix(_ text: String, utf8Bytes limit: Int) -> String {
        var used = 0
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix { scalar in
            used += UTF8.width(scalar)
            return used <= limit
        }))
    }

    /// The activation response, and responses to requests Alas sent and still waits on. Anything else is stray and
    /// ignored.
    private func handleResponse(id: JSONRPCID, error: JSONRPCError?, data: Data) {
        if case .number(let token) = id, hostRequests[token] != nil {
            answer(token, data)
            return
        }
        guard id == Self.activateID, state == .activating else { return }
        if let error {
            fail("plugin rejected activation: \(Self.bounded(error.message))")
        } else {
            state = .active
        }
    }

    // MARK: - Helpers

    /// Text a plugin controls is bounded before Alas retains it. Bound by scalars: `String.prefix`
    /// counts grapheme clusters, and one base character followed by many combining marks is a single one.
    private static func bounded(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(logMessageLimit)))
    }

    private func fail(_ reason: String) {
        endInstance()
        state = .failed(reason)
        runtime = nil
        clearCanvas()
        appendLog("error", reason)
    }

    private func appendLog(_ level: String, _ message: String) {
        log.append(PluginLogEntry(level: level, message: Self.bounded(message)))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private func record(_ direction: PluginTraceEntry.Direction, _ data: Data) {
        trace.append(PluginTraceEntry(direction: direction, text: String(decoding: data.prefix(2000), as: UTF8.self)))
        if trace.count > Self.traceLimit { trace.removeFirst(trace.count - Self.traceLimit) }
    }

    private func errorReply(_ id: JSONRPCID, code: Int, _ message: String) -> Data {
        // Messages echo plugin-controlled text (a method name, a worktree id). Bounding it keeps the reply
        // inside the message limit, so a refused request is answered instead of stopping the plugin.
        encode(PluginResponse<PluginEmptyPayload>(
            id: id, result: nil, error: JSONRPCError(code: code, message: Self.bounded(message), data: nil)))
    }

    /// Method names like `workspace/changed` must reach plugins unescaped.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    private func encode(_ value: some Encodable) -> Data {
        // Our own payload types always encode.
        (try? Self.encoder.encode(value)) ?? Data()
    }
}
