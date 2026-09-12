import Foundation

enum AttentionNavigationResult: Equatable {
    case opened
    case opening
    case unavailable(String)
}

struct AttentionPendingReviewReveal {
    let worktreeID: String
    let tabID: TabID
    let sessionID: String
    let command: DiffReviewDraftCommentScrollCommand
    let eventIDs: [UUID]
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
                guard let destination = appState.attentionSessionDestination(for: sessionID, preferredWorktreeID: worktree.id) else {
                    return false
                }
                switch destination.owner {
                case .worktree(let worktreeID):
                    if let leafID = destination.leafID {
                        _ = appState.tabs.setFocusedLeaf(worktreeId: worktreeID, tabId: destination.tabID, leafId: leafID)
                    }
                    appState.activateWorktreeCenterTab(worktreeId: worktreeID, tabId: destination.tabID)
                case .workspaceCheckout:
                    appState.selectWorkspaceCheckout(owner: destination.owner, focusedWorktreeID: worktree.id)
                    if let leafID = destination.leafID {
                        _ = appState.tabs.setFocusedLeaf(owner: destination.owner, tabId: destination.tabID, leafId: leafID)
                    }
                    appState.tabs.activate(owner: destination.owner, tabId: destination.tabID)
                    appState.tabs.clearActiveTab(worktreeId: worktree.id)
                    appState.acknowledgeFocusedSessionAttention(worktreeID: worktree.id, owner: destination.owner, tabID: destination.tabID)
                }
                return true
            },
            presentScriptFailure: { [weak appState] item, failureID in
                guard let appState, let worktree = item.worktree else { return false }
                let failure = appState.runScriptFailures(in: worktree.id).first(where: { $0.id == failureID })
                    ?? RunScriptFailure(
                        id: failureID,
                        runID: "attention:\(item.eventID.uuidString)",
                        scriptKey: "attention-history",
                        scriptName: item.title.replacingOccurrences(of: " failed with exit code [0-9]+$", with: "", options: .regularExpression),
                        worktreeID: worktree.id,
                        branch: item.display.branch,
                        exitCode: Int32(item.title.split(separator: " ").last ?? "-1") ?? -1,
                        completedAt: item.occurredAt,
                        capturedOutput: item.body.map { body in
                            let marker = "\n\n[Output truncated]"
                            if body.hasSuffix(marker) {
                                return .available(text: String(body.dropLast(marker.count)), truncated: true)
                            }
                            return .available(text: body, truncated: false)
                        } ?? .unavailable
                    )
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
                      let records = try? reviewSessionStore.list(worktreeID: worktree.id) else { return false }
                let storedComment = try? reviewCommentStore.load(sessionID: draftID).first(where: { $0.id == commentID })
                let comment = storedComment ?? (try? reviewCommentStore.find(commentID: commentID))
                guard let comment,
                      let record = records.first(where: { $0.target.draftSessionID == comment.sessionID }) else { return false }
                let focused = record.selectingFile(comment.fileID, now: Date()).focusingComment(commentID, now: Date())
                do { try reviewSessionStore.save(focused) } catch { return false }
                let tab = appState.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: focused)
                appState.activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
                guard case .reviewSession(let session) = tab, let command = session.commentScrollRequest else { return false }
                appState.attentionPendingReviewReveal = AttentionPendingReviewReveal(
                    worktreeID: worktree.id, tabID: tab.id, sessionID: comment.sessionID.rawValue,
                    command: command, eventIDs: [item.eventID]
                )
                return true
            },
            focusRemoteWorktree: { item in
                guard let host = item.worktree?.display.host else { return false }
                return RemoteHostStatusStore.shared.reachability(for: host) == .offline
            }
        )
    }
}

extension AppState {
    @discardableResult
    func openAttentionItem(_ item: AttentionItem) async -> AttentionNavigationResult {
        attentionNavigationDepth += 1
        defer { attentionNavigationDepth -= 1 }
        func unavailable(_ message: String) -> AttentionNavigationResult {
            attentionNavigationErrors[item.eventID] = message
            return .unavailable(message)
        }
        guard let worktree = attentionWorktree(forNavigationItem: item),
              let project = projects.first(where: { $0.id == worktree.projectId }) else {
            return unavailable("The worktree is no longer available.")
        }
        guard !projectsManager.isWorktreeHidden(projectId: project.id, path: worktree.path) else {
            return unavailable("The worktree is archived. Restore it to open this item.")
        }
        // The row may have been rendered before a rename, branch switch, or refresh.
        let current = AttentionWorktree(worktree: worktree, project: project).resolved
        let currentOwner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let resolved = AttentionItem(eventID: item.eventID, sourceKey: item.sourceKey, owner: currentOwner,
                                     kind: item.kind, title: item.title, body: item.body, occurredAt: item.occurredAt,
                                     presentation: item.presentation, jumpTarget: item.jumpTarget, display: current.display,
                                     worktree: current, acknowledgedAt: item.acknowledgedAt)
        focusGlobalWorktree(id: worktree.id, projectId: project.id)
        attentionNavigationGeneration += 1
        let navigationGeneration = attentionNavigationGeneration
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
        guard isAttentionNavigationCurrent(generation: navigationGeneration, owner: currentOwner, worktreeID: worktree.id) else {
            return unavailable("Navigation was canceled because the destination changed.")
        }
        guard opened else { return unavailable(failure) }
        attentionNavigationErrors[item.eventID] = nil
        isAttentionInboxOpen = false
        if attentionPendingReviewReveal?.eventIDs == [item.eventID] { return .opening }
        attentionStore.acknowledge(eventID: item.eventID, at: Date())
        return .opened
    }

