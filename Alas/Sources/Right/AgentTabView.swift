import SwiftUI
import Combine

struct AgentSidebarActions {
    let onFocus: (AgentSidebarRowID) -> Void
    let onInterrupt: (ACPSession.ID) -> Void
    let onFollowUp: (ACPSession.ID, String) -> Void
    let onDelegate: ((ACPSession.ID) -> Void)?
}

enum AgentSidebarFollowUpDelivery: Equatable {
    case sending
    case sent
    case failed
}

struct AgentSidebarFollowUpDraft: Equatable {
    var text = ""
    var delivery: AgentSidebarFollowUpDelivery?
}

/// Observes the manager and its nested Combine models for this worktree only.
struct AgentWorktreeTabView: View {
    let state: AppState
    let worktree: Worktree
    @ObservedObject var manager: ACPSessionManager
    @State private var sessionRevision = 0

    var followUps: Binding<[ACPSession.ID: AgentSidebarFollowUpDraft]> {
        Binding(
            get: { state.agentSidebarFollowUps[worktree.id, default: [:]] },
            set: { state.agentSidebarFollowUps[worktree.id] = $0 }
        )
    }

    var body: some View {
        let _ = sessionRevision
        AgentTabView(
            rollup: state.agentSidebarRollup(for: worktree),
            agentLookup: { agentID in
                state.agent(id: agentID == AgentKind.cursor.rawValue ? "cursor-agent" : agentID)
            },
            actions: AgentSidebarActions(
                onFocus: { rowID in
                    Task { await state.focusAgentSidebarRow(rowID, in: worktree) }
                },
                onInterrupt: { sessionID in
                    Task { await state.stop(for: sessionID, worktreeID: worktree.id) }
                },
                onFollowUp: { sessionID, text in
                    state.sendAgentSidebarFollowUp(for: sessionID, worktreeID: worktree.id, text: text)
                },
                onDelegate: nil
            ),
            controllableSessionIDs: Set(manager.sessions.keys.filter { manager.isWriter(for: $0) }),
            followUps: followUps
        )
        .onReceive(sessionUpdates) { _ in sessionRevision &+= 1 }
        .task { await manager.refreshRecentNow() }
    }

    private var sessionUpdates: AnyPublisher<Void, Never> {
        Publishers.MergeMany(manager.sessions.values.flatMap { session in
            [session.objectWillChange.eraseToAnyPublisher(),
             session.transcript.objectWillChange.eraseToAnyPublisher()]
        })
        // Published notifications arrive before mutation; deliver after the
        // update and coalesce streaming events into one sidebar refresh.
        .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }
}

struct AgentTabView: View {
    let rollup: AgentSidebarRollup
    let agentLookup: (String) -> AgentDefinition?
    let actions: AgentSidebarActions
    var controllableSessionIDs: Set<ACPSession.ID> = []
    @Binding var followUps: [ACPSession.ID: AgentSidebarFollowUpDraft]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if rollup.rows.isEmpty {
                    AgentSidebarEmptyState()
                } else {
                    section(title: "Active", rows: rollup.active)
                    section(title: "History", rows: rollup.history)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section(title: String, rows: [AgentSidebarRow]) -> some View {
        if !rows.isEmpty {
            AgentSidebarSectionHeader(title: title, count: rows.count)
            ForEach(rows) { row in
                AgentSidebarRowView(
                    row: row,
                    agent: agentLookup(row.agentID),
                    actions: actions,
                    canControl: row.sessionID.map { controllableSessionIDs.contains($0) } ?? false,
                    delivery: row.sessionID.flatMap { followUps[$0]?.delivery },
                    draft: Binding(
                        get: { row.sessionID.flatMap { followUps[$0]?.text } ?? "" },
                        set: { text in
                            if let sessionID = row.sessionID {
                                followUps[sessionID, default: .init()].text = text
                            }
                        }
                    )
                )
            }
        }
    }
}
