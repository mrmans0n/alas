// Alas/Sources/Settings/AgentEditView.swift
import SwiftUI

struct AgentEditView: View {
    @Bindable var state: AppState
    let target: AgentsPane.EditTarget
    let onDismiss: () -> Void

    @State private var draft: AgentDefinition
    @State private var deleteConfirmShown = false

    @Environment(\.theme) var theme

    init(state: AppState, target: AgentsPane.EditTarget, onDismiss: @escaping () -> Void) {
        self.state = state
        self.target = target
        self.onDismiss = onDismiss
        switch target {
        case .new:
            _draft = State(initialValue: AgentDefinition(
                id: UUID().uuidString,
                displayName: "",
                binary: "",
                binaryOverride: nil,
                promptModeArgs: [],
                bypassPermissionsFlag: nil,
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
                agent = builtin
            } else {
                agent = AgentDefinition(
                    id: id, displayName: id, binary: "",
                    binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
                    isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
                )
            }
            _draft = State(initialValue: agent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerTitle)
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 12)

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
                        .font(.system(size: 12, design: .monospaced))
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
            SettingsRow(name: "Enabled") {
                AlasToggle(on: $draft.isEnabled)
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
            .padding(.top, 16)
        }
        .padding(24)
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

    private var isNew: Bool {
        if case .new = target { return true } else { return false }
    }

    private var headerTitle: String {
        if isNew { return "Add agent" }
        return draft.displayName.isEmpty ? "Edit agent" : "Edit \(draft.displayName)"
    }

    private var canSave: Bool {
        if draft.isBuiltin { return true }
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
            state.config.agents.builtinState[draft.id] = entry
        } else if isNew {
            state.config.agents.custom.append(draft)
        } else if let idx = state.config.agents.custom.firstIndex(where: { $0.id == draft.id }) {
            state.config.agents.custom[idx] = draft
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