    func beginReviewAttentionInteraction(worktreeID: String, tabID: TabID, sessionID: String, command: DiffReviewDraftCommentScrollCommand) {
        guard !isAttentionInboxOpen, selectedWorktreeId == worktreeID else { return }
        let eventIDs = attentionAggregation.items.filter { item in
            guard item.worktree?.id == worktreeID,
                  case .reviewComment(_, command.commentID) = item.jumpTarget
            else { return false }
            return true
        }.map(\.eventID)
        attentionPendingReviewReveal = AttentionPendingReviewReveal(worktreeID: worktreeID, tabID: tabID,
            sessionID: sessionID, command: command, eventIDs: eventIDs)
    }

    func completeReviewAttentionReveal(worktreeID: String, tabID: TabID, sessionID: String,
                                      command: DiffReviewDraftCommentScrollCommand, succeeded: Bool) {
        guard let pending = attentionPendingReviewReveal,
              pending.worktreeID == worktreeID, pending.tabID == tabID,
              pending.sessionID == sessionID, pending.command == command else { return }
        attentionPendingReviewReveal = nil
        guard !isAttentionInboxOpen, selectedWorktreeId == worktreeID,
              tabs.activeTabId(forWorktree: worktreeID) == tabID else { return }
        for eventID in pending.eventIDs {
            if succeeded {
                attentionStore.acknowledge(eventID: eventID, at: Date())
                attentionNavigationErrors[eventID] = nil
            } else {
                attentionNavigationErrors[eventID] = "The review comment could not be revealed."
            }
        }
    }

    func dismissAttentionItem(_ item: AttentionItem) {
        attentionStore.acknowledge(eventID: item.eventID, at: Date())
        attentionNavigationErrors[item.eventID] = nil
    }

    func dismissAllAttentionItems() {
        for item in attentionAggregation.items {
            attentionStore.acknowledge(eventID: item.eventID, at: Date())
            attentionNavigationErrors[item.eventID] = nil
        }
    }

    func acknowledgeReviewCommentAttention(worktreeID: String, commentID: String) {
        guard !isAttentionInboxOpen, attentionNavigationDepth == 0, selectedWorktreeId == worktreeID else { return }
        for item in attentionAggregation.items where item.worktree?.id == worktreeID {
            guard case .reviewComment(_, let itemCommentID) = item.jumpTarget,
                  itemCommentID == commentID else { continue }
            attentionStore.acknowledge(eventID: item.eventID, at: Date())
            attentionNavigationErrors[item.eventID] = nil
        }
    }

