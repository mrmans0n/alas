import Foundation

enum AgentSidebarState: Equatable {
    case running
    case awaitingInput
    case permissionRequest
    case idle
    /// The last turn failed; the session is stopped until the next prompt.
    case failed
    case detached
    case unknown
}

struct AgentSidebarPlanProgress: Equatable {
    let completed: Int
    let total: Int
    let currentStep: String?
}

/// A delegated family is at most two levels deep: `ACPSessionOrchestrationPolicy`
/// refuses `authorizeCreate` for a session that already has a parent, so a child
/// can never delegate further and the sidebar never indents more than once.
enum AgentSidebarDelegation: Equatable {
    /// Carries how many of this session's children are present in the rollup,
    /// which may be fewer than it ever spawned once archived rows drop out.
    case parent(childCount: Int)
    /// `isNested` is false when the parent is missing from this worktree's
    /// rollup or sits in the other section, in which case the child renders at
    /// top level with a caption instead of under a connector.
    case child(parentID: ACPSession.ID, parentTitle: String?, isNested: Bool)

    var isNestedChild: Bool {
        guard case .child(_, _, let isNested) = self else { return false }
        return isNested
    }
}

/// One of a live session's own (native) subagents. These hang off their
/// parent row rather than being rows themselves, so counts and plugin
/// snapshots built from `AgentSidebarRollup.rows` keep meaning sessions.
struct AgentSidebarSubagent: Identifiable, Equatable {
    let id: String
    let name: String
    let task: String?
    let state: ACPSubagentState
    let canCancel: Bool
    let startedAt: Date
    let finishedAt: Date?
}

struct AgentSidebarRow: Identifiable, Equatable {
    enum ID: Hashable {
        case acp(ACPSession.ID)
        case terminal(tabID: TabID, sessionID: String)
    }

    let id: ID
    let agentID: String
    let title: String
    let model: String?
    let state: AgentSidebarState
    let contextUsage: ACPUsageInfo?
    /// Per-model quota breakdown, mirroring `ACPSession.lastTurnQuota` /
    /// `sessionQuotaTotal`. Threaded through so the sidebar's context-usage
    /// popover shows the same data as the composer's — including for
    /// quota-only adapters that never send `usage_update`.
    let lastTurnQuota: ACPPromptQuota?
    let sessionQuotaTotal: ACPPromptQuota?
    let plan: AgentSidebarPlanProgress?
    let host: String?
    /// The timestamp shown in the metadata caption: creation time for active
    /// rows, last-activity time for history rows (`.distantPast` for
    /// terminal rows, which hide the segment entirely).
    let activityAt: Date
    let isLiveACP: Bool
    var delegation: AgentSidebarDelegation?
    var subagents: [AgentSidebarSubagent] = []

    static func acp(
        id: ACPSession.ID,
        agentID: String,
        title: String,
        model: String?,
        state: AgentSidebarState,
        contextUsage: ACPUsageInfo? = nil,
        lastTurnQuota: ACPPromptQuota? = nil,
        sessionQuotaTotal: ACPPromptQuota? = nil,
        plan: AgentSidebarPlanProgress? = nil,
        host: String? = nil,
        activityAt: Date,
        isLive: Bool,
        delegation: AgentSidebarDelegation? = nil
    ) -> Self {
        Self(
            id: .acp(id),
            agentID: agentID,
            title: title,
            model: model,
            state: state,
            contextUsage: contextUsage,
            lastTurnQuota: lastTurnQuota,
            sessionQuotaTotal: sessionQuotaTotal,
            plan: plan,
            host: host,
            activityAt: activityAt,
            isLiveACP: isLive,
            delegation: delegation
        )
    }

    static func terminal(
        tabID: TabID,
        sessionID: String,
        agentID: String,
        title: String,
        state: AgentSidebarState,
        host: String? = nil
    ) -> Self {
        Self(
            id: .terminal(tabID: tabID, sessionID: sessionID),
            agentID: agentID,
            title: title,
            model: nil,
            state: state,
            contextUsage: nil,
            lastTurnQuota: nil,
            sessionQuotaTotal: nil,
            plan: nil,
            host: host,
            activityAt: .distantPast,
            isLiveACP: false,
            delegation: nil
        )
    }
}

typealias AgentSidebarRowID = AgentSidebarRow.ID

struct AgentSidebarRollup: Equatable {
    let rows: [AgentSidebarRow]

    var active: [AgentSidebarRow] {
        rows.filter { $0.state != .detached }
    }

    var history: [AgentSidebarRow] {
        rows.filter { $0.state == .detached }
    }
}

@MainActor
struct AgentSidebarRollupBuilder {
    struct Input {
        let worktreeID: String
        let persistedACP: [ACPSessionRow]
        let liveACP: [ACPSession]
        let terminalTabs: [TerminalTabState]
        let harnessActivity: [String: HarnessService.HarnessActivityState]
        let remoteHost: String?
        /// Child session id to parent session id, spanning every delegation the
        /// app knows about. Ids outside this rollup are ignored.
        var delegatedParents: [String: String] = [:]
    }

