import Foundation

/// Where a new session runs.
public enum SessionTarget: Codable, Hashable, Sendable {
    case worktree(WorktreeRef)
    case workspaceCheckout(id: UUID)
}

/// Why the host did not act on a session.
public enum SessionRefusal: Error, Codable, Equatable, Sendable {
    /// No loaded session has this id.
    case notFound
    /// Another instance or device drives the session.
    case notWriter
    /// The worktree or Workspace checkout cannot host sessions now.
    case ownerUnavailable(reason: String)
    /// The agent is not enabled, or cannot run where the session would.
    case agentUnavailable
    /// The request was answered or replaced since the client saw it.
    case notPending
    /// The answer does not fit the request: an option it does not offer, a
    /// question left unanswered, a form that does not validate.
    case invalidAnswer
    /// The session did not take the prompt (it needs sign-in, or is shutting down).
    case promptRejected
    /// The session offers no such setting, or the value does not fit it.
    case invalidSetting
}

extension SessionsAPI {
    /// Creates a session for `agentID` and starts connecting it to the agent.
    /// The summary is ready at once; the session streams once it connects.
    public func create(
        _ target: SessionTarget,
        agentID: String,
        modelID: String? = nil,
        autoRun: Bool = false,
        caller: HostCaller
    ) async throws -> HostSessionSummary {
        caller.log("sessions.create", agentID)
        let manager: ACPSessionManager
        var worktreeOwner: Worktree?
        switch target {
        case .worktree(let ref):
            let listed = core.projects.worktrees(projectId: ref.projectID)
            let path = URL(fileURLWithPath: ref.path).standardizedFileURL.path
            guard let worktree = listed.first(where: { $0.path.standardizedFileURL.path == path }),
                  !core.projects.isWorktreeHidden(projectId: ref.projectID, path: worktree.path)
            else { throw SessionRefusal.ownerUnavailable(reason: "The worktree is not listed, or is archived.") }
            let remoteHost = core.projects.projects.first { $0.id == ref.projectID }?.host
            guard core.environment.admitsAgent(agentID, remoteHost: remoteHost) else { throw SessionRefusal.agentUnavailable }
            worktreeOwner = worktree
            do {
                manager = try core.environment.sessionManager(for: worktree, in: core)
            } catch is AlasCoreContext.WorktreeOperationInProgress {
                throw SessionRefusal.ownerUnavailable(reason: "Another operation holds the worktree.")
            }
        case .workspaceCheckout(let id):
            let checkout = try await idleCheckout(id)
            guard core.environment.admitsAgent(agentID, remoteHost: checkout.executionLocation.sshHost) else {
                throw SessionRefusal.agentUnavailable
            }
            guard await !core.environment.checkpointRecoveryBlocksSessions(owner: .workspaceCheckout(checkout.id, checkout.executionLocation), in: core) else {
                throw SessionRefusal.ownerUnavailable(reason: Self.checkpointRecoveryReason)
            }
            manager = try await core.environment.sessionManager(forCheckout: checkout, in: core)
        }
        // A checkpoint restore being recovered keeps agents out of the owner.
        guard await !core.environment.checkpointRecoveryBlocksSessions(owner: manager.owner, in: core) else {
            throw SessionRefusal.ownerUnavailable(reason: Self.checkpointRecoveryReason)
        }
        // Everything above can suspend: what the owner is now decides. This is
        // the last suspension before the session exists.
        if case .workspaceCheckout(let id) = target { _ = try await idleCheckout(id) }
        if let worktreeOwner {
            guard core.projects.admitsNewWork(in: worktreeOwner),
                  !core.projects.isWorktreeHidden(projectId: worktreeOwner.projectId, path: worktreeOwner.path)
            else { throw SessionRefusal.ownerUnavailable(reason: "Another operation holds the worktree.") }
        }
        guard core.sessionManagers[manager.owner] === manager else {
            throw SessionRefusal.ownerUnavailable(reason: "The session's owner was closed meanwhile.")
        }
        let session = manager.createSession(agentId: agentID, autoRunDefault: autoRun)
        // Picked up by `attach`, so the first turn already runs on it.
        if let modelID { manager.pendingModel[session.id] = modelID }
        Task { @MainActor [weak manager] in
            await manager?.attach(to: session.id, freshlyCreated: true)
        }
        guard let row = manager.sessionRows.first(where: { $0.id == session.id }) else { throw SessionRefusal.notFound }
        return Self.summary(of: row, in: manager)
    }

