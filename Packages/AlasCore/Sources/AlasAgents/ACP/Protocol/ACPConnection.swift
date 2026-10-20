import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public final class ACPRequestHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private let action: @Sendable () -> Void

    public init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    public func fire() {
        lock.lock()
        guard !hasFired else {
            lock.unlock()
            return
        }
        hasFired = true
        lock.unlock()
        action()
    }
}

private final class ACPRequestHandoffBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private let action: @Sendable () throws -> Void

    init(_ action: @escaping @Sendable () throws -> Void) {
        self.action = action
    }

    func fire() throws {
        lock.lock()
        guard !hasFired else {
            lock.unlock()
            return
        }
        hasFired = true
        lock.unlock()
        try action()
    }
}

public struct ACPInitializeOutcome: Equatable, Sendable {
    public let promptCapabilities: ACPInitializeResult.ACPPromptCapabilities
    public let authMethods: [ACPInitializeResult.ACPAuthMethod]
    public let loadSession: Bool
    public let sessionCapabilities: ACPInitializeResult.ACPAgentSessionCapabilities
    public let mcpCapabilities: ACPMCPServerCapabilities
    public let providerCapabilities: EmptyObject?
    public let goalCapability: ACPGoalCapability?
    /// True when the agent answered our subagent opt-in — either with the
    /// standard `sessionCapabilities.subagents` or with OpenCode's
    /// `_meta["opencode/child-session-updates"]`.
    public let supportsSubagents: Bool
    /// Whether the agent advertised the `_auth/status_update` extension marker.
    public let advertisesAuthStatus: Bool
    public let supportsSteering: Bool
    public let supportsAsyncTasks: Bool
    public let supportsContextBreakdown: Bool
    /// The adapter advertised `_meta.systemPrompt.append` (codex-acp).
    public let supportsSystemPromptAppend: Bool
    /// The advertised append limit in UTF-8 bytes, if any.
    public let systemPromptAppendMaxBytes: Int?
    /// The client-neutral session index, when the agent advertised it.
    public let sessionIndex: ACPSessionIndexSupport?
    /// The adapter's self-reported name/version, when it sent `agentInfo`.
    public let agentInfo: ACPImplementationInfo?

    public init(
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        authMethods: [ACPInitializeResult.ACPAuthMethod],
        loadSession: Bool,
        sessionCapabilities: ACPInitializeResult.ACPAgentSessionCapabilities,
        mcpCapabilities: ACPMCPServerCapabilities,
        providerCapabilities: EmptyObject?,
        goalCapability: ACPGoalCapability? = nil,
        supportsSubagents: Bool = false,
        advertisesAuthStatus: Bool = false,
        agentInfo: ACPImplementationInfo? = nil,
        supportsSteering: Bool = false,
        supportsAsyncTasks: Bool = false,
        supportsContextBreakdown: Bool = false,
        supportsSystemPromptAppend: Bool = false,
        systemPromptAppendMaxBytes: Int? = nil,
        sessionIndex: ACPSessionIndexSupport? = nil
    ) {
        self.promptCapabilities = promptCapabilities
        self.authMethods = authMethods
        self.loadSession = loadSession
        self.sessionCapabilities = sessionCapabilities
        self.mcpCapabilities = mcpCapabilities
        self.providerCapabilities = providerCapabilities
        self.goalCapability = goalCapability
        self.supportsSubagents = supportsSubagents
        self.advertisesAuthStatus = advertisesAuthStatus
        self.agentInfo = agentInfo
        self.supportsSteering = supportsSteering
        self.supportsAsyncTasks = supportsAsyncTasks
        self.supportsContextBreakdown = supportsContextBreakdown
        self.supportsSystemPromptAppend = supportsSystemPromptAppend
        self.systemPromptAppendMaxBytes = systemPromptAppendMaxBytes
        self.sessionIndex = sessionIndex
    }
}

