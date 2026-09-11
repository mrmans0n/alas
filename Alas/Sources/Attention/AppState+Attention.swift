import Foundation

struct AttentionReturnDestination {
    let worktreeID: String?
    let activeTabID: TabID?
}

enum AttentionNavigationResult: Equatable {
    case opened
    case unavailable(String)
}

struct AttentionNavigationEnvironment {
    var focusSession: @MainActor (AttentionItem, String) -> Bool
    var presentScriptFailure: @MainActor (AttentionItem, String) -> Bool
    var revealRightPane: @MainActor (AttentionItem, AttentionJumpTarget) async -> Bool
    var focusReviewComment: @MainActor (AttentionItem, String, String) -> Bool
    var focusRemoteWorktree: @MainActor (AttentionItem) -> Bool

    @MainActor
    static func live(appState: AppState,
                     reviewSessionStore: ReviewSessionStore = ReviewSessionStore(),
                     reviewCommentStore: ReviewDraftCommentStore = ReviewDraftCommentStore()) -> Self {
        Self(
            focusSession: { [weak appState] item, sessionID in
                guard let appState, let worktree = item.worktree else { return false }
                for tab in appState.tabs.tabs(forWorktree: worktree.id) {
                    switch tab {
                    case .terminal(let terminal):
                        guard let leaf = terminal.root.leaves().first(where: { $0.sessionId == sessionID || $0.id == sessionID }) else { continue }
                        _ = appState.tabs.setFocusedLeaf(worktreeId: worktree.id, tabId: tab.id, leafId: leaf.id)
                    case .acpSession(let session):
                        guard session.sessionId == sessionID else { continue }
                    default: continue
                    }
                    appState.activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
                    return true
                }
                return false
            },
            presentScriptFailure: { [weak appState] item, failureID in
                guard let appState, let worktree = item.worktree,
                      let failure = appState.runScriptFailures(in: worktree.id).first(where: { $0.id == failureID }) else { return false }
                appState.presentRunScriptFailure(failure)
                return true
            },
            revealRightPane: { [weak appState] item, target in
                guard let appState, let worktree = appState.attentionWorktree(for: item.owner) else { return false }
                if let host = item.worktree?.display.host, RemoteHostStatusStore.shared.isOffline(host) { return false }
                return await appState.rightPaneStore.revealAttentionTarget(target, for: worktree)
            },
            focusReviewComment: { [weak appState] item, sessionID, commentID in
                guard let appState, let worktree = item.worktree,
                      let draftID = ReviewDraftSessionID(rawValue: sessionID),
                      let comment = try? reviewCommentStore.load(sessionID: draftID).first(where: { $0.id == commentID }),
                      let records = try? reviewSessionStore.list(worktreeID: worktree.id),
                      let record = records.first(where: { $0.target.draftSessionID == draftID }) else { return false }
                let focused = record.selectingFile(comment.fileID, now: Date()).focusingComment(commentID, now: Date())
                do { try reviewSessionStore.save(focused) } catch { return false }
                let tab = appState.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: focused)
                appState.activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
                return true
            },
            focusRemoteWorktree: { item in
                guard let host = item.worktree?.display.host else { return false }
                return RemoteHostStatusStore.shared.isOffline(host)
            }
        )
    }
}

