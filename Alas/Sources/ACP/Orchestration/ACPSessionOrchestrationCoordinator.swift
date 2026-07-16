import Foundation

@MainActor
final class ACPSessionOrchestrationCoordinator {
    struct WorktreeCreationError: Error {
        let message: String
    }

    struct SessionLocation {
        let origin: ACPOrchestrationSessionOrigin
        let manager: ACPSessionManager
    }

    struct Environment {
        let persistence: ACPOrchestrationPersistence
        let instanceId: String
        let now: () -> Int64
        let makeID: () -> String
        let worktree: (String) -> Worktree?
        let existingWorktree: (String, String) -> Worktree?
        let availableAgents: () -> [ACPOrchestrationAgent]
        let sessionLocation: (String) -> SessionLocation?
        let manager: (Worktree) -> ACPSessionManager?
        let newWorktreeDestination: (String, String) -> URL?
        let createWorktree: (String, String, String?) async -> Result<Worktree, WorktreeCreationError>
        let rememberParent: (String, String) -> Void
        let notifyChanged: () -> Void
    }

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func list(origin: ACPOrchestrationSessionOrigin) async -> AlasCLIResponse {
        do {
            let parent = try await environment.persistence.parent(childSessionId: origin.sessionId)
            let children = try await environment.persistence.children(parentSessionId: origin.sessionId)
            let visible = ACPSessionOrchestrationPolicy.visibleSessions(
                callerSessionId: origin.sessionId,
                parent: parent,
                children: children
            )
            let summaries = visible.compactMap { visible -> ACPOrchestrationSessionSummary? in
                if visible.sessionId == origin.sessionId {
                    return sessionSummary(
                        sessionId: origin.sessionId,
                        relationship: nil,
                        agentId: environment.sessionLocation(origin.sessionId)?.manager.liveSession(for: origin.sessionId)?.agentId ?? parent?.agentId ?? "unknown",
                        worktreeId: origin.worktreeId,
                        phase: .ready,
                        failure: nil,
                        createdAt: 0
                    )
                }
                if visible.relationship == .parent {
                    let location = environment.sessionLocation(visible.sessionId)
                    return sessionSummary(
                        sessionId: visible.sessionId,
                        relationship: "parent",
                        agentId: location?.manager.liveSession(for: visible.sessionId)?.agentId ?? "unknown",
                        worktreeId: location?.origin.worktreeId ?? parent?.parentWorktreeId ?? "",
                        phase: .ready,
                        failure: nil,
                        createdAt: 0
                    )
                }
                guard let record = children.first(where: { $0.childSessionId == visible.sessionId }) else { return nil }
                return sessionSummary(
                    sessionId: record.childSessionId,
                    relationship: "child",
                    agentId: record.agentId,
                    worktreeId: record.childWorktreeId ?? record.worktreeRequest.worktreeId ?? "",
                    phase: record.phase,
                    failure: record.failureMessage,
                    createdAt: record.createdAt
                )
            }
            return json(ACPOrchestrationListResponse(sessions: summaries))
        } catch {
            return .error("Could not load delegated sessions.")
        }
    }

    func create(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionNewRequest
    ) async -> AlasCLIResponse {
        let parentLocation = environment.sessionLocation(origin.sessionId)
        guard let parentSession = parentLocation?.manager.liveSession(for: origin.sessionId) else {
            return .error("The originating ACP session is no longer available.")
        }

        let parent: ACPDelegationRecord?
        do {
            parent = try await environment.persistence.parent(childSessionId: origin.sessionId)
        } catch {
            return .error("Could not verify session delegation.")
        }
        guard case .success = ACPSessionOrchestrationPolicy.authorizeCreate(parent: parent) else {
            return .error("Delegated sessions cannot create child sessions.")
        }

        let prompt: String
        let agentID: String
        do {
            prompt = try ACPSessionOrchestrationPolicy.validatedPrompt(request.prompt)
            agentID = try ACPSessionOrchestrationPolicy.resolveAgent(
                requestedId: request.agentId,
                parentAgentId: parentSession.agentId,
                available: environment.availableAgents()
            )
        } catch ACPSessionOrchestrationPolicy.Error.blankPrompt {
            return .error("prompt must not be blank")
        } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
            return .error("Agent is not enabled or ACP-capable: \(id)")
        } catch {
            return .error("Could not validate delegated session request.")
        }

