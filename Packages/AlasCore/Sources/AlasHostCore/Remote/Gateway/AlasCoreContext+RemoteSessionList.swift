import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP
import AlasSessions

extension AlasCoreContext {
    /// Every unarchived session of the loaded managers as a Remote list shows
    /// it, a session recorded twice under one agent session shown once.
    /// `tabIndex` says where the app shows a session's tab, if it does.
    func remoteSessionSummaries(tabIndex: @MainActor (_ sessionID: String, _ owner: SessionOwnerID) -> Int?) async -> [RemoteSessionSummary] {
        var summariesByIdentity: [String: RemoteSessionSummaryCandidate] = [:]
        var identities: [String] = []
        // Read at most once, and only when the environment lacks what a
        // checkout's block needs.
        var storedState: WorkspaceStateFile??
        func workspaceState() async -> WorkspaceStateFile? {
            if let storedState { return storedState }
            let state: WorkspaceStateFile? = if case .loaded(let state) = await workspaceStore.load() { state } else { nil }
            storedState = .some(state)
            return state
        }

        for (owner, mgr) in sessionManagers {
            let resolved = owner.worktreeID.flatMap(projectAndWorktree(withWorktreeId:))
            let worktreeSummary = if let resolved {
                await remoteWorktreeSummary(project: resolved.project, worktree: resolved.worktree)
            } else {
                RemoteWorktreeSummary?.none
            }
            var checkout: RemoteSessionCheckout?
            if case .workspaceCheckout(let id, _) = owner {
                checkout = await remoteSessionCheckout(id: id, state: workspaceState)
            }

            for row in mgr.sessionRows where !row.archived {
                var effectiveRow = row
                if let liveRemoteId = mgr.liveSession(for: row.id)?.remoteSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !liveRemoteId.isEmpty {
                    effectiveRow.remoteSessionId = liveRemoteId
                }
                let state = reportedStreamingState(of: row.id, live: mgr.runners[row.id]?.session.transcript.streamingState)
                let candidate = RemoteSessionSummaryCandidate(
                    row: effectiveRow,
                    status: state.map(RemoteSessionGateway.stateString) ?? "idle",
                    hasRunner: state != nil,
                    tabIndex: tabIndex(row.id, owner),
                    canDrive: mgr.isWriter(for: row.id),
                    projectId: resolved?.project.id,
                    worktreeId: resolved?.worktree.id,
                    worktree: worktreeSummary,
                    detail: mgr.runners[row.id].map { Self.remoteSessionDetail(of: $0.session) },
                    checkout: checkout
                )
                let identity = Self.remoteSessionListIdentity(owner: owner, row: effectiveRow)
                if let existing = summariesByIdentity[identity] {
                    summariesByIdentity[identity] = existing.merging(candidate)
                } else {
                    identities.append(identity)
                    summariesByIdentity[identity] = candidate
                }
            }
        }
        return identities.compactMap { summariesByIdentity[$0]?.summary(parents: delegatedSessionParents) }
    }

    /// Checkout `id` with its available, visible members that are listed as
    /// worktrees, as the host has it loaded or else as stored. Nil when it is
    /// unknown or archived. Members carry no git metrics: listing sessions
    /// runs no git per member.
    private func remoteSessionCheckout(id: UUID, state: () async -> WorkspaceStateFile?) async -> RemoteSessionCheckout? {
        let loaded = environment.workspaceCheckout(id: id)
        guard let checkout = if let loaded { loaded } else { await state()?.checkouts.first(where: { $0.id == id }) },
              checkout.archivedAt == nil
        else { return nil }
        let projectIDs = Set(checkout.members.map(\.projectID))
        let worktrees = projectIDs.flatMap { projects.worktrees(projectId: $0) }
        let resolved = WorkspaceMemberWorktreeResolver.resolvedWorktreeIDs(checkout: checkout, worktrees: worktrees)
        let members: [RemoteSessionCheckout.Member] = checkout.members.compactMap { member in
            guard let worktreeID = resolved[member.id],
                  let worktree = worktrees.first(where: { $0.id == worktreeID }),
                  !projects.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path),
                  let project = projects.projects.first(where: { $0.id == member.projectID })
            else { return nil }
            return RemoteSessionCheckout.Member(
                id: member.id.uuidString, name: project.name, projectId: project.id, worktreeId: worktree.id,
                worktree: remoteWorktreeSummaryWithoutMetrics(project: project, worktree: worktree)
            )
        }
        var name: String?
        if let workspaceID = checkout.workspaceID {
            name = environment.workspaceName(id: workspaceID)
            if name == nil { name = await state()?.workspaces.first { $0.id == workspaceID }?.name }
        }
        return RemoteSessionCheckout(
            id: checkout.id.uuidString, name: name ?? checkout.fallbackWorkspaceName, branch: checkout.branch,
            rootPath: Self.remoteCheckoutRootPath(checkout), members: members
        )
    }

    /// A checkout's root in the form its members' worktree paths are listed:
    /// `host:/path` for an SSH checkout, as `RemotePath.display` gives.
    @_spi(Testing) public nonisolated static func remoteCheckoutRootPath(_ checkout: WorkspaceCheckout) -> String {
        RemotePath.display(checkout.inAppWorktreePath(checkout.rootPath))
    }

    /// Live-session facts a peer's badge popover shows.
    private static func remoteSessionDetail(of session: ACPSession) -> RemoteSessionDetail {
        var detail = RemoteSessionDetail(model: session.currentModelDisplayName)
        if let usage = session.contextUsage, usage.size > 0 {
            let percent = (Double(usage.used) * 100 / Double(usage.size)).rounded()
            detail.contextPercent = Int(min(max(percent, 0), 100))
        }
        let transcript = session.transcript
        if let items = transcript.currentPlan, !items.isEmpty {
            let done = items.filter { $0.status == "completed" }.count
            detail.planCompleted = done
            detail.planTotal = items.count
            // Same step choice as the toolbar's plan pill.
            if let active = items.first(where: { $0.status == "in_progress" }) {
                detail.planStep = ACPSessionTranscriptReader.replyExcerpt(active.content, limit: 200)
            } else if done == items.count {
                detail.planStep = "All steps complete"
            } else {
                detail.planStep = (items.first(where: { $0.status == "pending" }) ?? items.last)
                    .flatMap { ACPSessionTranscriptReader.replyExcerpt($0.content, limit: 200) }
            }
        }
        if let title = transcript.pendingPermission?.params.toolCall.title, !title.isEmpty {
            detail.preview = ACPSessionTranscriptReader.replyExcerpt(title)
            detail.previewKind = detail.preview == nil ? nil : .permission
        }
        // A running or permission-gated card never shows a reply, so skip the transcript walk.
        let showsReply = transcript.streamingState != .sending && transcript.streamingState != .streaming
        if detail.preview == nil, showsReply, let reply = ACPSessionTranscriptReader.lastAgentReplyStart(transcript.messages) {
            detail.preview = reply
            detail.previewKind = .reply
        }
        return detail
    }

    private static func remoteSessionListIdentity(owner: SessionOwnerID, row: ACPSessionRow) -> String {
        if let remoteSessionId = row.remoteSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteSessionId.isEmpty {
            return "\(owner.storageKey)\u{0}\(row.agentId)\u{0}\(remoteSessionId)"
        }
        return "\(owner.storageKey)\u{0}local:\(row.id)"
    }
}

