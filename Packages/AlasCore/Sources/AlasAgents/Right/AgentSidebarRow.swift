import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum AgentSidebarState: Equatable, Sendable {
    case running
    case awaitingInput
    case permissionRequest
    case idle
    /// The last turn failed; the session is stopped until the next prompt.
    case failed
    case detached
    case unknown
}

public struct AgentSidebarPlanProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let currentStep: String?

    public init(completed: Int, total: Int, currentStep: String?) {
        self.completed = completed
        self.total = total
        self.currentStep = currentStep
    }
}

/// A delegated family is at most two levels deep: `ACPSessionOrchestrationPolicy`
/// refuses `authorizeCreate` for a session that already has a parent, so a child
/// can never delegate further and the sidebar never indents more than once.
public enum AgentSidebarDelegation: Equatable, Sendable {
    /// Carries how many of this session's children are present in the rollup,
    /// which may be fewer than it ever spawned once archived rows drop out.
    case parent(childCount: Int)
    /// `isNested` is false when the parent is missing from this worktree's
    /// rollup or sits in the other section, in which case the child renders at
    /// top level with a caption instead of under a connector.
    case child(parentID: ACPSession.ID, parentTitle: String?, isNested: Bool)

    public var isNestedChild: Bool {
        guard case .child(_, _, let isNested) = self else { return false }
        return isNested
    }
}

/// One of a live session's own (native) subagents. These hang off their
/// parent row rather than being rows themselves, so counts and plugin
/// snapshots built from `AgentSidebarRollup.rows` keep meaning sessions.
public struct AgentSidebarSubagent: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let task: String?
    public let state: ACPSubagentState
    public let canCancel: Bool
    public let startedAt: Date
    public let finishedAt: Date?

    public init(id: String, name: String, task: String?, state: ACPSubagentState, canCancel: Bool, startedAt: Date, finishedAt: Date?) {
        self.id = id
        self.name = name
        self.task = task
        self.state = state
        self.canCancel = canCancel
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct AgentSidebarRow: Identifiable, Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case acp(ACPSession.ID)
        case terminal(tabID: TabID, sessionID: String)
    }

    public let id: ID
    public let agentID: String
    public let title: String
    public let model: String?
    public let state: AgentSidebarState
    public let contextUsage: ACPUsageInfo?
    /// Per-model quota breakdown, mirroring `ACPSession.lastTurnQuota` /
    /// `sessionQuotaTotal`. Threaded through so the sidebar's context-usage
    /// popover shows the same data as the composer's — including for
    /// quota-only adapters that never send `usage_update`.
    public let lastTurnQuota: ACPPromptQuota?
    public let sessionQuotaTotal: ACPPromptQuota?
    public let plan: AgentSidebarPlanProgress?
    public let host: String?
    /// The timestamp shown in the metadata caption: creation time for active
    /// rows, last-activity time for history rows (`.distantPast` for
    /// terminal rows, which hide the segment entirely).
    public let activityAt: Date
    public let isLiveACP: Bool
    public var delegation: AgentSidebarDelegation?
    public var subagents: [AgentSidebarSubagent] = []

    public static func acp(
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

    public static func terminal(
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

    public init(id: ID, agentID: String, title: String, model: String?, state: AgentSidebarState, contextUsage: ACPUsageInfo?, lastTurnQuota: ACPPromptQuota?, sessionQuotaTotal: ACPPromptQuota?, plan: AgentSidebarPlanProgress?, host: String?, activityAt: Date, isLiveACP: Bool, delegation: AgentSidebarDelegation? = nil, subagents: [AgentSidebarSubagent] = []) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.model = model
        self.state = state
        self.contextUsage = contextUsage
        self.lastTurnQuota = lastTurnQuota
        self.sessionQuotaTotal = sessionQuotaTotal
        self.plan = plan
        self.host = host
        self.activityAt = activityAt
        self.isLiveACP = isLiveACP
        self.delegation = delegation
        self.subagents = subagents
    }
}
