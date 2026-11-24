import AlasRemoteKit
import SwiftUI

/// Starts a session on a worktree that exists, or on a new one the host creates.
struct NewSessionSheet: View {
    @Bindable var model: NewSessionModel
    @Environment(\.dismiss) private var dismiss
    let showCreatingWorktree: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.hostID == nil {
                    ContentUnavailableView("No machine online", systemImage: "laptopcomputer.slash",
                                           description: Text("Connect to a machine to start a session."))
                } else {
                    form
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isLocked)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isCreating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            model.create()
                            if model.mode == .new, model.isCreating { showCreatingWorktree() }
                        }
                        .disabled(!model.canCreate)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isLocked)
        .task { model.start() }
        // Opened with no Mac online: take the first one that connects.
        .onChange(of: model.onlineHosts.map(\.id)) { _, ids in
            if model.hostID == nil, let first = ids.first { model.select(host: first) }
        }
    }

    private var form: some View {
        Form {
            if model.showsMachine {
                Section {
                    Picker("Machine", selection: Binding(get: { model.hostID }, set: { model.select(host: $0) })) {
                        ForEach(model.machineOptions) { host in
                            Label { Text(host.name) } icon: { PeerIconView(icon: host.icon ?? .laptop) }
                                .tag(Optional(host.id))
                        }
                    }
                }
            }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if model.outcomeUnknown {
                        Button("Retry") { model.retry() }.disabled(!model.canRetry)
                    }
                }
            }
            if model.hostIsOnline {
                Section {
                    Picker("Worktree", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                        Text("Existing").tag(RemoteNewSession.WorktreeMode.existing)
                        Text("New worktree").tag(RemoteNewSession.WorktreeMode.new)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                .disabled(model.outcomeUnknown)
                Group {
                    if model.mode == .existing { existingSection } else { newWorktreeSections }
                    agentSections
                }
                .disabled(model.outcomeUnknown)
            } else {
                Section {
                    Label("Waiting for \(model.hostName ?? "the machine") to come online", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.isCreating)
    }

    // MARK: Existing worktree

    @ViewBuilder private var existingSection: some View {
        Section("Worktree") {
            if model.worktrees == nil {
                ProgressView()
            } else {
                TextField("Filter worktrees", text: $model.filter)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                let visible = model.visibleWorktrees
                if visible.isEmpty {
                    Text("No worktrees found.").foregroundStyle(.secondary)
                }
                ForEach(visible, id: \.id) { worktree in
                    Button { model.selectWorktree(worktree.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(worktree.projectName) / \(worktree.worktreeName)").foregroundStyle(.primary)
                                if !worktree.path.isEmpty {
                                    Text(worktree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Text(Self.meta(worktree).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if worktree.id == model.selectedWorktreeId {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
        }
    }

    /// The web's `createWorktreeMeta`.
    private static func meta(_ worktree: RemoteWorktreeOption) -> [String] {
        guard worktree.metricsAvailable else { return ["changes unavailable"] }
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if !worktree.branch.isEmpty { parts.append(worktree.branch) }
        if worktree.commitCount > 0 { parts.append(plural(worktree.commitCount, "commit")) }
        if worktree.conflictCount > 0 { parts.append(plural(worktree.conflictCount, "conflict")) }
        if worktree.changedFileCount > 0 { parts.append(plural(worktree.changedFileCount, "file")) }
        var lines: [String] = []
        if worktree.addedLines > 0 { lines.append("+\(worktree.addedLines)") }
        if worktree.deletedLines > 0 { lines.append("-\(worktree.deletedLines)") }
        if !lines.isEmpty { parts.append(lines.joined(separator: " / ")) }
        return parts.isEmpty ? ["clean"] : parts
    }

    // MARK: New worktree

    @ViewBuilder private var newWorktreeSections: some View {
        Section {
            if let projects = model.projects {
                if projects.isEmpty {
                    Text("No repositories are available.").foregroundStyle(.secondary)
                } else {
                    Picker("Repository", selection: Binding(get: { model.projectId }, set: { if let id = $0 { model.selectProject(id) } })) {
                        if model.projectId == nil { Text("Choose a repository").tag(String?.none) }
                        ForEach(projects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            } else {
                HStack { Text("Loading repositories...")
                Spacer()
                ProgressView() }
            }
        } header: {
            Text("Repository")
        } footer: {
            Text("Choose the repository for the new worktree.")
        }

        if model.projectId != nil {
            Section {
                switch model.branches {
                case nil:
                    HStack { Text("Loading branches...")
                    Spacer()
                    ProgressView() }
                case .failed(let message):
                    Text(message.isEmpty ? "Could not load branches." : message).foregroundStyle(.red)
                    Button("Retry") { model.retryBranches() }
                case .loaded:
                    Picker("Base branch", selection: $model.base) {
                        ForEach(model.branchNames, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
            } footer: {
                if case .loaded = model.branches { Text("Choose the branch to base this worktree on.") }
            }

            Section {
                BranchNameField(text: $model.branch,
                                placeholder: model.namesBranchFromFirstPrompt ? "Name from first prompt" : "New branch")
                // A name the first prompt picks always follows the rule, as on the Mac.
                if let naming = model.branchNaming, naming.appliesRule, !model.namesBranchFromFirstPrompt {
                    Toggle(isOn: $model.useBranchNaming) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(naming.template == nil ? "Use branch prefix" : "Use branch template")
                            Text(naming.template ?? naming.prefix)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if model.namesBranchFromFirstPrompt {
                        Text("The first prompt names the branch. Type a name to choose one yourself.")
                    } else if let preview = model.branchPreview {
                        Text("Branch to create: \(preview)").font(.footnote.monospaced())
                            .textSelection(.enabled)
                    } else if model.branchNaming == nil {
                        Text("This Mac applies its branch naming settings on create.")
                    }
                    if let message = model.branchError { Text(message).foregroundStyle(.red) }
                }
            }
        }
    }

    // MARK: Agent

    @ViewBuilder private var agentSections: some View {
        Section("Agent") {
            if model.agents == nil {
                ProgressView()
            } else if model.availableAgents.isEmpty {
                Text(model.agents?.isEmpty == true ? "No agents available." : "No agents can run in this repository.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.availableAgents, id: \.id) { agent in
                Button { model.selectAgent(agent.id) } label: {
                    HStack(spacing: 12) {
                        AgentLogo(agentId: agent.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name.isEmpty ? agent.id : agent.name).foregroundStyle(.primary)
                            if agent.isDefault { Text("Default agent").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if agent.id == model.agentId { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
                .tint(.primary)
            }
        }
        if let agent = model.selectedAgent, let chips = model.chips {
            Section {
                if chips.showsModel {
                    Picker("Model", selection: $model.modelId) {
                        Text("Default").tag(String?.none)
                        ForEach(agent.models ?? [], id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if chips.showsEffort {
                    Picker("Effort", selection: $model.effortId) {
                        Text("Default").tag(String?.none)
                        ForEach(agent.efforts ?? [], id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            } footer: {
                if chips.showsDefaultsHint { Text("The agent's defaults apply.") }
            }
        }
        if model.mode == .new, model.projectId != nil {
            Section("Review") {
                LabeledContent("Repository", value: model.projects?.first { $0.id == model.projectId }?.name ?? "Not selected")
                LabeledContent("Base", value: model.base ?? "Not selected")
                LabeledContent("Branch", value: model.branchPreview ?? (model.namesBranchFromFirstPrompt ? "From first prompt" : model.branch.isEmpty ? "Not entered" : model.branch))
            }
        }
    }
}

/// An agent's logo, from the Mac's set (`AgentKind.logoAssetName`); a generic glyph for agents it has none for.
struct AgentLogo: View {
    let agentId: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let asset = Self.asset[agentId] {
                Image(asset).resizable().scaledToFit()
            } else {
                Image(systemName: "sparkles").font(.system(size: size * 0.5)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// ACP agent id to asset, as `AgentKind(acpAgentID:)` maps them on the Mac.
    private static let asset: [String: String] = [
        "claude": "agent-claude", "codex": "agent-codex", "cursor-agent": "agent-cursor",
        "gemini": "agent-gemini", "antigravity": "agent-antigravity", "opencode": "agent-opencode", "pi": "agent-pi",
        "omp": "agent-omp", "copilot": "agent-copilot",
    ]
}
