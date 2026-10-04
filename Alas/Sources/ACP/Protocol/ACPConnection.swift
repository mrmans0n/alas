import Foundation

final class ACPRequestHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private let action: @Sendable () -> Void

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func fire() {
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

struct ACPInitializeOutcome: Equatable {
    let promptCapabilities: ACPInitializeResult.ACPPromptCapabilities
    let authMethods: [ACPInitializeResult.ACPAuthMethod]
    let loadSession: Bool
    let sessionCapabilities: ACPInitializeResult.ACPAgentSessionCapabilities
    let mcpCapabilities: ACPMCPServerCapabilities
    let providerCapabilities: EmptyObject?
    let goalCapability: ACPGoalCapability?
    /// True when the agent answered our subagent opt-in — either with the
    /// standard `sessionCapabilities.subagents` or with OpenCode's
    /// `_meta["opencode/child-session-updates"]`.
    let supportsSubagents: Bool
    /// Whether the agent advertised the `_auth/status_update` extension marker.
    let advertisesAuthStatus: Bool
    let supportsSteering: Bool
    /// The adapter's self-reported name/version, when it sent `agentInfo`.
    let agentInfo: ACPImplementationInfo?

    init(
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
        supportsSteering: Bool = false
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
    }
}

/// Result of `session/prompt`: the durable-consumption acknowledgement (see
/// `ACPResponse`) plus the decoded `_meta.quota`, when the agent sent it.
struct ACPPromptOutcome {
    let acknowledgement: ACPDurableConsumptionAcknowledgement?
    let quota: ACPPromptQuota?
}

enum ACPSteeringOutcome: String, Decodable {
    case injected, startedNewTurn, promptRequired, failed
}

struct ACPSteeringResult {
    let outcome: Result<ACPSteeringOutcome, Error>
    let acknowledgement: ACPDurableConsumptionAcknowledgement?
}

struct ACPSteeringParams: Encodable {
    let sessionId: String
    let prompt: [ACPContentBlock]
    // Claude honors this opt-in. Older adapters may still return startedNewTurn.
    var meta = ["steering": ["idleBehavior": "promptRequired"]]

    enum CodingKeys: String, CodingKey {
        case sessionId, prompt
        case meta = "_meta"
    }
}

/// Higher-level wrapper that owns one `ACPClient` and exposes typed
/// methods for the messages we send.
final class ACPConnection: @unchecked Sendable {
    let client: ACPClient
    private let durableResponseLock = NSLock()
    private var pendingDurableSessionResponses: [ACPDurableConsumptionAcknowledgement] = []

    /// `_meta` attached to every session/new, session/load, session/resume,
    /// and session/fork this connection sends. Set once, right after the
    /// connection is created and before any session request, from the
    /// policy the Alas session was created with — so a reconnect or restore
    /// re-sends exactly what the fresh session got.
    var sessionMeta: ACPSessionMeta?

    init(client: ACPClient, sessionMeta: ACPSessionMeta? = nil) {
        self.client = client
        self.sessionMeta = sessionMeta
    }

    /// Returns the initialize outcome advertised by the agent, defaulting
    /// missing prompt capability fields to false and missing auth methods to empty.
    @discardableResult
    func initialize(brokerOperationKey: String? = nil) async throws -> ACPInitializeOutcome {
        let req = ACPRequest(method: "initialize",
                             params: ACPInitializeParams(
                                protocolVersion: ACPProtocolVersion.current,
                                clientCapabilities: .init(
                                    fs: .init(readTextFile: true, writeTextFile: true),
                                    terminal: client.advertisesTerminalCapability)),
                             brokerOperationKey: brokerOperationKey)
        let resp = try await client.send(req)
        defer { resp.acknowledgeDurableConsumption() }
        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: resp.body)
        let capabilities = result.agentCapabilities
        return ACPInitializeOutcome(
            promptCapabilities: capabilities?.promptCapabilities ?? .init(),
            authMethods: result.authMethods,
            loadSession: capabilities?.loadSession ?? false,
            sessionCapabilities: capabilities?.sessionCapabilities ?? .init(),
            mcpCapabilities: capabilities?.mcpCapabilities ?? .init(),
            providerCapabilities: capabilities?.providerCapabilities,
            goalCapability: capabilities?.meta.goal,
            supportsSubagents: capabilities?.sessionCapabilities.supportsSubagents == true
                || capabilities?.meta.openCodeChildSessionUpdates == true,
            advertisesAuthStatus: capabilities?.advertisesAuthStatus ?? false,
            agentInfo: result.agentInfo,
            supportsSteering: result.supportsSteering
        )
    }

    func newSession(
        cwd: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/new",
                             params: ACPSessionNewParams(cwd: cwd, mcpServers: mcpServers, meta: sessionMeta),
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

    func authenticate(methodId: String) async throws {
        let resp = try await client.send(ACPRequest(
            method: "authenticate",
            params: ACPAuthenticateParams(methodId: methodId)
        ))
        resp.acknowledgeDurableConsumption()
    }

    func loadSession(
        cwd: String,
        sessionId: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/load",
                             params: ACPSessionLoadParams(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers, meta: sessionMeta),
                             brokerOperationKey: brokerOperationKey)
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        deferDurableSessionResponse(resp)
        return result.sessionId.isEmpty ? result.withSessionId(sessionId) : result
    }

    func resumeSession(
        cwd: String,
        sessionId: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(
            method: "session/resume",
            params: ACPSessionResumeParams(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers, meta: sessionMeta),
            brokerOperationKey: brokerOperationKey
        )
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        deferDurableSessionResponse(resp)
        return result.sessionId.isEmpty ? result.withSessionId(sessionId) : result
    }

    func listSessions(cwd: String?, cursor: String? = nil) async throws -> ACPSessionListResult {
        let req = ACPRequest(
            method: "session/list",
            params: ACPSessionListParams(cwd: cwd, cursor: cursor)
        )
        let resp = try await client.send(req)
        defer { resp.acknowledgeDurableConsumption() }
        return try JSONDecoder().decode(ACPSessionListResult.self, from: resp.body)
    }

    func forkSession(
        cwd: String,
        sessionId: String,
        mcpServers: [ACPMCPServer],
        brokerOperationKey: String? = nil
    ) async throws -> ACPSessionNewResult {
        let req = ACPRequest(
            method: "session/fork",
            params: ACPSessionForkParams(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers, meta: sessionMeta),
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

    func closeSession(sessionId: String) async throws {
        let response = try await client.send(ACPRequest(
            method: "session/close",
            params: ACPSessionCloseParams(sessionId: sessionId)
        ))
        response.acknowledgeDurableConsumption()
    }

    func deleteSession(sessionId: String) async throws {
        let response = try await client.send(ACPRequest(
            method: "session/delete",
            params: ACPSessionDeleteParams(sessionId: sessionId)
        ))
        defer { response.acknowledgeDurableConsumption() }
        _ = try JSONDecoder().decode(EmptyObject.self, from: response.body)
    }

    func cancel(sessionId: String) async throws {
        // ACP defines `session/cancel` as a JSON-RPC NOTIFICATION
        // (no `id`, no reply). Sending it as a request and awaiting a
        // response left `userCancel()` suspended forever against
        // spec-compliant agents, so the UI never returned to idle.
        try await client.notify(ACPRequest(method: "session/cancel",
                                           params: ACPSessionCancelParams(sessionId: sessionId)))
    }

    // ACP wire methods use snake_case (`session/set_mode`,
    // `session/set_model`). Cursor / Kiro / claude-agent-acp all
    // method-not-found camelCase variants, which previously left Alas
    // showing the new selection while the agent stayed on the old one.
    func setMode(sessionId: String, modeId: String) async throws {
        let resp = try await client.send(ACPRequest(method: "session/set_mode",
                                                    params: ACPSessionSetModeParams(sessionId: sessionId, modeId: modeId)))
        resp.acknowledgeDurableConsumption()
    }

    func setModel(sessionId: String, modelId: String) async throws {
        let resp = try await client.send(ACPRequest(method: "session/set_model",
                                                    params: ACPSessionSetModelParams(sessionId: sessionId, modelId: modelId)))
        resp.acknowledgeDurableConsumption()
    }

    func controlGoal(
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

    func listProviders() async throws -> [ACPProviderInfo] {
        let response = try await client.send(ACPRequest(
            method: "providers/list",
            params: ACPProvidersListParams()
        ))
        defer { response.acknowledgeDurableConsumption() }
        return try JSONDecoder().decode(ACPProvidersListResult.self, from: response.body).providers
    }

    func setProvider(_ params: ACPProviderSetParams) async throws -> [ACPProviderInfo] {
        let response = try await client.send(ACPRequest(method: "providers/set", params: params))
        response.acknowledgeDurableConsumption()
        return try await listProviders()
    }

    func disableProvider(providerId: String) async throws -> [ACPProviderInfo] {
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
    func setConfigOption(sessionId: String,
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
    func prompt(
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

    func steer(
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

    func acknowledgeDurableSessionResponses() {
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

    func shutdown() async { await client.shutdown() }

    func detach() async { await client.detach() }
}
