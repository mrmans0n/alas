import SwiftUI

@Observable
@MainActor
final class ACPRegistryBrowserModel {
    enum LoadState: Equatable {
        case loading
        case loaded([ACPRegistryAgent])
        case failed(String)
    }

    enum Operation: Equatable {
        case installing
        case uninstalling
    }

    private(set) var loadState: LoadState = .loading
    var query: String
    private(set) var operations: [String: Operation] = [:]
    private(set) var errors: [String: String] = [:]
    private let client: ACPRegistryClient

    init(query: String = "", client: ACPRegistryClient = ACPRegistryClient()) {
        self.query = query
        self.client = client
    }

    func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.agents())
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func visibleAgents(_ agents: [ACPRegistryAgent]) -> [ACPRegistryAgent] {
        agents.filter { $0.matches(query: query) }
    }

    func unlistedInstalls(_ installed: [ACPRegistryInstalledAgent]) -> [ACPRegistryInstalledAgent] {
        let registry: [ACPRegistryAgent]?
        switch loadState {
        case .loading: return []
        case .failed: registry = nil
        case .loaded(let agents): registry = agents
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ACPRegistryInstalledAgent.unlisted(installed, registry: registry).filter {
            trimmed.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.registryID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func install(_ agent: ACPRegistryAgent, state: AppState) async {
        guard operations[agent.id] == nil else { return }
        operations[agent.id] = .installing
        errors[agent.id] = nil
        defer { operations[agent.id] = nil }
        do {
            try await state.installRegistryAgent(agent)
        } catch {
            errors[agent.id] = error.localizedDescription
        }
    }

    func uninstall(registryID: String, state: AppState) async {
        guard operations[registryID] == nil else { return }
        operations[registryID] = .uninstalling
        errors[registryID] = nil
        defer { operations[registryID] = nil }
        do {
            try await state.uninstallRegistryAgent(registryID: registryID)
        } catch {
            errors[registryID] = error.localizedDescription
        }
    }
}

/// Settings → Agents sheet that browses and searches the official ACP agent
/// registry and installs agents into the ACP launch catalog.
struct ACPRegistryBrowserView: View {
    @Bindable var state: AppState
    let onDismiss: () -> Void
    @State private var model: ACPRegistryBrowserModel
    @Environment(\.theme) var theme

    init(state: AppState, initialQuery: String = "", onDismiss: @escaping () -> Void) {
        self.state = state
        self.onDismiss = onDismiss
        _model = State(initialValue: ACPRegistryBrowserModel(query: initialQuery))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACP Registry")
                .font(.system(size: 16, weight: .semibold))
            Text("Install agents from the official Agent Client Protocol registry. Installed agents open in Chat.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .padding(.bottom, 12)
            TextField("Search agents…", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                AlasButton(title: "Done", style: .primary, action: onDismiss)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 620, height: 560)
        .background(theme.color("bg-1"))
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        let unlisted = model.unlistedInstalls(state.config.agents.registry)
        switch model.loadState {
        case .loading:
            VStack(spacing: 8) {
                Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 14, height: 14)
                Text("Loading registry…")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text("Could not load the ACP registry.")
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                AlasButton(title: "Retry", style: .normal) {
                    Task { await model.load() }
                }
                if !unlisted.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            unlistedRows(unlisted, note: "Installed from the ACP registry.")
                        }
                    }
                    .padding(.top, 8)
                }
            }
        case .loaded(let agents):
            let visible = model.visibleAgents(agents)
            if visible.isEmpty && unlisted.isEmpty {
                Text("No agents match “\(model.query)”.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { agent in
                            ACPRegistryRow(
                                agent: agent,
                                status: ACPRegistryEntryStatus.resolve(
                                    agent: agent,
                                    installed: state.config.agents.registry
                                ),
                                operation: model.operations[agent.id],
                                error: model.errors[agent.id],
                                onInstall: { Task { await model.install(agent, state: state) } },
                                onUninstall: { Task { await model.uninstall(registryID: agent.id, state: state) } }
                            )
                        }
                        unlistedRows(unlisted, note: "No longer listed in the ACP registry.")
                    }
                }
            }
        }
    }

    private func unlistedRows(_ installs: [ACPRegistryInstalledAgent], note: String) -> some View {
        ForEach(installs) { install in
            ACPRegistryUnlistedRow(
                install: install,
                note: note,
                error: model.errors[install.registryID],
                isRemoving: model.operations[install.registryID] != nil,
                onUninstall: { Task { await model.uninstall(registryID: install.registryID, state: state) } }
            )
        }
    }
}

/// An install with no registry row; it can only be uninstalled.
private struct ACPRegistryUnlistedRow: View {
    let install: ACPRegistryInstalledAgent
    let note: String
    let error: String?
    let isRemoving: Bool
    let onUninstall: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(install.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    Text(install.version)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                }
                Text(note)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("warn"))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if isRemoving {
                HStack(spacing: 6) {
                    Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10)
                    Text("Removing…")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                }
            } else {
                AlasButton(title: "Uninstall", style: .subtle, action: onUninstall)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.color("line-soft"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ACPRegistryRow: View {
    let agent: ACPRegistryAgent
    let status: ACPRegistryEntryStatus
    let operation: ACPRegistryBrowserModel.Operation?
    let error: String?
    let onInstall: () -> Void
    let onUninstall: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    Text(agent.version)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                    if let plan = agent.installPlan() {
                        pill(plan.label, fg: theme.color("fg-dim"))
                    }
                }
                Text(agent.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(2)
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("warn"))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.color("line-soft"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var actions: some View {
        if let operation {
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10)
                Text(operation == .installing ? "Installing…" : "Removing…")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
        } else {
            switch status {
            case .builtin:
                pill("built in", fg: theme.color("accent"))
                    .help("Alas ships a curated launcher for this agent. Manage it from the agent cards.")
            case .unsupported:
                pill("not available on macOS", fg: theme.color("fg-dim"))
            case .notInstalled:
                AlasButton(title: "Install", style: .normal, action: onInstall)
            case .installed:
                HStack(spacing: 6) {
                    pill("installed", fg: theme.color("add"))
                    AlasButton(title: "Uninstall", style: .subtle, action: onUninstall)
                }
            case .updateAvailable(let installedVersion):
                HStack(spacing: 6) {
                    AlasButton(title: "Update", style: .normal, action: onInstall)
                        .help("Installed version: \(installedVersion)")
                    AlasButton(title: "Uninstall", style: .subtle, action: onUninstall)
                }
            }
        }
    }

    private func pill(_ text: String, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(fg.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
