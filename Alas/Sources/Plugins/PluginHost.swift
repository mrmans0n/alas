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
    ]
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
    /// Panel trees, by the manifest's panel id.
    private(set) var panelViews: [String: PluginViewNode] = [:]
    @ObservationIgnored private var visibleViews = 0
    /// How many places show each panel. Owned by the UI, so it outlives a restart.
    @ObservationIgnored private var visiblePanels: [String: Int] = [:]
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
    @ObservationIgnored private var fetchesInFlight = 0
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]

    @ObservationIgnored private let source: Data
    @ObservationIgnored private let actions: PluginHostActions
    @ObservationIgnored private let storage: PluginStorage
    @ObservationIgnored private let limits: PluginLimits
    @ObservationIgnored private var runtime: PluginRuntime?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let settings: PluginSettings
    @ObservationIgnored private let transport: any PluginHTTPTransport
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        manifest: PluginManifest,
        source: Data,
        project: PluginProjectRef,
        grants: Set<PluginCapability>,
        actions: PluginHostActions,
        storage: PluginStorage,
        settings: PluginSettings,
        transport: any PluginHTTPTransport = PluginURLSessionTransport(),
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
        self.limits = limits
        self.now = now
        self.settings = settings
        self.transport = transport
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
        for panel in manifest.panels where visiblePanels[panel.id, default: 0] > 0 {
            guard state == .active else { return }
            await sendPanelVisible(panel.id, true)
        }
    }

    /// Each place that shows the panel holds one count; `panel/visible` is sent when the first appears or the last goes.
    func setPanelVisible(_ panel: String, _ visible: Bool) async {
        guard manifest.panels.contains(where: { $0.id == panel }) else { return }
        let before = visiblePanels[panel, default: 0]
        let after = max(0, before + (visible ? 1 : -1))
        visiblePanels[panel] = after
        guard (before == 0) != (after == 0), state == .active else { return }
        await sendPanelVisible(panel, visible)
    }

    private func sendPanelVisible(_ panel: String, _ visible: Bool) async {
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "panel/visible", params: PluginPanelVisibleParams(panel: panel, visible: visible))))
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

    var receivesSessionEvents: Bool { !manifest.events.isEmpty && grants.contains(.sessionRead) }

    /// Sends the events the manifest subscribes to.
    func sessionEvents(_ events: [PluginSessionEvent]) async {
        guard receivesSessionEvents else { return }
        for event in events where manifest.events.contains(event.event) {
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
        lastTick = nil
    }

    /// Each visible instance of one of this plugin's tabs holds one count.
    func setViewVisible(_ visible: Bool) {
        visibleViews = max(0, visibleViews + (visible ? 1 : -1))
        if visibleViews == 0 { lastTick = nil }
    }

    var isTicking: Bool { state == .active && visibleViews > 0 && manifest.tabs.contains { $0.kind == .canvas } }

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

    /// Only nodes in the panel's current tree can send events.
    func viewEvent(panel: String, id: String, kind: String, value: String?) async {
        guard state == .active, let root = panelViews[panel], Self.contains(root, id: id) else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "view/event", params: PluginViewEventParams(panel: panel, id: id, kind: kind, value: value))))
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
            handleResponse(id: id, error: header.error)
            return .none
        case (nil, nil):
            return .violation("plugin sent a malformed message")
        }
    }

    private func handleRequest(_ method: String, id: JSONRPCID, data: Data) -> Data? {
        // `methods[method]` is a double optional: unwrap only the lookup, the entry itself may be nil.
        guard let capability = Self.methods[method] else {
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
            case .stored: return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
            case .invalidKey: return errorReply(id, code: -32602, "invalid storage key")
            case .invalidValue: return errorReply(id, code: -32602, "invalid storage value")
            case .full: return errorReply(id, code: -32003, "storage full")
            case .failed: return errorReply(id, code: -32003, "storage unavailable")
            }
        case "storage/keys":
            guard storage.isAvailable else { return errorReply(id, code: -32003, "storage unavailable") }
            return encode(PluginResponse(id: id, result: PluginStorageKeysResult(keys: storage.keys()), error: nil))
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
        default:
            return errorReply(id, code: -32601, "method not found: \(method)")
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
        guard fetchesInFlight < Self.maxFetchesInFlight else { return errorReply(id, code: -32003, "too many requests in flight") }
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
        fetchesInFlight += 1
        let instance = instance
        let transport = transport
        Task { [weak self, request, redirectHosts] in
            let outcome: Result<(Data, HTTPURLResponse), any Error>
            do {
                outcome = .success(try await transport.data(for: request, redirectHosts: redirectHosts))
            } catch {
                outcome = .failure(error)
            }
            await self?.fetchSettled(id: id, instance: instance, outcome)
        }
        return nil
    }

    private func fetchSettled(id: JSONRPCID, instance: Int, _ outcome: Result<(Data, HTTPURLResponse), any Error>) async {
        guard instance == self.instance else { return }
        fetchesInFlight -= 1
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

    /// Drops what belongs to the instance that is ending: its timers, and the replies to its fetches.
    private func endInstance() {
        instance += 1
        fetchesInFlight = 0
        for timer in timers.values { timer.cancel() }
        timers = [:]
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
                guard tabIs(tab, .view) else {
                    return .violation("plugin sent view/render to tab \(tab), which is not a view tab")
                }
            case (nil, let panel?):
                guard manifest.panels.contains(where: { $0.id == panel }) else {
                    return .violation(Self.bounded("plugin sent view/render to panel \"\(panel)\", which it does not declare"))
                }
            default:
                return .violation("plugin sent a malformed view/render: needs exactly one of tab and panel")
            }
            // Re-serialised, so the tree decoder always gets UTF-8 whatever encoding the plugin used.
            guard let params = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["params"] as? [String: Any],
                  let root = params["root"],
                  let rootData = try? JSONSerialization.data(withJSONObject: root, options: .fragmentsAllowed)
            else { return .violation("plugin sent a malformed view/render") }
            switch PluginViewTree.decode(rootData) {
            case .success(let node):
                if let panel = header.panel { panelViews[panel] = node } else if let tab = header.tab { views[tab] = node }
                return .none
            case .failure(let error):
                return .violation(Self.bounded("plugin sent a malformed view/render: \(error.reason)"))
            }
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

    /// Only the activation response matters in v1. Anything else is stray and ignored.
    private func handleResponse(id: JSONRPCID, error: JSONRPCError?) {
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
