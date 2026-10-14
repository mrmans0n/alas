import SwiftUI

struct AiSplitButton: View {
    let availableAgents: [AgentDefinition]
    @Binding var selectedToolId: String
    let busy: Bool
    let onGenerate: () -> Void

    @Environment(\.theme) var theme

    /// Agent the button runs: the pinned one, or the first on Automatic.
    /// Nil for None or an agent missing from `availableAgents`.
    private var selected: AgentDefinition? {
        RepositoryAgentSelectionPolicy.selection(
            selectedID: selectedToolId,
            availability: .available(availableAgents)
        ).agent
    }

    private var primaryLabel: String {
        if busy { return "Cancel" }
        return selected?.displayName ?? "None"
    }

    private var primaryDisabled: Bool {
        !busy && selected == nil
    }

    var body: some View {
        HStack(spacing: 1) {
            Button(action: onGenerate) {
                HStack(spacing: 6) {
                    if busy {
                        Spinner(lineWidth: 1.5, duration: 0.7)
                            .frame(width: 12, height: 12)
                    } else {
                        Text("✨").font(.system(size: 11))
                    }
                    Text(primaryLabel)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundColor(primaryDisabled ? theme.color("fg-faint") : theme.color("fg"))
                .background(theme.color("bg-3"))
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
            .help(primaryDisabled
                  ? "Pick an agent in Settings → Agents to enable"
                  : busy
                      ? "Cancel generation"
                      : "Generate commit message with \(selected?.displayName ?? "")")

            Menu {
                Button {
                    selectedToolId = AppConfig.Changes.automaticAIToolID
                } label: {
                    HStack {
                        Text("Automatic")
                        if selectedToolId == AppConfig.Changes.automaticAIToolID {
                            Icon(name: "check", size: 10)
                        }
                    }
                }
                Divider()
                ForEach(availableAgents) { agent in
                    Button {
                        selectedToolId = agent.id
                    } label: {
                        HStack {
                            Text(agent.displayName)
                            if agent.id == selectedToolId {
                                Icon(name: "check", size: 10)
                            }
                        }
                    }
                }
                Divider()
                Button("None") { selectedToolId = AppConfig.Changes.disabledAIToolID }
            } label: {
                Icon(name: "chev-down", size: 9, color: theme.color("fg-faint"))
                    .padding(.horizontal, 7).padding(.vertical, 7)
                    .background(theme.color("bg-3"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Select AI agent")
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