        let childID = environment.makeID()
        let now = environment.now()
        switch request.worktree {
        case .current:
            guard let worktree = environment.worktree(origin.worktreeId) else {
                return .error("The current worktree is no longer available.")
            }
            return await createChild(
                childID: childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                worktree: worktree,
                request: .current(worktreeId: worktree.id),
                phase: .starting,
                now: now
            )
        case .existing(let id):
            guard let worktree = environment.existingWorktree(origin.projectId, id) else {
                return .error("The requested worktree is not available in this project.")
            }
            return await createChild(
                childID: childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                worktree: worktree,
                request: .existing(worktreeId: worktree.id),
                phase: .starting,
                now: now
            )
        case .new(let branch, let base):
            guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("new_worktree branch must not be blank")
            }
            guard let destination = environment.newWorktreeDestination(origin.projectId, branch) else {
                return .error("The project is no longer available.")
            }
            let optimisticID = "pending-\(childID)"
            let record = ACPDelegationRecord(
                childSessionId: childID,
                parentSessionId: origin.sessionId,
                projectId: origin.projectId,
                parentWorktreeId: origin.worktreeId,
                childWorktreeId: nil,
                agentId: agentID,
                worktreeRequest: .new(
                    branch: branch,
                    base: base,
                    destinationPath: destination.path,
                    optimisticId: optimisticID
                ),
                pendingInitialPrompt: prompt,
                phase: .creatingWorktree,
                failureMessage: nil,
                createdAt: now,
                updatedAt: now
            )
            do {
                try await environment.persistence.insert(record)
            } catch {
                return .error("Could not persist delegated session.")
            }
            environment.notifyChanged()
            Task { @MainActor in
                let result = await self.environment.createWorktree(origin.projectId, branch, base)
                switch result {
                case .success(let worktree):
                    await self.startPersistedChild(childID: childID, prompt: prompt, worktree: worktree)
                case .failure(let error):
                    try? await self.environment.persistence.updatePhase(
                        childSessionId: childID, phase: .failed, failureMessage: error.message, updatedAt: self.environment.now()
                    )
                    self.environment.notifyChanged()
                }
            }
            return json(ACPOrchestrationNewResponse(sessionId: childID, state: "creating_worktree", worktreeId: nil))
        }
    }

    func send(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionMessageRequest
    ) async -> AlasCLIResponse {
        let prompt: String
        do {
            prompt = try ACPSessionOrchestrationPolicy.validatedPrompt(request.prompt)
        } catch {
            return .error("prompt must not be blank")
        }
        let callerParent: ACPDelegationRecord?
        let targetParent: ACPDelegationRecord?
        do {
            callerParent = try await environment.persistence.parent(childSessionId: origin.sessionId)
            targetParent = try await environment.persistence.parent(childSessionId: request.targetSessionId)
            let target = environment.sessionLocation(request.targetSessionId)
            guard let targetProjectId = target?.origin.projectId ?? targetParent?.projectId ?? callerParent?.projectId else {
                return .error("The target ACP session is not available.")
            }
            guard case .success = ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: origin.sessionId,
                callerProjectId: origin.projectId,
                targetSessionId: request.targetSessionId,
                targetProjectId: targetProjectId,
                callerParent: callerParent,
                targetParent: targetParent
            ) else {
                return .error("Messages may only be sent to a direct parent or child session.")
            }
            guard ACPSessionOrchestrationPolicy.acceptsMessages(target: targetParent) else {
                return .error("The target delegated session is not available.")
            }
        } catch {
            return .error("Could not verify session delegation.")
        }

        let message = ACPDelegatedMessage(
            id: environment.makeID(),
            sourceSessionId: origin.sessionId,
            targetSessionId: request.targetSessionId,
            prompt: prompt,
            createdAt: environment.now()
        )
        do {
            try await environment.persistence.enqueue(message)
        } catch {
            return .error("Could not queue delegated message.")
        }
        environment.notifyChanged()
        Task { @MainActor in
            await self.deliverPendingMessages(
                to: request.targetSessionId,
                callerParent: callerParent,
                targetParent: targetParent
            )
        }
        return json(ACPOrchestrationSendResponse(messageId: message.id, state: "queued"))
    }

    private func createChild(
        childID: String,
        origin: ACPOrchestrationSessionOrigin,
        prompt: String,
        agentID: String,
        worktree: Worktree,
        request: ACPDelegatedWorktreeRequest,
        phase: ACPDelegationPhase,
        now: Int64
    ) async -> AlasCLIResponse {
        environment.rememberParent(childID, origin.sessionId)
        let record = ACPDelegationRecord(
            childSessionId: childID,
            parentSessionId: origin.sessionId,
            projectId: origin.projectId,
            parentWorktreeId: origin.worktreeId,
            childWorktreeId: worktree.id,
            agentId: agentID,
            worktreeRequest: request,
            pendingInitialPrompt: prompt,
            phase: phase,
            failureMessage: nil,
            createdAt: now,
            updatedAt: now
        )
            do {
                self.environment.rememberParent(childID, origin.sessionId)
                try await environment.persistence.insert(record)
        } catch {
            return .error("Could not persist delegated session.")
        }
        environment.notifyChanged()
        Task { @MainActor in
            await self.startPersistedChild(childID: childID, prompt: prompt, worktree: worktree)
        }
        return json(ACPOrchestrationNewResponse(sessionId: childID, state: "starting", worktreeId: worktree.id))
    }

    private func startPersistedChild(childID: String, prompt: String, worktree: Worktree) async {
        guard let manager = environment.manager(worktree) else {
            try? await environment.persistence.updatePhase(
                childSessionId: childID, phase: .failed, failureMessage: "Could not create ACP session manager.", updatedAt: environment.now()
            )
            environment.notifyChanged()
            return
        }
        let record: ACPDelegationRecord?
        do {
            record = try await environment.persistence.delegation(childSessionId: childID)
        } catch {
            return
        }
        guard let record else { return }
        environment.rememberParent(childID, record.parentSessionId)
        try? await environment.persistence.updateChildWorktree(
            childSessionId: childID,
            worktreeId: worktree.id,
            phase: .starting,
            updatedAt: environment.now()
        )
        if manager.liveSession(for: childID) == nil {
            _ = manager.createSession(id: childID, agentId: record.agentId)
        }
        let accepted = await manager.enqueueDelegatedPrompt(
            text: prompt,
            source: ACPDelegatedPromptSource(sessionId: record.parentSessionId, messageId: "initial-\(childID)"),
            into: childID
        )
        guard accepted else {
            try? await environment.persistence.updatePhase(
                childSessionId: childID, phase: .failed, failureMessage: "Could not queue initial prompt.", updatedAt: environment.now()
            )
            environment.notifyChanged()
            return
        }
        try? await environment.persistence.clearPendingInitialPrompt(childSessionId: childID, updatedAt: environment.now())
        try? await environment.persistence.updatePhase(
            childSessionId: childID, phase: .ready, failureMessage: nil, updatedAt: environment.now()
        )
        environment.notifyChanged()
        await deliverPendingMessages(
            to: childID,
            callerParent: record,
            targetParent: record
        )
        Task { @MainActor [weak manager] in
            await manager?.attach(to: childID, freshlyCreated: true)
        }
    }

    private func deliverPendingMessages(
        to sessionID: String,
        callerParent: ACPDelegationRecord?,
        targetParent: ACPDelegationRecord?
    ) async {
        guard let target = await resolveDeliveryTarget(
            sessionID: sessionID,
            callerParent: callerParent,
            targetParent: targetParent
        ), let messages = try? await environment.persistence.pendingMessages(targetSessionId: sessionID)
        else { return }
        for message in messages {
            await deliver(message.id, to: target)
        }
    }

    private func resolveDeliveryTarget(
        sessionID: String,
        callerParent: ACPDelegationRecord?,
        targetParent: ACPDelegationRecord?
    ) async -> SessionLocation? {
        if let target = environment.sessionLocation(sessionID) {
            return target
        }
        let worktreeID = targetParent?.childWorktreeId ?? callerParent?.parentWorktreeId
        guard let worktreeID,
              let worktree = environment.worktree(worktreeID),
              let manager = environment.manager(worktree),
              await manager.persistedSessionRow(id: sessionID) != nil
        else { return nil }
        _ = manager.placeholderSession(id: sessionID)
        await manager.hydrateIfNeeded(id: sessionID)
        return .init(
            origin: ACPOrchestrationSessionOrigin(
                sessionId: sessionID,
                projectId: worktree.projectId,
                worktreeId: worktree.id
            ),
            manager: manager
        )
    }

    private func deliver(_ messageID: String, to target: SessionLocation) async {
        guard let claimed = try? await environment.persistence.claimMessage(
            id: messageID,
            instanceId: environment.instanceId,
            token: environment.makeID(),
            now: environment.now(),
            staleAfter: 60
        ) else { return }
        await target.manager.attach(to: claimed.message.targetSessionId, freshlyCreated: false)
        guard target.manager.isWriter(for: claimed.message.targetSessionId) else {
            try? await environment.persistence.releaseMessageClaim(id: claimed.message.id, claim: claimed.claim)
            target.manager.notifyDelegatedMessagesAvailable()
            return
        }
        let accepted = await target.manager.enqueueDelegatedPrompt(
            text: claimed.message.prompt,
            source: ACPDelegatedPromptSource(
                sessionId: claimed.message.sourceSessionId,
                messageId: claimed.message.id
            ),
            into: claimed.message.targetSessionId
        )
        guard accepted else {
            try? await environment.persistence.releaseMessageClaim(id: claimed.message.id, claim: claimed.claim)
            return
        }
        try? await environment.persistence.removeDeliveredMessage(id: claimed.message.id, claim: claimed.claim)
        environment.notifyChanged()
    }

    private func sessionSummary(
        sessionId: String,
        relationship: String?,
        agentId: String,
        worktreeId: String,
        phase: ACPDelegationPhase,
        failure: String?,
        createdAt: Int64
    ) -> ACPOrchestrationSessionSummary {
        let runtime = environment.sessionLocation(sessionId).flatMap { location -> ACPOrchestrationRuntimeState? in
            guard let session = location.manager.liveSession(for: sessionId) else { return nil }
            switch session.transcript.streamingState {
            case .idle: return .idle
            case .sending, .streaming: return .running
            case .awaitingPermission, .awaitingInput: return .awaitingInput
            }
        }
        let state = ACPSessionOrchestrationPolicy.publicState(phase: phase, runtime: runtime, archived: false)
        return .init(
            sessionId: sessionId,
            relationship: relationship,
            agentId: agentId,
            worktreeId: worktreeId,
            state: state.rawValue,
            failure: failure,
            createdAt: createdAt
        )
    }

    private func json<T: Encodable>(_ value: T) -> AlasCLIResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let line = String(data: data, encoding: .utf8) else {
            return .error("Could not encode session response.")
        }
        return .text([line])
    }
}