extension AppState {
    @discardableResult
    func openAttentionItem(_ item: AttentionItem) async -> AttentionNavigationResult {
        func unavailable(_ message: String) -> AttentionNavigationResult {
            attentionNavigationErrors[item.eventID] = message
            return .unavailable(message)
        }
        guard let worktree = attentionWorktree(for: item.owner),
              let project = projects.first(where: { $0.id == worktree.projectId }) else {
            return unavailable("The worktree is no longer available.")
        }
        guard !projectsManager.isWorktreeHidden(projectId: project.id, path: worktree.path) else {
            return unavailable("The worktree is archived. Restore it to open this item.")
        }
        // The row may have been rendered before a rename, branch switch, or refresh.
        let current = AttentionWorktree(worktree: worktree, project: project).resolved
        let resolved = AttentionItem(eventID: item.eventID, sourceKey: item.sourceKey, owner: item.owner,
                                     kind: item.kind, title: item.title, body: item.body, occurredAt: item.occurredAt,
                                     presentation: item.presentation, jumpTarget: item.jumpTarget, display: current.display,
                                     worktree: current, acknowledgedAt: item.acknowledgedAt)
        focusGlobalWorktree(id: worktree.id, projectId: project.id)
        let environment = attentionNavigationEnvironment ?? .live(appState: self)
        let opened: Bool
        let failure: String
        switch item.jumpTarget {
        case .session(let sessionID):
            opened = environment.focusSession(resolved, sessionID)
            failure = "The session is no longer available."
        case .runScriptFailure(let failureID):
            opened = environment.presentScriptFailure(resolved, failureID)
            failure = "The script failure is no longer available."
        case .conflicts, .gitOperation, .reviewRequest:
            opened = await environment.revealRightPane(resolved, item.jumpTarget)
            failure = "The requested changes or review are no longer available."
        case .reviewComment(let sessionID, let commentID):
            opened = environment.focusReviewComment(resolved, sessionID, commentID)
            failure = "The review comment is no longer available."
        case .remoteWorktree:
            opened = environment.focusRemoteWorktree(resolved)
            failure = "The host is no longer disconnected."
        case .none:
            opened = false
            failure = "This event has no destination."
        }
        guard opened else { return unavailable(failure) }
        attentionNavigationErrors[item.eventID] = nil
        isAttentionInboxOpen = false
        attentionReturnDestination = nil
        attentionStore.acknowledge(eventID: item.eventID, at: Date())
        return .opened
    }

    var attentionAggregation: AttentionAggregation {
        let document = attentionStore.document
        let liveSignals = currentAttentionSignals.compactMap { signal -> AttentionLiveSignal? in
            guard let observation = document.observations[signal.sourceKey],
                  observation.isActive, observation.fingerprint == signal.fingerprint,
                  let eventID = observation.eventID else { return nil }
            return AttentionLiveSignal(eventID: eventID, signal: signal, isCurrentlyActive: true)
        }
        return AttentionSignalAggregator.aggregate(
            liveSignals: liveSignals, document: document, worktrees: attentionWorktrees
        )
    }

    var attentionWorktrees: [AttentionWorktree] {
        projects.flatMap { project in
            projectsManager.worktrees(projectId: project.id).map {
                AttentionWorktree(worktree: $0, project: project)
            }
        }
    }

    /// Read producer-owned state each time; persisted observations only identify occurrences.
    var currentAttentionSignals: [AttentionSignal] {
        var signals = harness.activityBySession.flatMap { sessionID, activity -> [AttentionSignal] in
            guard let worktree = attentionWorktree(forSessionID: sessionID),
                  let context = attentionContext(for: worktree) else { return [] }
            return AttentionProducer.harness(
                sessionID: sessionID, agent: activity.agent, state: activity.state,
                body: activity.lastBody, owner: context.owner, display: context.display
            ).compactMap(\.activeSignal)
        }
        for entry in attentionWorktrees {
            let owner = AttentionWorktreeIdentity.make(worktree: entry.worktree, project: entry.project)
            if let pane = rightPaneStore.activeState(worktreeId: entry.worktree.id), pane.hasLoadedSnapshot {
                signals += rightPaneAttentionObservations(snapshot: pane.attentionSnapshot, owner: owner, display: entry.resolved.display).compactMap(\.activeSignal)
            }
            if let host = entry.project.host {
                signals += AttentionProducer.host(host: host, isDisconnected: RemoteHostStatusStore.shared.isOffline(host), owner: owner, display: entry.resolved.display).compactMap(\.activeSignal)
            }
            for failure in runScriptFailureQueue.failures(for: entry.worktree.id) {
                signals += AttentionProducer.script(
                    failure: failure,
                    owner: .make(worktree: entry.worktree, project: entry.project),
                    display: entry.resolved.display
                ).compactMap(\.activeSignal)
            }
        }
        return signals
    }

