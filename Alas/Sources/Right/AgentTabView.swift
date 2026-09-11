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
    let actions: AgentSidebarActions
    var controllableSessionIDs: Set<ACPSession.ID> = []
    @Binding var followUps: [ACPSession.ID: AgentSidebarFollowUpDraft]
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if rollup.rows.isEmpty {
                    Text("No agent sessions or terminals in this worktree.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("fg-muted"))
                        .padding(16)
                } else {
                    section(title: "Active", rows: rollup.active)
                    section(title: "History", rows: rollup.history)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section(title: String, rows: [AgentSidebarRow]) -> some View {
        if !rows.isEmpty {
            HStack {
                Text(title)
                Spacer()
                Text("\(rows.count)").monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ForEach(rows) { row in
                AgentSidebarRowView(
                    row: row,
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

private struct AgentSidebarRowView: View {
    let row: AgentSidebarRow
    let actions: AgentSidebarActions
    let canControl: Bool
    let delivery: AgentSidebarFollowUpDelivery?
    @Binding var draft: String
    @State private var isEditing = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { actions.onFocus(row.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(row.state.label)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("fg-muted"))
                    }
                    HStack(spacing: 5) {
                        Text(row.agentID)
                        if let model = row.model { Text("· \(model)") }
                        if row.createdAt != .distantPast {
                            Text("·")
                            Text(row.createdAt, style: .relative)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(1)
                    if let host = row.host {
                        Label(host, systemImage: "network")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("fg-muted"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Focus \(row.title)")

            if let plan = row.plan {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tasks \(plan.completed)/\(plan.total)")
                        .font(.system(size: 10, weight: .medium))
                    if let step = plan.currentStep {
                        Text(step).font(.system(size: 10)).lineLimit(2)
                    }
                    ProgressView(value: Double(plan.completed), total: Double(plan.total))
                }
                .foregroundStyle(theme.color("fg-muted"))
            }
            if row.contextUsage != nil || canControl {
                HStack(spacing: 8) {
                    ACPContextUsageButton(usage: row.contextUsage, modelName: row.model)
                    Spacer(minLength: 0)
                    if let sessionID = row.sessionID, row.isLiveACP, canControl {
                        if row.state == .running || row.state == .awaitingInput || row.state == .permissionRequest {
                            Button("Interrupt") { actions.onInterrupt(sessionID) }
                        }
                        Button("Follow up") { isEditing.toggle() }
                        if let onDelegate = actions.onDelegate {
                            Button("Delegate") { onDelegate(sessionID) }
                        }
                    }
                }
                .controlSize(.small)
            }
            if let sessionID = row.sessionID,
               isEditing || !draft.isEmpty || delivery == .failed {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Follow-up message", text: $draft, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .disabled(delivery == .sending)
                    HStack {
                        if delivery == .failed {
                            Text("Could not send. Your message is kept here.")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                        Spacer(minLength: 0)
                        Button(delivery == .sending ? "Sending…" : "Send") {
                            actions.onFollowUp(sessionID, draft)
                        }
                        .disabled(!canControl || delivery == .sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .controlSize(.small)
                    }
                }
            }
        }
        .foregroundStyle(theme.color("fg"))
        .padding(12)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: delivery) {
            if delivery == .sent {
                isEditing = false
            }
        }
    }
}

private extension AgentSidebarRow {
    var sessionID: ACPSession.ID? {
        guard case .acp(let sessionID) = id else { return nil }
        return sessionID
    }
}

private extension AgentSidebarState {
    var label: String {
        switch self {
        case .running: "Running"
        case .awaitingInput: "Awaiting input"
        case .permissionRequest: "Permission requested"
        case .idle: "Idle"
        case .detached: "Detached"
        case .unknown: "Unknown"
        }
    }
}