    /// Sends a prompt as the session's next user turn. Only the session's
    /// writer can.
    public func send(_ sessionID: String, prompt: String, caller: HostCaller) async throws {
        caller.log("sessions.send", sessionID)
        let manager = try writerManager(for: sessionID)
        let accepted = await withCheckedContinuation { continuation in
            Task { @MainActor in
                await manager.sendPrompt(for: sessionID, text: prompt, attachments: []) { continuation.resume(returning: $0) }
            }
        }
        guard accepted else { throw SessionRefusal.promptRejected }
    }

    /// Stops the session's running turn. Like the app's stop button, any
    /// client may: it is the brake, not a way to drive the session.
    public func stop(_ sessionID: String, caller: HostCaller) async throws {
        caller.log("sessions.stop", sessionID)
        try await liveManager(for: sessionID).interruptBypassingLease(for: sessionID)
    }

    /// Renames the session's row, as the app does from its tab.
    public func rename(_ sessionID: String, title: String, caller: HostCaller) throws {
        caller.log("sessions.rename", sessionID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionRefusal.invalidAnswer }
        guard let manager = rowManager(for: sessionID),
              manager.renameSessionCosmetic(id: sessionID, title: trimmed, source: .manual)
        else { throw SessionRefusal.notFound }
    }

    /// Stops the session, closing it with the agent, and hides it from the
    /// list. A session another live instance drives is refused.
    public func archive(_ sessionID: String, caller: HostCaller) async throws {
        caller.log("sessions.archive", sessionID)
        guard let manager = rowManager(for: sessionID) else { throw SessionRefusal.notFound }
        guard try await manager.archiveUnlessDrivenElsewhere(id: sessionID) else { throw SessionRefusal.notWriter }
    }

    public func setModel(_ sessionID: String, modelID: String, caller: HostCaller) async throws {
        caller.log("sessions.setModel", sessionID)
        let manager = try writerManager(for: sessionID)
        if let advertised = manager.liveSession(for: sessionID)?.availableModels, !advertised.isEmpty,
           !advertised.contains(where: { $0.id == modelID }) {
            throw SessionRefusal.invalidSetting
        }
        await manager.setModel(for: sessionID, modelId: modelID)
        try confirmStillWriter(manager, sessionID)
    }

    public func setMode(_ sessionID: String, modeID: String, caller: HostCaller) async throws {
        caller.log("sessions.setMode", sessionID)
        let manager = try writerManager(for: sessionID)
        if let advertised = manager.liveSession(for: sessionID)?.availableModes, !advertised.isEmpty,
           !advertised.contains(where: { $0.id == modeID }) {
            throw SessionRefusal.invalidSetting
        }
        await manager.setMode(for: sessionID, modeId: modeID)
        try confirmStillWriter(manager, sessionID)
    }

    public func setConfigOption(_ sessionID: String, configID: String, value: ACPConfigValue, caller: HostCaller) async throws {
        caller.log("sessions.setConfigOption", sessionID)
        let manager = try writerManager(for: sessionID)
        guard let option = manager.liveSession(for: sessionID)?.availableConfigOptions.first(where: { $0.id == configID }),
              option.acceptsPersistedValue(value)
        else { throw SessionRefusal.invalidSetting }
        // Nil from here means applied later, once the session finishes attaching.
        await manager.setConfigOption(for: sessionID, configId: configID, value: value)?.value
        try confirmStillWriter(manager, sessionID)
    }

    /// Answers the session's pending permission request `requestID`.
    public func answerPermission(
        _ sessionID: String,
        requestID: JSONRPCID,
        optionID: String,
        scope: ACPRequestAnswers.PermissionScope = .optionDefault,
        caller: HostCaller
    ) async throws {
        caller.log("sessions.answerPermission", sessionID)
        let manager = try liveManager(for: sessionID)
        guard let pending = manager.liveSession(for: sessionID)?.transcript.pendingPermission, pending.id == requestID,
              let policy = manager.permissionPolicy(for: sessionID)
        else { throw SessionRefusal.notPending }
        guard let answer = ACPRequestAnswers.permission(pending, optionId: optionID, scope: scope) else {
            throw SessionRefusal.invalidAnswer
        }
        guard await policy.userDecided(
            scopeKey: answer.scopeKey, optionId: answer.optionId, decision: answer.decision, persistScope: answer.persistScope
        ) else { throw SessionRefusal.notPending }
    }

