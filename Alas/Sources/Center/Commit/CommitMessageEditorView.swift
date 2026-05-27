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
    @FocusState private var focused: Field?
    private enum Field: Hashable { case subject, body }

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
            headerRow
            subjectField
            bodyField
            if let error {
                InlineErrorStrip(message: error, onDismiss: {})
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [theme.color("composer-bg-top"), theme.color("composer-bg-bot")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.clear,
                    theme.color("accent-glow"),
                    Color.clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Icon(name: "commit", size: 12, color: theme.color("accent"))
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
                HStack(spacing: 8) {
                    Text(displayedLabel)
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 2) {
                        kbdBadge("⌘")
                        kbdBadge("⏎")
                    }
                }
                .padding(.leading, 14).padding(.trailing, 12)
                .frame(height: 28)
                .foregroundColor(.white)
                .background(canRunPrimary ? theme.color("accent") : theme.color("accent").opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!canRunPrimary)
            // Default to ⌘⏎ so existing-commit callers (which pass
            // nil) keep their save shortcut. Draft callers pass their
            // own value (which is also ⌘⏎ via shortcut settings).
            .keyboardShortcut(primaryAction.keyboardShortcut ?? KeyboardShortcut(.return, modifiers: .command))
        }
    }

    private var subjectField: some View {
        TextField("Subject", text: $subject)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(theme.color("fg"))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.color("field-bg"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        focused == .subject ? theme.color("accent") : theme.color("line"),
                        lineWidth: focused == .subject ? 1 : 0.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focused == .subject ? theme.color("accent-glow-soft") : .clear,
                        lineWidth: 2
                    )
                    .padding(-2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .focused($focused, equals: .subject)
            .disabled(busy)
    }

    private var bodyField: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 70, maxHeight: 150)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(theme.color("field-bg"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        focused == .body ? theme.color("accent") : theme.color("line"),
                        lineWidth: focused == .body ? 1 : 0.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focused == .body ? theme.color("accent-glow-soft") : .clear,
                        lineWidth: 2
                    )
                    .padding(-2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .focused($focused, equals: .body)
            .disabled(busy)
    }

    @ViewBuilder
    private func kbdBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .frame(minWidth: 14, minHeight: 14)
            .padding(.horizontal, 3)
            .background(Color.black.opacity(0.25))
            .foregroundColor(.white.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