    func observeRightPaneAttention(worktreeID: String, snapshot: RightPaneAttentionSnapshot, at date: Date = Date()) {
        guard let entry = attentionWorktrees.first(where: { $0.worktree.id == worktreeID }),
              let context = attentionContext(for: entry.worktree) else { return }
        let observations = rightPaneAttentionObservations(snapshot: snapshot, owner: context.owner, display: context.display)
        let activeKeys = Set(observations.compactMap(\.activeSignal).map(\.sourceKey))
        // Only a successful provider snapshot can confirm that a request disappeared.
        // Missing/auth-failed snapshots leave occurrence identity and acknowledgments intact.
        if let review = snapshot.review,
           review.providerAvailable, review.providerAuthenticated, review.errorMessage == nil {
            for event in attentionStore.events where event.owner == context.owner && [.failedChecks, .actionableFeedback, .reviewSyncBlocked].contains(event.kind) {
                if !activeKeys.contains(event.sourceKey) {
                    observeAttention(.inactive(sourceKey: event.sourceKey), at: date)
                }
            }
        }
        reconcileAttention(liveSignals: observations.compactMap(\.activeSignal), at: date)
        for observation in observations where observation.activeSignal == nil { observeAttention(observation, at: date) }
    }

    func observeHostAttention(host: String, isDisconnected: Bool, at date: Date = Date()) {
        for entry in attentionWorktrees where entry.project.host == host {
            for observation in AttentionProducer.host(host: host, isDisconnected: isDisconnected, owner: .make(worktree: entry.worktree, project: entry.project), display: entry.resolved.display) {
                observeAttention(observation, at: date)
            }
        }
    }

    func observeReviewReplyAttention(worktree: Worktree, comment: ReviewDraftComment, reply: ReviewCommentReply) {
        guard let context = attentionContext(for: worktree) else { return }
        for observation in AttentionProducer.reviewReply(comment: comment, owner: context.owner, display: context.display) {
            if let signal = observation.activeSignal,
               let latestAcknowledgment = attentionStore.events
                   .filter({ $0.sourceKey == signal.sourceKey })
                   .compactMap({ attentionStore.acknowledgments[$0.id]?.acknowledgedAt }).max(),
               reply.createdAt <= latestAcknowledgment {
                continue
            }
            observeAttention(observation, at: reply.createdAt)
        }
    }

    private func rightPaneAttentionObservations(snapshot: RightPaneAttentionSnapshot, owner: AttentionWorktreeIdentity, display: AttentionWorktreeDisplaySnapshot) -> [AttentionObservation] {
        let conflicts = snapshot.conflictedPaths.map {
            ChangedFile(path: $0, status: "U", stage: .unstaged, add: 0, del: 0, renameFrom: nil, conflict: .bothModified)
        }
        var observations = AttentionProducer.git(operation: snapshot.mergeOperation, changes: conflicts, owner: owner, display: display)
        if let review = snapshot.review,
           review.providerAvailable, review.providerAuthenticated, review.errorMessage == nil {
            observations += AttentionProducer.review(snapshot: review, owner: owner, display: display)
        }
        return observations
    }

    func openAttentionInbox() {
        guard !isAttentionInboxOpen else { return }
        attentionReturnDestination = AttentionReturnDestination(
            worktreeID: selectedWorktreeId,
            activeTabID: selectedWorktreeId.flatMap { tabs.activeTabId(forWorktree: $0) }
        )
        isAttentionInboxOpen = true
    }

    func closeAttentionInbox() {
        guard isAttentionInboxOpen else { return }
        isAttentionInboxOpen = false
        guard let destination = attentionReturnDestination else { return }
        attentionReturnDestination = nil
        selectedWorktreeId = destination.worktreeID
        if let worktreeID = destination.worktreeID {
            if let tabID = destination.activeTabID,
               tabs.tabs(forWorktree: worktreeID).contains(where: { $0.id == tabID }) {
                tabs.activate(worktreeId: worktreeID, tabId: tabID)
            } else if destination.activeTabID == nil {
                tabs.clearActiveTab(worktreeId: worktreeID)
            }
        }
    }