/// Result of `session/prompt`: the durable-consumption acknowledgement (see
/// `ACPResponse`) plus the decoded `_meta.quota`, when the agent sent it.
public struct ACPPromptOutcome: Sendable {
    public let acknowledgement: ACPDurableConsumptionAcknowledgement?
    public let quota: ACPPromptQuota?

    public init(acknowledgement: ACPDurableConsumptionAcknowledgement?, quota: ACPPromptQuota?) {
        self.acknowledgement = acknowledgement
        self.quota = quota
    }
}

public enum ACPSteeringOutcome: String, Decodable, Sendable {
    case injected, startedNewTurn, promptRequired, failed
}

public struct ACPSteeringResult: Sendable {
    public let outcome: Result<ACPSteeringOutcome, Error>
    public let acknowledgement: ACPDurableConsumptionAcknowledgement?

    public init(outcome: Result<ACPSteeringOutcome, Error>, acknowledgement: ACPDurableConsumptionAcknowledgement?) {
        self.outcome = outcome
        self.acknowledgement = acknowledgement
    }
}

public struct ACPSteeringParams: Encodable, Sendable {
    public let sessionId: String
    public let prompt: [ACPContentBlock]
    // Claude honors this opt-in. Older adapters may still return startedNewTurn.
    public var meta = ["steering": ["idleBehavior": "promptRequired"]]

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId, prompt
        case meta = "_meta"
    }
}

/// Higher-level wrapper that owns one `ACPClient` and exposes typed
/// methods for the messages we send.
public final class ACPConnection: @unchecked Sendable {
    public let client: ACPClient
    private let durableResponseLock = NSLock()
    private var pendingDurableSessionResponses: [ACPDurableConsumptionAcknowledgement] = []

    /// `_meta` attached to every session/new, session/load, session/resume,
    /// and session/fork this connection sends. Set once, right after the
    /// connection is created and before any session request, from the
    /// policy the Alas session was created with — so a reconnect or restore
    /// re-sends exactly what the fresh session got.
    public var sessionMeta: ACPSessionMeta?
    /// Set after `initialize` from `ACPMCPStartupWaitPolicy`. Sent on
    /// session/new, session/resume, and session/fork when Alas requests MCP
    /// servers; never on session/load, which ignores it.
    public var mcpStartupAwaitTimeoutMs: Int?
    /// The session index the agent advertised on `initialize`, if any.
    public private(set) var negotiatedSessionIndex: ACPSessionIndexSupport?
    /// Set after `initialize` from `ACPSessionInstructionsPolicy`. Sent as
    /// `_meta.systemPrompt.append` on session/new, load, resume, and fork.
    public var sessionInstructions: String?

    public init(client: ACPClient, sessionMeta: ACPSessionMeta? = nil) {
        self.client = client
        self.sessionMeta = sessionMeta
    }

    /// `sessionMeta` plus the per-connection fields. `mcpServers` is nil for
    /// session/load, which never gets the MCP startup wait.
    private func requestMeta(mcpServers: [ACPMCPServer]?) -> ACPSessionMeta? {
        var meta = sessionMeta ?? ACPSessionMeta()
        if let mcpStartupAwaitTimeoutMs, let mcpServers, !mcpServers.isEmpty {
            meta.mcpStartupAwaitTimeoutMs = mcpStartupAwaitTimeoutMs
        }
        if let sessionInstructions {
            meta.systemPrompt = .init(append: sessionInstructions)
        }
        return meta == ACPSessionMeta() ? sessionMeta : meta
    }

