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
