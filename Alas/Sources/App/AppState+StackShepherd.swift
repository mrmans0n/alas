import Foundation

extension AppState {
    /// Watches every pull or merge request of a bound gg stack. It decides
    /// when and what; the effects installed here reach gg, sessions,
    /// notifications and the archive path.
    var stackShepherd: StackShepherd { core.stackShepherd }

    // MARK: - Wiring

    func installStackShepherdEffects() {
        stackShepherd.effects = StackShepherd.Effects(
            worktreeContext: { [weak self] worktreeID in
                self?.stackShepherdWorktreeContext(worktreeID)
            },
            loadStack: { path in
                // Older gg builds lack `--no-refresh`; they read remote state too.
                let localOnly = GGAvailability.shared.capabilities.localStackSnapshot
                return try await GGService().currentStack(worktreePath: path.path, refreshRemote: !localOnly)
            },
            syncStack: { [weak self] worktreeID, plan in
                guard let self else { throw GGMutationError.staleConfirmation }
                try await self.syncStackForShip(worktreeID: worktreeID, plan: plan)
            },
            rebaseStack: { [weak self] worktreeID, expected in
                guard let self else { throw GGMutationError.staleConfirmation }
                try await self.ggPane(worktreeID: worktreeID).rebaseGGForShip(expected: expected)
            },
            sessionState: { [weak self] sessionID, worktreeID in
                await self?.shepherdSessionState(sessionID: sessionID, worktreeID: worktreeID) ?? .missing
            },
            deliverPrompt: { [weak self] sessionID, worktreeID, prompt, isStillWanted in
                await self?.deliverShepherdPrompt(
                    sessionID: sessionID, worktreeID: worktreeID, prompt: prompt, isStillWanted: isStillWanted
                ) ?? .failed
            },
            rules: { [weak self] worktreeID in
                try await self?.shepherdRules(worktreeID: worktreeID) ?? ShepherdRules.none
            },
            notify: { [weak self] event in
                self?.notifyStackShepherdEvent(event)
            },
            archiveWorktreeIfAllowed: { [weak self] worktreeID, sessionID, isStillWanted in
                await self?.archiveShepherdWorktreeIfAllowed(
                    worktreeID, sessionID: sessionID, isStillWanted: isStillWanted
                ) ?? .declined
            }
        )
    }

    // MARK: - Eligibility

    /// The gg stack Alas's stacked-diffs settings put `worktree` on, for a
    /// worktree the shepherd can watch; nil outside gg mode.
    func shepherdStackName(for worktree: Worktree) -> String? {
        guard isShepherdEligible(worktree),
              let integration = ggACPWorktreeIntegration(worktreePath: worktree.path.path),
              case .active(let name) = integration.context
        else { return nil }
        return name
    }

    /// Whether Ship works on the worktree's gg stack rather than its branch's
    /// PR: in gg mode, or while the session still shepherds a stack.
    func shipsStack(sessionID: String, worktree: Worktree) -> Bool {
        if let record = stackShepherd.record(forSession: sessionID), !record.isFinished { return true }
        return shepherdStackName(for: worktree) != nil
    }

