import SwiftUI
import Combine

struct AgentSidebarActions {
    let onFocus: (AgentSidebarRowID) -> Void
    let onInterrupt: (ACPSession.ID) -> Void
    /// Nil where the rail cannot send follow-ups; hides the Follow up button.
    let onFollowUp: ((ACPSession.ID, String) -> Void)?
    let onDelegate: ((ACPSession.ID) -> Void)?
    /// Parent session id, subagent session id. Nil where the rail cannot cancel.
    var onCancelSubagent: ((ACPSession.ID, String) -> Void)? = nil
    /// Asks a session's adapter what fills its context window. Nil where the
    /// rail cannot reach the adapter.
    var loadContextBreakdown: ((ACPSession.ID) async -> ACPContextBreakdown?)? = nil
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

/// What the user unfolded in the rail, by session.
struct AgentSidebarDisclosure: Equatable {
    var contextDetails: Set<ACPSession.ID> = []
    var doneSubagents: Set<ACPSession.ID> = []
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

    var disclosure: Binding<AgentSidebarDisclosure> {
        Binding(
            get: { state.agentSidebarDisclosure[worktree.id, default: .init()] },
            set: { state.agentSidebarDisclosure[worktree.id] = $0 }
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
                onDelegate: nil,
                onCancelSubagent: { sessionID, subagentSessionId in
                    Task { await manager.cancelSubagent(for: sessionID, subagentSessionId: subagentSessionId) }
                },
                loadContextBreakdown: { sessionID in
                    await manager.runners[sessionID]?.contextBreakdown()
                }
            ),
            controllableSessionIDs: Set(manager.sessions.keys.filter { manager.isWriter(for: $0) }),
            followUps: followUps,
            disclosure: disclosure
        )
        .onReceive(sessionUpdates) { _ in sessionRevision &+= 1 }
        .task { await manager.refreshRecentNow() }
    }

    private var sessionUpdates: AnyPublisher<Void, Never> {
        Publishers.MergeMany(manager.sessions.values.flatMap { session in
            [session.objectWillChange.eraseToAnyPublisher(),
             session.transcript.objectWillChange.eraseToAnyPublisher(),
             session.transcript.streamingTicks.eraseToAnyPublisher()]
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
    @Binding var disclosure: AgentSidebarDisclosure
    var disabledReason: (AgentSidebarRow) -> String? = { _ in nil }

    @Environment(\.designScale) private var scale

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: scale.space[2]) {
                if rollup.rows.isEmpty {
                    AgentSidebarEmptyState()
                } else {
                    section(title: "Active", rows: rollup.active)
                    section(title: "History", rows: rollup.history)
                }
            }
            .padding(.horizontal, scale.space[2])
            .padding(.vertical, scale.space[3])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section(title: String, rows: [AgentSidebarRow]) -> some View {
        if !rows.isEmpty {
            AgentSidebarSectionHeader(title: title, count: rows.count)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let isNested = row.delegation?.isNestedChild == true
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
                    ),
                    showsContextDetails: isUnfolded(\.contextDetails, for: row),
                    disabledReason: disabledReason(row)
                )
                .padding(.leading, isNested ? AgentSidebarDelegationConnector.gutter : 0)
                .background(alignment: .topLeading) {
                    if isNested {
                        AgentSidebarDelegationConnector(
                            continuesBelow: hasSiblingBelow(rows, after: index)
                        )
                    }
                }
                subagentRows(of: row, isNested: isNested, siblingBelow: hasSiblingBelow(rows, after: index))
            }
        }
    }

    /// A row's own subagents sit one level under it. Under a nested child that
    /// is a second level, so the child's rail is carried past them to the
    /// next nested sibling. Finished ones fold into one line after the rest,
    /// so the ones still working stay next to their parent.
    private func subagentRows(of row: AgentSidebarRow, isNested: Bool, siblingBelow: Bool) -> some View {
        let done = row.subagents.filter(\.isSettled)
        let showsDone = isUnfolded(\.doneSubagents, for: row)
        var entries = row.subagents.filter { !$0.isSettled }.map(SubagentEntry.card)
        if !done.isEmpty {
            entries.append(.doneGroup(done))
            if showsDone.wrappedValue { entries += done.map(SubagentEntry.card) }
        }
        return ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            let isLast = index + 1 == entries.count
            Group {
                switch entry {
                case .card(let subagent):
                    AgentSidebarSubagentRowView(
                        subagent: subagent,
                        onFocus: { actions.onFocus(row.id) },
                        onCancel: cancelAction(row: row, subagent: subagent)
                    )
                case .doneGroup(let subagents):
                    AgentSidebarDoneSubagentsRow(subagents: subagents, isExpanded: showsDone)
                }
            }
            .padding(.leading, AgentSidebarDelegationConnector.gutter)
            .background(alignment: .topLeading) {
                AgentSidebarDelegationConnector(
                    continuesBelow: !isLast || (!isNested && siblingBelow), elbowY: entry.elbowY)
            }
            .padding(.leading, isNested ? AgentSidebarDelegationConnector.gutter : 0)
            .background(alignment: .topLeading) {
                if isNested && siblingBelow {
                    AgentSidebarDelegationConnector(continuesBelow: true, hasElbow: false)
                }
            }
        }
    }

    private enum SubagentEntry: Identifiable {
        case card(AgentSidebarSubagent)
        case doneGroup([AgentSidebarSubagent])

        var id: String {
            switch self {
            case .card(let subagent): subagent.id
            case .doneGroup: "done-group"
            }
        }

        /// Where the connector's elbow meets the entry: a card's title line,
        /// or the middle of the one-line group.
        var elbowY: CGFloat {
            switch self {
            case .card: AgentSidebarDelegationConnector.cardElbowY
            case .doneGroup: AgentSidebarDoneSubagentsRow.height / 2
            }
        }
    }

    private func isUnfolded(
        _ sessions: WritableKeyPath<AgentSidebarDisclosure, Set<ACPSession.ID>>, for row: AgentSidebarRow
    ) -> Binding<Bool> {
        Binding(
            get: { row.sessionID.map { disclosure[keyPath: sessions].contains($0) } ?? false },
            set: { unfolded in
                guard let sessionID = row.sessionID else { return }
                if unfolded {
                    disclosure[keyPath: sessions].insert(sessionID)
                } else {
                    disclosure[keyPath: sessions].remove(sessionID)
                }
            }
        )
    }

    private func cancelAction(row: AgentSidebarRow, subagent: AgentSidebarSubagent) -> (() -> Void)? {
        guard subagent.canCancel,
              let sessionID = row.sessionID,
              controllableSessionIDs.contains(sessionID),
              let onCancelSubagent = actions.onCancelSubagent
        else { return nil }
        return { onCancelSubagent(sessionID, subagent.id) }
    }

    /// The builder emits a parent's nested children consecutively, so the rail
    /// only has to continue when the very next row is nested too.
    private func hasSiblingBelow(_ rows: [AgentSidebarRow], after index: Int) -> Bool {
        let next = index + 1
        guard next < rows.count else { return false }
        return rows[next].delegation?.isNestedChild == true
    }
}