    static func build(_ input: Input) -> AgentSidebarRollup {
        let liveSessions = input.liveACP.filter { $0.worktreeId == input.worktreeID }
        let liveIDs = Set(liveSessions.map(\.id))
        let persistedByID = Dictionary(uniqueKeysWithValues: input.persistedACP.map { ($0.id, $0) })

        let liveRows = liveSessions.map {
            liveRow(for: $0, remoteHost: input.remoteHost, persisted: persistedByID[$0.id])
        }
        let persistedRows = input.persistedACP
            .filter { !liveIDs.contains($0.id) }
            .map { persistedRow($0, remoteHost: input.remoteHost) }
        let terminalRowsList = input.terminalTabs.flatMap {
            terminalRows(for: $0, activity: input.harnessActivity, remoteHost: input.remoteHost)
        }

        let acpRows = nestDelegations(in: liveRows + persistedRows, parents: input.delegatedParents)
        return AgentSidebarRollup(rows: acpRows + terminalRowsList)
    }

    /// A peer worktree's sessions: open tabs in tab order, then history as
    /// the peer listed it.
    static func peer(_ sessions: [RemoteSessionSummary]) -> AgentSidebarRollup {
        let active = sessions.filter(\.isActive).sorted { ($0.tabIndex ?? .max) < ($1.tabIndex ?? .max) }
        let rows = (active + sessions.filter { !$0.isActive }).map { session in
            AgentSidebarRow.acp(
                id: session.id,
                agentID: session.agentId,
                title: session.title,
                model: nil,
                state: session.isActive ? peerState(session.status) : .detached,
                // Open rows caption their creation time, which peers don't send.
                activityAt: session.isActive
                    ? .distantPast
                    : Date(timeIntervalSince1970: TimeInterval(session.updatedAt)),
                isLive: session.isActive
            )
        }
        return AgentSidebarRollup(rows: rows)
    }

    private static func peerState(_ status: String) -> AgentSidebarState {
        switch status {
        case "streaming": .running
        case "awaitingInput": .awaitingInput
        case "awaitingPermission": .permissionRequest
        case "idle": .idle
        default: .unknown
        }
    }

