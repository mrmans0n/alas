import Foundation

extension AppState {
    /// Watches bound pull and merge requests. It decides when and what; the
    /// effects installed here reach sessions, notifications and panes.
    var reviewShepherd: ReviewShepherd { core.reviewShepherd }

    // MARK: - Wiring

    func installReviewShepherdEffects() {
        reviewShepherd.effects = ReviewShepherd.Effects(
            worktreeContext: { [weak self] worktreeID in
                self?.shepherdWorktreeContext(worktreeID)
            },
            sessionState: { [weak self] sessionID, worktreeID in
                await self?.shepherdSessionState(sessionID: sessionID, worktreeID: worktreeID) ?? .missing
            },
            deliverPrompt: { [weak self] sessionID, worktreeID, text, isStillWanted in
                await self?.deliverShepherdPrompt(
                    sessionID: sessionID, worktreeID: worktreeID, text: text, isStillWanted: isStillWanted
                ) ?? .failed
            },
            rules: { [weak self] worktreeID in
                await self?.shepherdRules(worktreeID: worktreeID) ?? ShepherdRules.none
            },
            notify: { [weak self] event in
                self?.notifyShepherdEvent(event)
            },
            refreshPaneIfCached: { [weak self] worktreeID in
                guard let self else { return }
                Task { await self.rightPaneStore.refresh(worktreeId: worktreeID, forceReviewLoopRemote: true) }
            },
            archiveWorktreeIfAllowed: { [weak self] worktreeID, sessionID, isStillWanted in
                await self?.archiveShepherdWorktreeIfAllowed(
                    worktreeID, sessionID: sessionID, isStillWanted: isStillWanted
                ) ?? .declined
            }
        )
    }

    /// Called once the worktree topology is loaded, because records resolve
    /// their worktrees against it.
    func startReviewShepherd() {
        reviewShepherd.start()
    }

    // MARK: - Eligibility, rules and base