    /// Snapshot reconciliation cannot invent events when previous acknowledgments are unknown.
    func reconcileAttention(liveSignals: [AttentionSignal], at date: Date = Date()) {
        for signal in liveSignals {
            if attentionStore.loadError != nil,
               attentionStore.document.observations[signal.sourceKey] == nil {
                if attentionSuppressedStartupSignals[signal.sourceKey] == nil {
                    attentionSuppressedStartupSignals[signal.sourceKey] = signal.fingerprint
                }
            }
            observeAttention(.active(signal), at: date)
        }
    }

    func observeAttention(_ observation: AttentionObservation, at date: Date = Date()) {
        switch observation {
        case .active(let signal):
            guard attentionSuppressedStartupSignals[signal.sourceKey] != signal.fingerprint else { return }
            attentionSuppressedStartupSignals[signal.sourceKey] = nil
            registerAttentionAlias(for: signal)
        case .inactive(let sourceKey):
            attentionSuppressedStartupSignals[sourceKey] = nil
        }
        attentionStore.observe(observation, at: date)
    }

    func attentionContext(for worktree: Worktree) -> (owner: AttentionWorktreeIdentity, display: AttentionWorktreeDisplaySnapshot)? {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return nil }
        return (.make(worktree: worktree, project: project), AttentionWorktree(worktree: worktree, project: project).resolved.display)
    }

    func attentionWorktree(for owner: AttentionWorktreeIdentity) -> Worktree? {
        let worktrees = attentionWorktrees
        let resolver = AttentionWorktreeResolver(worktrees: worktrees, aliases: attentionStore.document.aliases)
        guard let resolved = resolver.resolve(owner) else { return nil }
        return worktrees.first { $0.worktree.id == resolved.id && $0.project.id == resolved.projectID }?.worktree
    }

    func attentionWorktree(forSessionID sessionID: String) -> Worktree? {
        let worktrees = attentionWorktrees
        if let session = terminal.registry.session(for: sessionID),
           let worktree = worktrees.first(where: { $0.worktree.id == session.worktreeId })?.worktree {
            return worktree
        }
        return worktrees.first { entry in
            tabs.tabs(forWorktree: entry.worktree.id).contains { tab in
                switch tab {
                case .terminal(let state):
                    state.root.leaves().contains { $0.id == sessionID || $0.sessionId == sessionID }
                case .acpSession(let state):
                    state.sessionId == sessionID
                default:
                    false
                }
            }
        }?.worktree
    }

    func observeHarnessAttention(_ transition: HarnessActivityTransition) {
        // Forget can arrive after the tab or session owner has already been removed.
        guard let state = transition.state else {
            for suffix in ["awaiting", "permission"] {
                observeAttention(.inactive(sourceKey: .init(rawValue: "session:\(transition.sessionID):\(suffix)")), at: transition.occurredAt)
            }
            return
        }
        guard let worktree = attentionWorktree(forSessionID: transition.sessionID),
              let context = attentionContext(for: worktree) else { return }
        let observations = AttentionProducer.harness(
            sessionID: transition.sessionID, agent: transition.agent, state: state,
            body: transition.body, owner: context.owner, display: context.display
        )
        if transition.isSnapshot {
            reconcileAttention(liveSignals: observations.compactMap(\.activeSignal), at: transition.occurredAt)
        } else {
            for observation in observations { observeAttention(observation, at: transition.occurredAt) }
        }
        if state == .idle, !transition.isSnapshot {
            attentionStore.appendHistory(AttentionProducer.finished(
                sessionID: transition.sessionID, agent: transition.agent,
                owner: context.owner, display: context.display
            ), at: transition.occurredAt)
        }
    }

    private func registerAttentionAlias(for signal: AttentionSignal) {
        guard signal.owner.lineageID != nil else { return }
        let legacyOwner = AttentionWorktreeIdentity(
            projectID: signal.owner.projectID, location: signal.owner.location,
            lineageID: nil, legacyPath: signal.display.path
        )
        attentionStore.registerAlias(from: legacyOwner, to: signal.owner)
    }
}
