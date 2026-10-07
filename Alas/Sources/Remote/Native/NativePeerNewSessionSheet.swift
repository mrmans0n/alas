import AppKit
import SwiftUI

/// Worktree, agent, model and effort for a new session on a peer. Reads
/// `client.newSession` live, so peer replies fill it in while it is open.
/// The worktree is either an existing one or a new one the peer creates.
struct NativePeerNewSessionSheet: View {
    @Bindable var client: NativePeerSessions
    /// Nil until the peer's worktrees arrive and pick the default.
    @State private var mode: NativePeerNewSession.WorktreeMode?
    @State private var worktreeId: String?
    @State private var base = ""
    @State private var branch = ""
    /// The recovered worktree already switched to, so picking "New worktree"
    /// again afterwards is not undone.
    @State private var appliedRecoveryId: String?
    @State private var agentId: String?
    /// Nil is "Default": no model is sent and the peer uses the agent's own.
    @State private var modelId: String?
    /// Nil is "Default": no effort is sent and the peer uses the agent's own.
    @State private var effortId: String?
    @Environment(\.theme) private var theme

    /// Chip item standing for "send nothing". Advertised ids that are empty
    /// are dropped from the lists, so this can never shadow a real option.
    private static let defaultItemId = ""

    private var request: NativePeerNewSession? { client.newSession }
    private var peerName: String { request?.peerName ?? "peer" }
    /// The peer can only create a worktree in a repo it identifies by id.
    private var canCreateWorktrees: Bool { request?.projectId != nil }
    private var createsWorktree: Bool { mode == .new && canCreateWorktrees }

    /// Agents the peer can launch in the selected worktree's project.
    private var agents: [RemoteAgentOption] {
        let projectId = createsWorktree
            ? request?.projectId
            : request?.worktrees?.first { $0.id == worktreeId }?.projectId
        return (request?.agents ?? []).filter { $0.isAvailable(inProjectId: projectId) }
    }
    private var selectedAgent: RemoteAgentOption? { agents.first { $0.id == agentId } }
    private var visibility: NativePeerNewSession.ChipVisibility? {
        NativePeerNewSession.chipVisibility(for: selectedAgent)
    }

    private var canCreate: Bool {
        guard let request, !request.isLoading, request.phase != .creating,
              request.phase != .failed(NativePeerSessions.peerUnavailableMessage) else { return false }
        guard agentId != nil else { return false }
        if createsWorktree {
            return NativePeerNewSession.canCreateWorktree(base: base, branch: branch, branches: request.branches)
        }
        return worktreeId != nil
    }

    var body: some View {
        DialogContainer(
            title: "New session on \(peerName)",
            subtitle: request?.repoName,
            content: { fields },
            cancelTitle: "Cancel",
            confirmTitle: request?.phase == .creating ? "Creating…" : "Create",
            confirmStyle: .primary,
            onCancel: { client.cancelNewSession() },
            onConfirm: create,
            confirmEnabled: canCreate
        )
        .onAppear(perform: preselect)
        .onChange(of: request?.worktrees) { preselect() }
        .onChange(of: request?.agents) { preselect() }
        .onChange(of: request?.branches) { preselect() }
        .onChange(of: mode) { preselect() }
        .onChange(of: worktreeId) { preselect() }
        .onChange(of: agentId) {
            modelId = nil
            effortId = nil
        }
    }

