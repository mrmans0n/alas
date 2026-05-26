import SwiftUI

struct CommitMessageEditorView: View {
    @Binding var subject: String
    @Binding var bodyText: String
    @Binding var aiToolId: String
    let title: String
    let busy: Bool
    let error: String?
    let availableAgents: [AgentDefinition]
    let onGenerate: () -> Void
    let primaryAction: CommitPrimaryAction
    var accessory: AnyView? = nil

    @Environment(\.theme) private var theme

    private var canRunPrimary: Bool {
        primaryAction.isEnabled && !busy
    }

    private var displayedLabel: String {
        if primaryAction.showSavedState, let saved = primaryAction.savedLabel {
            return saved
        }
        return primaryAction.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Icon(name: "commit", size: 12, color: theme.color("fg-dim"))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Spacer()
                if let accessory {
                    accessory
                }
                AiSplitButton(
                    availableAgents: availableAgents,
                    selectedToolId: $aiToolId,
                    busy: busy,
                    onGenerate: onGenerate
                )
                Button(action: primaryAction.handler) {
                    Text(displayedLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundColor(theme.color("bg-0"))
                        .background(canRunPrimary ? theme.color("accent") : theme.color("accent").opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!canRunPrimary)
            }

            TextField("Subject", text: $subject)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg"))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.color("bg-2"))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.color("line-soft"), lineWidth: 0.5))
                .disabled(busy)

            TextEditor(text: $bodyText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 150)
                .scrollContentBackground(.hidden)
                .background(theme.color("bg-2"))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.color("line-soft"), lineWidth: 0.5))
                .disabled(busy)

            if let error {
                InlineErrorStrip(message: error, onDismiss: {})
            }
        }
        .padding(12)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}