    private func stackShepherdWorktreeContext(_ worktreeID: String) -> StackShepherd.WorktreeContext? {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              !projectsManager.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return nil }
        return StackShepherd.WorktreeContext(
            worktreeID: resolved.worktree.id,
            path: resolved.worktree.path,
            stackName: shepherdStackName(for: resolved.worktree),
            isEligible: isShepherdEligible(resolved.worktree)
        )
    }

    /// `gg sync` through the worktree's Changes pane state, the path the
    /// stack drawer's Sync and Commit & sync use: the same preflight, paused
    /// operation guard, progress and refresh.
    private func syncStackForShip(worktreeID: String, plan: StackShipPlan) async throws {
        let pane = try ggPane(worktreeID: worktreeID)
        guard plan != .wholeStack else {
            try await pane.syncGGForCommitPublish(.sync)
            return
        }
        guard GGAvailability.shared.capabilities.syncUntilDraft else { throw GGMutationError.scopedSyncUnsupported }
        try await pane.syncGGForCommitPublish(.syncUntil(target: plan.shipThroughEntryID, draft: plan.opensDrafts))
    }

    /// The worktree's Changes pane state, which runs its gg mutations.
    private func ggPane(worktreeID: String) throws -> RightPaneState {
        guard let worktree = worktree(withId: worktreeID) else { throw GGMutationError.staleConfirmation }
        return rightPaneStore.state(
            for: worktree,
            baseBranch: config.worktrees.baseBranch,
            comparisonMode: config.changes.comparisonMode,
            activates: false
        )
    }

    // MARK: - Ship

    /// The toolbar's Ship stack button: remembers what to publish for the
    /// session's `stack_ship`, then asks the session to fold its work into
    /// the stack and call it.
    func requestShipStack(sessionID: String, worktree: Worktree, plan: StackShipPlan) {
        let session = acpManager(for: worktree)?.liveSession(for: sessionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await preparingShip(session: session) {
                await sendShipStackPrompt(sessionID: sessionID, worktree: worktree, plan: plan)
            }
        }
    }

    /// Returns once the session took the prompt or it was refused.
    private func sendShipStackPrompt(sessionID: String, worktree: Worktree, plan: StackShipPlan) async {
        guard let manager = acpManager(for: worktree) else { return }
        let stackName = shepherdStackName(for: worktree) ?? worktree.branch
        let remotes = (try? await GitService().remotes(worktreePath: worktree.path)) ?? []
        guard let kind = CodeHostRemoteDetector.detect(from: remotes)?.kind else {
            inAppNotifications.post(
                "No GitHub or GitLab remote for \(worktree.branch).",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        // Set even for the whole stack, so an earlier choice never carries over.
        stackShepherd.setPendingShipPlan(
            plan, sessionID: sessionID, id: StackShepherdRecordID(worktreeID: worktree.id, stackName: stackName)
        )
        await manager.sendPrompt(
            for: sessionID,
            text: StackShepherdPromptBuilder.shipPrompt(kind: kind, plan: plan),
            attachments: [],
            delegatedSource: .shipStack(stackName: stackName, kind: kind, messageID: UUID()),
            normalUserTurn: false
        ) { [weak self] sent in
            guard !sent else { return }
            self?.inAppNotifications.post(
                "Could not send the Ship stack prompt to this session.",
                severity: .error,
                worktreeID: worktree.id
            )
        }
    }

    /// The shepherding popover's Ship more: publishes `plan` straight away,
    /// without an agent turn, since the held-back entries are already
    /// committed.
    func shipMoreStack(sessionID: String, worktree: Worktree, plan: StackShipPlan) async {
        if case .error(let message) = await core.shipStack(sessionID: sessionID, worktreeID: worktree.id, plan: plan) {
            inAppNotifications.post("Couldn't ship more of the stack: \(message)", severity: .error, worktreeID: worktree.id)
        }
    }

    /// Binds the worktree's published stack to the session and sends it the
    /// context prompt, taking the stack over from another session if one
    /// shepherds it.
    func shepherdStackWithSession(_ sessionID: String, worktree: Worktree) async {
        guard let rules = await shepherdRulesForBinding(worktree: worktree) else { return }
        do {
            _ = try await core.shepherdPublishedStack(sessionID: sessionID, worktreeID: worktree.id, contextRules: rules)
        } catch {
            inAppNotifications.post(
                "Couldn't start shepherding the stack: \(AlasCoreContext.prShepherdErrorMessage(error))",
                severity: .error,
                worktreeID: worktree.id
            )
        }
    }

    /// `/ship` in a gg stack worktree: what the Ship stack popover offers.
    func shipStackFromCommand(session: ACPSession, worktree: Worktree) async {
        let context = StackShepherdSessionContext(sessionID: session.id, worktree: worktree, state: self)
        // A finished record is not this session's stack: load what gg lists.
        let hasLiveRecord = context.record?.isFinished == false || context.otherRecord != nil
        let stack = hasLiveRecord ? nil : try? await stackShepherd.effects?.loadStack(worktree.path)
        switch StackShipAction.resolve(
            record: context.record,
            otherRecord: context.otherRecord,
            stack: stack,
            isBusy: session.transcript.streamingState != .idle
        ) {
        case .shepherding(let name):
            session.lastError = "This session already shepherds the gg stack \(name). Its status is in the toolbar's stack button."
        case .adopt:
            await shepherdStackWithSession(session.id, worktree: worktree)
        case .create:
            await sendShipStackPrompt(sessionID: session.id, worktree: worktree, plan: .wholeStack)
        case .unavailable(let reason):
            session.lastError = reason
        }
    }

    // MARK: - Notifications

    private func notifyStackShepherdEvent(_ event: StackShepherd.Event) {
        let message = Self.stackShepherdNotification(for: event) { record in
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
                jumpTarget: .reviewRequest(number: record.openEntries.first?.requestNumber ?? 0),
                display: context.display
            ))
        } else {
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

    /// `host` is the SSH host of the record's project, where `gh`/`glab` run.
    static func stackShepherdNotification(
        for event: StackShepherd.Event,
        host: (StackShepherdRecord) -> String?
    ) -> (record: StackShepherdRecord, escalation: ShepherdEscalation?, title: String, body: String) {
        func stack(_ record: StackShepherdRecord) -> String { "gg stack \"\(record.id.stackName)\"" }
        func requests(_ record: StackShepherdRecord, _ count: Int) -> String {
            let label = record.remote.kind == .gitlab ? "merge request" : "pull request"
            return "\(count) \(label)\(count == 1 ? "" : "s")"
        }
        switch event {
        case .ready(let record):
            return (record, nil, "Stack ready to land",
                    "All \(requests(record, record.openEntries.count)) in \(stack(record)) pass their checks with no open review threads. Land it from the stack drawer once it's approved.")
        case .finished(let record, .merged):
            return (record, nil, "Stack landed", "Every request in \(stack(record)) was merged.")
        case .finished(let record, .closed):
            return (record, nil, "Stack closed", "\(stack(record)) finished with requests closed without merging.")
        case .entryClosed(let record, let entry, let title):
            return (record, nil, "Closed", "\(reference(record, entry)) \"\(title)\" in \(stack(record)) was closed without merging.")
        case .escalated(let record, let entries, let reason):
            let subject = "\(entries.map { reference(record, $0) }.joined(separator: ", ")) in \(stack(record))"
            let cli = record.remote.kind == .github ? "gh" : "glab"
            let detail: String = switch reason {
            case .attemptsExhausted: "still \(entries.count == 1 ? "has" : "have") problems after \(record.fixAttemptBudget) fix attempts."
            case .noProgress: "\(entries.count == 1 ? "has" : "have") not moved since the last fix prompt."
            case .deliveryFailed: "could not reach the stack's chat session."
            case .ownerGone: "lost the stack's chat session. Use Ship in another session to take the stack over."
            case .authFailed:
                if let host = host(record) {
                    "can't be checked: \(cli) is missing or signed out on \(host). Run \(cli) auth login there."
                } else {
                    "can't be checked: \(cli) is missing or signed out. Run \(cli) auth login."
                }
            }
            return (record, reason, "Stack shepherd needs you", "\(subject) \(detail)")
        }
    }

    private static func reference(_ record: StackShepherdRecord, _ entry: StackShepherdEntry) -> String {
        let kind = record.remote.kind
        return "\(kind.displayName) \(kind.reviewRequestNumberPrefix)\(entry.requestNumber)"
    }
}