    /// Returns the initialize outcome advertised by the agent, defaulting
    /// missing prompt capability fields to false and missing auth methods to empty.
    @discardableResult
    public func initialize(brokerOperationKey: String? = nil) async throws -> ACPInitializeOutcome {
        let req = ACPRequest(method: "initialize",
                             params: ACPInitializeParams(
                                protocolVersion: ACPProtocolVersion.current,
                                clientCapabilities: .init(
                                    fs: .init(readTextFile: true, writeTextFile: true),
                                    terminal: client.advertisesTerminalCapability,
                                    meta: .terminalAuth)),
                             brokerOperationKey: brokerOperationKey)
        let resp = try await client.send(req)
        defer { resp.acknowledgeDurableConsumption() }
        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: resp.body)
        let capabilities = result.agentCapabilities
        negotiatedSessionIndex = result.meta?.sessionIndex?.support
        return ACPInitializeOutcome(
            promptCapabilities: capabilities?.promptCapabilities ?? .init(),
            authMethods: result.authMethods,
            loadSession: capabilities?.loadSession ?? false,
            sessionCapabilities: capabilities?.sessionCapabilities ?? .init(),
            mcpCapabilities: capabilities?.mcpCapabilities ?? .init(),
            providerCapabilities: capabilities?.providerCapabilities,
            goalCapability: result.meta?.goal ?? capabilities?.meta.goal,
            supportsSubagents: capabilities?.sessionCapabilities.supportsSubagents == true
                || capabilities?.meta.openCodeChildSessionUpdates == true,
            advertisesAuthStatus: capabilities?.advertisesAuthStatus ?? false,
            agentInfo: result.agentInfo,
            supportsSteering: result.supportsSteering,
            supportsAsyncTasks: result.meta?.asyncTasks?.supportsStop == true,
            supportsContextBreakdown: result.supportsContextBreakdown,
            supportsSystemPromptAppend: result.supportsSystemPromptAppend,
            systemPromptAppendMaxBytes: result.systemPromptAppendMaxBytes,
            sessionIndex: result.meta?.sessionIndex?.support
        )
    }

    public func newSession(
        cwd: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/new",
                             params: ACPSessionNewParams(cwd: cwd, mcpServers: mcpServers, meta: requestMeta(mcpServers: mcpServers)),
                             brokerOperationKey: brokerOperationKey)
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        guard !result.sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "session/new response is missing sessionId"
            ))
        }
        deferDurableSessionResponse(resp)
        return result
    }

    public func authenticate(methodId: String) async throws {
        let resp = try await client.send(ACPRequest(
            method: "authenticate",
            params: ACPAuthenticateParams(methodId: methodId)
        ))
        resp.acknowledgeDurableConsumption()
    }

    public func loadSession(
        cwd: String,
        sessionId: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/load",
                             params: ACPSessionLoadParams(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers, meta: requestMeta(mcpServers: nil)),
                             brokerOperationKey: brokerOperationKey)
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        deferDurableSessionResponse(resp)
        return result.sessionId.isEmpty ? result.withSessionId(sessionId) : result
    }

    public func resumeSession(
        cwd: String,
        sessionId: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(
            method: "session/resume",
            params: ACPSessionResumeParams(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers, meta: requestMeta(mcpServers: mcpServers)),
            brokerOperationKey: brokerOperationKey
        )
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        deferDurableSessionResponse(resp)
        return result.sessionId.isEmpty ? result.withSessionId(sessionId) : result
    }

    /// `index` asks for the session index page; send it only to an agent
    /// that advertised `_meta.sessionIndex`.
    public func listSessions(
        cwd: String?,
        cursor: String? = nil,
        index: ACPSessionIndexListOptions? = nil
    ) async throws -> ACPSessionListResult {
        let req = ACPRequest(
            method: "session/list",
            params: ACPSessionListParams(cwd: cwd, cursor: cursor, index: index)
        )
        let resp = try await client.send(req)
        defer { resp.acknowledgeDurableConsumption() }
        return try JSONDecoder().decode(ACPSessionListResult.self, from: resp.body)
    }

    public func renameSession(sessionId: String, title: String) async throws {
        try await sendIgnoringResult(method: "_session/rename", params: ACPSessionRenameParams(sessionId: sessionId, title: title))
    }

    public func archiveSession(sessionId: String) async throws {
        try await sendIgnoringResult(method: "_session/archive", params: ACPSessionArchiveParams(sessionId: sessionId))
    }

    public func unarchiveSession(sessionId: String) async throws {
        try await sendIgnoringResult(method: "_session/unarchive", params: ACPSessionArchiveParams(sessionId: sessionId))
    }

    /// Returns the subscription id; changes arrive on
    /// `client.sessionListChanges`.
    public func subscribeSessionList(cwd: String) async throws -> String {
        let resp = try await client.send(ACPRequest(
            method: "_session/list/subscribe",
            params: ACPSessionListSubscribeParams(cwd: cwd)
        ))
        defer { resp.acknowledgeDurableConsumption() }
        return try JSONDecoder().decode(ACPSessionListSubscribeResult.self, from: resp.body).subscriptionId
    }

    public func unsubscribeSessionList(subscriptionId: String) async throws {
        try await sendIgnoringResult(
            method: "_session/list/unsubscribe",
            params: ACPSessionListUnsubscribeParams(subscriptionId: subscriptionId)
        )
    }

    private func sendIgnoringResult(method: String, params: some Encodable & Sendable) async throws {
        let resp = try await client.send(ACPRequest(method: method, params: params))
        resp.acknowledgeDurableConsumption()
    }

    public func forkSession(
        cwd: String,
        sessionId: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(
            method: "session/fork",
            params: ACPSessionForkParams(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers, meta: requestMeta(mcpServers: mcpServers)),
            brokerOperationKey: brokerOperationKey
        )
        let resp = try await client.send(req)
        deferDurableSessionResponse(resp)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        guard !result.sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "session/fork response is missing sessionId"
            ))
        }
        return result
    }

    public func closeSession(sessionId: String) async throws {
        let response = try await client.send(ACPRequest(
            method: "session/close",
            params: ACPSessionCloseParams(sessionId: sessionId)
        ))
        response.acknowledgeDurableConsumption()
    }

    /// For an agent with the session index (our adapter forks), an unknown
    /// session (`-32002`) counts as deleted: they answer that for a session
    /// that is already gone. ACP gives `-32002` no such meaning, so for any
    /// other agent it stays an error.
    public func deleteSession(sessionId: String) async throws {
        let response: ACPResponse
        do {
            response = try await client.send(ACPRequest(
                method: "session/delete",
                params: ACPSessionDeleteParams(sessionId: sessionId)
            ))
        } catch ACPClientError.jsonrpc(let error) where error.code == -32002 && negotiatedSessionIndex != nil {
            return
        }
        defer { response.acknowledgeDurableConsumption() }
        _ = try JSONDecoder().decode(EmptyObject.self, from: response.body)
    }

    public func cancel(sessionId: String) async throws {
        // ACP defines `session/cancel` as a JSON-RPC NOTIFICATION
        // (no `id`, no reply). Sending it as a request and awaiting a
        // response left `userCancel()` suspended forever against
        // spec-compliant agents, so the UI never returned to idle.
        try await client.notify(ACPRequest(method: "session/cancel",
                                           params: ACPSessionCancelParams(sessionId: sessionId)))
    }

    public func stopBackgroundTask(sessionId: String, asyncTaskId: String) async throws -> Bool {
        struct Params: Encodable { let sessionId: String
        let asyncTaskId: String }
        struct Result: Decodable { let stopped: Bool }
        let response = try await client.send(ACPRequest(
            method: "_session/async_task/stop", params: Params(sessionId: sessionId, asyncTaskId: asyncTaskId)))
        defer { response.acknowledgeDurableConsumption() }
        return try JSONDecoder().decode(Result.self, from: response.body).stopped
    }

    /// `detail: "full"` counts each category with the token-count API;
    /// `"summary"` estimates locally from the last response's usage.
    public func contextBreakdown(sessionId: String, detail: String) async throws -> ACPContextBreakdown {
        struct Params: Encodable { let sessionId: String
        let detail: String }
        let response = try await client.send(ACPRequest(
            method: "_alas/context_usage", params: Params(sessionId: sessionId, detail: detail)))
        defer { response.acknowledgeDurableConsumption() }
        return try JSONDecoder().decode(ACPContextBreakdown.self, from: response.body)
    }

    // ACP wire methods use snake_case (`session/set_mode`,
    // `session/set_model`). Cursor / Kiro / claude-agent-acp all
    // method-not-found camelCase variants, which previously left Alas
    // showing the new selection while the agent stayed on the old one.
    public func setMode(sessionId: String, modeId: String) async throws {
        let resp = try await client.send(ACPRequest(method: "session/set_mode",
                                                    params: ACPSessionSetModeParams(sessionId: sessionId, modeId: modeId)))
        resp.acknowledgeDurableConsumption()
    }

    public func setModel(sessionId: String, modelId: String) async throws {
        let resp = try await client.send(ACPRequest(method: "session/set_model",
                                                    params: ACPSessionSetModelParams(sessionId: sessionId, modelId: modelId)))
        resp.acknowledgeDurableConsumption()
    }

    public func controlGoal(
        sessionId: String,
        capability: ACPGoalCapability,
        action: ACPGoalAction,
        objective: String? = nil
    ) async throws {
        guard capability.actions.contains(action) else {
            throw ACPGoalControlError.unsupportedAction(action)
        }
        let normalizedObjective: String?
        if action == .set {
            let trimmed = objective?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { throw ACPGoalControlError.objectiveRequired }
            normalizedObjective = trimmed
        } else {
            normalizedObjective = nil
        }
        let response = try await client.send(ACPRequest(
            method: capability.controlMethod,
            params: ACPGoalControlParams(sessionId: sessionId, action: action, objective: normalizedObjective)
        ))
        defer { response.acknowledgeDurableConsumption() }
        _ = try JSONDecoder().decode(EmptyObject.self, from: response.body)
    }

    public func listProviders() async throws -> [ACPProviderInfo] {
        let response = try await client.send(ACPRequest(
            method: "providers/list",
            params: ACPProvidersListParams()
        ))
        defer { response.acknowledgeDurableConsumption() }
        return try JSONDecoder().decode(ACPProvidersListResult.self, from: response.body).providers
    }

    public func setProvider(_ params: ACPProviderSetParams) async throws -> [ACPProviderInfo] {
        let response = try await client.send(ACPRequest(method: "providers/set", params: params))
        response.acknowledgeDurableConsumption()
        return try await listProviders()
    }

    public func disableProvider(providerId: String) async throws -> [ACPProviderInfo] {
        let response = try await client.send(ACPRequest(
            method: "providers/disable",
            params: ACPProviderDisableParams(providerId: providerId)
        ))
        response.acknowledgeDurableConsumption()
        return try await listProviders()
    }

    /// Sends a config-option change and returns the agent's refreshed
    /// `configOptions` list. The agent may return empty (older/non-compliant
    /// implementations) in which case the caller's optimistic local update
    /// stands; on a full echo the caller should overwrite local state so
    /// dependent options stay in sync.
    public func setConfigOption(sessionId: String,
                         configId: String,
                         value: ACPConfigValue) async throws -> [ACPConfigOption] {
        let resp = try await client.send(ACPRequest(method: "session/set_config_option",
                                                    params: ACPSessionSetConfigOptionParams(
                                                        sessionId: sessionId,
                                                        configId: configId,
                                                        value: value)))
        defer { resp.acknowledgeDurableConsumption() }
        let result = try? JSONDecoder().decode(ACPSessionSetConfigOptionResult.self, from: resp.body)
        return result?.configOptions ?? []
    }

    @discardableResult
    public func prompt(
        sessionId: String,
        blocks: [ACPContentBlock],
        brokerOperationKey: String? = nil,
        acknowledgeDurableConsumption: Bool = true,
        onRequestHandoff: (@Sendable () -> Void)? = nil,
        onTransportHandoff: (@Sendable () -> Void)? = nil,
        beforeRequestHandoff: (@Sendable (ACPBrokerGeneration?) async throws -> Void)? = nil,
        onRequestHandoffDidOccur: (@Sendable () throws -> Void)? = nil
    ) async throws -> ACPPromptOutcome {
        let request = ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: sessionId, prompt: blocks),
            brokerOperationKey: brokerOperationKey
        )
        let resp: ACPResponse
        let handoff = onRequestHandoff.map(ACPRequestHandoff.init)
        let handoffBoundary = onRequestHandoffDidOccur.map(ACPRequestHandoffBoundary.init)
        do {
            if let beforeRequestHandoff,
               let preparingClient = client as? ACPRequestHandoffPreparing {
                resp = try await preparingClient.send(
                    request,
                    beforeRequestHandoff: beforeRequestHandoff,
                    onRequestHandoff: {
                        try handoffBoundary?.fire()
                        onTransportHandoff?()
                        handoff?.fire()
                    }
                )
            } else if handoff != nil || onTransportHandoff != nil {
                resp = try await client.send(request, onRequestHandoff: {
                    onTransportHandoff?()
                    handoff?.fire()
                })
            } else {
                resp = try await client.send(request)
            }
        } catch {
            handoff?.fire()
            throw error
        }
        let quota = (try? JSONDecoder().decode(ACPSessionPromptResult.self, from: resp.body))?.quota
        if acknowledgeDurableConsumption {
            resp.acknowledgeDurableConsumption()
            return ACPPromptOutcome(acknowledgement: nil, quota: quota)
        }
        return ACPPromptOutcome(acknowledgement: resp.durableConsumptionAcknowledgement, quota: quota)
    }

    public func steer(
        sessionId: String, blocks: [ACPContentBlock],
        brokerOperationKey: String? = nil,
        onRequestHandoff: (@Sendable () -> Void)? = nil
    ) async throws -> ACPSteeringResult {
        let request = ACPRequest(
            method: "_session/steering",
            params: ACPSteeringParams(sessionId: sessionId, prompt: blocks),
            brokerOperationKey: brokerOperationKey
        )
        let handoff = onRequestHandoff.map(ACPRequestHandoff.init)
        let response: ACPResponse
        func dispatch() async throws -> ACPResponse {
            if let handoff {
                return try await client.send(request, onRequestHandoff: { handoff.fire() })
            }
            return try await client.send(request)
        }
        do {
            do {
                response = try await dispatch()
            } catch {
                // The broker already completed this exact operation. Reusing
                // its saved key recovers the outcome without another delivery.
                guard brokerOperationKey != nil, error is ACPBrokerDurableCompletionReplayError else { throw error }
                response = try await dispatch()
            }
        } catch {
            handoff?.fire()
            throw error
        }
        struct DecodedResult: Decodable { let outcome: ACPSteeringOutcome }
        return ACPSteeringResult(
            outcome: Result { try JSONDecoder().decode(DecodedResult.self, from: response.body).outcome },
            acknowledgement: response.durableConsumptionAcknowledgement)
    }

    public func acknowledgeDurableSessionResponses() {
        durableResponseLock.lock()
        let acknowledgements = pendingDurableSessionResponses
        pendingDurableSessionResponses.removeAll(keepingCapacity: true)
        durableResponseLock.unlock()
        for acknowledgement in acknowledgements {
            acknowledgement()
        }
    }

    private func deferDurableSessionResponse(_ response: ACPResponse) {
        guard let acknowledgement = response.durableConsumptionAcknowledgement else { return }
        durableResponseLock.lock()
        pendingDurableSessionResponses.append(acknowledgement)
        durableResponseLock.unlock()
    }

    public func shutdown() async { await client.shutdown() }

    public func detach() async { await client.detach() }
}
