import Foundation

enum AgentSidebarState: Equatable {
    case running
    case awaitingInput
    case permissionRequest
    case idle
    case detached
    case unknown
}

struct AgentSidebarPlanProgress: Equatable {
    let completed: Int
    let total: Int
    let currentStep: String?
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
    let plan: AgentSidebarPlanProgress?
    let host: String?
    let createdAt: Date
    let isLiveACP: Bool

    static func acp(
        id: ACPSession.ID,
        agentID: String,
        title: String,
        model: String?,
        state: AgentSidebarState,
        contextUsage: ACPUsageInfo? = nil,
        plan: AgentSidebarPlanProgress? = nil,
        host: String? = nil,
        createdAt: Date,
        isLive: Bool
    ) -> Self {
        Self(
            id: .acp(id),
            agentID: agentID,
            title: title,
            model: model,
            state: state,
            contextUsage: contextUsage,
            plan: plan,
            host: host,
            createdAt: createdAt,
            isLiveACP: isLive
        )
    }

    static func terminal(
        tabID: TabID,
        sessionID: String,
        agentID: String,
        title: String,
        state: AgentSidebarState
    ) -> Self {
        Self(
            id: .terminal(tabID: tabID, sessionID: sessionID),
            agentID: agentID,
            title: title,
            model: nil,
            state: state,
            contextUsage: nil,
            plan: nil,
            host: nil,
            createdAt: .distantPast,
            isLiveACP: false
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
    }

    static func build(_ input: Input) -> AgentSidebarRollup {
        let liveSessions = input.liveACP.filter { $0.worktreeId == input.worktreeID }
        let liveIDs = Set(liveSessions.map(\.id))

        let liveRows = liveSessions.map { liveRow(for: $0, remoteHost: input.remoteHost) }
        let persistedRows = input.persistedACP
            .filter { !liveIDs.contains($0.id) }
            .map(persistedRow)
        let terminalRows = input.terminalTabs.map { terminalRow(for: $0, activity: input.harnessActivity) }

        return AgentSidebarRollup(rows: liveRows + persistedRows + terminalRows)
    }

    private static func liveRow(for session: ACPSession, remoteHost: String?) -> AgentSidebarRow {
        .acp(
            id: session.id,
            agentID: session.agentId,
            title: session.title,
            model: session.currentModel,
            state: state(for: session),
            contextUsage: session.contextUsage,
            plan: planProgress(for: session.transcript.currentPlan),
            host: remoteHost,
            createdAt: session.createdAt,
            isLive: true
        )
    }

    private static func persistedRow(_ row: ACPSessionRow) -> AgentSidebarRow {
        .acp(
            id: row.id,
            agentID: row.agentId,
            title: row.title,
            model: row.currentModel,
            state: .detached,
            createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAt)),
            isLive: false
        )
    }

    private static func terminalRow(
        for tab: TerminalTabState,
        activity: [String: HarnessService.HarnessActivityState]
    ) -> AgentSidebarRow {
        let leaf = tab.root.find(leafId: tab.focusedLeafId)?.leaf ?? tab.root.firstLeaf()
        let hook = activity[leaf.sessionId]
        return .terminal(
            tabID: tab.id,
            sessionID: leaf.sessionId,
            agentID: hook?.agent.rawValue ?? "terminal",
            title: tab.title,
            state: hook.map { state(for: $0.state) } ?? .unknown
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
                return .idle
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
        case .idle:
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