    @ViewBuilder
    private var fields: some View {
        DialogField(label: "Worktree") {
            VStack(alignment: .leading, spacing: 8) {
                if canCreateWorktrees {
                    AlasSegmentedControl(
                        selection: mode ?? .existing,
                        options: [
                            AlasSegmentedOption(id: .existing, label: "Existing"),
                            AlasSegmentedOption(id: .new, label: "New worktree"),
                        ],
                        onSelect: { mode = $0 }
                    )
                    .fixedSize()
                }
                if !createsWorktree {
                    if let worktrees = request?.worktrees {
                        NativePeerWorktreePicker(selection: $worktreeId, worktrees: worktrees)
                    } else {
                        loadingField("Loading worktrees…")
                    }
                }
            }
        }
        if createsWorktree {
            newWorktreeFields
        }
        DialogField(label: "Agent") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if request?.agents != nil {
                        agentChip(agents)
                        if let selectedAgent, visibility?.showsModel == true {
                            modelChip(selectedAgent.models ?? [])
                        }
                        if let selectedAgent, visibility?.showsEffort == true {
                            effortChip(selectedAgent.efforts ?? [])
                        }
                    } else {
                        loadingChip("Loading agents…")
                    }
                }
                if let selectedAgent, visibility?.showsDefaultsHint == true {
                    Text("Model and effort use \(selectedAgent.name)'s defaults until it has run once on \(peerName).")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg-muted"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let hint = emptyHint {
            Text(hint).font(.system(size: 11.5)).foregroundColor(theme.color("fg-muted"))
        }
        if case .failed(let message) = request?.phase {
            Text(message).font(.system(size: 11.5)).foregroundColor(theme.color("del"))
        }
    }

    @ViewBuilder
    private var newWorktreeFields: some View {
        DialogField(label: "Base branch") {
            BranchPicker(
                selection: $base,
                branches: request?.branchNames ?? [],
                isLoading: request?.branches == nil,
                errorMessage: branchLoadError
            )
        }
        DialogField(label: "Branch name") {
            AlasField(
                text: $branch,
                monospaced: true,
                focusOnAppear: true,
                onSubmit: create,
                disablesAutomaticTextSubstitutions: true
            )
        }
        if let message = NativePeerNewSession.branchValidationMessage(branch) {
            Text(message).font(.system(size: 11.5)).foregroundColor(theme.color("del"))
        }
    }

    private var branchLoadError: String? {
        if case .failed(let message) = request?.branches { return message }
        return nil
    }

    private func agentChip(_ agents: [RemoteAgentOption]) -> some View {
        ACPSelectChip(
            label: selectedAgent?.name ?? "",
            placeholder: "Agent",
            accent: theme.color("fg-muted"),
            items: agents.map {
                ACPSelectChip.Item(id: $0.id, name: $0.name, description: nil, icon: Self.agentIcon(id: $0.id))
            },
            selectedId: agentId,
            searchDescriptions: false,
            searchIdentifiers: false,
            fillsWidth: false,
            onSelect: { agentId = $0.id }
        )
    }

    private func modelChip(_ models: [RemoteModelOption]) -> some View {
        let items = [ACPSelectChip.Item(id: Self.defaultItemId, name: "Default model", description: nil)]
            + models.filter { !$0.id.isEmpty }.map { ACPSelectChip.Item(id: $0.id, name: $0.name, description: nil) }
        let selected = modelId ?? Self.defaultItemId
        return ACPSelectChip(
            label: items.first { $0.id == selected }?.name ?? "Default model",
            placeholder: "Model",
            accent: theme.color("syntax-keyword"),
            items: items,
            selectedId: selected,
            searchDescriptions: false,
            searchIdentifiers: false,
            fillsWidth: false,
            onSelect: { modelId = $0.id == Self.defaultItemId ? nil : $0.id }
        )
    }

    private func effortChip(_ efforts: [RemoteEffortOption]) -> some View {
        let items = [ACPSelectChip.Item(id: Self.defaultItemId, name: "Default", description: nil)]
            + efforts.filter { !$0.id.isEmpty }.map { ACPSelectChip.Item(id: $0.id, name: $0.name, description: nil) }
        let selected = effortId ?? Self.defaultItemId
        return ACPSelectChip(
            label: "🧠 \(items.first { $0.id == selected }?.name ?? "Default")",
            placeholder: "Thinking",
            accent: theme.color("warn"),
            items: items,
            selectedId: selected,
            searchDescriptions: false,
            searchIdentifiers: false,
            fillsWidth: false,
            onSelect: { effortId = $0.id == Self.defaultItemId ? nil : $0.id }
        )
    }

    /// The bundled logo for a built-in agent id, else the sparkle used for
    /// agents without artwork (custom and registry agents).
    private static func agentIcon(id: String) -> ACPSelectChip.Icon {
        guard let agent = AgentBuiltins.entry(id: id) else { return .system("sparkles") }
        return .image(AgentLogoView.menuImage(for: agent, size: 14))
    }

    private func loadingField(_ text: String) -> some View {
        HStack(spacing: 8) {
            Spinner(lineWidth: 1.5, duration: 0.7, color: theme.color("fg-muted"))
                .frame(width: 12, height: 12)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func loadingChip(_ text: String) -> some View {
        let accent = theme.color("fg-muted")
        return HStack(spacing: ACPSelectChipMetrics.labelChevronSpacing) {
            Spinner(lineWidth: 1.2, duration: 0.7, color: accent)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accent.opacity(0.45), lineWidth: 0.75))
    }

    private var emptyHint: String? {
        guard let request, !request.isLoading else { return nil }
        if !createsWorktree, request.worktrees?.isEmpty == true { return "No worktrees in \(request.repoName) on \(request.peerName)." }
        if request.agents?.isEmpty ?? true { return "No agents are enabled on \(request.peerName)." }
        if agents.isEmpty { return "No agents on \(request.peerName) can run in this repository." }
        return nil
    }

    private func preselect() {
        let worktrees = request?.worktrees ?? []
        if mode == nil, let loaded = request?.worktrees {
            mode = NativePeerNewSession.defaultWorktreeMode(for: loaded)
        }
        // A worktree the peer created without its session: retry in it
        // rather than create another.
        if let recovered = request?.recoveredWorktreeId, recovered != appliedRecoveryId,
           worktrees.contains(where: { $0.id == recovered }) {
            appliedRecoveryId = recovered
            mode = .existing
            worktreeId = recovered
        }
        if base.isEmpty, let preferred = NativePeerNewSession.preselectedBase(in: request?.branches) {
            base = preferred
        }
        // After a worktree change the filtered list reflects its project.
        if worktreeId == nil || !worktrees.contains(where: { $0.id == worktreeId }) {
            worktreeId = NativePeerNewSession.preselectedWorktreeId(
                in: worktrees, selectedWorktreeId: client.newSessionDefaultWorktreeId
            )
        }
        if agentId == nil || !agents.contains(where: { $0.id == agentId }) {
            agentId = NativePeerNewSession.preselectedAgentId(in: agents)
        }
        // A refreshed agent list (the peer reconnected) can drop a level or
        // model picked earlier; fall back to Default rather than send it.
        let agent = agents.first { $0.id == agentId }
        if let chosen = modelId, !(agent?.models ?? []).contains(where: { $0.id == chosen }) {
            modelId = nil
        }
        if let chosen = effortId, !(agent?.efforts ?? []).contains(where: { $0.id == chosen }) {
            effortId = nil
        }
    }

    private func create() {
        guard canCreate, let agentId else { return }
        if createsWorktree {
            client.createNewWorktreeSession(
                base: base, branch: branch, agentId: agentId, modelId: modelId, effortId: effortId)
        } else if let worktreeId {
            client.createNewSession(worktreeId: worktreeId, agentId: agentId, modelId: modelId, effortId: effortId)
        }
    }
}

/// A peer worktree picker in `ProjectPicker`'s style. The worktree's name
/// leads in monospace and its branch follows muted, so the two never read
/// as one label.
private struct NativePeerWorktreePicker: View {
    @Binding var selection: String?
    let worktrees: [RemoteWorktreeOption]
    @Environment(\.theme) private var theme
    @State private var open = false

    private var selected: RemoteWorktreeOption? { worktrees.first { $0.id == selection } }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                branchIcon
                if let selected {
                    Text(selected.worktreeName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                    Text("on \(selected.branch)")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg-muted"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No worktrees")
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg-dim"))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(theme.color("bg-1"))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(worktrees.isEmpty)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(worktrees, id: \.id) { row($0) }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 360)
            .frame(maxHeight: 320)
        }
    }

    private var branchIcon: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
    }

    private func row(_ option: RemoteWorktreeOption) -> some View {
        Button {
            selection = option.id
            open = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .opacity(option.id == selection ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.worktreeName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        branchIcon
                        Text(option.branch)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-muted"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
