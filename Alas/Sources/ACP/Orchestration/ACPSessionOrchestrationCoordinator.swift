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
        /// Every request the given session is currently blocked on. Supplied
        /// by `ACPSessionManager`, which is the only place that can see a
        /// parked permission's real id.
        let blockedRequestKeys: (String) -> Set<String>
        /// Seconds before a still-blocked child escalates from notice to wake.
        /// 0 disables escalation.
        let escalationDelaySeconds: () -> Int
        /// Arranges for `work` to run after `delay` seconds. Defaults to a
        /// no-op, so `childBlocked` schedules nothing in any fixture that
        /// doesn't override this — every test drives the re-check by calling
        /// `escalateBlockerIfStillBlocked` directly instead of waiting out a
        /// real delay. Only `AppState`'s construction (Task 7) sleeps for real.
        let scheduleEscalationCheck: (Int, @escaping @Sendable () async -> Void) -> Void
        let makeID: () -> String
        let worktree: (String) -> Worktree?
        let existingWorktree: (String, String) -> Worktree?
        let configuredAgents: () -> [ACPOrchestrationAgent]
        let availableAgents: (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPOrchestrationAgent]
        /// Read-only discovery rows for the caller's worktree, computed on
        /// every request from current Settings and install state.
        let delegationAgents: (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPDelegationAgentSummary]
        /// The models an agent advertised during this launch on the host the
        /// worktree runs on, nil when none reported there; the spawn-time
        /// model check reads it.
        let launchModels: (String, Worktree) -> [ACPAgentModelCatalog.Model]?
        let sessionLocation: (String) -> SessionLocation?
        let manager: (Worktree) -> ACPSessionManager?
        let newWorktreeDestination: (String, String) -> URL?
        /// Creates the worktree for `(projectId, branch, base)`. The last
        /// argument records the prepared destination on the delegation and
        /// must be awaited before the checkout is created.
        let createWorktree: (String, String, String?, @escaping @MainActor (URL) async throws -> Void) async -> Result<Worktree, WorktreeCreationError>
        let rememberParent: (String, String) -> Void
        let autoRunDefault: () -> Bool
        let notifyChanged: () -> Void
        /// Suspends `session_wait` between polls. Tests replace it to change
        /// state between polls instead of sleeping.
        let pause: (Duration) async -> Void

        init(
            persistence: ACPOrchestrationPersistence,
            instanceId: String,
            now: @escaping () -> Int64,
            nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
            blockedRequestKeys: @escaping (String) -> Set<String> = { _ in [] },
            escalationDelaySeconds: @escaping () -> Int = { 30 },
            scheduleEscalationCheck: @escaping (Int, @escaping @Sendable () async -> Void) -> Void = { _, _ in },
            makeID: @escaping () -> String,
            worktree: @escaping (String) -> Worktree?,
            existingWorktree: @escaping (String, String) -> Worktree?,
            configuredAgents: @escaping () -> [ACPOrchestrationAgent],
            availableAgents: @escaping (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPOrchestrationAgent],
            delegationAgents: @escaping (ACPOrchestrationSessionOrigin, Worktree) async -> [ACPDelegationAgentSummary] = { _, _ in [] },
            launchModels: @escaping (String, Worktree) -> [ACPAgentModelCatalog.Model]? = { _, _ in nil },
            sessionLocation: @escaping (String) -> SessionLocation?,
            manager: @escaping (Worktree) -> ACPSessionManager?,
            newWorktreeDestination: @escaping (String, String) -> URL?,
            createWorktree: @escaping (String, String, String?, @escaping @MainActor (URL) async throws -> Void) async -> Result<Worktree, WorktreeCreationError>,
            rememberParent: @escaping (String, String) -> Void,
            autoRunDefault: @escaping () -> Bool,
            notifyChanged: @escaping () -> Void,
            pause: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        ) {
            self.persistence = persistence
            self.instanceId = instanceId
            self.now = now
            self.nowMillis = nowMillis
            self.blockedRequestKeys = blockedRequestKeys
            self.escalationDelaySeconds = escalationDelaySeconds
            self.scheduleEscalationCheck = scheduleEscalationCheck
            self.makeID = makeID
            self.worktree = worktree
            self.existingWorktree = existingWorktree
            self.configuredAgents = configuredAgents
            self.availableAgents = availableAgents
            self.delegationAgents = delegationAgents
            self.launchModels = launchModels
            self.sessionLocation = sessionLocation
            self.manager = manager
            self.newWorktreeDestination = newWorktreeDestination
            self.createWorktree = createWorktree
            self.rememberParent = rememberParent
            self.autoRunDefault = autoRunDefault
            self.notifyChanged = notifyChanged
            self.pause = pause
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

    /// Read-only: never starts a session, a model request, or a focus change.
    /// `worktreeSelector` mirrors `session_new`'s existing-worktree target:
    /// install state can differ per worktree, so a caller planning to spawn
    /// elsewhere in the project asks about that worktree.
    func discoverAgents(origin: ACPOrchestrationSessionOrigin, worktree worktreeSelector: String?) async -> AlasCLIResponse {
        let worktree: Worktree
        if let worktreeSelector {
            guard let resolved = environment.existingWorktree(origin.projectId, worktreeSelector) else {
                return .error("The requested worktree is not available in this project.")
            }
            worktree = resolved
        } else {
            guard let current = environment.worktree(origin.worktreeId) else {
                return .error("The current worktree is no longer available.")
            }
            worktree = current
        }
        let parent: ACPDelegationRecord?
        do {
            parent = try await environment.persistence.parent(childSessionId: origin.sessionId)
        } catch {
            return .error("Could not verify session delegation.")
        }
        let canDelegate: Bool
        switch ACPSessionOrchestrationPolicy.authorizeCreate(parent: parent) {
        case .success: canDelegate = true
        case .failure: canDelegate = false
        }
        return json(ACPDelegationAgentListResponse(
            version: ACPDelegationAgentListResponse.currentVersion,
            callerAgentId: environment.sessionLocation(origin.sessionId)?.manager
                .liveSession(for: origin.sessionId)?.agentId,
            canDelegate: canDelegate,
            worktreeId: worktree.id,
            agents: await environment.delegationAgents(origin, worktree)
        ))
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
            if let rejection = modelSelectionRejection(request.modelSelection, agentID: agentID, worktree: worktree) {
                return rejection
            }
            return await createChild(
                childID: childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                modelSelection: request.modelSelection,
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
            if let rejection = modelSelectionRejection(request.modelSelection, agentID: agentID, worktree: worktree) {
                return rejection
            }
            return await createChild(
                childID: childID,
                origin: origin,
                prompt: prompt,
                agentID: agentID,
                modelSelection: request.modelSelection,
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
            // The new worktree belongs to the same project, so it runs on the
            // caller's host.
            if let rejection = modelSelectionRejection(
                request.modelSelection, agentID: agentID, worktree: environment.worktree(origin.worktreeId)
            ) {
                return rejection
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
                updatedAt: now,
                modelSelection: request.modelSelection
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
                let result = await self.environment.createWorktree(origin.projectId, branch, base) { prepared in
                    // Recovery matches an interrupted create by this path, so it
                    // must be the prepared one (remote home, virtual path).
                    try await self.environment.persistence.updateWorktreeRequest(
                        childSessionId: childID,
                        request: .new(branch: branch, base: base, destinationPath: prepared.path, optimisticId: optimisticID),
                        updatedAt: self.environment.now()
                    )
                }
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

    private func modelSelectionRejection(
        _ selection: ACPDelegatedModelSelection?,
        agentID: String,
        worktree: Worktree?
    ) -> AlasCLIResponse? {
        guard let selection else { return nil }
        guard let error = ACPSessionOrchestrationPolicy.preflightModelSelection(
            selection,
            agentId: agentID,
            launchModels: worktree.flatMap { environment.launchModels(agentID, $0) }
        ) else { return nil }
        return .error(error.localizedDescription)
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
        // A child's report is framed at enqueue, not delivery, so every
        // delivery path (and an older build sharing the store) hands the
        // parent the same text.
        let deliveredPrompt = callerParent.flatMap { record in
            record.parentSessionId == request.targetSessionId
                ? ACPDelegatedOutcomeText.childReport(outcomeContext(for: record), message: prompt)
                : nil
        } ?? prompt
        let message = ACPDelegatedMessage(
            id: environment.makeID(),
            sourceSessionId: origin.sessionId,
            targetSessionId: request.targetSessionId,
            prompt: deliveredPrompt,
            createdAt: environment.now()
        )
        // The phase was checked above, but another instance sharing the store
        // can fail the target in between; the store rechecks it atomically
        // with the insert, so a failed child never gets a stranded row.
        do {
            guard try await environment.persistence.enqueueUnlessTargetEnded(message) else {
                return .error("The target delegated session is not available.")
            }
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

    func perform(origin: ACPOrchestrationSessionOrigin, _ action: ACPDelegatedSessionAction) async -> AlasCLIResponse {
        switch action {
        case .read(let request): await read(origin: origin, request: request)
        case .search(let request): await search(origin: origin, request: request)
        case .wait(let request): await wait(origin: origin, request: request)
        case .interrupt(let targetSessionId): await interrupt(origin: origin, targetSessionId: targetSessionId)
        }
    }

    /// `session_read`: one page of a direct parent's or child's transcript.
    func read(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionReadRequest
    ) async -> AlasCLIResponse {
        let session: ACPSession
        switch await readableSession(origin: origin, targetSessionId: request.targetSessionId) {
        case .success(let readable): session = readable
        case .failure(let error): return .error(error.message)
        }
        let page = ACPSessionTranscriptReader.page(
            ACPSessionTranscriptReader.entries(session.transcript.messages),
            offset: request.offset,
            limit: request.limit,
            maxChars: request.maxChars,
            lastEntryIsLive: Self.runtimeState(session) != .idle
        )
        return json(ACPOrchestrationReadResponse(
            sessionId: request.targetSessionId,
            entries: page.entries,
            start: page.start,
            end: page.end,
            total: page.total
        ))
    }

    /// `session_search`: text matches across the caller's direct parent and
    /// children, the same sessions `session_list` shows. Sessions without a
    /// readable transcript are skipped.
    func search(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionSearchRequest
    ) async -> AlasCLIResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .error("query must not be blank") }
        let targets: [ACPOrchestrationVisibleSession]
        do {
            targets = ACPSessionOrchestrationPolicy.visibleSessions(
                callerSessionId: origin.sessionId,
                parent: try await environment.persistence.parent(childSessionId: origin.sessionId),
                children: try await environment.persistence.children(parentSessionId: origin.sessionId)
            ).filter { $0.relationship != nil }
        } catch {
            return .error("Could not load delegated sessions.")
        }
        var matches: [ACPOrchestrationSearchResponse.Match] = []
        var truncated = false
        search: for target in targets {
            guard case .success(let session) = await readableSession(
                origin: origin, targetSessionId: target.sessionId
            ) else { continue }
            let entries = ACPSessionTranscriptReader.entries(session.transcript.messages)
            for match in ACPSessionTranscriptReader.search(entries, query: query) {
                guard matches.count < request.limit else {
                    truncated = true
                    break search
                }
                matches.append(.init(
                    sessionId: target.sessionId, index: match.index, role: match.role, snippet: match.snippet
                ))
            }
        }
        return json(ACPOrchestrationSearchResponse(matches: matches, truncated: truncated))
    }

    static let waitPollInterval: Duration = .milliseconds(250)

    /// `session_wait`: returns once every listed direct child has settled
    /// (see `ACPSessionOrchestrationPolicy.waitSettled`) or the timeout
    /// passes, with each child's state and latest agent text either way.
    func wait(
        origin: ACPOrchestrationSessionOrigin,
        request: ACPDelegatedSessionWaitRequest
    ) async -> AlasCLIResponse {
        var sessionIds: [String] = []
        for id in request.targetSessionIds where !sessionIds.contains(id) {
            sessionIds.append(id)
        }
        do {
            for id in sessionIds {
                guard case .success = ACPSessionOrchestrationPolicy.authorizeChildControl(
                    callerSessionId: origin.sessionId,
                    callerProjectId: origin.projectId,
                    target: try await environment.persistence.delegation(childSessionId: id)
                ) else {
                    return .error("Only direct child sessions can be waited on: \(id)")
                }
            }
        } catch {
            return .error("Could not verify session delegation.")
        }
        let deadline = environment.nowMillis() + Int64(request.timeoutMillis)
        while true {
            var sessions: [ACPOrchestrationWaitResponse.Session] = []
            for id in sessionIds {
                sessions.append(await waitSnapshot(sessionId: id))
            }
            let settled = sessions.allSatisfy(\.settled)
            if settled || environment.nowMillis() >= deadline || Task.isCancelled {
                return json(ACPOrchestrationWaitResponse(sessions: sessions, timedOut: !settled))
            }
            await environment.pause(Self.waitPollInterval)
        }
    }

    /// `session_interrupt`: cancels a direct child's running turn, as the
    /// Stop button would. A pending permission request is cancelled with the
    /// turn, never approved.
    func interrupt(
        origin: ACPOrchestrationSessionOrigin,
        targetSessionId: String
    ) async -> AlasCLIResponse {
        do {
            guard case .success = ACPSessionOrchestrationPolicy.authorizeChildControl(
                callerSessionId: origin.sessionId,
                callerProjectId: origin.projectId,
                target: try await environment.persistence.delegation(childSessionId: targetSessionId)
            ) else {
                return .error("Only a direct child session can be interrupted.")
            }
        } catch {
            return .error("Could not verify session delegation.")
        }
        guard let location = environment.sessionLocation(targetSessionId),
              let session = location.manager.liveSession(for: targetSessionId),
              Self.runtimeState(session) != .idle
        else {
            return json(ACPOrchestrationInterruptResponse(sessionId: targetSessionId, cancelRequested: false))
        }
        // False when another Alas instance holds the child's writer lease and
        // this one only mirrors it.
        let cancelRequested = await location.manager.interrupt(for: targetSessionId)
        return json(ACPOrchestrationInterruptResponse(sessionId: targetSessionId, cancelRequested: cancelRequested))
    }

    private struct ObservationError: Error {
        let message: String
    }

    /// A direct parent or child whose transcript may be read, the same edge
    /// `session_send` may use. A session that is not live is hydrated from
    /// its stored transcript; an archived one is not readable.
    private func readableSession(
        origin: ACPOrchestrationSessionOrigin,
        targetSessionId: String
    ) async -> Result<ACPSession, ObservationError> {
        let callerParent: ACPDelegationRecord?
        let targetParent: ACPDelegationRecord?
        do {
            callerParent = try await environment.persistence.parent(childSessionId: origin.sessionId)
            targetParent = try await environment.persistence.parent(childSessionId: targetSessionId)
        } catch {
            return .failure(.init(message: "Could not verify session delegation."))
        }
        guard let targetProjectId = environment.sessionLocation(targetSessionId)?.origin.projectId
            ?? targetParent?.projectId ?? callerParent?.projectId,
            case .success = ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: origin.sessionId,
                callerProjectId: origin.projectId,
                targetSessionId: targetSessionId,
                targetProjectId: targetProjectId,
                callerParent: callerParent,
                targetParent: targetParent
            )
        else {
            return .failure(.init(message: "Only a direct parent or child session's transcript can be read."))
        }
        guard let location = await resolveDeliveryTarget(
            sessionID: targetSessionId,
            callerParent: callerParent,
            targetParent: targetParent
        ) else {
            return .failure(.init(message: "The target ACP session has no transcript available."))
        }
        // A restored tab can still be loading its stored transcript, and
        // hydration applies only the tail before backfilling older messages,
        // which would shift every entry index between pages.
        await location.manager.hydrateIfNeeded(id: targetSessionId)
        await location.manager.awaitBackfill(id: targetSessionId)
        guard let session = location.manager.liveSession(for: targetSessionId) else {
            return .failure(.init(message: "The target ACP session has no transcript available."))
        }
        return .success(session)
    }

    private func waitSnapshot(sessionId: String) async -> ACPOrchestrationWaitResponse.Session {
        let record = try? await environment.persistence.delegation(childSessionId: sessionId)
        let session = environment.sessionLocation(sessionId)?.manager.liveSession(for: sessionId)
        let runtime = session.map(Self.runtimeState)
        let phase = record?.phase ?? .closed
        var queued = session.map { ACPSessionOrchestrationPolicy.queueOwesTurn($0.queue) } ?? false
        var archived = false
        if session == nil, phase == .ready, let record {
            // Not live here: restored later, or driven by another instance.
            // Judge it by its stored queue, whose head stays until the turn
            // ends, and keep it unsettled when its store is out of reach.
            switch await storedTurnState(record) {
            case .archived: archived = true
            case .queue(let stored): queued = ACPSessionOrchestrationPolicy.queueOwesTurn(stored)
            case nil: queued = true
            }
        }
        let undelivered = !((try? await environment.persistence.pendingMessages(targetSessionId: sessionId)) ?? []).isEmpty
        let settled = archived || ACPSessionOrchestrationPolicy.waitSettled(
            phase: phase, runtime: runtime, hasPendingPrompts: queued || undelivered
        )
        // A settled child that is not live here still has its result in its
        // stored transcript; load it only now, not on every poll.
        var transcriptSession = session
        if transcriptSession == nil, settled, !archived, phase == .ready, let record,
           let location = await resolveDeliveryTarget(sessionID: sessionId, callerParent: record, targetParent: record) {
            await location.manager.hydrateIfNeeded(id: sessionId)
            transcriptSession = location.manager.liveSession(for: sessionId)
        }
        return .init(
            sessionId: sessionId,
            state: ACPSessionOrchestrationPolicy.publicState(phase: phase, runtime: runtime, archived: archived).rawValue,
            settled: settled,
            lastAgentText: transcriptSession.flatMap { ACPSessionTranscriptReader.lastAgentText($0.transcript.messages) },
            failure: record?.failureMessage
        )
    }

    private enum StoredTurnState {
        case archived
        case queue([QueuedPrompt])
    }

    /// A child's persisted state when it has no live session here, or nil
    /// when its worktree or stored session cannot be reached.
    private func storedTurnState(_ record: ACPDelegationRecord) async -> StoredTurnState? {
        guard let worktreeId = record.childWorktreeId,
              let worktree = environment.worktree(worktreeId),
              let manager = environment.manager(worktree),
              let row = await manager.persistedSessionRow(id: record.childSessionId)
        else { return nil }
        if row.archived { return .archived }
        guard let queue = try? await manager.persistence.loadQueue(sessionId: record.childSessionId) else {
            return nil
        }
        return .queue(queue)
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
        case (.notice, .cancelled):
            prompt = ACPDelegatedOutcomeText.cancelled(context)
        case (.notice, .limited):
            prompt = ACPDelegatedOutcomeText.limited(context)
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
        // The fixed outcome id (`outcome-<childId>-failed`) only dedupes via
        // INSERT OR IGNORE while the row is still in the inbox — once the
        // parent's outcome is delivered, the row is deleted and a later call
        // for the same already-failed child would re-enqueue and wake the
        // parent a second time for one failure. `claimFailedPhase` makes the
        // transition itself the source of truth: its conditional
        // `WHERE phase != 'failed'` inside one transaction (mirroring the
        // inbox's own `claimMessage`) ensures exactly one caller — even
        // across two Alas instances racing on the same shared SQLite file —
        // sees `true` and is responsible for the outcome. A separate read
        // before the write would leave a window where both readers see the
        // pre-transition phase before either writes.
        //
        // The outcome is built here, before the claim, because its text needs
        // the delegation record — but it is WRITTEN inside the claim's own
        // transaction, so the phase change and the parent's notification
        // commit together. Splitting them left a crash window that stranded
        // the child permanently: phase `.failed`, no outcome, and every later
        // call correctly losing the claim.
        guard let record = try? await environment.persistence.delegation(childSessionId: childSessionId)
        else { return }
        let outcome = ACPDelegatedMessage(
            id: "outcome-\(childSessionId)-failed",
            sourceSessionId: childSessionId,
            targetSessionId: record.parentSessionId,
            prompt: ACPDelegatedOutcomeText.failure(outcomeContext(for: record), message: message),
            createdAt: environment.now(),
            kind: .prompt
        )
        // A child still waiting on its model selection must never run the
        // parent's prompt on the agent's default model: drop it from the
        // session's queue, durably, before `.failed` lifts the prompt hold
        // (a later hydration of a failed child is not held).
        let holdsDispatch = ACPSessionOrchestrationPolicy.holdsPromptDispatch(target: record)
        let heldManager = holdsDispatch ? environment.sessionLocation(childSessionId)?.manager : nil
        let initialPromptGone = await heldManager?.discardDelegatedPrompt(
            messageId: initialPromptSource(for: record).messageId,
            in: childSessionId
        ) ?? true
        // A child whose model selection never took effect loses its held
        // inbox rows in the same transaction, so no path (startup recovery
        // included) can later run them on the agent's default model.
        let wonTransition = (try? await environment.persistence.claimFailedPhase(
            childSessionId: childSessionId,
            failureMessage: message,
            updatedAt: environment.now(),
            outcome: outcome,
            discardingHeldMessages: record.modelSelection != nil
        )) ?? false
        // Lift the hold only once `.failed` is durable: a claim that threw
        // (busy timeout, I/O) left the child `starting`, and a released hold
        // cannot be re-armed on this session object. If the prompt could not
        // be written out of the queue, the hold stays for this process.
        if let heldManager, initialPromptGone,
           (try? await environment.persistence.delegation(childSessionId: childSessionId))??.phase == .failed {
            heldManager.releaseDelegatedSelectionHold(childSessionId)
        }
        environment.notifyChanged()
        guard wonTransition else { return }
        await deliverPendingMessages(
            to: outcome.targetSessionId,
            callerParent: record,
            targetParent: nil
        )
    }

    /// A delegated child stopped on something only a human can resolve. The
    /// parent is noticed at once, then woken only if the same request is still
    /// unresolved after the configured delay.
    func childBlocked(_ blocker: ACPChildBlocker) async {
        guard let record = try? await environment.persistence.delegation(childSessionId: blocker.sessionId),
              record.phase != .failed, record.phase != .closed
        else { return }
        var context = outcomeContext(for: record)
        context.blockerSummary = blocker.summary
        await enqueueOutcome(.init(
            id: "blocker-\(blocker.sessionId)-\(blocker.requestKey)-notice",
            sourceSessionId: blocker.sessionId,
            targetSessionId: record.parentSessionId,
            prompt: ACPDelegatedOutcomeText.blocker(
                context, kindLabel: blocker.kind.rawValue, waitedSeconds: 0, escalated: false
            ),
            createdAt: environment.now(),
            kind: .notice
        ), child: record)

        let delay = environment.escalationDelaySeconds()
        guard delay > 0 else { return }
        environment.scheduleEscalationCheck(delay) { [weak self] in
            await self?.escalateBlockerIfStillBlocked(blocker)
        }
    }

    /// The delayed re-check, reached in production through
    /// `scheduleEscalationCheck` and called directly by tests. Reads live
    /// state rather than tracking timers, so a block the human already
    /// cleared simply produces nothing and no cancellation is required.
    func escalateBlockerIfStillBlocked(_ blocker: ACPChildBlocker) async {
        guard environment.escalationDelaySeconds() > 0,
              let record = try? await environment.persistence.delegation(childSessionId: blocker.sessionId),
              record.phase != .failed, record.phase != .closed,
              case .wake = ACPSessionOrchestrationPolicy.escalation(
                  blocker: blocker,
                  liveBlockedRequestKeys: environment.blockedRequestKeys(blocker.sessionId)
              )
        else { return }
        var context = outcomeContext(for: record)
        context.blockerSummary = blocker.summary
        await enqueueOutcome(.init(
            id: "blocker-\(blocker.sessionId)-\(blocker.requestKey)",
            sourceSessionId: blocker.sessionId,
            targetSessionId: record.parentSessionId,
            prompt: ACPDelegatedOutcomeText.blocker(
                context,
                kindLabel: blocker.kind.rawValue,
                waitedSeconds: environment.escalationDelaySeconds(),
                escalated: true
            ),
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
        modelSelection: ACPDelegatedModelSelection?,
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
            updatedAt: now,
            modelSelection: modelSelection
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
        // Without a model selection the prompt is queued before attach, as it
        // always was, and goes out once the runner registers. With one, it is
        // queued only after the selection is acknowledged, and the session
        // holds every prompt (a human's in the open tab too) until then.
        if record.modelSelection != nil {
            manager.holdPromptsForDelegatedSelection(childID)
        } else {
            guard await manager.enqueueDelegatedPrompt(
                text: prompt,
                source: initialPromptSource(for: record),
                into: childID
            ) else {
                await markChildFailed(childSessionId: childID, message: "Could not queue initial prompt.")
                return
            }
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
        if let selection = record.modelSelection {
            guard await queueInitialPromptAfterModelSelection(
                selection, record: record, prompt: prompt, manager: manager
            ) else { return }
        }
        try? await environment.persistence.clearPendingInitialPrompt(childSessionId: childID, updatedAt: environment.now())
        let markedReady = (try? await environment.persistence.updatePhase(
            childSessionId: childID, phase: .ready, failureMessage: nil, updatedAt: environment.now()
        )) != nil
        // Unless `.ready` is durable, the child stays held: other instances
        // and the next launch still treat it as starting and reapply the
        // selection.
        if record.modelSelection != nil, markedReady {
            manager.releaseDelegatedSelectionHold(childID)
        }
        environment.notifyChanged()
        await deliverPendingMessages(
            to: childID,
            callerParent: record,
            targetParent: record
        )
    }

    func initialPromptSource(for record: ACPDelegationRecord) -> ACPDelegatedPromptSource {
        ACPDelegatedPromptSource(
            sessionId: record.parentSessionId,
            messageId: ACPSessionOrchestrationPolicy.initialPromptMessageId(childSessionId: record.childSessionId)
        )
    }

    /// Applies a child's requested model/reasoning on its attached session
    /// and only then queues the initial prompt, so no prompt can run on the
    /// agent's default. Any failure marks the child failed, which wakes the
    /// parent with the reason, and nothing is queued. Also used by startup
    /// recovery, so a restarted child reapplies the same selection. The
    /// session's prompt hold stays on: the caller lifts it once the child is
    /// marked ready, and the prompt is queued ahead of anything a human typed
    /// in the tab meanwhile.
    func queueInitialPromptAfterModelSelection(
        _ selection: ACPDelegatedModelSelection,
        record: ACPDelegationRecord,
        prompt: String,
        manager: ACPSessionManager
    ) async -> Bool {
        do {
            try await manager.applyDelegatedModelSelection(selection, to: record.childSessionId)
        } catch {
            // `markChildFailed` writes the queue without the prompt, which
            // recovery may have withheld in memory, before the failed phase
            // takes the child out of recovery.
            await markChildFailed(childSessionId: record.childSessionId, message: error.localizedDescription)
            return false
        }
        guard await manager.enqueueDelegatedPrompt(
            text: prompt,
            source: initialPromptSource(for: record),
            into: record.childSessionId,
            ahead: true
        ) else {
            await markChildFailed(childSessionId: record.childSessionId, message: "Could not queue initial prompt.")
            return false
        }
        return true
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
        // Read fresh: a caller's snapshot can predate the start transition.
        if ACPSessionOrchestrationPolicy.defersInboxDelivery(
            target: try? await environment.persistence.delegation(childSessionId: sessionID)
        ) {
            return
        }
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
                    message: claimed.message,
                    senderDelegation: try? await environment.persistence.delegation(
                        childSessionId: claimed.message.sourceSessionId
                    )
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
        let runtime = location?.manager.liveSession(for: sessionId).map(Self.runtimeState)
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

    private static func runtimeState(_ session: ACPSession) -> ACPOrchestrationRuntimeState {
        switch session.transcript.streamingState {
        case .idle: .idle
        case .sending, .streaming: .running
        case .awaitingPermission, .awaitingInput: .awaitingInput
        }
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
