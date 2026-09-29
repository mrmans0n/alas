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

/// What a plugin may ask Alas to do, already scoped to one project.
@MainActor
struct PluginHostActions {
    var snapshot: () -> PluginWorkspaceSnapshot
    /// Returns false when `id` is not a worktree of this project.
    var switchWorktree: (String) -> Bool
}

/// Runs the v1 protocol for one plugin in one project.
@MainActor
@Observable
final class PluginHost {
    static let apiVersion = 1
    private static let activateID = JSONRPCID.number(0)
    private static let requiredCapability: [String: PluginCapability] = [
        "workspace/snapshot": .workspaceRead,
        "worktree/switch": .worktreeSwitch,
    ]
    private static let traceLimit = 100
    private static let logLimit = 200
    static let logMessageLimit = 2000
    private static let logLevels: Set<String> = ["debug", "info", "warn", "error"]

    let manifest: PluginManifest
    let project: PluginProjectRef
    let grants: Set<PluginCapability>
    private(set) var state: PluginHostState = .loaded
    private(set) var trace: [PluginTraceEntry] = []
    private(set) var log: [PluginLogEntry] = []

    @ObservationIgnored private let wasm: [UInt8]
    @ObservationIgnored private let actions: PluginHostActions
    @ObservationIgnored private let limits: PluginLimits
    @ObservationIgnored private var runtime: PluginRuntime?

    init(
        manifest: PluginManifest,
        wasm: [UInt8],
        project: PluginProjectRef,
        grants: Set<PluginCapability>,
        actions: PluginHostActions,
        limits: PluginLimits = PluginLimits()
    ) {
        self.manifest = manifest
        self.wasm = wasm
        self.project = project
        self.grants = grants
        self.actions = actions
        self.limits = limits
    }

    private var isRunning: Bool { state == .activating || state == .active }

    /// Starts a fresh instance. Also used to restart after `stopped` or `failed`.
    func activate() async {
        guard !isRunning, state != .deactivating else { return }
        state = .activating
        trace = []
        do {
            let loaded = try await PluginRuntime.load(wasm: wasm, limits: limits)
            guard state == .activating else { return }  // deactivated while the module loaded
            runtime = loaded
        } catch {
            guard state == .activating else { return }
            fail(String(describing: error))
            return
        }
        let params = PluginActivateParams(
            api: Self.apiVersion, project: project,
            grants: grants.sorted { $0.rawValue < $1.rawValue })
        await deliver(
            encode(JSONRPCEnvelope(id: Self.activateID, method: "alas/activate", params: params)),
            isActivation: true)
    }

    func workspaceChanged(_ snapshot: PluginWorkspaceSnapshot) async {
        guard state == .active, grants.contains(.workspaceRead) else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "workspace/changed", params: PluginSnapshotPayload(snapshot: snapshot))))
    }

    /// Sends `alas/deactivate`, then drops the instance whatever the plugin does.
    /// Anything the plugin sends back is ignored.
    func deactivate() async {
        if state == .activating, runtime == nil {  // still loading the module
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
    }

    // MARK: - Delivery

    private enum Outcome {
        case none
        case reply(Data)
        case violation(String)
    }

    /// Delivers `first`, then any replies to requests the plugin made, each in
    /// its own `alas_handle` call. Stops as soon as the host leaves the running
    /// states, which drops everything still queued.
    /// The activation response must come from the first call, so an activation
    /// delivery fails as soon as that call's messages are processed without one.
    private func deliver(_ first: Data, isActivation: Bool = false) async {
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
            let sent: [Data]
            do {
                sent = try await runtime.handle(message)
            } catch {
                fail(String(describing: error))
                return
            }
            for data in sent {
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
            return .reply(handleRequest(method, id: id, data: data))
        case let (method?, nil):
            handleNotification(method, data: data)
            return .none
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

    private func handleRequest(_ method: String, id: JSONRPCID, data: Data) -> Data {
        guard let capability = Self.requiredCapability[method] else {
            return errorReply(id, code: -32601, "method not found: \(method)")
        }
        guard grants.contains(capability) else {
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
        default:
            return errorReply(id, code: -32601, "method not found: \(method)")
        }
    }

    /// Notifications never get replies, so bad ones are dropped.
    private func handleNotification(_ method: String, data: Data) {
        guard method == "log",
              let params = try? JSONDecoder().decode(PluginParams<PluginLogParams>.self, from: data).params,
              Self.logLevels.contains(params.level)
        else { return }
        appendLog(params.level, params.message)
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
        state = .failed(reason)
        runtime = nil
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
