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
            deliverPrompt: { [weak self] sessionID, worktreeID, text in
                await self?.deliverShepherdPrompt(sessionID: sessionID, worktreeID: worktreeID, text: text) ?? false
            },
            rules: { [weak self] worktreeID in
                self?.shepherdRules(worktreeID: worktreeID) ?? ShepherdRules.none
            },
            notify: { [weak self] event in
                self?.notifyShepherdEvent(event)
            },
            refreshPaneIfCached: { [weak self] worktreeID in
                guard let self else { return }
                Task { await self.rightPaneStore.refresh(worktreeId: worktreeID, forceReviewLoopRemote: true) }
            },
            archiveWorktreeIfAllowed: { [weak self] worktreeID in
                await self?.archiveShepherdWorktreeIfAllowed(worktreeID)
            }
        )
    }

    /// Called once the worktree topology is loaded, because records resolve
    /// their worktrees against it.
    func startReviewShepherd() {
        reviewShepherd.start()
    }

    // MARK: - Eligibility, rules and base

    /// Local git worktrees outside Workspace checkouts. Remote (SSH)
    /// projects, folders and checkout members are out of scope for v1.
    func isShepherdEligible(_ worktree: Worktree) -> Bool {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return false }
        return project.host == nil && !project.isFolder && !isWorkspaceCheckoutMember(worktree)
    }

    func shepherdRules(worktreeID: String) -> ShepherdRules {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID) else { return ShepherdRules.none }
        return ShepherdRulesResolver.load(
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

    /// Queues `text` on the session as a shepherd prompt, captioned "Alas PR
    /// shepherd". Hydrates a session with no open tab, like the orchestration
    /// coordinator's delivery, then brings its agent up the way the composer
    /// does, so the prompt runs after any turn in progress. False when the
    /// session is missing or archived, or the queue could not be saved.
    func deliverShepherdPrompt(sessionID: String, worktreeID: String, text: String) async -> Bool {
        guard let worktree = worktree(withId: worktreeID),
              let manager = acpManager(for: worktree),
              let row = await manager.persistedSessionRow(id: sessionID),
              !row.archived,
              manager.placeholderSession(id: sessionID) != nil
        else { return false }
        await manager.hydrateIfNeeded(id: sessionID)
        guard manager.liveSession(for: sessionID)?.hydrationState == .ready else { return false }
        let recordKey = reviewShepherd.record(forSession: sessionID)?.id.storageKey ?? worktreeID
        let source = ACPDelegatedPromptSource.shepherd(recordKey: recordKey, messageID: UUID())
        guard await manager.enqueueDelegatedPrompt(text: text, source: source, into: sessionID) else { return false }
        // Attaches an idle, disconnected or failed agent; a no-op while it is
        // spawning or ready, where the enqueue already flushed the queue.
        await manager.reattach(to: sessionID)
        return true
    }

    func shepherdSessionState(sessionID: String, worktreeID: String) async -> ShepherdSessionState {
        guard let worktree = worktree(withId: worktreeID),
              let manager = acpManager(for: worktree),
              let row = await manager.persistedSessionRow(id: sessionID)
        else { return .missing }
        if row.archived { return .archived }
        if let session = manager.liveSession(for: sessionID) {
            return Self.shepherdSessionIsBusy(session, now: Date()) ? .busy : .idle
        }
        return row.directTurnInFlight ? .busy : .idle
    }

    /// The popover's Create PR/MR button: asks the session, as a normal user
    /// turn, to commit what belongs to the work and call `pr_create`.
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
                attachments: []
            ) { [weak self] sent in
                guard !sent else { return }
                self?.inAppNotifications.post(
                    "Could not send the Create \(kind.reviewRequestLabel) prompt to this session.",
                    severity: .error,
                    worktreeID: worktree.id
                )
            }
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
            rules: shepherdRules(worktreeID: worktree.id)
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
        // The launch returns normally when the session could not be opened,
        // so check what it left behind, as plugin tasks do.
        guard acpManager(for: worktree)?.liveSession(for: prepared.sessionID) != nil else {
            inAppNotifications.post(
                "Could not open a chat session for \(agentID) in \(worktree.branch).",
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
            return session.queue.contains { $0.lastError == nil && ($0.scheduledAt ?? .distantPast) <= now }
        case .idle, .disconnected, .failed:
            return false
        }
    }

    private func notifyShepherdEvent(_ event: ReviewShepherd.Event) {
        let message = Self.shepherdNotification(for: event)
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

    private static func shepherdNotification(
        for event: ReviewShepherd.Event
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
            case .authFailed: "can't be checked: \(cli) is missing or signed out. Run \(cli) auth login."
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
    /// without touching disk.
    private func archiveShepherdWorktreeIfAllowed(_ worktreeID: String) async {
        guard config.changes.shepherd.archiveAfterMerge,
              let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              resolved.worktree.isMainWorktree != true,
              !projectsManager.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return }
        let worktree = resolved.worktree
        if let record = reviewShepherd.record(forWorktree: worktreeID),
           await shepherdSessionState(sessionID: record.sessionID, worktreeID: worktreeID) == .busy {
            inAppNotifications.post(
                "Kept \(worktree.branch): its chat session is still working.",
                severity: .information,
                worktreeID: worktreeID
            )
            return
        }
        // `archiveWorktree` would ask about unsaved edits in a modal prompt.
        guard tabs.tabIdsWithUnsavedChanges(forWorktree: worktreeID).isEmpty else {
            inAppNotifications.post(
                "Kept \(worktree.branch): it has unsaved editor changes.",
                severity: .information,
                worktreeID: worktreeID
            )
            return
        }
        archiveWorktree(worktree)
    }
}