    func isAttentionNavigationCurrent(generation: Int, owner: AttentionWorktreeIdentity, worktreeID: String) -> Bool {
        guard !Task.isCancelled, attentionNavigationGeneration == generation,
              selectedWorktreeId == worktreeID,
              let worktree = attentionWorktree(for: owner), worktree.id == worktreeID else { return false }
        return !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path)
    }

    var attentionAggregation: AttentionAggregation {
        refreshAttentionAliases()
        reconcileHostAttentionForCurrentTopology()
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
        currentAttentionObservations.compactMap(\.activeSignal)
    }

    var currentAttentionObservations: [AttentionObservation] {
        var observations = harness.activityBySession.flatMap { sessionID, activity -> [AttentionObservation] in
            guard let worktree = attentionWorktree(forSessionID: sessionID),
                  let context = attentionContext(for: worktree) else {
                return [
                    .inactive(sourceKey: .init(rawValue: "session:\(sessionID):awaiting")),
                    .inactive(sourceKey: .init(rawValue: "session:\(sessionID):permission"))
                ]
            }
            return AttentionProducer.harness(
                sessionID: sessionID, agent: activity.agent, state: activity.state,
                body: activity.lastBody, owner: context.owner, display: context.display
            )
        }
        let knownHarnessSessionIDs = Set(harness.activityBySession.keys)
        observations += restoredAttentionSessionIDs()
            .subtracting(knownHarnessSessionIDs)
            .flatMap { sessionID in
                [
                    .inactive(sourceKey: .init(rawValue: "session:\(sessionID):awaiting")),
                    .inactive(sourceKey: .init(rawValue: "session:\(sessionID):permission"))
                ]
            }
        for entry in attentionWorktrees {
            let owner = AttentionWorktreeIdentity.make(worktree: entry.worktree, project: entry.project)
            if rightPaneStore.isActiveState(worktreeId: entry.worktree.id),
               let pane = rightPaneStore.activeState(worktreeId: entry.worktree.id),
               pane.hasCurrentAttentionSnapshot {
                observations += rightPaneAttentionObservations(snapshot: pane.attentionSnapshot, owner: owner, display: entry.resolved.display)
            }
            if let host = entry.project.host {
                switch RemoteHostStatusStore.shared.reachability(for: host) {
                case .offline where canRecordHostAttention(for: entry, host: host, isDisconnected: true):
                    observations += AttentionProducer.host(host: host, isDisconnected: true, owner: owner, display: entry.resolved.display)
                case .online:
                    observations += AttentionProducer.host(host: host, isDisconnected: false, owner: owner, display: entry.resolved.display)
                case .offline, .unknown:
                    break
                }
            }
            for failure in runScriptFailureQueue.failures(for: entry.worktree.id) {
                observations += AttentionProducer.script(
                    failure: failure,
                    owner: .make(worktree: entry.worktree, project: entry.project),
                    display: entry.resolved.display
                )
            }
        }
        return observations
    }

    private func restoredAttentionSessionIDs() -> Set<String> {
        var sessionIDs = Set<String>()
        for entry in attentionWorktrees {
            for tab in tabs.tabs(forWorktree: entry.worktree.id) {
                sessionIDs.formUnion(tab.attentionSessionIDs)
            }
        }
        for checkout in workspacesManager.checkouts where checkout.archivedAt == nil {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            for tab in tabs.tabs(for: owner) {
                sessionIDs.formUnion(tab.attentionSessionIDs)
            }
        }
        return sessionIDs
    }

    func observeRightPaneAttention(worktreeID: String, snapshot: RightPaneAttentionSnapshot, at date: Date = Date()) {
        refreshAttentionAliases()
        guard let entry = attentionWorktrees.first(where: { $0.worktree.id == worktreeID }),
              let context = attentionContext(for: entry.worktree) else { return }
        let observations = rightPaneAttentionObservations(snapshot: snapshot, owner: context.owner, display: context.display)
        let activeKeys = Set(observations.compactMap(\.activeSignal).map(\.sourceKey))
        let deferredFeedbackKey = deferredReviewFeedbackKey(for: snapshot.review?.reviewRequest, owner: context.owner)
        // Only a successful provider snapshot can confirm that a request disappeared.
        // Missing/auth-failed snapshots leave occurrence identity and acknowledgments intact.
        if let review = snapshot.review,
           review.providerAvailable, review.providerAuthenticated, review.errorMessage == nil {
            for key in Array(attentionSuppressedStartupSignals.keys)
                where key.rawValue.hasPrefix("review:\(context.owner.storageKey):")
                    && !activeKeys.contains(key)
                    && shouldDeactivateMissingReviewKey(key, deferredFeedbackKey: deferredFeedbackKey) {
                observeAttention(.inactive(sourceKey: key), at: date)
            }
            for key in activeStoredReviewObservationKeys(owner: context.owner)
                where !activeKeys.contains(key)
                    && shouldDeactivateMissingReviewKey(key, deferredFeedbackKey: deferredFeedbackKey) {
                observeAttention(.inactive(sourceKey: key), at: date)
            }
        }
        let initialGitSnapshot = attentionInitializedSnapshotSources.insert("git:\(context.owner.storageKey)").inserted
        let gitSignals = observations.compactMap(\.activeSignal).filter { $0.kind == .gitOperation || $0.kind == .conflicts }
        reconcileAttention(liveSignals: gitSignals, isInitialSnapshot: initialGitSnapshot, at: date)
        if let review = snapshot.review,
           review.providerAvailable, review.providerAuthenticated, review.errorMessage == nil {
            let initialReviewSnapshot = attentionInitializedSnapshotSources.insert("review:\(context.owner.storageKey)").inserted
            let reviewSignals = observations.compactMap(\.activeSignal).filter { $0.kind != .gitOperation && $0.kind != .conflicts }
            let feedbackSignals = reviewSignals.filter { $0.kind == .actionableFeedback }
            let otherReviewSignals = reviewSignals.filter { $0.kind != .actionableFeedback }
            reconcileAttention(liveSignals: otherReviewSignals, isInitialSnapshot: initialReviewSnapshot, at: date)
            if review.reviewRequest?.areThreadsComplete != false {
                let initialFeedbackSnapshot = attentionInitializedSnapshotSources.insert("review-feedback:\(context.owner.storageKey)").inserted
                reconcileAttention(liveSignals: feedbackSignals, isInitialSnapshot: initialFeedbackSnapshot, at: date)
            }
        }
        for observation in observations where observation.activeSignal == nil {
            if case .inactive(let sourceKey) = observation,
               !shouldDeactivateMissingReviewKey(sourceKey, deferredFeedbackKey: deferredFeedbackKey) {
                continue
            }
            observeAttention(observation, at: date)
        }
    }

    private func deferredReviewFeedbackKey(for request: ReviewRequest?, owner: AttentionWorktreeIdentity) -> AttentionSourceKey? {
        guard let request, !request.areThreadsComplete else { return nil }
        return AttentionSourceKey(rawValue: "review:\(owner.storageKey):\(request.remote.webURL.absoluteString):\(request.number):feedback")
    }

    private func shouldDeactivateMissingReviewKey(_ key: AttentionSourceKey, deferredFeedbackKey: AttentionSourceKey?) -> Bool {
        guard key.rawValue.hasSuffix(":feedback"), let deferredFeedbackKey else { return true }
        return key != deferredFeedbackKey
    }

    private func activeStoredReviewObservationKeys(owner: AttentionWorktreeIdentity) -> [AttentionSourceKey] {
        let prefix = "review:\(owner.storageKey):"
        return attentionStore.document.observations.compactMap { key, observation in
            guard observation.isActive, key.rawValue.hasPrefix(prefix) else { return nil }
            return key
        }
    }

    func observeHostAttention(host: String, isDisconnected: Bool, at date: Date = Date()) {
        for entry in attentionWorktrees where canRecordHostAttention(for: entry, host: host, isDisconnected: isDisconnected) {
            for observation in AttentionProducer.host(host: host, isDisconnected: isDisconnected, owner: .make(worktree: entry.worktree, project: entry.project), display: entry.resolved.display) {
                observeAttention(observation, at: date)
            }
        }
    }

    private func reconcileHostAttentionForCurrentTopology(at date: Date = Date()) {
        let hosts = Set(attentionWorktrees.compactMap(\.project.host))
        for host in hosts {
            switch RemoteHostStatusStore.shared.reachability(for: host) {
            case .offline:
                observeHostAttentionIfChanged(host: host, isDisconnected: true, at: date)
            case .online:
                observeHostAttentionIfChanged(host: host, isDisconnected: false, at: date)
            case .unknown:
                continue
            }
        }
    }

    private func observeHostAttentionIfChanged(host: String, isDisconnected: Bool, at date: Date) {
        for entry in attentionWorktrees where canRecordHostAttention(for: entry, host: host, isDisconnected: isDisconnected) {
            for observation in AttentionProducer.host(host: host, isDisconnected: isDisconnected, owner: .make(worktree: entry.worktree, project: entry.project), display: entry.resolved.display) {
                guard !attentionObservationMatchesStored(observation) else { continue }
                observeAttention(observation, at: date)
            }
        }
    }

    private func canRecordHostAttention(for entry: AttentionWorktree, host: String, isDisconnected: Bool) -> Bool {
        guard entry.project.host == host else { return false }
        guard isDisconnected else { return true }
        return !projectsManager.isWorktreeHidden(projectId: entry.project.id, path: entry.worktree.path)
    }

    private func attentionObservationMatchesStored(_ observation: AttentionObservation) -> Bool {
        switch observation {
        case .active(let signal):
            guard let stored = attentionStore.document.observations[signal.sourceKey] else { return false }
            return stored.isActive && stored.fingerprint == signal.fingerprint
        case .inactive(let sourceKey):
            guard let stored = attentionStore.document.observations[sourceKey] else { return true }
            return !stored.isActive
        }
    }

    func observeReviewReplyAttention(worktree: Worktree, comment: ReviewDraftComment, reply: ReviewCommentReply) {
        guard let context = attentionContext(for: worktree) else { return }
        for observation in AttentionProducer.reviewReply(comment: comment, observedReply: reply, owner: context.owner, display: context.display) {
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
        if let selectedWorktreeId { rightPaneStore.activeState(worktreeId: selectedWorktreeId)?.endAttentionReveal() }
        isAttentionInboxOpen = true
    }

    func closeAttentionInbox() {
        guard isAttentionInboxOpen else { return }
        isAttentionInboxOpen = false
    }

    /// Snapshot reconciliation cannot invent events when previous acknowledgments are unknown.
    func reconcileAttention(liveSignals: [AttentionSignal], isInitialSnapshot: Bool = true, at date: Date = Date()) {
        reconcileAttention(observations: liveSignals.map(AttentionObservation.active), isInitialSnapshot: isInitialSnapshot, at: date)
    }

    func reconcileAttention(observations: [AttentionObservation], isInitialSnapshot: Bool = true, at date: Date = Date()) {
        for observation in observations {
            guard let signal = observation.activeSignal else {
                observeAttention(observation, at: date)
                continue
            }
            if isInitialSnapshot, attentionStore.loadError != nil,
               attentionStore.document.observations[signal.sourceKey] == nil {
                if attentionSuppressedStartupSignals[signal.sourceKey] == nil {
                    attentionSuppressedStartupSignals[signal.sourceKey] = signal.fingerprint
                }
            }
            observeAttention(.active(signal), at: date)
        }
    }

    /// Called by explicit surface interactions, never by producer refreshes.
    func acknowledgeAttentionSurface(worktreeID: String, target: AttentionJumpTarget) {
        guard !isAttentionInboxOpen, attentionNavigationDepth == 0 else { return }
        for item in attentionAggregation.items where item.worktree?.id == worktreeID {
            if attentionItem(item, matches: target) { attentionStore.acknowledge(eventID: item.eventID, at: Date()) }
        }
    }

    private func acknowledgeAttentionTarget(_ target: AttentionJumpTarget) {
        guard !isAttentionInboxOpen, attentionNavigationDepth == 0 else { return }
        for item in attentionAggregation.items where attentionItem(item, matches: target) {
            attentionStore.acknowledge(eventID: item.eventID, at: Date())
        }
    }

    private func attentionItem(_ item: AttentionItem, matches target: AttentionJumpTarget) -> Bool {
        if case .conflicts = target, case .conflicts = item.jumpTarget {
            return true
        }
        return item.jumpTarget == target
    }

    func acknowledgeFocusedSessionAttention(worktreeID: String, tabID: TabID) {
        guard selectedWorktreeId == worktreeID, tabs.activeTabId(forWorktree: worktreeID) == tabID,
              let tab = tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID }) else { return }
        acknowledgeSessionAttention(worktreeID: worktreeID, owner: .worktree(worktreeID), tab: tab)
    }

    func acknowledgeFocusedSessionAttention(worktreeID: String, owner: SessionOwnerID, tabID: TabID) {
        guard selectedWorktreeId == worktreeID,
              tabs.activeTabId(for: owner) == tabID,
              let tab = tabs.tabs(for: owner).first(where: { $0.id == tabID }) else { return }
        acknowledgeSessionAttention(worktreeID: worktreeID, owner: owner, tab: tab)
    }

    private func acknowledgeSessionAttention(worktreeID: String, owner: SessionOwnerID, tab: Tab) {
        switch tab {
        case .acpSession(let session):
            acknowledgeSessionTarget(worktreeID: worktreeID, owner: owner, sessionID: session.sessionId)
        case .terminal(let terminal):
            guard let leaf = terminal.root.find(leafId: terminal.focusedLeafId)?.leaf else { return }
            acknowledgeSessionTarget(worktreeID: worktreeID, owner: owner, sessionID: leaf.sessionId ?? leaf.id)
        default: break
        }
    }

    private func acknowledgeSessionTarget(worktreeID: String, owner: SessionOwnerID, sessionID: String) {
        let target = AttentionJumpTarget.session(sessionID: sessionID)
        if case .workspaceCheckout = owner {
            acknowledgeAttentionTarget(target)
        } else {
            acknowledgeAttentionSurface(worktreeID: worktreeID, target: target)
        }
    }

    func acknowledgeACPResponseInteraction(owner: SessionOwnerID, sessionID: String) {
        guard let resolution = attentionSessionResolution(for: sessionID, owner: owner) else { return }
        acknowledgeSessionTarget(worktreeID: resolution.worktree.id, owner: resolution.owner, sessionID: sessionID)
    }

    func observeAttention(_ observation: AttentionObservation, at date: Date = Date()) {
        switch observation {
        case .active(let signal):
            if let suppressedFingerprint = attentionSuppressedStartupSignals[signal.sourceKey] {
                if suppressedFingerprint == signal.fingerprint {
                    return
                }
                if isSuppressedAttentionFingerprintShrink(sourceKey: signal.sourceKey, suppressedFingerprint: suppressedFingerprint, currentFingerprint: signal.fingerprint) {
                    attentionSuppressedStartupSignals[signal.sourceKey] = signal.fingerprint
                    return
                }
                attentionSuppressedStartupSignals[signal.sourceKey] = nil
            }
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

    private func attentionWorktree(forNavigationItem item: AttentionItem) -> Worktree? {
        if case .session(let sessionID) = item.jumpTarget,
           let worktree = attentionSessionResolution(for: sessionID, preferredWorktreeID: item.worktree?.id)?.worktree {
            return worktree
        }
        return attentionWorktree(for: item.owner)
    }

    func attentionWorktree(forSessionID sessionID: String) -> Worktree? {
        attentionSessionResolution(for: sessionID)?.worktree
    }

    private func attentionSessionResolution(for sessionID: String, owner explicitOwner: SessionOwnerID? = nil, preferredWorktreeID: String? = nil) -> (worktree: Worktree, owner: SessionOwnerID)? {
        let worktrees = attentionWorktrees
        if let explicitOwner,
           let resolved = attentionWorktree(forSessionOwner: explicitOwner, preferredWorktreeID: preferredWorktreeID) {
            return resolved
        }
        if let session = terminal.registry.session(for: sessionID),
           let resolved = attentionWorktree(forSessionOwner: session.owner, preferredWorktreeID: preferredWorktreeID) {
            return resolved
        }
        if let entry = worktrees.first(where: { entry in
            tabs.tabs(forWorktree: entry.worktree.id).contains { tab in tab.hostsSession(sessionID) }
        }) {
            return (entry.worktree, .worktree(entry.worktree.id))
        }
        for checkout in workspacesManager.checkouts where checkout.archivedAt == nil {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            guard tabs.tabs(for: owner).contains(where: { $0.hostsSession(sessionID) }),
                  let worktree = attentionWorktree(for: checkout, preferredWorktreeID: preferredWorktreeID) else { continue }
            return (worktree, owner)
        }
        return nil
    }

    private func attentionWorktree(forSessionOwner owner: SessionOwnerID, preferredWorktreeID: String?) -> (worktree: Worktree, owner: SessionOwnerID)? {
        switch owner {
        case .worktree(let worktreeID):
            guard let worktree = attentionWorktrees.first(where: { $0.worktree.id == worktreeID })?.worktree else { return nil }
            return (worktree, owner)
        case .workspaceCheckout(let checkoutID, let location):
            guard let checkout = workspacesManager.checkout(id: checkoutID),
                  checkout.archivedAt == nil,
                  checkout.executionLocation.normalized == location.normalized,
                  let worktree = attentionWorktree(for: checkout, preferredWorktreeID: preferredWorktreeID) else { return nil }
            return (worktree, owner)
        }
    }

    private func attentionWorktree(for checkout: WorkspaceCheckout, preferredWorktreeID: String?) -> Worktree? {
        let worktrees = projects.flatMap { projectsManager.worktrees(projectId: $0.id) }
        let memberWorktreeIDs = WorkspaceMemberWorktreeResolver.resolvedWorktreeIDs(checkout: checkout, worktrees: worktrees)
        if let preferredWorktreeID, memberWorktreeIDs.values.contains(preferredWorktreeID),
           let worktree = worktrees.first(where: { $0.id == preferredWorktreeID }) {
            return worktree
        }
        if let selectedWorktreeId, memberWorktreeIDs.values.contains(selectedWorktreeId),
           let worktree = worktrees.first(where: { $0.id == selectedWorktreeId }) {
            return worktree
        }
        for worktreeID in memberWorktreeIDs.values.sorted() {
            if let worktree = worktrees.first(where: { $0.id == worktreeID }) {
                return worktree
            }
        }
        return nil
    }

    fileprivate func selectWorkspaceCheckout(owner: SessionOwnerID, focusedWorktreeID: String) {
        guard case .workspaceCheckout(let checkoutID, _) = owner,
              let checkout = workspacesManager.checkout(id: checkoutID) else { return }
        selectWorkspaceCheckout(id: checkoutID)
        let memberWorktreeIDs = attentionWorkspaceMemberWorktreeIDs(checkout)
        guard let memberID = memberWorktreeIDs.first(where: { $0.value == focusedWorktreeID })?.key else { return }
        focusWorkspaceCheckoutMember(id: memberID)
    }

    fileprivate func attentionSessionDestination(for sessionID: String, preferredWorktreeID: String?) -> (owner: SessionOwnerID, tabID: TabID, leafID: String?)? {
        let candidateOwners: [SessionOwnerID] = {
            if let owner = terminal.registry.session(for: sessionID)?.owner {
                return [owner]
            }
            return []
        }()
        for owner in candidateOwners {
            if let destination = attentionSessionDestination(for: sessionID, owner: owner) { return destination }
        }
        if let preferredWorktreeID,
           let destination = attentionSessionDestination(for: sessionID, owner: .worktree(preferredWorktreeID)) {
            return destination
        }
        for entry in attentionWorktrees {
            if let destination = attentionSessionDestination(for: sessionID, owner: .worktree(entry.worktree.id)) {
                return destination
            }
        }
        for checkout in workspacesManager.checkouts where checkout.archivedAt == nil {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            if let destination = attentionSessionDestination(for: sessionID, owner: owner) {
                return destination
            }
        }
        return nil
    }

    private func attentionSessionDestination(for sessionID: String, owner: SessionOwnerID) -> (owner: SessionOwnerID, tabID: TabID, leafID: String?)? {
        for tab in tabs.tabs(for: owner) {
            switch tab {
            case .terminal(let terminal):
                guard let leaf = terminal.root.leaves().first(where: { $0.sessionId == sessionID || $0.id == sessionID }) else { continue }
                return (owner, tab.id, leaf.id)
            case .acpSession(let session):
                guard session.sessionId == sessionID else { continue }
                return (owner, tab.id, nil)
            default:
                continue
            }
        }
        return nil
    }

    func observeHarnessAttention(_ transition: HarnessActivityTransition) {
        // Forget can arrive after the tab or session owner has already been removed.
        guard let state = transition.state else {
            for suffix in ["awaiting", "permission"] {
                observeAttention(.inactive(sourceKey: .init(rawValue: "session:\(transition.sessionID):\(suffix)")), at: transition.occurredAt)
            }
            return
        }
        guard let resolution = attentionSessionResolution(for: transition.sessionID, owner: transition.owner),
              let context = attentionContext(for: resolution.worktree) else { return }
        let observations = AttentionProducer.harness(
            sessionID: transition.sessionID, agent: transition.agent, state: state,
            body: transition.body, owner: context.owner, display: context.display
        )
        if transition.isSnapshot {
            reconcileAttention(liveSignals: observations.compactMap(\.activeSignal), at: transition.occurredAt)
            for observation in observations where observation.activeSignal == nil {
                observeAttention(observation, at: transition.occurredAt)
            }
        } else {
            for observation in observations { observeAttention(observation, at: transition.occurredAt) }
        }
        if !transition.isSnapshot,
           transition.previousState == .awaitingInput || transition.previousState == .permissionRequest,
           state == .busy || state == .idle {
            acknowledgeSessionTarget(worktreeID: resolution.worktree.id, owner: resolution.owner, sessionID: transition.sessionID)
        }
        if state == .idle, !transition.isSnapshot {
            attentionStore.appendHistory(AttentionProducer.finished(
                sessionID: transition.sessionID, agent: transition.agent,
                owner: context.owner, display: context.display
            ), at: transition.occurredAt)
        }
    }

    private func registerAttentionAlias(for signal: AttentionSignal) {
        registerAttentionAlias(owner: signal.owner, displayPath: signal.display.path)
    }

    private var currentAttentionAliases: [(from: AttentionWorktreeIdentity, to: AttentionWorktreeIdentity)] {
        attentionWorktrees.compactMap { entry in
            let owner = AttentionWorktreeIdentity.make(worktree: entry.worktree, project: entry.project)
            return attentionAlias(owner: owner, displayPath: entry.resolved.display.path)
        }
    }

    private func refreshAttentionAliases() {
        let aliases = currentAttentionAliases
        attentionStore.registerAliases(aliases, retryExisting: false)
        migrateSuppressedStartupSignals(aliases)
        migrateInitializedSnapshotSources(aliases)
        scheduleAttentionAliasRetryIfNeeded(aliases)
    }

    private func registerAttentionAlias(owner: AttentionWorktreeIdentity, displayPath: String) {
        guard let alias = attentionAlias(owner: owner, displayPath: displayPath) else { return }
        attentionStore.registerAlias(from: alias.from, to: alias.to)
        migrateSuppressedStartupSignals([alias])
        migrateInitializedSnapshotSources([alias])
    }

    private func scheduleAttentionAliasRetryIfNeeded(_ aliases: [(from: AttentionWorktreeIdentity, to: AttentionWorktreeIdentity)]) {
        guard attentionStore.writeError != nil else {
            attentionAliasRetryAttempts = 0
            attentionAliasRetryNotBefore = nil
            attentionAliasRetryTask?.cancel()
            attentionAliasRetryTask = nil
            return
        }
        guard !aliases.isEmpty, attentionAliasRetryTask == nil else { return }
        let date = Date()
        let delay = attentionAliasRetryNotBefore.map { max(0.0, $0.timeIntervalSince(date)) }
            ?? attentionAliasRetryDelay(attempt: attentionAliasRetryAttempts)
        scheduleAttentionAliasRetry(delay: delay)
    }

    private func scheduleAttentionAliasRetry(delay: TimeInterval) {
        attentionAliasRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.attentionStore.writeError != nil else {
                self.attentionAliasRetryAttempts = 0
                self.attentionAliasRetryNotBefore = nil
                self.attentionAliasRetryTask = nil
                return
            }
            let aliases = self.currentAttentionAliases
            guard !aliases.isEmpty else {
                self.attentionAliasRetryNotBefore = nil
                self.attentionAliasRetryTask = nil
                return
            }
            self.attentionStore.registerAliases(aliases)
            if self.attentionStore.writeError == nil {
                self.attentionAliasRetryAttempts = 0
                self.attentionAliasRetryNotBefore = nil
                self.attentionAliasRetryTask = nil
            } else {
                self.attentionAliasRetryAttempts += 1
                let nextDelay = self.attentionAliasRetryDelay(attempt: self.attentionAliasRetryAttempts)
                self.attentionAliasRetryNotBefore = Date().addingTimeInterval(nextDelay)
                self.scheduleAttentionAliasRetry(delay: nextDelay)
            }
        }
    }

    private func attentionAliasRetryDelay(attempt: Int) -> TimeInterval {
        min(10.0, 0.2 * pow(2.0, Double(min(attempt, 6))))
    }

    private func attentionAlias(owner: AttentionWorktreeIdentity, displayPath: String) -> (from: AttentionWorktreeIdentity, to: AttentionWorktreeIdentity)? {
        guard owner.lineageID != nil else { return nil }
        let legacyOwner = AttentionWorktreeIdentity(
            projectID: owner.projectID, location: owner.location,
            lineageID: nil, legacyPath: displayPath
        )
        return legacyOwner == owner ? nil : (legacyOwner, owner)
    }

    private func migrateSuppressedStartupSignals(_ aliases: [(from: AttentionWorktreeIdentity, to: AttentionWorktreeIdentity)]) {
        for alias in aliases {
            for (sourceKey, fingerprint) in Array(attentionSuppressedStartupSignals) {
                guard let migratedKey = migratedAttentionSourceKey(sourceKey, from: alias.from, to: alias.to),
                      migratedKey != sourceKey else { continue }
                if attentionSuppressedStartupSignals[migratedKey] == nil {
                    attentionSuppressedStartupSignals[migratedKey] = fingerprint
                }
                attentionSuppressedStartupSignals[sourceKey] = nil
            }
        }
    }

    private func migrateInitializedSnapshotSources(_ aliases: [(from: AttentionWorktreeIdentity, to: AttentionWorktreeIdentity)]) {
        for alias in aliases {
            for source in Array(attentionInitializedSnapshotSources) {
                guard let migratedSource = migratedInitializedSnapshotSource(source, from: alias.from, to: alias.to),
                      migratedSource != source else { continue }
                attentionInitializedSnapshotSources.insert(migratedSource)
                attentionInitializedSnapshotSources.remove(source)
            }
        }
    }

    private func migratedInitializedSnapshotSource(_ source: String, from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) -> String? {
        let legacyKey = legacyOwner.storageKey
        let lineageKey = lineageOwner.storageKey
        for prefix in ["git:", "review:", "review-feedback:"] {
            guard source == "\(prefix)\(legacyKey)" else { continue }
            return "\(prefix)\(lineageKey)"
        }
        return nil
    }

    private func migratedAttentionSourceKey(_ sourceKey: AttentionSourceKey, from legacyOwner: AttentionWorktreeIdentity, to lineageOwner: AttentionWorktreeIdentity) -> AttentionSourceKey? {
        let legacyKey = legacyOwner.storageKey
        let lineageKey = lineageOwner.storageKey
        for prefix in ["git:", "review:", "host:"] {
            let legacyPrefix = "\(prefix)\(legacyKey):"
            guard sourceKey.rawValue.hasPrefix(legacyPrefix) else { continue }
            return AttentionSourceKey(rawValue: "\(prefix)\(lineageKey):\(sourceKey.rawValue.dropFirst(legacyPrefix.count))")
        }
        return nil
    }

    private func attentionWorkspaceMemberWorktreeIDs(_ checkout: WorkspaceCheckout) -> [UUID: String] {
        WorkspaceMemberWorktreeResolver.resolvedWorktreeIDs(
            checkout: checkout,
            worktrees: projects.flatMap { projectsManager.worktrees(projectId: $0.id) }
        )
    }

    private func isSuppressedAttentionFingerprintShrink(
        sourceKey: AttentionSourceKey,
        suppressedFingerprint: String,
        currentFingerprint: String
    ) -> Bool {
        if sourceKey.rawValue.hasSuffix(":conflicts") {
            return isStrictNonEmptySubset(decodedFingerprintSet(currentFingerprint), of: decodedFingerprintSet(suppressedFingerprint))
        }
        if sourceKey.rawValue.hasSuffix(":checks") {
            return isHeadScopedFingerprintSetShrink(from: suppressedFingerprint, to: currentFingerprint, droppedPrefixCount: 1)
        }
        if sourceKey.rawValue.hasSuffix(":feedback") {
            return isHeadScopedThreadFingerprintSetShrink(from: suppressedFingerprint, to: currentFingerprint)
        }
        return false
    }

    private func isHeadScopedThreadFingerprintSetShrink(from previousFingerprint: String, to currentFingerprint: String) -> Bool {
        let previousParts = previousFingerprint.split(separator: "|", omittingEmptySubsequences: false)
        let currentParts = currentFingerprint.split(separator: "|", omittingEmptySubsequences: false)
        guard previousParts.count >= 4,
              currentParts.count >= 3,
              previousParts[0] == currentParts[0],
              previousParts[1] == "decision",
              currentParts[1] == "decision",
              previousParts[2] == currentParts[2],
              previousParts[3] == "threads"
        else { return false }
        if currentParts.count == 3 {
            return true
        }
        guard currentParts[3] == "threads" else { return false }
        return isStrictNonEmptySubset(
            Set(currentParts.dropFirst(4).map(String.init)),
            of: Set(previousParts.dropFirst(4).map(String.init))
        )
    }

    private func isHeadScopedFingerprintSetShrink(from previousFingerprint: String, to currentFingerprint: String, droppedPrefixCount: Int) -> Bool {
        let previousParts = previousFingerprint.split(separator: "|", omittingEmptySubsequences: false)
        let currentParts = currentFingerprint.split(separator: "|", omittingEmptySubsequences: false)
        guard previousParts.first == currentParts.first else { return false }
        return isStrictNonEmptySubset(
            Set(currentParts.dropFirst(droppedPrefixCount).map(String.init)),
            of: Set(previousParts.dropFirst(droppedPrefixCount).map(String.init))
        )
    }

    private func decodedFingerprintSet(_ fingerprint: String) -> Set<String> {
        if let values = decodeLengthPrefixedFingerprintSet(fingerprint) {
            return Set(values)
        }
        return Set(fingerprint.split(separator: "|").map(String.init))
    }

    private func decodeLengthPrefixedFingerprintSet(_ fingerprint: String) -> [String]? {
        var index = fingerprint.startIndex
        var values: [String] = []
        while index < fingerprint.endIndex {
            guard let separator = fingerprint[index...].firstIndex(of: ":"),
                  let count = Int(fingerprint[index ..< separator])
            else { return nil }
            let valueStart = fingerprint.index(after: separator)
            guard let valueEnd = fingerprint.index(valueStart, offsetBy: count, limitedBy: fingerprint.endIndex)
            else { return nil }
            values.append(String(fingerprint[valueStart ..< valueEnd]))
            index = valueEnd
        }
        return values
    }

    private func isStrictNonEmptySubset(_ current: Set<String>, of previous: Set<String>) -> Bool {
        !current.isEmpty && current.isStrictSubset(of: previous)
    }
}

private extension Tab {
    var attentionSessionIDs: Set<String> {
        switch self {
        case .terminal(let terminal):
            Set(terminal.root.leaves().flatMap { [$0.id, $0.sessionId].compactMap(\.self) })
        case .acpSession(let session):
            [session.sessionId]
        default:
            []
        }
    }

    func hostsSession(_ sessionID: String) -> Bool {
        switch self {
        case .terminal(let terminal):
            terminal.root.leaves().contains { $0.id == sessionID || $0.sessionId == sessionID }
        case .acpSession(let session):
            session.sessionId == sessionID
        default:
            false
        }
    }
}