    /// Answers the session's pending question `requestID`.
    public func answerQuestion(_ sessionID: String, requestID: JSONRPCID, answers: [ACPQuestionAnswer], caller: HostCaller) throws {
        caller.log("sessions.answerQuestion", sessionID)
        let manager = try liveManager(for: sessionID)
        guard let session = manager.liveSession(for: sessionID),
              let pending = ACPRequestAnswers.pendingQuestion(in: session), pending.id == requestID
        else { throw SessionRefusal.notPending }
        guard let response = ACPRequestAnswers.question(pending, answers: answers) else { throw SessionRefusal.invalidAnswer }
        guard manager.answerQuestion(for: sessionID, requestId: requestID, response) else { throw SessionRefusal.notPending }
    }

    /// Answers the session's pending plan `requestID`.
    public func respondToPlan(_ sessionID: String, requestID: JSONRPCID, action: ACPRequestAnswers.PlanAction, caller: HostCaller) throws {
        caller.log("sessions.respondToPlan", sessionID)
        let manager = try liveManager(for: sessionID)
        guard let pending = manager.liveSession(for: sessionID)?.transcript.pendingPlan, pending.id == requestID else {
            throw SessionRefusal.notPending
        }
        guard let response = ACPRequestAnswers.plan(pending, action: action) else { throw SessionRefusal.invalidAnswer }
        guard manager.respondToPlan(for: sessionID, requestId: requestID, response) else { throw SessionRefusal.notPending }
    }

    /// Answers the session's pending form or URL request `requestID`.
    public func respondToUserInput(
        _ sessionID: String,
        requestID: UUID,
        answer: ACPRequestAnswers.UserInputAnswer,
        caller: HostCaller
    ) throws {
        caller.log("sessions.respondToUserInput", sessionID)
        let manager = try liveManager(for: sessionID)
        guard let pending = manager.liveSession(for: sessionID)?.transcript.pendingUserInputs.first,
              pending.id == requestID, case .elicitation = pending.source
        else { throw SessionRefusal.notPending }
        guard let action = ACPRequestAnswers.userInput(pending, answer: answer) else { throw SessionRefusal.invalidAnswer }
        guard manager.respondToUserInput(for: sessionID, token: requestID, action: action) else { throw SessionRefusal.notPending }
    }

    static let checkpointRecoveryReason = "An interrupted checkpoint restore must be recovered first."

    /// The Workspace checkout `id`, when it is not archived and nothing is
    /// changing it.
    private func idleCheckout(_ id: UUID) async throws -> WorkspaceCheckout {
        let checkout = try await WorkspaceAutomationService(store: core.workspaceStore).checkout(id: id)
        guard checkout.operation == .idle, checkout.archivedAt == nil else {
            throw SessionRefusal.ownerUnavailable(reason: "The Workspace checkout is busy.")
        }
        return checkout
    }

    /// The manager whose live session is `sessionID`.
    private func liveManager(for sessionID: String) throws -> ACPSessionManager {
        guard let manager = core.sessionManagers.values.first(where: { $0.liveSession(for: sessionID) != nil }) else {
            throw SessionRefusal.notFound
        }
        return manager
    }

    /// The live session's manager, when this instance drives the session.
    private func writerManager(for sessionID: String) throws -> ACPSessionManager {
        let manager = try liveManager(for: sessionID)
        guard manager.isWriter(for: sessionID) else { throw SessionRefusal.notWriter }
        return manager
    }

    /// A setting is applied only once the manager confirms the lease; one it
    /// lost meanwhile drops the setting, which the caller must hear about.
    private func confirmStillWriter(_ manager: ACPSessionManager, _ sessionID: String) throws {
        guard manager.isWriter(for: sessionID) else { throw SessionRefusal.notWriter }
    }

    /// The manager that lists `sessionID`, live or not.
    private func rowManager(for sessionID: String) -> ACPSessionManager? {
        core.sessionManagers.values.first { manager in
            manager.liveSession(for: sessionID) != nil || manager.sessionRows.contains { $0.id == sessionID }
        }
    }
}