    /// Annotates ACP rows with their delegation relationship and moves nested
    /// children directly behind their parent, leaving every other row in place.
    private static func nestDelegations(
        in rows: [AgentSidebarRow],
        parents: [String: String]
    ) -> [AgentSidebarRow] {
        guard !parents.isEmpty else { return rows }

        var isActive: [ACPSession.ID: Bool] = [:]
        var titles: [ACPSession.ID: String] = [:]
        for row in rows {
            guard let id = row.sessionID else { continue }
            isActive[id] = row.state != .detached
            titles[id] = row.title
        }
        // Only links whose parent is also on screen can be drawn as a tree.
        let presentParents = rows.reduce(into: [ACPSession.ID: ACPSession.ID]()) { links, row in
            guard let id = row.sessionID,
                  let parentID = parents[id],
                  parentID != id,
                  isActive[parentID] != nil
            else { return }
            links[id] = parentID
        }

        var annotations: [ACPSession.ID: AgentSidebarDelegation] = [:]
        var nestedChildren: [ACPSession.ID: [ACPSession.ID]] = [:]
        var childCounts: [ACPSession.ID: Int] = [:]

        for row in rows {
            guard let id = row.sessionID, let parentID = parents[id] else { continue }
            guard presentParents[id] != nil else {
                annotations[id] = .child(parentID: parentID, parentTitle: nil, isNested: false)
                continue
            }
            childCounts[parentID, default: 0] += 1
            // A parent that is itself a child would imply a third level, which
            // the orchestration policy forbids; refusing to nest there also
            // keeps a corrupt parent cycle from dropping rows below.
            let nested = presentParents[parentID] == nil && isActive[parentID] == isActive[id]
            annotations[id] = .child(parentID: parentID, parentTitle: titles[parentID], isNested: nested)
            if nested { nestedChildren[parentID, default: []].append(id) }
        }
        for (parentID, count) in childCounts where annotations[parentID] == nil {
            annotations[parentID] = .parent(childCount: count)
        }

        let rowsByID = rows.reduce(into: [ACPSession.ID: AgentSidebarRow]()) { result, row in
            if let id = row.sessionID { result[id] = row }
        }
        func annotated(_ row: AgentSidebarRow) -> AgentSidebarRow {
            var copy = row
            copy.delegation = row.sessionID.flatMap { annotations[$0] }
            return copy
        }

        var ordered: [AgentSidebarRow] = []
        ordered.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row.sessionID else {
                ordered.append(row)
                continue
            }
            // Nested children are emitted by their parent's iteration instead.
            if annotations[id]?.isNestedChild == true { continue }
            ordered.append(annotated(row))
            for childID in nestedChildren[id] ?? [] {
                guard let childRow = rowsByID[childID] else { continue }
                ordered.append(annotated(childRow))
            }
        }
        return ordered
    }

    private static func liveRow(
        for session: ACPSession,
        remoteHost: String?,
        persisted: ACPSessionRow?
    ) -> AgentSidebarRow {
        let resolvedState = state(for: session)
        // A session that disconnects renders in History like any persisted
        // row, so it needs the same "last activity" semantics; its own
        // creation time would otherwise misdescribe the accessibility label.
        let activityAt: Date
        if resolvedState == .detached, let updatedAt = persisted?.updatedAt {
            activityAt = Date(timeIntervalSince1970: TimeInterval(updatedAt))
        } else {
            activityAt = session.createdAt
        }
        var row = AgentSidebarRow.acp(
            id: session.id,
            agentID: session.agentId,
            title: session.title,
            model: modelDisplay(currentModel: session.currentModel, availableModels: session.availableModels),
            state: resolvedState,
            contextUsage: session.contextUsage,
            lastTurnQuota: session.lastTurnQuota,
            sessionQuotaTotal: session.sessionQuotaTotal,
            plan: planProgress(for: session.transcript.currentPlan),
            host: remoteHost,
            activityAt: activityAt,
            isLive: true
        )
        // A session in History has ended, and so has everything it spawned.
        if resolvedState != .detached {
            row.subagents = session.orderedSubagents.map { run in
                AgentSidebarSubagent(
                    id: run.subagentSessionId,
                    name: run.displayName,
                    task: run.task,
                    state: run.state,
                    canCancel: ACPSubagentRowPolicy.showsCancel(state: run.state, capabilities: run.capabilities),
                    startedAt: run.startedAt,
                    finishedAt: run.finishedAt
                )
            }
        }
        return row
    }

    private static func persistedRow(_ row: ACPSessionRow, remoteHost: String?) -> AgentSidebarRow {
        .acp(
            id: row.id,
            agentID: row.agentId,
            title: row.title,
            // Persisted rows never carry the adapter's model list, so this
            // always falls through to the heuristic shortener.
            model: modelDisplay(currentModel: row.currentModel, availableModels: []),
            state: .detached,
            host: remoteHost,
            activityAt: Date(timeIntervalSince1970: TimeInterval(row.updatedAt)),
            isLive: false
        )
    }

    /// Prefers the adapter's own declared name for the active model — it
    /// already knows composite/provider-specific shapes (e.g. Cursor's
    /// "provider:gpt-5-fable-5" advertised as "Fable 5") that no
    /// id-shortening heuristic can reliably reconstruct — falling back to
    /// `AgentSidebarModelDisplay.shortName` only when the id isn't found in
    /// the advertised list (unknown/stale id, or no list yet).
    private static func modelDisplay(currentModel: String?, availableModels: [ACPModelInfo]) -> String? {
        guard let currentModel else { return nil }
        if let declared = availableModels.first(where: { $0.id == currentModel })?.name {
            return declared
        }
        return AgentSidebarModelDisplay.shortName(for: currentModel)
    }

    private static func terminalRows(
        for tab: TerminalTabState,
        activity: [String: HarnessService.HarnessActivityState],
        remoteHost: String?
    ) -> [AgentSidebarRow] {
        tab.root.leaves()
            .sorted { lhs, rhs in
                if lhs.id == tab.focusedLeafId { return true }
                if rhs.id == tab.focusedLeafId { return false }
                return lhs.id < rhs.id
            }
            .map { terminalRow(for: tab, leaf: $0, activity: activity, remoteHost: remoteHost) }
    }

    private static func terminalRow(
        for tab: TerminalTabState,
        leaf: PaneLeaf,
        activity: [String: HarnessService.HarnessActivityState],
        remoteHost: String?
    ) -> AgentSidebarRow {
        let hook = activity[leaf.sessionId]
        return .terminal(
            tabID: tab.id,
            sessionID: leaf.sessionId,
            agentID: hook?.agent.rawValue ?? "terminal",
            title: tab.title,
            state: hook.map { state(for: $0.state) } ?? .unknown,
            host: remoteHost
        )
    }

    private static func state(for session: ACPSession) -> AgentSidebarState {
        switch session.transcript.streamingState {
        case .sending, .streaming:
            return .running
        case .awaitingInput:
            return .awaitingInput
        case .awaitingPermission:
            return .permissionRequest
        case .idle:
            switch session.agentState {
            case .spawning:
                return .running
            case .idle, .ready:
                return session.turnFailure == nil ? .idle : .failed
            case .disconnected:
                return .detached
            case .failed:
                return .unknown
            }
        }
    }

    private static func state(for activity: ActivityState) -> AgentSidebarState {
        switch activity {
        case .busy:
            return .running
        case .awaitingInput:
            return .awaitingInput
        case .permissionRequest:
            return .permissionRequest
        case .failed:
            return .failed
        case .idle, .limited:
            return .idle
        }
    }

    private static func planProgress(for plan: [ACPMessage.PlanItem]?) -> AgentSidebarPlanProgress? {
        guard let state = ACPPlanPillState(items: plan) else { return nil }
        return AgentSidebarPlanProgress(
            completed: state.done,
            total: state.total,
            currentStep: state.currentStep
        )
    }
}
