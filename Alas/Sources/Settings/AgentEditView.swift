// Alas/Sources/Settings/AgentEditView.swift
import SwiftUI

struct AgentEditView: View {
    @Bindable var state: AppState
    let target: AgentsPane.EditTarget
    let onDismiss: () -> Void

    @State private var draft: AgentDefinition
    @State private var deleteConfirmShown = false

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
            let agent = state.agentRegistry.agents.first(where: { $0.id == id })
                ?? AgentBuiltins.entry(id: id)
                ?? AgentDefinition(
                    id: id, displayName: id, binary: "",
                    binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
                    isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
                )
            _draft = State(initialValue: agent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headerTitle).font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 12)

            row("Name") {
                AlasField(text: $draft.displayName, monospaced: false)
                    .disabled(draft.isBuiltin)
            }
            row(draft.isBuiltin ? "Binary override" : "Binary / command") {
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
                row("Default binary") {
                    Text(draft.binary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            row("Prompt-mode args") {
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
            row("Bypass-perms flag") {
                AlasField(
                    text: Binding(
                        get: { draft.bypassPermissionsFlag ?? "" },
                        set: { draft.bypassPermissionsFlag = $0.isEmpty ? nil : $0 }
                    ),
                    monospaced: true
                )
                .disabled(draft.isBuiltin)
            }
            row("Enabled") {
                AlasToggle(on: $draft.isEnabled)
            }

            Spacer()

            HStack {
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
        }
        .padding(24)
        .frame(width: 520, height: 460)
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
        if isNew { return "New custom agent" }
        return draft.displayName.isEmpty ? "Edit agent" : draft.displayName
    }

    private var canSave: Bool {
        if draft.isBuiltin { return true }
        return !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.binary.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func row<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
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
