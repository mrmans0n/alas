import Foundation

struct AttentionReturnDestination {
    let spaceID: String
    let worktreeID: String?
    let activeTabID: TabID?
}

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
                      let comment = try? reviewCommentStore.load(sessionID: draftID).first(where: { $0.id == commentID }),
                      let records = try? reviewSessionStore.list(worktreeID: worktree.id),
                      let record = records.first(where: { $0.target.draftSessionID == draftID }) else { return false }
                let focused = record.selectingFile(comment.fileID, now: Date()).focusingComment(commentID, now: Date())
                do { try reviewSessionStore.save(focused) } catch { return false }
                let tab = appState.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: focused)
                appState.activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
                guard case .reviewSession(let session) = tab, let command = session.commentScrollRequest else { return false }
                appState.attentionPendingReviewReveal = AttentionPendingReviewReveal(
                    worktreeID: worktree.id, tabID: tab.id, sessionID: sessionID,
                    command: command, eventIDs: [item.eventID]
                )
                return true
            },
            focusRemoteWorktree: { item in
                item.worktree?.display.host != nil
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
        guard isAttentionNavigationCurrent(generation: navigationGeneration, owner: item.owner, worktreeID: worktree.id) else {
            return unavailable("Navigation was canceled because the destination changed.")
        }
        guard opened else { return unavailable(failure) }
        attentionNavigationErrors[item.eventID] = nil
        isAttentionInboxOpen = false
        attentionReturnDestination = nil
        if attentionPendingReviewReveal?.eventIDs == [item.eventID] { return .opening }
        attentionStore.acknowledge(eventID: item.eventID, at: Date())
        return .opened
    }

    func beginReviewAttentionInteraction(worktreeID: String, tabID: TabID, sessionID: String, command: DiffReviewDraftCommentScrollCommand) {
        guard !isAttentionInboxOpen, selectedWorktreeId == worktreeID else { return }
        let target = AttentionJumpTarget.reviewComment(sessionID: sessionID, commentID: command.commentID)
        let eventIDs = attentionAggregation.items.filter { $0.worktree?.id == worktreeID && $0.jumpTarget == target }.map(\.eventID)
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

    func isAttentionNavigationCurrent(generation: Int, owner: AttentionWorktreeIdentity, worktreeID: String) -> Bool {
        guard !Task.isCancelled, attentionNavigationGeneration == generation,
              selectedWorktreeId == worktreeID,
              let worktree = attentionWorktree(for: owner), worktree.id == worktreeID else { return false }
        return !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path)
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
            if rightPaneStore.isActiveState(worktreeId: entry.worktree.id),
               let pane = rightPaneStore.activeState(worktreeId: entry.worktree.id),
               pane.hasCurrentAttentionSnapshot {
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
            for key in Array(attentionSuppressedStartupSignals.keys)
                where key.rawValue.hasPrefix("review:\(context.owner.storageKey):") && !activeKeys.contains(key) {
                observeAttention(.inactive(sourceKey: key), at: date)
            }
            for event in attentionStore.events where event.owner == context.owner && [.failedChecks, .actionableFeedback, .reviewSyncBlocked].contains(event.kind) {
                if !activeKeys.contains(event.sourceKey) {
                    observeAttention(.inactive(sourceKey: event.sourceKey), at: date)
                }
            }
        }
        let initialGitSnapshot = attentionInitializedSnapshotSources.insert("git:\(context.owner.storageKey)").inserted
        let gitSignals = observations.compactMap(\.activeSignal).filter { $0.kind == .gitOperation || $0.kind == .conflicts }
        reconcileAttention(liveSignals: gitSignals, isInitialSnapshot: initialGitSnapshot, at: date)
        if let review = snapshot.review,
           review.providerAvailable, review.providerAuthenticated, review.errorMessage == nil {
            let initialReviewSnapshot = attentionInitializedSnapshotSources.insert("review:\(context.owner.storageKey)").inserted
            let reviewSignals = observations.compactMap(\.activeSignal).filter { $0.kind != .gitOperation && $0.kind != .conflicts }
            reconcileAttention(liveSignals: reviewSignals, isInitialSnapshot: initialReviewSnapshot, at: date)
        }
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
        if let selectedWorktreeId { rightPaneStore.activeState(worktreeId: selectedWorktreeId)?.endAttentionReveal() }
        attentionReturnDestination = AttentionReturnDestination(
            spaceID: spacesManager.activeSpaceId,
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
        _ = switchToSpace(id: destination.spaceID)
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
    func reconcileAttention(liveSignals: [AttentionSignal], isInitialSnapshot: Bool = true, at date: Date = Date()) {
        for signal in liveSignals {
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
            let matches: Bool
            if case .conflicts = target, case .conflicts = item.jumpTarget {
                matches = true
            } else {
                matches = item.jumpTarget == target
            }
            if matches { attentionStore.acknowledge(eventID: item.eventID, at: Date()) }
        }
    }

    func acknowledgeFocusedSessionAttention(worktreeID: String, tabID: TabID) {
        guard selectedWorktreeId == worktreeID, tabs.activeTabId(forWorktree: worktreeID) == tabID,
              let tab = tabs.tabs(forWorktree: worktreeID).first(where: { $0.id == tabID }) else { return }
        acknowledgeSessionAttention(worktreeID: worktreeID, tab: tab)
    }

    func acknowledgeFocusedSessionAttention(worktreeID: String, owner: SessionOwnerID, tabID: TabID) {
        guard selectedWorktreeId == worktreeID,
              tabs.activeTabId(for: owner) == tabID,
              let tab = tabs.tabs(for: owner).first(where: { $0.id == tabID }) else { return }
        acknowledgeSessionAttention(worktreeID: worktreeID, tab: tab)
    }

    private func acknowledgeSessionAttention(worktreeID: String, tab: Tab) {
        switch tab {
        case .acpSession(let session):
            acknowledgeAttentionSurface(worktreeID: worktreeID, target: .session(sessionID: session.sessionId))
        case .terminal(let terminal):
            guard let leaf = terminal.root.find(leafId: terminal.focusedLeafId)?.leaf else { return }
            acknowledgeAttentionSurface(worktreeID: worktreeID, target: .session(sessionID: leaf.sessionId ?? leaf.id))
        default: break
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

private extension Tab {
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
