// Alas/Sources/Settings/AgentEditView.swift
import SwiftUI

struct AgentEditView: View {
    @Environment(\.designScale) private var scale
    @Bindable var state: AppState
    let target: AgentsPane.EditTarget
    let onDismiss: () -> Void

    @State private var draft: AgentDefinition
    @State private var nativeSubagentsDisabled: Bool
    @State private var sessionInstructions: String
    @State private var sessionHooks: String
    @State private var alasMCPServerName: String
    @State private var deleteConfirmShown = false
    /// Pi only: what the installed Pi extensions leave uncovered. Read once
    /// when the sheet opens.
    @State private var piExtensionCoverage: ACPPiSubagentExtensions.Coverage?

    @Environment(\.theme) var theme

    init(state: AppState, target: AgentsPane.EditTarget, onDismiss: @escaping () -> Void) {
        self.state = state
        self.target = target
        self.onDismiss = onDismiss
        let targetID: String? = if case .existing(let id) = target { id } else { nil }
        _nativeSubagentsDisabled = State(initialValue: targetID.map {
            state.config.agents.nativeSubagentsDisabled(for: $0)
        } ?? false)
        _sessionInstructions = State(initialValue: targetID.flatMap {
            state.config.agents.builtinState[$0]?.sessionInstructions
        } ?? "")
        _sessionHooks = State(initialValue: targetID.flatMap {
            state.config.agents.builtinState[$0]?.sessionHooks
        } ?? "")
        _alasMCPServerName = State(initialValue: targetID.flatMap {
            state.config.agents.builtinState[$0]?.alasMCPServerName
        } ?? "")
        _piExtensionCoverage = State(initialValue: targetID == ACPManagedAdapterDescriptor.pi.agentID
            ? ACPPiSubagentExtensions.coverage(
                agentDirectory: ACPPiSubagentExtensions.agentDirectory(),
                projects: Self.localPiRoots(state.projects, checkouts: state.workspacesManager.checkouts),
                customPiCommand: ProcessInfo.processInfo.environment[ACPPiSubagentExtensions.piCommandKey])
            : nil)
        switch target {
        case .new:
            _draft = State(initialValue: AgentDefinition(
                id: UUID().uuidString,
                displayName: "",
                binary: "",
                binaryOverride: nil,
                promptModeArgs: [],
                bypassPermissionsFlag: nil,
                extraTerminalArgs: nil,
                isBuiltin: false,
                isEnabled: true,
                builtinLogoAssetName: nil
            ))
        case .existing(let id):
            // Source from config, not from `state.agentRegistry`. The registry
            // clamps `isEnabled` against install detection, so reading the
            // draft from there would silently persist `isEnabled = false`
            // when the user opens a missing-binary card to fix its path.
            let agent: AgentDefinition
            if let custom = state.config.agents.custom.first(where: { $0.id == id }) {
                agent = custom
            } else if var builtin = AgentBuiltins.entry(id: id) {
                let persisted = state.config.agents.builtinState[id]
                builtin.isEnabled = persisted?.isEnabled ?? builtin.isEnabled
                builtin.binaryOverride = persisted?.binaryOverride
                builtin.extraTerminalArgs = persisted?.extraTerminalArgs
                agent = builtin
            } else {
                agent = AgentDefinition(
                    id: id, displayName: id, binary: "",
                    binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
                    extraTerminalArgs: nil,
                    isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
                )
            }
            _draft = State(initialValue: agent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerTitle)
                .font(SettingsPaneStyle.titleFont)
                .padding(.bottom, scale.space[3])

            SettingsRow(name: "Name") {
                AlasField(text: $draft.displayName, monospaced: false)
                    .disabled(draft.isBuiltin)
            }
            SettingsRow(name: draft.isBuiltin ? "Binary override" : "Binary / command") {
                AlasField(
                    text: Binding(
                        get: { draft.isBuiltin ? (draft.binaryOverride ?? "") : draft.binary },
                        set: {
                            if draft.isBuiltin {
                                draft.binaryOverride = $0.isEmpty ? nil : $0
                            } else {
                                draft.binary = $0
                            }
                        }
                    ),
                    monospaced: true
                )
            }
            if draft.isBuiltin {
                SettingsRow(name: "Default binary") {
                    Text(draft.binary)
                        .font(scale.meta.font(design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            SettingsRow(name: "Prompt-mode args") {
                AlasField(
                    text: Binding(
                        get: { draft.promptModeArgs.joined(separator: " ") },
                        set: { newValue in
                            draft.promptModeArgs = newValue
                                .split(separator: " ", omittingEmptySubsequences: true)
                                .map(String.init)
                        }
                    ),
                    monospaced: true
                )
                .disabled(draft.isBuiltin)
            }
            SettingsRow(name: "Bypass-perms flag") {
                AlasField(
                    text: Binding(
                        get: { draft.bypassPermissionsFlag ?? "" },
                        set: { draft.bypassPermissionsFlag = $0.isEmpty ? nil : $0 }
                    ),
                    monospaced: true
                )
                .disabled(draft.isBuiltin)
            }
            SettingsRow(name: "Extra terminal args") {
                AlasField(
                    text: Binding(
                        get: { draft.extraTerminalArgs?.joined(separator: " ") ?? "" },
                        set: { newValue in
                            let parts = newValue.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                            draft.extraTerminalArgs = parts.isEmpty ? nil : parts
                        }
                    ),
                    monospaced: true
                )
            }
            SettingsRow(name: "Enabled") {
                AlasToggle(on: $draft.isEnabled)
            }
            if draft.isBuiltin, let descriptor = ACPManagedAdapterDescriptor.descriptor(for: draft.id) {
                ACPAdapterSettingsRow(descriptor: descriptor, coordinator: state.acpAdapterInstallCoordinator)
            }
            SettingsRow(
                name: "Disable native subagents",
                desc: nativeDelegationSupport.settingsRowDescription(
                    isOn: nativeSubagentsDisabled,
                    alasToolsExposed: state.config.harness.exposeAlasMCP,
                    extensionCoverage: piExtensionCoverage
                )
            ) {
                AlasToggle(on: $nativeSubagentsDisabled)
                    .disabled(!nativeDelegationSupport.canEnforce)
                    .opacity(nativeDelegationSupport.canEnforce ? 1 : 0.4)
            }
            if supportsSessionInstructions {
                SettingsRow(
                    name: "Session instructions",
                    desc: "Added to the agent's own instructions and project rules. Applies to new sessions."
                ) {
                    TextEditor(text: $sessionInstructions)
                        .font(scale.metaFont)
                        .scrollContentBackground(.hidden)
                        .frame(height: 72)
                        .padding(scale.space[2])
                        .background(theme.color("bg-0"))
                        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium)
                            .strokeBorder(theme.color("line"), lineWidth: 0.5))
                }
            }
            if supportsSessionHooks {
                SettingsRow(
                    name: "Session hooks",
                    desc: "Advanced. Claude Code hooks JSON, like {\"PostToolUse\": [...]}. "
                        + "Runs alongside your user and project hooks, on the agent's host "
                        + "in the session's worktree. Applies to new sessions."
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $sessionHooks)
                            .font(scale.meta.font(design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(height: 72)
                            .padding(scale.space[2])
                            .background(theme.color("bg-0"))
                            .overlay(RoundedRectangle(cornerRadius: scale.radius.medium)
                                .strokeBorder(theme.color(sessionHooksError == nil ? "line" : "del"), lineWidth: 0.5))
                        if let sessionHooksError {
                            Text(sessionHooksError)
                                .font(scale.metaFont)
                                .foregroundColor(theme.color("del"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if supportsAlasMCPServerName {
                SettingsRow(
                    name: "Alas MCP server name",
                    desc: "The name this agent sees the built-in Alas MCP server under. Change it when a "
                        + "managed policy only allows certain server names. Applies when a session reconnects."
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        AlasField(
                            text: $alasMCPServerName,
                            placeholder: BuiltInAlasMCP.serverName,
                            monospaced: true
                        )
                        if let alasMCPServerNameError {
                            Text(alasMCPServerNameError)
                                .font(scale.metaFont)
                                .foregroundColor(theme.color("del"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                if !draft.isBuiltin && !isNew {
                    AlasButton(title: "Delete", style: .subtle) {
                        deleteConfirmShown = true
                    }
                } else if draft.isBuiltin {
                    AlasButton(title: "Reset overrides", style: .subtle, action: resetOverrides)
                }
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: onDismiss)
                AlasButton(
                    title: isNew ? "Add" : "Done",
                    style: .primary,
                    action: save
                )
                .disabled(!canSave)
            }
            .padding(.top, scale.space[4])
        }
        .padding(scale.space[5])
        .frame(width: 560)
        .background(theme.color("bg-1"))
        .confirmationDialog(
            "Delete this custom agent?",
            isPresented: $deleteConfirmShown,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Every local checkout a Pi session can start in: each project's main
    /// checkout and its linked worktrees, and each workspace checkout root,
    /// since Pi reads the session's own `.pi` folder.
    private static func localPiRoots(
        _ projects: [ProjectConfig],
        checkouts: [WorkspaceCheckout]
    ) -> [(name: String, root: URL)] {
        var seen = Set<String>()
        var roots: [(name: String, root: URL)] = []
        for project in projects where project.host == nil {
            roots.append((project.name, URL(fileURLWithPath: project.path, isDirectory: true)))
            for worktree in project.cachedWorktrees {
                roots.append(("\(project.name), \(worktree.name)", worktree.path))
            }
        }
        for checkout in checkouts where checkout.executionLocation == .local {
            roots.append(("workspace \(checkout.fallbackWorkspaceName), \(checkout.branch)",
                          URL(fileURLWithPath: checkout.rootPath, isDirectory: true)))
        }
        return roots.filter { seen.insert($0.root.standardizedFileURL.path).inserted }
    }

    /// Custom agents resolve to `.unsupported` (their ids are UUIDs).
    private var nativeDelegationSupport: ACPNativeDelegationSupport {
        draft.isBuiltin ? .resolve(agentID: draft.id) : .unsupported
    }

    private var supportsSessionInstructions: Bool {
        draft.isBuiltin && ACPSessionInstructionsPolicy.isConfigurable(agentID: draft.id)
    }

    private var supportsSessionHooks: Bool {
        draft.isBuiltin && ACPClaudeSessionHooksPolicy.isConfigurable(agentID: draft.id)
    }

    private var sessionHooksError: String? {
        guard supportsSessionHooks else { return nil }
        do {
            _ = try ACPClaudeSessionHooksPolicy.normalized(sessionHooks)
            return nil
        } catch {
            return error.errorDescription
        }
    }

    /// Agents that take MCP servers from Alas over ACP; the rest never see
    /// the built-in server's name.
    private var supportsAlasMCPServerName: Bool {
        draft.isBuiltin && ACPLaunchCatalog.spec(for: draft.id)?.mcpInjection == .sessionNew
    }

    private var alasMCPServerNameError: String? {
        guard supportsAlasMCPServerName,
              !alasMCPServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              BuiltInAlasMCP.normalizedServerName(alasMCPServerName) == nil
        else { return nil }
        return "Use letters, digits, _ and -, up to 64 characters."
    }

    private var isNew: Bool {
        if case .new = target { return true } else { return false }
    }

    private var headerTitle: String {
        if isNew { return "Add agent" }
        return draft.displayName.isEmpty ? "Edit agent" : "Edit \(draft.displayName)"
    }

    private var canSave: Bool {
        if draft.isBuiltin { return sessionHooksError == nil && alasMCPServerNameError == nil }
        return !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.binary.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        if draft.isBuiltin {
            var entry = state.config.agents.builtinState[draft.id]
                ?? BuiltinAgentState(isEnabled: true, binaryOverride: nil)
            entry.isEnabled = draft.isEnabled
            let trimmed = draft.binaryOverride?.trimmingCharacters(in: .whitespaces)
            entry.binaryOverride = (trimmed?.isEmpty == false) ? trimmed : nil
            let trimmedExtra = draft.extraTerminalArgs?.filter { !$0.isEmpty }
            entry.extraTerminalArgs = (trimmedExtra?.isEmpty == false) ? trimmedExtra : nil
            if nativeDelegationSupport.canEnforce {
                entry.nativeSubagentsDisabled = nativeSubagentsDisabled ? true : nil
            }
            if supportsSessionInstructions {
                entry.sessionInstructions = ACPSessionInstructionsPolicy.normalized(sessionInstructions)
            }
            if supportsSessionHooks {
                entry.sessionHooks = try? ACPClaudeSessionHooksPolicy.normalized(sessionHooks)
            }
            if supportsAlasMCPServerName {
                let name = BuiltInAlasMCP.normalizedServerName(alasMCPServerName)
                entry.alasMCPServerName = name == BuiltInAlasMCP.serverName ? nil : name
            }
            state.config.agents.builtinState[draft.id] = entry
        } else if isNew {
            state.config.agents.custom.append(draft.normalizedForSettingsSave())
        } else if let idx = state.config.agents.custom.firstIndex(where: { $0.id == draft.id }) {
            state.config.agents.custom[idx] = draft.normalizedForSettingsSave()
        }
        state.saveConfig()
        state.rescanAgents()
        onDismiss()
    }

    private func resetOverrides() {
        state.config.agents.builtinState.removeValue(forKey: draft.id)
        state.saveConfig()
        state.rescanAgents()
        onDismiss()
    }

    private func delete() {
        guard !draft.isBuiltin else { return }
        state.config.agents.custom.removeAll { $0.id == draft.id }
        state.saveConfig()
        state.rescanAgents()
        onDismiss()
    }
}

extension AgentDefinition {
    func normalizedForSettingsSave() -> AgentDefinition {
        var normalized = self
        normalized.displayName = displayName.trimmingCharacters(in: .whitespaces)
        normalized.binary = binary.trimmingCharacters(in: .whitespaces)
        normalized.binaryOverride = nil
        let trimmedBypass = bypassPermissionsFlag?.trimmingCharacters(in: .whitespaces)
        normalized.bypassPermissionsFlag = (trimmedBypass?.isEmpty == false) ? trimmedBypass : nil
        let trimmedExtra = extraTerminalArgs?.filter { !$0.isEmpty }
        normalized.extraTerminalArgs = (trimmedExtra?.isEmpty == false) ? trimmedExtra : nil
        return normalized
    }
}

/// The local install of an Alas-managed ACP adapter: its version and health,
/// with a clean reinstall for installs that npm left incomplete.
private struct ACPAdapterSettingsRow: View {
    let descriptor: ACPManagedAdapterDescriptor
    let coordinator: ACPAdapterInstallCoordinator

    private enum Health: Equatable {
        case checking
        case installed(version: String?)
        case notInstalled
        case broken(String)
    }

    @State private var health: Health = .checking
    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        SettingsRow(name: "ACP adapter", desc: description, selectable: true) {
            HStack(spacing: 8) {
                AlasButton(title: buttonTitle, style: .subtle) { reinstall() }
                    .disabled(isInstalling || health == .checking)
                    .help("Uninstalls the adapter and installs it again. Sessions already running on it may fail meanwhile.")
                if isInstalling || health == .checking {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task { await refresh() }
    }

    private var description: String {
        if isInstalling { return "Reinstalling `\(descriptor.packageName)`…" }
        if let installError { return "Reinstall failed: \(installError)" }
        switch health {
        case .checking:
            return "Checking `\(descriptor.packageName)`…"
        case .installed(let version):
            return "`\(descriptor.packageName)`\(version.map { " \($0)" } ?? "") is installed on this Mac."
        case .notInstalled:
            return "`\(descriptor.packageName)` is not installed on this Mac."
        case .broken(let reason):
            return reason
        }
    }

    private var buttonTitle: String {
        health == .notInstalled ? "Install" : "Reinstall"
    }

    private func refresh() async {
        let state = await ACPInstallerRegistry.installer(for: descriptor.agentID)?.installState()
            ?? .missing(reason: "")
        switch state {
        case .ready:
            let version = await ACPSetupChecker(env: ACPProcessEnvironment.baseEnvironment())
                .installedVersion(ofNpmPackage: descriptor.packageName)
            health = .installed(version: version)
        case .missing:
            health = .notInstalled
        case .error(let message):
            health = .broken(message)
        }
    }

    private func reinstall() {
        isInstalling = true
        installError = nil
        Task {
            do {
                try await coordinator.install(target: .local, agentID: descriptor.agentID, mode: .reinstall)
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
            health = .checking
            await refresh()
        }
    }
}
