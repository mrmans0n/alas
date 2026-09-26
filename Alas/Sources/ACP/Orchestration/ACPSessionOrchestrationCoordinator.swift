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
        /// Epoch **milliseconds**, unlike `now` (seconds). Used only where
        /// millisecond precision matters: recording when a delegated child
        /// reported to its parent, compared against `ACPTurnCompletion
        /// .startedAt` (also milliseconds) in `outcomeDisposition`. Defaults
        /// to a real millisecond clock so existing call sites that don't
        /// care about this comparison don't need to supply one.
        let nowMillis: () -> Int64
        let makeID: () -> String
        let worktree: (String) -> Worktree?
        let existingWorktree: (String, String) -> Worktree?
        let configuredAgents: () -> [ACPOrchestrationAgent]
        let availableAgents: (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPOrchestrationAgent]
        let sessionLocation: (String) -> SessionLocation?
        let manager: (Worktree) -> ACPSessionManager?
        let newWorktreeDestination: (String, String) -> URL?
        let createWorktree: (String, String, String?) async -> Result<Worktree, WorktreeCreationError>
        let rememberParent: (String, String) -> Void
        let autoRunDefault: () -> Bool
        let notifyChanged: () -> Void

        init(
            persistence: ACPOrchestrationPersistence,
            instanceId: String,
            now: @escaping () -> Int64,
            nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
            makeID: @escaping () -> String,
            worktree: @escaping (String) -> Worktree?,
            existingWorktree: @escaping (String, String) -> Worktree?,
            configuredAgents: @escaping () -> [ACPOrchestrationAgent],
            availableAgents: @escaping (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPOrchestrationAgent],
            sessionLocation: @escaping (String) -> SessionLocation?,
            manager: @escaping (Worktree) -> ACPSessionManager?,
            newWorktreeDestination: @escaping (String, String) -> URL?,
            createWorktree: @escaping (String, String, String?) async -> Result<Worktree, WorktreeCreationError>,
            rememberParent: @escaping (String, String) -> Void,
            autoRunDefault: @escaping () -> Bool,
            notifyChanged: @escaping () -> Void
        ) {
            self.persistence = persistence
            self.instanceId = instanceId
            self.now = now
            self.nowMillis = nowMillis
            self.makeID = makeID
            self.worktree = worktree
            self.existingWorktree = existingWorktree
            self.configuredAgents = configuredAgents
            self.availableAgents = availableAgents
            self.sessionLocation = sessionLocation
            self.manager = manager
            self.newWorktreeDestination = newWorktreeDestination
            self.createWorktree = createWorktree
            self.rememberParent = rememberParent
            self.autoRunDefault = autoRunDefault
            self.notifyChanged = notifyChanged
        }
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
            var summaries: [ACPOrchestrationSessionSummary] = []
            for visible in visible {
                if visible.sessionId == origin.sessionId {
                    summaries.append(await sessionSummary(
                        sessionId: origin.sessionId,
                        relationship: nil,
                        agentId: environment.sessionLocation(origin.sessionId)?.manager.liveSession(for: origin.sessionId)?.agentId ?? parent?.agentId ?? "unknown",
                        worktreeId: origin.worktreeId,
                        phase: .ready,
                        failure: nil,
                        createdAt: 0
                    ))
                    continue
                }
                if visible.relationship == .parent {
                    let location = environment.sessionLocation(visible.sessionId)
                    summaries.append(await sessionSummary(
                        sessionId: visible.sessionId,
                        relationship: "parent",
                        agentId: location?.manager.liveSession(for: visible.sessionId)?.agentId ?? "unknown",
                        worktreeId: location?.origin.worktreeId ?? parent?.parentWorktreeId ?? "",
                        phase: .ready,
                        failure: nil,
                        createdAt: 0
                    ))
                    continue
                }
                guard let record = children.first(where: { $0.childSessionId == visible.sessionId }) else { continue }
                summaries.append(await sessionSummary(
                    sessionId: record.childSessionId,
                    relationship: "child",
                    agentId: record.agentId,
                    worktreeId: record.childWorktreeId ?? record.worktreeRequest.worktreeId ?? "",
                    phase: record.phase,
                    failure: record.failureMessage,
                    createdAt: record.createdAt
                ))
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
        do {
            prompt = try ACPSessionOrchestrationPolicy.validatedPrompt(request.prompt)
        } catch ACPSessionOrchestrationPolicy.Error.blankPrompt {
            return .error("prompt must not be blank")
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
            let agentID: String
            do {
                agentID = try await resolveAgent(
                    requestedId: request.agentId,
                    parentAgentId: parentSession.agentId,
                    origin: origin,
                    worktree: worktree
                )
            } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
                return .error("Agent is not enabled or ACP-capable: \(id)")
            } catch {
                return .error("Could not validate delegated session request.")
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
            let agentID: String
            do {
                agentID = try await resolveAgent(
                    requestedId: request.agentId,
                    parentAgentId: parentSession.agentId,
                    origin: origin,
                    worktree: worktree
                )
            } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
                return .error("Agent is not enabled or ACP-capable: \(id)")
            } catch {
                return .error("Could not validate delegated session request.")
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
            switch GitNameValidator.validateBranchName(branch) {
            case .valid:
                break
            case .invalid(let message):
                return .error("invalid branch name: \(message)")
            }
            guard let destination = environment.newWorktreeDestination(origin.projectId, branch) else {
                return .error("The project is no longer available.")
            }
            let agentID: String
            do {
                agentID = try ACPSessionOrchestrationPolicy.resolveAgent(
                    requestedId: request.agentId,
                    parentAgentId: parentSession.agentId,
                    available: environment.configuredAgents()
                )
            } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
                return .error("Agent is not enabled or ACP-capable: \(id)")
            } catch {
                return .error("Could not validate delegated session request.")
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
            parentSession.nextPromptWorkCount += 1
            environment.notifyChanged()
            Task { @MainActor in
                defer { parentSession.nextPromptWorkCount -= 1 }
                let result = await self.environment.createWorktree(origin.projectId, branch, base)
                switch result {
                case .success(let worktree):
                    await self.startPersistedChild(childID: childID, prompt: prompt, worktree: worktree)
                case .failure(let error):
                    await self.markChildFailed(childSessionId: childID, message: error.message)
                }
            }
            return json(ACPOrchestrationNewResponse(sessionId: childID, state: "creating_worktree", worktreeId: nil))
        }
    }

    private func resolveAgent(
        requestedId: String?,
        parentAgentId: String,
        origin: ACPOrchestrationSessionOrigin,
        worktree: Worktree
    ) async throws -> String {
        try ACPSessionOrchestrationPolicy.resolveAgent(
            requestedId: requestedId,
            parentAgentId: parentAgentId,
            available: await environment.availableAgents(origin, worktree)
        )
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
            let targetIsStillStarting = targetParent?.phase == .creatingWorktree
                || targetParent?.phase == .starting
            if !targetIsStillStarting,
               await resolveDeliveryTarget(
                   sessionID: request.targetSessionId,
                   callerParent: callerParent,
                   targetParent: targetParent
               ) == nil {
                return .error("The target ACP session is not available.")
            }
        } catch {
            return .error("Could not verify session delegation.")
        }

        let targetSession = environment.sessionLocation(request.targetSessionId)?.manager.liveSession(for: request.targetSessionId)
        targetSession?.nextPromptWorkCount += 1
        var deliveryScheduled = false
        defer { if !deliveryScheduled { targetSession?.nextPromptWorkCount -= 1 } }
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
        targetSession?.hasPendingDelegatedMessages = true
        if callerParent?.parentSessionId == request.targetSessionId {
            // `nowMillis`, not `message.createdAt` (seconds): this is compared
            // against `ACPTurnCompletion.startedAt`, also milliseconds, in
            // `outcomeDisposition` — whole-second precision let a report near
            // the end of one turn be mistaken for covering the next.
            try? await environment.persistence.markParentReport(
                childSessionId: origin.sessionId,
                at: environment.nowMillis()
            )
        }
        environment.notifyChanged()
        deliveryScheduled = true
        Task { @MainActor in
            defer { targetSession?.nextPromptWorkCount -= 1 }
            await self.deliverPendingMessages(
                to: request.targetSessionId,
                callerParent: callerParent,
                targetParent: targetParent
            )
        }
        return json(ACPOrchestrationSendResponse(messageId: message.id, state: "queued"))
    }

    /// Entry point for a delegated child's finished turn. Non-children and
    /// terminal children are ignored; everything else becomes an inbox row
    /// for the parent, wake or notice per `outcomeDisposition`.
    func childTurnCompleted(_ completion: ACPTurnCompletion) async {
        guard let record = try? await environment.persistence.delegation(childSessionId: completion.sessionId),
              record.phase != .failed, record.phase != .closed
        else { return }
        let disposition = ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: completion.result,
            lastParentReportAt: record.lastParentReportAt,
            turnStartedAt: completion.startedAt
        )
        let context = outcomeContext(for: record)
        let prompt: String
        switch (disposition, completion.result) {
        case (.notice, _):
            prompt = ACPDelegatedOutcomeText.notice(context)
        case (.wake, .failed(let message)):
            prompt = ACPDelegatedOutcomeText.failure(context, message: message)
        case (.wake, _):
            prompt = ACPDelegatedOutcomeText.unreported(context, lastAgentText: completion.lastAgentText)
        }
        await enqueueOutcome(.init(
            id: "outcome-\(record.childSessionId)-\(completion.startedAt)",
            sourceSessionId: record.childSessionId,
            targetSessionId: record.parentSessionId,
            prompt: prompt,
            createdAt: environment.now(),
            kind: disposition == .wake ? .prompt : .notice
        ), child: record)
    }

    /// Mark a delegated child failed and wake its parent with the reason.
    /// Idempotent: the outcome id is fixed per child, so repeated calls
    /// update the phase but enqueue nothing new.
    func markChildFailed(childSessionId: String, message: String) async {
        try? await environment.persistence.updatePhase(
            childSessionId: childSessionId,
            phase: .failed,
            failureMessage: message,
            updatedAt: environment.now()
        )
        environment.notifyChanged()
        guard let record = try? await environment.persistence.delegation(childSessionId: childSessionId) else { return }
        await enqueueOutcome(.init(
            id: "outcome-\(childSessionId)-failed",
            sourceSessionId: childSessionId,
            targetSessionId: record.parentSessionId,
            prompt: ACPDelegatedOutcomeText.failure(outcomeContext(for: record), message: message),
            createdAt: environment.now(),
            kind: .prompt
        ), child: record)
    }

    private func outcomeContext(for record: ACPDelegationRecord) -> ACPDelegatedOutcomeText.Context {
        .init(
            childSessionId: record.childSessionId,
            agentId: record.agentId,
            worktreeName: record.childWorktreeId.flatMap { environment.worktree($0)?.name }
        )
    }

    private func enqueueOutcome(_ message: ACPDelegatedMessage, child: ACPDelegationRecord) async {
        do {
            try await environment.persistence.enqueue(message)
        } catch {
            return
        }
        environment.notifyChanged()
        await deliverPendingMessages(
            to: message.targetSessionId,
            callerParent: child,
            targetParent: nil
        )
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
        let parentSession = environment.sessionLocation(origin.sessionId)?.manager.liveSession(for: origin.sessionId)
        parentSession?.nextPromptWorkCount += 1
        environment.notifyChanged()
        Task { @MainActor in
            defer { parentSession?.nextPromptWorkCount -= 1 }
            await self.startPersistedChild(childID: childID, prompt: prompt, worktree: worktree)
        }
        return json(ACPOrchestrationNewResponse(sessionId: childID, state: "starting", worktreeId: worktree.id))
    }

    private func startPersistedChild(childID: String, prompt: String, worktree: Worktree) async {
        guard let manager = environment.manager(worktree) else {
            await markChildFailed(childSessionId: childID, message: "Could not create ACP session manager.")
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
        let parentLocation = environment.sessionLocation(record.parentSessionId)
        let parentSession = parentLocation?.manager.liveSession(for: record.parentSessionId)
        let validationOrigin = parentLocation?.origin ?? ACPOrchestrationSessionOrigin(
            sessionId: childID,
            projectId: record.projectId,
            worktreeId: worktree.id
        )
        do {
            _ = try await resolveAgent(
                requestedId: record.agentId,
                parentAgentId: parentSession?.agentId ?? record.agentId,
                origin: validationOrigin,
                worktree: worktree
            )
        } catch ACPSessionOrchestrationPolicy.Error.agentUnavailable(let id) {
            await markChildFailed(childSessionId: childID, message: "Agent is not enabled or ACP-capable: \(id)")
            return
        } catch {
            await markChildFailed(childSessionId: childID, message: "Could not validate delegated session request.")
            return
        }
        try? await environment.persistence.updateChildWorktree(
            childSessionId: childID,
            worktreeId: worktree.id,
            phase: .starting,
            updatedAt: environment.now()
        )
        if manager.liveSession(for: childID) == nil {
            _ = manager.createSession(
                id: childID,
                agentId: record.agentId,
                autoRunDefault: environment.autoRunDefault()
            )
        }
        let accepted = await manager.enqueueDelegatedPrompt(
            text: prompt,
            source: ACPDelegatedPromptSource(sessionId: record.parentSessionId, messageId: "initial-\(childID)"),
            into: childID
        )
        guard accepted else {
            await markChildFailed(childSessionId: childID, message: "Could not queue initial prompt.")
            return
        }
        await manager.attach(to: childID, freshlyCreated: true)
        guard let session = manager.liveSession(for: childID),
              session.agentState == .ready
        else {
            await markChildFailed(
                childSessionId: childID,
                message: delegatedChildStartFailureMessage(manager.liveSession(for: childID))
            )
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
    }

    private func delegatedChildStartFailureMessage(_ session: ACPSession?) -> String {
        guard let session else { return "Could not start delegated ACP session." }
        switch session.setupState {
        case .needsSetup(let reason), .setupError(let reason):
            return reason
        case .needsAuth(_, let reason):
            return reason ?? "ACP session needs authentication."
        case .checking, .ready:
            break
        }
        if case .failed(let reason) = session.agentState {
            return reason
        }
        return "Could not start delegated ACP session."
    }

    private func deliverPendingMessages(
        to sessionID: String,
        callerParent: ACPDelegationRecord?,
        targetParent: ACPDelegationRecord?
    ) async {
        let session = environment.sessionLocation(sessionID)?.manager.liveSession(for: sessionID)
        session?.nextPromptWorkCount += 1
        defer { session?.nextPromptWorkCount -= 1 }
        guard let target = await resolveDeliveryTarget(
            sessionID: sessionID,
            callerParent: callerParent,
            targetParent: targetParent
        ), let messages = try? await environment.persistence.pendingMessages(targetSessionId: sessionID)
        else { return }
        let targetSession = target.manager.liveSession(for: sessionID)
        targetSession?.hasPendingDelegatedMessages = !messages.isEmpty
        for message in messages {
            await deliver(message.id, to: target)
        }
        if let remaining = try? await environment.persistence.pendingMessages(targetSessionId: sessionID) {
            targetSession?.hasPendingDelegatedMessages = !remaining.isEmpty
        }
    }

    private func resolveDeliveryTarget(
        sessionID: String,
        callerParent: ACPDelegationRecord?,
        targetParent: ACPDelegationRecord?
    ) async -> SessionLocation? {
        if let target = environment.sessionLocation(sessionID) {
            guard let row = await target.manager.persistedSessionRow(id: sessionID), !row.archived else {
                return nil
            }
            return target
        }
        let worktreeID = targetParent?.childWorktreeId ?? callerParent?.parentWorktreeId
        guard let worktreeID,
              let worktree = environment.worktree(worktreeID),
              let manager = environment.manager(worktree),
              let row = await manager.persistedSessionRow(id: sessionID),
              !row.archived
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
        let accepted: Bool
        switch claimed.message.kind {
        case .prompt:
            accepted = await target.manager.enqueueDelegatedPrompt(
                text: claimed.message.prompt,
                source: ACPDelegatedPromptSource(
                    sessionId: claimed.message.sourceSessionId,
                    messageId: claimed.message.id
                ),
                into: claimed.message.targetSessionId
            )
        case .notice:
            accepted = await target.manager.appendDelegatedNotice(
                text: claimed.message.prompt,
                into: claimed.message.targetSessionId
            )
        }
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
    ) async -> ACPOrchestrationSessionSummary {
        let location = environment.sessionLocation(sessionId)
        let runtime = location.flatMap { location -> ACPOrchestrationRuntimeState? in
            guard let session = location.manager.liveSession(for: sessionId) else { return nil }
            switch session.transcript.streamingState {
            case .idle: return .idle
            case .sending, .streaming: return .running
            case .awaitingPermission, .awaitingInput: return .awaitingInput
            }
        }
        let archived: Bool
        if location != nil {
            archived = false
        } else if let worktree = environment.worktree(worktreeId),
                  let manager = environment.manager(worktree),
                  let row = await manager.persistedSessionRow(id: sessionId) {
            archived = row.archived
        } else {
            archived = true
        }
        let state = ACPSessionOrchestrationPolicy.publicState(phase: phase, runtime: runtime, archived: archived)
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
