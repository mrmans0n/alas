import Foundation

/// The relay operations the bridge needs from `RemoteHelperClient`.
public protocol RemoteMCPRouteServing: Sendable {
    func completeMCPRoute(origin: RemoteMCPRelayOrigin, completion: RemoteMCPRelayCompletion) async throws
    func closeMCPRoute(_ handle: RemoteMCPRouteHandle) async
}

extension RemoteHelperClient: RemoteMCPRouteServing {}

/// Serves one SSH session's relayed `visual_show` traffic on this Mac.
///
/// The remote helper delivers opaque MCP frames; the bridge hands them to a
/// local `alas mcp --visual-only` process, which owns the tool schema,
/// validation, and the app-socket call, and sends each response back to the
/// helper exchange that delivered the request. The bridge only understands
/// JSON-RPC envelopes: it rewrites request ids so frames from concurrent
/// remote proxy processes cannot collide in the shared backend, and restores
/// each caller's id (and its JSON type) on the way back.
///
/// A response is delivered only to the registration and helper generation
/// that relayed its request; the helper client drops anything else. Pending
/// work is discarded, never replayed, when the route becomes unavailable.
public actor RemoteVisualMCPBridge {
    public typealias BackendFactory = @Sendable () -> JSONRPCStdioTransporting
    /// Whether the session that owns this route may still act. Checked
    /// before every dispatch; the app's CLI router and the session manager
    /// remain the final authority for the visual itself.
    public typealias Authorization = @Sendable () async -> Bool
    /// Genuine agent traffic reached the backend through the current route:
    /// a successful `initialize`, `tools/list`, or accepted relayed tool call.
    public typealias RegistrationEvidence = @Sendable () async -> Void

    static let unavailableCode = -32000
    static let unavailableMessage = "Alas relay unavailable; the call's outcome is unknown"

    private struct Pending {
        let origin: RemoteMCPRelayOrigin
        /// The caller's id as JSON, so a number stays a number.
        let originalId: Data
        let provesRegistration: Bool
    }

    private let route: RemoteMCPRouteHandle
    private let events: AsyncStream<RemoteMCPRelayEvent>
    private let relay: any RemoteMCPRouteServing
    private let makeBackend: BackendFactory
    private let authorize: Authorization
    private let onRegistration: RegistrationEvidence

    private var eventsTask: Task<Void, Never>?
    private var backend: JSONRPCStdioTransporting?
    private var backendTask: Task<Void, Never>?
    private var backendEpoch = 0
    /// Bumped whenever the route becomes unavailable, so work suspended on
    /// authorization cannot dispatch into a later registration.
    private var routeEpoch = 0
    private var pending: [String: Pending] = [:]
    private var reportedRegistration = false
    private var invalidated = false

    public init(
        route: RemoteMCPRouteHandle,
        events: AsyncStream<RemoteMCPRelayEvent>,
        relay: any RemoteMCPRouteServing,
        makeBackend: @escaping BackendFactory,
        authorize: @escaping Authorization,
        onRegistration: @escaping RegistrationEvidence
    ) {
        self.route = route
        self.events = events
        self.relay = relay
        self.makeBackend = makeBackend
        self.authorize = authorize
        self.onRegistration = onRegistration
    }

    /// The tools a route serves: what the helper can relay, narrowed to
    /// `visual_show` for sessions that cannot use the PR shepherd, such as
    /// Workspace Checkouts.
    public static func toolScope(helper: BuiltInMCPToolScope, allowsPRTools: Bool) -> BuiltInMCPToolScope {
        allowsPRTools ? helper : .visualOnly
    }

    /// Opens a fenced route on the helper and starts serving it, with a
    /// backend for the tools the helper can relay and the session can use.
    /// The returned attachment's invalidation revokes the route.
    @MainActor
    public static func prepare(
        client: RemoteHelperClient,
        fence: RemoteSessionFence,
        allowsPRTools: Bool,
        makeBackend: @escaping @Sendable (BuiltInMCPToolScope) -> JSONRPCStdioTransporting,
        authorize: @escaping Authorization,
        onRegistration: @escaping RegistrationEvidence
    ) async throws -> PreparedBuiltInMCPAttachment {
        let opened = try await client.openMCPRoute(fence: fence)
        let toolScope = toolScope(helper: opened.toolScope, allowsPRTools: allowsPRTools)
        let bridge = RemoteVisualMCPBridge(
            route: opened.handle,
            events: opened.events,
            relay: client,
            makeBackend: { makeBackend(toolScope) },
            authorize: authorize,
            onRegistration: onRegistration
        )
        await bridge.start()
        return PreparedBuiltInMCPAttachment(
            injection: BuiltInAlasMCP.remoteVisualInjection(descriptor: opened.descriptor, toolScope: toolScope),
            cleanup: { await bridge.invalidate() }
        )
    }

    public func start() {
        guard eventsTask == nil, !invalidated else { return }
        let events = events
        eventsTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.routeClosed()
        }
    }

    /// Stops accepting relayed frames, ends the backend, and fails pending
    /// exchanges before releasing the helper route. Only this bridge's own
    /// route and backend are touched. The helper round trips run detached,
    /// so a stalled SSH connection cannot hold up session teardown.
    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        eventsTask?.cancel()
        eventsTask = nil
        let abandoned = stopBackend()
        let relay = relay
        let route = route
        Task {
            for exchange in abandoned {
                try? await relay.completeMCPRoute(origin: exchange.origin, completion: Self.unavailable)
            }
            await relay.closeMCPRoute(route)
        }
    }

    private static var unavailable: RemoteMCPRelayCompletion {
        .failed(code: unavailableCode, message: unavailableMessage)
    }

    private func handle(_ event: RemoteMCPRelayEvent) async {
        guard !invalidated else { return }
        switch event {
        case .available:
            break
        case .unavailable:
            // The helper's exchanges died with its generation; nothing can
            // be completed, and a new registration starts a fresh backend.
            routeEpoch += 1
            reportedRegistration = false
            _ = stopBackend()
        case .request(let origin, let frame):
            await relayFrame(frame, from: origin)
        }
    }

    private func routeClosed() {
        guard !invalidated else { return }
        routeEpoch += 1
        _ = stopBackend()
    }

    private func relayFrame(_ frame: Data, from origin: RemoteMCPRelayOrigin) async {
        guard let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
            await complete(origin, .failed(code: -32700, message: "Parse error"))
            return
        }
        guard let method = message["method"] as? String else {
            // A response to a server request this backend never makes.
            await complete(origin, .notification)
            return
        }
        guard message.keys.contains("id") else {
            await relayNotification(message, method: method, from: origin)
            return
        }
        guard let id = message["id"], Self.isValidId(id),
              let originalId = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed)
        else {
            await complete(origin, .failed(code: -32600, message: "Invalid Request"))
            return
        }
        let epoch = routeEpoch
        guard await authorize(), !invalidated, routeEpoch == epoch,
              let backend = ensureBackend()
        else {
            await complete(origin, Self.unavailable)
            return
        }
        let backendId = Self.backendId(for: origin)
        var forwarded = message
        forwarded["id"] = backendId
        guard let data = try? JSONSerialization.data(withJSONObject: forwarded, options: [.withoutEscapingSlashes]) else {
            await complete(origin, .failed(code: -32600, message: "Invalid Request"))
            return
        }
        pending[backendId] = Pending(
            origin: origin,
            originalId: originalId,
            provesRegistration: Self.provesRegistration(method: method, message: message)
        )
        do {
            try backend.send(data)
        } catch {
            pending.removeValue(forKey: backendId)
            await complete(origin, Self.unavailable)
        }
    }

    private func relayNotification(_ message: [String: Any], method: String, from origin: RemoteMCPRelayOrigin) async {
        let epoch = routeEpoch
        guard await authorize(), !invalidated, routeEpoch == epoch,
              let backend = ensureBackend(),
              let forwarded = forwardedNotification(message, method: method, relayId: origin.relayId),
              let data = try? JSONSerialization.data(withJSONObject: forwarded, options: [.withoutEscapingSlashes])
        else {
            await complete(origin, .notification)
            return
        }
        try? backend.send(data)
        await complete(origin, .notification)
    }

    /// A cancellation names the caller's request id; point it at the
    /// backend id when exactly one pending request of this registration
    /// matches, and drop it otherwise rather than cancel the wrong call.
    private func forwardedNotification(_ message: [String: Any], method: String, relayId: String) -> [String: Any]? {
        guard method == "notifications/cancelled" else { return message }
        guard var params = message["params"] as? [String: Any],
              let requestId = params["requestId"],
              let requestIdData = try? JSONSerialization.data(withJSONObject: requestId, options: .fragmentsAllowed)
        else { return nil }
        let matches = pending.filter { $0.value.origin.relayId == relayId && $0.value.originalId == requestIdData }
        guard matches.count == 1, let backendId = matches.keys.first else { return nil }
        params["requestId"] = backendId
        var forwarded = message
        forwarded["params"] = params
        return forwarded
    }

    private func ensureBackend() -> JSONRPCStdioTransporting? {
        if let backend { return backend }
        let next = makeBackend()
        do {
            try next.start()
        } catch {
            return nil
        }
        backendEpoch += 1
        let epoch = backendEpoch
        backend = next
        backendTask = Task { [weak self] in
            for await incoming in next.incoming {
                await self?.handleBackend(incoming, epoch: epoch)
            }
            await self?.backendEnded(epoch: epoch)
        }
        return next
    }

    /// Ends the current backend and returns its pending exchanges.
    private func stopBackend() -> [Pending] {
        backendEpoch += 1
        backendTask?.cancel()
        backendTask = nil
        backend?.terminate()
        backend = nil
        let abandoned = Array(pending.values)
        pending.removeAll()
        return abandoned
    }

    private func handleBackend(_ incoming: JSONRPCStdioTransport.Incoming, epoch: Int) async {
        guard epoch == backendEpoch, !invalidated else { return }
        switch incoming {
        case .frame(let data, let onConsumed):
            defer { onConsumed?() }
            await deliverBackendFrame(data)
        case .stderr:
            // Diagnostic only; it may echo request content, so it is not kept.
            break
        case .exited:
            await backendEnded(epoch: epoch)
        }
    }

    private func deliverBackendFrame(_ data: Data) async {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] == nil,
              let backendId = message["id"] as? String,
              let exchange = pending.removeValue(forKey: backendId),
              let originalId = try? JSONSerialization.jsonObject(with: exchange.originalId, options: .fragmentsAllowed)
        else { return }
        message["id"] = originalId
        guard let response = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            await complete(exchange.origin, Self.unavailable)
            return
        }
        await complete(exchange.origin, .frame(response))
        if exchange.provesRegistration, !reportedRegistration, Self.succeeded(message) {
            reportedRegistration = true
            await onRegistration()
        }
    }

    private func backendEnded(epoch: Int) async {
        guard epoch == backendEpoch else { return }
        let abandoned = stopBackend()
        for exchange in abandoned {
            await complete(exchange.origin, Self.unavailable)
        }
    }

    private func complete(_ origin: RemoteMCPRelayOrigin, _ completion: RemoteMCPRelayCompletion) async {
        try? await relay.completeMCPRoute(origin: origin, completion: completion)
    }

    private static func backendId(for origin: RemoteMCPRelayOrigin) -> String {
        "relay-\(origin.relayId)-\(origin.requestId)"
    }

    private static func isValidId(_ id: Any) -> Bool {
        if id is String { return true }
        guard let number = id as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    /// Every tool any relay backend serves; the backend itself refuses the
    /// ones outside its scope.
    static let relayedToolNames: Set<String> = ["visual_show", "pr_create", "pr_status"]

    private static func provesRegistration(method: String, message: [String: Any]) -> Bool {
        switch method {
        case "initialize", "tools/list":
            return true
        case "tools/call":
            let name = (message["params"] as? [String: Any])?["name"] as? String
            return name.map(relayedToolNames.contains) ?? false
        default:
            return false
        }
    }

    private static func succeeded(_ response: [String: Any]) -> Bool {
        guard response["error"] == nil, let result = response["result"] as? [String: Any] else { return false }
        return result["isError"] as? Bool != true
    }
}