private struct RemoteSessionSummaryCandidate {
    var operationalRow: ACPSessionRow
    var displayRow: ACPSessionRow
    var status: String
    var hasRunner: Bool
    var tabIndex: Int?
    var canDrive: Bool
    let projectId: String?
    let worktreeId: String?
    let worktree: RemoteWorktreeSummary?
    var detail: RemoteSessionDetail?
    let checkout: RemoteSessionCheckout?

    init(
        row: ACPSessionRow,
        status: String,
        hasRunner: Bool,
        tabIndex: Int?,
        canDrive: Bool,
        projectId: String?,
        worktreeId: String?,
        worktree: RemoteWorktreeSummary?,
        detail: RemoteSessionDetail?,
        checkout: RemoteSessionCheckout?
    ) {
        self.operationalRow = row
        self.displayRow = row
        self.status = status
        self.hasRunner = hasRunner
        self.tabIndex = tabIndex
        self.canDrive = canDrive
        self.projectId = projectId
        self.worktreeId = worktreeId
        self.worktree = worktree
        self.detail = detail
        self.checkout = checkout
    }

    var isActive: Bool { tabIndex != nil }

    func summary(parents: [String: String]) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: operationalRow.id,
            title: displayRow.title,
            agentId: operationalRow.agentId,
            status: status,
            canDrive: canDrive,
            isActive: isActive,
            tabIndex: tabIndex,
            projectId: projectId,
            worktreeId: worktreeId,
            updatedAt: displayRow.updatedAt,
            worktree: worktree,
            parentSessionId: parents[operationalRow.id],
            detail: detail,
            checkout: checkout
        )
    }

    func merging(_ other: RemoteSessionSummaryCandidate) -> RemoteSessionSummaryCandidate {
        var merged = self
        if other.isBetterOperationalRow(than: merged) {
            merged.operationalRow = other.operationalRow
            merged.status = other.status
            merged.hasRunner = other.hasRunner
            merged.tabIndex = other.tabIndex
            merged.canDrive = other.canDrive
            merged.detail = other.detail
        }
        if Self.isBetterDisplayRow(other.displayRow, than: merged.displayRow) {
            merged.displayRow = other.displayRow
        }
        return merged
    }

    private func isBetterOperationalRow(than other: RemoteSessionSummaryCandidate) -> Bool {
        if canDrive != other.canDrive { return canDrive }
        if hasRunner != other.hasRunner { return hasRunner }
        if isActive != other.isActive { return isActive }
        if operationalRow.lastOpenedAt != other.operationalRow.lastOpenedAt {
            return operationalRow.lastOpenedAt > other.operationalRow.lastOpenedAt
        }
        return operationalRow.updatedAt > other.operationalRow.updatedAt
    }

    private static func isBetterDisplayRow(_ candidate: ACPSessionRow, than current: ACPSessionRow) -> Bool {
        let candidateScore = displayTitleScore(candidate)
        let currentScore = displayTitleScore(current)
        if candidateScore != currentScore { return candidateScore > currentScore }
        return candidate.updatedAt > current.updatedAt
    }

    private static func displayTitleScore(_ row: ACPSessionRow) -> Int {
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulTitle = !title.isEmpty && title != "New session"
        let sourceScore: Int
        switch row.titleSource {
        case .manual: sourceScore = 5
        case .provider, .generated: sourceScore = 4
        case .local: sourceScore = 3
        case .fallback: sourceScore = 2
        case .placeholder: sourceScore = 1
        }
        return (meaningfulTitle ? 100 : 0) + sourceScore
    }
}