    /// Git worktrees, local or SSH, outside Workspace checkouts. On an SSH
    /// project git and `gh`/`glab` run on the remote host, which must have
    /// the CLI installed and signed in. Folders and checkout members are out
    /// of scope.
    func isShepherdEligible(_ worktree: Worktree) -> Bool {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return false }
        return !project.isFolder && !isWorkspaceCheckoutMember(worktree)
    }

    /// Whether a session tab offers Ship, as the toolbar pill and `/ship`:
    /// the shepherd's eligibility plus no Workspace checkout-owned sessions.
    func offersShip(in worktree: Worktree, isWorkspaceCheckoutOwner: Bool) -> Bool {
        !isWorkspaceCheckoutOwner && isShepherdEligible(worktree)
    }

    func shepherdRules(worktreeID: String) async -> ShepherdRules {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID) else { return ShepherdRules.none }
        return await ShepherdRulesResolver.load(
            worktreePath: resolved.worktree.path,
            projectSettings: resolved.project.shepherd
        )
    }

    /// The base the Changes pane reviews against: its per-worktree override
    /// when the pane is cached, else the global default.
    func shepherdBaseBranch(for worktree: Worktree) -> String {
        rightPaneStore.activeState(worktreeId: worktree.id)?.reviewLoop.currentBaseBranch
            ?? config.worktrees.baseBranch
    }

    // MARK: - Sessions

    /// Sessions that can own a request in this worktree: not archived, most
    /// recently active first (the sessions popover sorts by last opened).
    /// Reads the manager's recent rows; a menu calls `refreshRecent()` on the
    /// manager as it opens, as `ACPSessionsButton` does.
    func shepherdSessionCandidates(worktree: Worktree) -> [ACPSessionRow] {
        guard let manager = acpManager(for: worktree) else { return [] }
        return manager.sessionRows
            .filter { !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// `shepherdSessionCandidates` as menu items naming each session's agent,
    /// for the Changes drawer and the Changes tab's "Shepherd with" line.
    /// Empty when the worktree can't be shepherded.
    func shepherdCandidateItems(worktreeID: String) -> [ReviewShepherdDrawerModel.Candidate] {
        guard let worktree = worktree(withId: worktreeID), isShepherdEligible(worktree) else { return [] }
        return shepherdSessionCandidates(worktree: worktree).map {
            ReviewShepherdDrawerModel.Candidate(id: $0.id, title: $0.title, agentName: agent(id: $0.agentId)?.displayName)
        }
    }

    /// Reloads the worktree's recent sessions, which `shepherdCandidateItems` reads.
    func refreshShepherdCandidates(worktreeID: String) {
        guard let worktree = worktree(withId: worktreeID) else { return }
        acpManager(for: worktree)?.refreshRecent()
    }

    /// Binds a request the Changes tab just created to the session picked in
    /// its "Shepherd with" line. `snapshot` is the review state the tab read
    /// after creating, and must describe the request at `url`. The request
    /// stays created whatever happens here: a failure only posts a message.
    func shepherdCreatedRequest(url: URL, sessionID: String, worktreeID: String, snapshot: ReviewLoopSnapshot?) async {
        guard let worktree = worktree(withId: worktreeID) else { return }
        guard let request = snapshot?.reviewRequest, request.url == url else {
            let label = snapshot?.remote?.kind.reviewRequestLabel ?? "PR"
            inAppNotifications.post(
                "Couldn't start shepherding the new \(label). Use Shepherd with… in the review drawer.",
                severity: .error,
                worktreeID: worktreeID
            )
            return
        }
        await shepherdWithSession(sessionID, worktree: worktree, request: request)
    }

    /// Queues `text` on the session as a shepherd prompt, captioned "Alas PR
    /// shepherd". Hydrates a session with no open tab, like the orchestration
    /// coordinator's delivery, then brings its agent up the way the composer
    /// does, which claims the writer lease, so the prompt runs after any turn
    /// in progress. `.failed` when the session is missing or archived, when
    /// another instance owns it (this one is a read-only mirror), or when the
    /// queue could not be saved under the lease. `.superseded` when
    /// `isStillWanted` turns false while the session is brought up.
    func deliverShepherdPrompt(
        sessionID: String,
        worktreeID: String,
        text: String,
        isStillWanted: @MainActor () -> Bool
    ) async -> ReviewShepherd.Delivery {
        guard let worktree = worktree(withId: worktreeID),
              let manager = acpManager(for: worktree),
              let row = await manager.persistedSessionRow(id: sessionID),
              !row.archived,
              manager.placeholderSession(id: sessionID) != nil
        else { return .failed }
        await manager.hydrateIfNeeded(id: sessionID)
        guard manager.liveSession(for: sessionID)?.hydrationState == .ready else { return .failed }
        // Attaches an idle, disconnected or failed agent, claiming the writer
        // lease first; a no-op while it is spawning or ready. When another
        // instance holds the lease, the attach leaves a mirror without one and
        // the fenced enqueue below refuses.
        await manager.reattach(to: sessionID)
        // The enqueue waits for a transcript backfill before touching the
        // queue; drain it here so the check below is the last suspension.
        await manager.awaitBackfill(id: sessionID)
        // Stop, rebind or a newer decision while the session came up: the
        // queue is left alone.
        guard isStillWanted() else { return .superseded }
        let recordKey = reviewShepherd.record(forSession: sessionID)?.id.storageKey ?? worktreeID
        let source = ACPDelegatedPromptSource.shepherd(recordKey: recordKey, messageID: UUID())
        let queued = await manager.enqueueDelegatedPrompt(text: text, source: source, into: sessionID, requiringWriter: true)
        return queued ? .delivered : .failed
    }

    func shepherdSessionState(sessionID: String, worktreeID: String) async -> ShepherdSessionState {
        guard let worktree = worktree(withId: worktreeID),
              let manager = acpManager(for: worktree),
              let row = await manager.persistedSessionRow(id: sessionID)
        else { return .missing }
        if row.archived { return .archived }
        guard let placeholder = manager.liveSession(for: sessionID) else {
            return row.directTurnInFlight ? .busy : .idle
        }
        // A loading placeholder has an idle transcript and an empty queue
        // until its persisted state is restored.
        if placeholder.hydrationState == .loading {
            await manager.hydrateIfNeeded(id: sessionID)
        }
        if let session = manager.liveSession(for: sessionID), session.hydrationState == .ready {
            return Self.shepherdSessionIsBusy(session, now: Date()) ? .busy : .idle
        }
        // Hydration did not finish: judge by the stored turn marker and queue.
        if row.directTurnInFlight { return .busy }
        let queue = (try? await manager.persistence.loadQueue(sessionId: sessionID)) ?? []
        return queue.contains { Self.shepherdQueueItemIsDue($0, now: Date()) } ? .busy : .idle
    }

    /// The popover's Ship with agent button records an Alas action while
    /// asking the agent to commit what belongs to the work and call `pr_create`.
    func requestShepherdCreatePR(sessionID: String, worktree: Worktree) {
        guard let manager = acpManager(for: worktree) else { return }
        Task { @MainActor [weak self] in
            let remotes = (try? await GitService().remotes(worktreePath: worktree.path)) ?? []
            guard let kind = CodeHostRemoteDetector.detect(from: remotes)?.kind else {
                self?.inAppNotifications.post(
                    "No GitHub or GitLab remote for \(worktree.branch).",
                    severity: .error,
                    worktreeID: worktree.id
                )
                return
            }
            await manager.sendPrompt(
                for: sessionID,
                text: ShepherdPromptBuilder.createPrompt(kind: kind),
                attachments: [],
                delegatedSource: .shipCreate(kind: kind, messageID: UUID()),
                normalUserTurn: false
            ) { [weak self] sent in
                guard !sent else { return }
                self?.inAppNotifications.post(
                    "Could not send the Ship with agent prompt to this session.",
                    severity: .error,
                    worktreeID: worktree.id
                )
            }
        }
    }

    /// `/ship`: runs what the Ship popover would offer this session, fetching
    /// the branch's status first when nothing has it cached.
    func shipFromCommand(session: ACPSession, worktree: Worktree) async {
        var context = ShepherdSessionContext(sessionID: session.id, worktree: worktree, state: self)
        if context.request == nil, let bound = context.record ?? context.otherRecord {
            let fetched = await reviewShepherd.statusSnapshot(for: bound.id)
            context = ShepherdSessionContext(sessionID: session.id, worktree: worktree, state: self, fetched: fetched)
        } else if context.snapshot == nil {
            let fetched = await reviewShepherd.fetchSnapshot(
                worktreePath: worktree.path,
                baseBranch: shepherdBaseBranch(for: worktree)
            )
            context = ShepherdSessionContext(sessionID: session.id, worktree: worktree, state: self, fetched: fetched)
        }
        switch ShepherdShipAction.resolve(
            record: context.record,
            otherRecord: context.otherRecord,
            request: context.request,
            snapshot: context.snapshot,
            isBusy: session.transcript.streamingState != .idle
        ) {
        case .shepherding(let number):
            session.lastError = "This session already shepherds \(number). Its status is in the toolbar's \(number) button."
        case .adopt(let request):
            await shepherdWithSession(session.id, worktree: worktree, request: request)
        case .create:
            requestShepherdCreatePR(sessionID: session.id, worktree: worktree)
        case .unavailable(let reason):
            session.lastError = reason
        }
    }

    /// Binds `request` to an existing session and sends it the context
    /// prompt. A rebind keeps the record's toggles; a new binding starts from
    /// the Settings defaults.
    func shepherdWithSession(_ sessionID: String, worktree: Worktree, request: ReviewRequest) async {
        let toggles = shepherdToggles(worktree: worktree, request: request)
        await reviewShepherd.bind(
            sessionID: sessionID,
            worktreeID: worktree.id,
            request: request,
            baseBranch: request.baseRefName,
            autoFix: toggles.autoFix,
            autoMerge: toggles.autoMerge,
            sendContext: true
        )
    }

    /// "New session" in the Changes drawer: launches the project's default
    /// chat agent with the context prompt as its first message (which also
    /// titles the session), then binds the request to that session.
    func shepherdWithNewSession(worktree: Worktree, request: ReviewRequest) async {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return }
        guard let agentID = defaultAgentID(projectId: project.id, worktreeRoot: worktree.path),
              ACPLaunchCatalog.spec(for: agentID) != nil
        else {
            inAppNotifications.post(
                "No chat agent is set up for \(project.name).",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        let prompt = ShepherdPromptBuilder.bindPrompt(
            request: request,
            fix: ShepherdPolicy.problems(in: request, handled: []),
            rules: await shepherdRules(worktreeID: worktree.id)
        )
        let prepared = PreparedWorktreeACPPrompt(sessionID: UUID().uuidString, promptID: UUID(), text: prompt)
        do {
            try await launchWorktreeSurface(
                .acp(agentId: agentID, preparedPrompt: prepared),
                worktree: worktree,
                project: project
            )
        } catch {
            inAppNotifications.post(
                "Could not start \(agentID): \(error.localizedDescription)",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        // The launch returns normally when the session could not be opened
        // or its agent did not start, so check what it left behind, as
        // plugin tasks do.
        guard let session = acpManager(for: worktree)?.liveSession(for: prepared.sessionID) else {
            inAppNotifications.post(
                "Could not open a chat session for \(agentID) in \(worktree.branch).",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        if let reason = session.lastError {
            inAppNotifications.post(
                "\(agentID) could not start in \(worktree.branch): \(reason)",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        let toggles = shepherdToggles(worktree: worktree, request: request)
        await reviewShepherd.bind(
            sessionID: prepared.sessionID,
            worktreeID: worktree.id,
            request: request,
            baseBranch: request.baseRefName,
            autoFix: toggles.autoFix,
            autoMerge: toggles.autoMerge,
            sendContext: false
        )
    }

    // MARK: - Effects

    private func shepherdToggles(worktree: Worktree, request: ReviewRequest) -> (autoFix: Bool, autoMerge: Bool) {
        let id = ShepherdRecordID(worktreeID: worktree.id, request: request)
        if let record = reviewShepherd.records[id], !record.phase.isTerminal {
            return (record.autoFix, record.autoMerge)
        }
        let defaults = config.changes.shepherd
        return (defaults.autoFix, defaults.autoMerge)
    }

    private func shepherdWorktreeContext(_ worktreeID: String) -> ReviewShepherd.WorktreeContext? {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              !projectsManager.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return nil }
        return ReviewShepherd.WorktreeContext(
            worktreeID: resolved.worktree.id,
            projectID: resolved.project.id,
            path: resolved.worktree.path,
            baseBranch: shepherdBaseBranch(for: resolved.worktree),
            isEligible: isShepherdEligible(resolved.worktree)
        )
    }

    /// Same membership test the worktree cleanup scanner uses: a checkout
    /// lists a member of this project at this path.
    private func isWorkspaceCheckoutMember(_ worktree: Worktree) -> Bool {
        let path = worktree.path.standardizedFileURL.path
        return workspacesManager.checkouts.contains { checkout in
            checkout.members.contains { member in
                member.projectID == worktree.projectId
                    && URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)).standardizedFileURL.path == path
            }
        }
    }

    /// Busy while a turn runs or waits on the user, while the agent starts,
    /// or while a ready agent has a queued prompt (a shepherd prompt
    /// included) that has not started. A prompt held behind an agent that
    /// failed, disconnected or never attached is not busy, so a stuck fix
    /// ends in a no-progress escalation instead of waiting forever.
    private static func shepherdSessionIsBusy(_ session: ACPSession, now: Date) -> Bool {
        if session.transcript.streamingState != .idle { return true }
        switch session.agentState {
        case .spawning:
            return true
        case .ready:
            return session.queue.contains { shepherdQueueItemIsDue($0, now: now) }
        case .idle, .disconnected, .failed:
            return false
        }
    }

    /// A queued prompt that will run as soon as the agent is free: no error,
    /// not scheduled for later.
    private static func shepherdQueueItemIsDue(_ item: QueuedPrompt, now: Date) -> Bool {
        item.lastError == nil && (item.scheduledAt ?? .distantPast) <= now
    }

    private func notifyShepherdEvent(_ event: ReviewShepherd.Event) {
        let message = Self.shepherdNotification(for: event) { record in
            projectAndWorktree(withWorktreeId: record.id.worktreeID)?.project.host
        }
        let record = message.record
        guard let resolved = projectAndWorktree(withWorktreeId: record.id.worktreeID) else { return }
        let agent = shepherdAgentKind(sessionID: record.sessionID, worktreeID: record.id.worktreeID)
        harness.notifications.notifyAlas(
            body: message.body,
            title: message.title,
            agent: agent,
            projectId: resolved.project.id,
            worktreeId: resolved.worktree.id,
            sessionId: record.sessionID,
            owner: record.owner
        )
        guard let escalation = message.escalation else { return }
        if escalation == .ownerGone {
            // No session left to flag: keep it in the worktree's attention history.
            guard let context = attentionContext(for: resolved.worktree) else { return }
            attentionStore.appendHistory(AttentionHistoryEvent(
                sourceKey: AttentionSourceKey(rawValue: "shepherd:\(record.id.storageKey):owner-gone"),
                fingerprint: "\(record.id.storageKey)|owner-gone|\(record.sessionID)",
                owner: context.owner,
                kind: .actionableFeedback,
                title: message.title,
                body: message.body,
                jumpTarget: .reviewRequest(number: record.id.requestNumber),
                display: context.display
            ))
        } else {
            // Same as MCP `notify` at attention level.
            harness.setExternalActivity(
                sessionId: record.sessionID,
                owner: record.owner,
                agent: agent,
                state: .awaitingInput,
                body: message.body,
                requiresUserInput: true
            )
        }
    }

    private func shepherdAgentKind(sessionID: String, worktreeID: String) -> AgentKind {
        let manager = acpManager(forWorktreeId: worktreeID)
        let agentID = manager?.liveSession(for: sessionID)?.agentId
            ?? manager?.cachedPersistedSessionRow(id: sessionID)?.agentId
        return agentID.map { ACPHarnessBridge.agentKind(for: $0) } ?? .codex
    }

    /// `host` is the SSH host of the record's project, where `gh`/`glab` run.
    private static func shepherdNotification(
        for event: ReviewShepherd.Event,
        host: (ShepherdRecord) -> String?
    ) -> (record: ShepherdRecord, escalation: ShepherdEscalation?, title: String, body: String) {
        switch event {
        case .ready(let record, let title):
            return (record, nil, "Ready to merge", "\(shepherdReference(record)) \"\(title)\" passes every check and can be merged.")
        case .merged(let record, let title):
            return (record, nil, "Merged", "\(shepherdReference(record)) \"\(title)\" was merged.")
        case .queued(let record, let title):
            return (record, nil, "Added to merge queue", "\(shepherdReference(record)) \"\(title)\" is in the merge queue.")
        case .closed(let record, let title):
            return (record, nil, "Closed", "\(shepherdReference(record)) \"\(title)\" was closed without merging.")
        case .escalated(let record, let reason, let title):
            let subject = title.map { "\(shepherdReference(record)) \"\($0)\"" } ?? shepherdReference(record)
            let cli = record.id.providerKind == .github ? "gh" : "glab"
            let detail: String = switch reason {
            case .attemptsExhausted: "still has problems after \(ShepherdPolicy.maxFixAttempts) fix attempts."
            case .noProgress: "has not moved since the last fix prompt."
            case .deliveryFailed: "could not reach its chat session."
            case .ownerGone: "lost its chat session. Pick another one in Changes."
            case .authFailed:
                if let host = host(record) {
                    "can't be checked: \(cli) is missing or signed out on \(host). Run \(cli) auth login there."
                } else {
                    "can't be checked: \(cli) is missing or signed out. Run \(cli) auth login."
                }
            }
            return (record, reason, "PR shepherd needs you", "\(subject) \(detail)")
        }
    }

    private static func shepherdReference(_ record: ShepherdRecord) -> String {
        let kind = record.id.providerKind
        return "\(kind.displayName) \(kind.reviewRequestNumberPrefix)\(record.id.requestNumber)"
    }

    /// Settings > Changes > "Archive worktree after its PR merges": the
    /// normal archive path, which hides the worktree and stops its tabs
    /// without touching disk. `sessionID` owns the finished record; the
    /// worktree may hold other records owned by other sessions. A busy owner
    /// defers quietly: the shepherd tries again when its turn ends.
    /// `isStillWanted` false (the record was stopped or rebound while the
    /// owner's state was read) declines without archiving.
    private func archiveShepherdWorktreeIfAllowed(
        _ worktreeID: String,
        sessionID: String,
        isStillWanted: @MainActor () -> Bool
    ) async -> ReviewShepherd.ArchiveResult {
        guard config.changes.shepherd.archiveAfterMerge,
              let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              !projectsManager.isMain(resolved.worktree, in: resolved.project),
              !projectsManager.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return .declined }
        let worktree = resolved.worktree
        // Archiving hides the worktree, and the shepherd then drops every record
        // in it, including one still watching another open request.
        if hasActiveShepherdRecord(worktreeID: worktreeID) {
            inAppNotifications.post(
                "Kept \(worktree.branch): another pull request in it is still shepherded.",
                severity: .information,
                worktreeID: worktreeID
            )
            return .declined
        }
        if await shepherdSessionState(sessionID: sessionID, worktreeID: worktreeID) == .busy {
            return .deferredBusy
        }
        // `archiveWorktree` would ask about unsaved edits in a modal prompt.
        guard tabs.tabIdsWithUnsavedChanges(forWorktree: worktreeID).isEmpty else {
            inAppNotifications.post(
                "Kept \(worktree.branch): it has unsaved editor changes.",
                severity: .information,
                worktreeID: worktreeID
            )
            return .declined
        }
        // The session state read suspends: the record, the setting or the
        // worktree may have changed meanwhile.
        guard isStillWanted(),
              config.changes.shepherd.archiveAfterMerge,
              !projectsManager.isWorktreeHidden(projectId: resolved.project.id, path: worktree.path),
              !hasActiveShepherdRecord(worktreeID: worktreeID)
        else { return .declined }
        archiveWorktree(worktree)
        return .archived
    }

    private func hasActiveShepherdRecord(worktreeID: String) -> Bool {
        reviewShepherd.records.values.contains { $0.id.worktreeID == worktreeID && !$0.phase.isTerminal }
    }
}
