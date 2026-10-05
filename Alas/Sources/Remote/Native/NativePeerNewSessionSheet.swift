import SwiftUI

/// Worktree, agent and model for a new session on a peer. Reads
/// `client.newSession` live, so peer replies fill it in while it is open.
struct NativePeerNewSessionSheet: View {
    @Bindable var client: NativePeerSessions
    @State private var worktreeId: String?
    @State private var agentId: String?
    /// Nil is "Default": no model is sent and the peer uses the agent's own.
    @State private var modelId: String?
    @Environment(\.theme) private var theme

    private var request: NativePeerNewSession? { client.newSession }
    private var worktrees: [RemoteWorktreeOption] { request?.worktrees ?? [] }
    private var agents: [RemoteAgentOption] { request?.agents ?? [] }
    private var models: [RemoteModelOption] {
        agents.first { $0.id == agentId }?.models ?? []
    }

    private var canCreate: Bool {
        guard let request, !request.isLoading, request.phase != .creating,
              request.phase != .failed(NativePeerSessions.peerUnavailableMessage) else { return false }
        return worktreeId != nil && agentId != nil
    }

    var body: some View {
        DialogContainer(
            title: "New session on \(request?.peerName ?? "peer")",
            subtitle: request?.repoName,
            content: { fields },
            cancelTitle: "Cancel",
            confirmTitle: request?.phase == .creating ? "Creating…" : "Create",
            confirmStyle: .primary,
            onCancel: { client.cancelNewSession() },
            onConfirm: create,
            confirmEnabled: canCreate,
            footerHint: request?.isLoading == true ? "Loading from \(request?.peerName ?? "peer")…" : nil
        )
        .onAppear(perform: preselect)
        .onChange(of: request?.worktrees) { preselect() }
        .onChange(of: request?.agents) { preselect() }
        .onChange(of: agentId) { modelId = nil }
    }

    @ViewBuilder
    private var fields: some View {
        DialogField(label: "Worktree") {
            Picker("Worktree", selection: $worktreeId) {
                ForEach(worktrees, id: \.id) { option in
                    Text("\(option.worktreeName) — \(option.branch)").tag(Optional(option.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(worktrees.isEmpty)
        }
        DialogField(label: "Agent") {
            Picker("Agent", selection: $agentId) {
                ForEach(agents, id: \.id) { agent in
                    Text(agent.name).tag(Optional(agent.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(agents.isEmpty)
        }
        DialogField(label: "Model") {
            Picker("Model", selection: $modelId) {
                Text("Default").tag(String?.none)
                ForEach(models, id: \.id) { model in
                    Text(model.name).tag(Optional(model.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        if let hint = emptyHint {
            Text(hint).font(.system(size: 11.5)).foregroundColor(theme.color("fg-muted"))
        }
        if case .failed(let message) = request?.phase {
            Text(message).font(.system(size: 11.5)).foregroundColor(theme.color("del"))
        }
    }

    private var emptyHint: String? {
        guard let request, !request.isLoading else { return nil }
        if worktrees.isEmpty { return "No worktrees in \(request.repoName) on \(request.peerName)." }
        if agents.isEmpty { return "No agents are enabled on \(request.peerName)." }
        return nil
    }

    private func preselect() {
        if worktreeId == nil || !worktrees.contains(where: { $0.id == worktreeId }) {
            worktreeId = NativePeerNewSession.preselectedWorktreeId(
                in: worktrees, selectedWorktreeId: client.newSessionDefaultWorktreeId
            )
        }
        if agentId == nil || !agents.contains(where: { $0.id == agentId }) {
            agentId = NativePeerNewSession.preselectedAgentId(in: agents)
        }
    }

    private func create() {
        guard canCreate, let worktreeId, let agentId else { return }
        client.createNewSession(worktreeId: worktreeId, agentId: agentId, modelId: modelId)
    }
}
