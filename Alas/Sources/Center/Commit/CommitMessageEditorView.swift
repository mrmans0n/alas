import AppKit
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
    var iconName: String = "commit"
    var editorDisabled: Bool = false
    var onDismissError: () -> Void = {}
    var accessory: AnyView? = nil

    @Environment(\.theme) private var theme
    @State private var focused: Field?
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
                InlineErrorStrip(message: error, onDismiss: onDismissError)
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
            Icon(name: iconName, size: 12, color: theme.color("accent"))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.middle)
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
            let effectiveShortcut = primaryAction.keyboardShortcut
                ?? KeyboardShortcut(.return, modifiers: .command)
            Button(action: primaryAction.handler) {
                HStack(spacing: 8) {
                    Text(displayedLabel)
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 2) {
                        ForEach(Array(kbdGlyphs(for: effectiveShortcut).enumerated()), id: \.offset) { _, g in
                            kbdBadge(g)
                        }
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
            .keyboardShortcut(effectiveShortcut)
        }
    }

    private var subjectField: some View {
        PairedTextField(
            text: $subject,
            placeholder: "Subject",
            font: .systemFont(ofSize: 12.5, weight: .medium),
            textColor: NSColor(theme.color("fg")),
            isEnabled: !(busy || editorDisabled),
            focusRingType: .none,
            isFocused: Binding(
                get: { focused == .subject },
                set: { value in
                    if value { focused = .subject }
                    else if focused == .subject { focused = nil }
                }
            )
        )
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
    }

    private var bodyField: some View {
        PairedTextEditor(
            text: $bodyText,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: NSColor(theme.color("fg")),
            isEnabled: !(busy || editorDisabled),
            isFocused: Binding(
                get: { focused == .body },
                set: { value in
                    if value { focused = .body }
                    else if focused == .body { focused = nil }
                }
            ),
            codeBlockStyle: .standard(
                theme: theme,
                baseFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                baseColor: NSColor(theme.color("fg")),
                monoSize: 12
            )
        )
            .frame(minHeight: 70, maxHeight: 150)
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
    }

    /// Render the modifier + key glyphs of a `KeyboardShortcut` for display
    /// in the in-button kbd badges. Order matches macOS menu convention:
    /// control, option, shift, command, then key. Falls back to the key's
    /// raw Character (uppercased) when no special glyph is known.
    private func kbdGlyphs(for shortcut: KeyboardShortcut) -> [String] {
        var out: [String] = []
        let mods = shortcut.modifiers
        if mods.contains(.control) { out.append("⌃") }
        if mods.contains(.option)  { out.append("⌥") }
        if mods.contains(.shift)   { out.append("⇧") }
        if mods.contains(.command) { out.append("⌘") }
        out.append(glyph(for: shortcut.key))
        return out
    }

    private func glyph(for key: KeyEquivalent) -> String {
        switch key {
        case .return:     return "⏎"
        case .tab:        return "⇥"
        case .space:      return "␣"
        case .escape:     return "⎋"
        case .delete:     return "⌫"
        case .leftArrow:  return "←"
        case .rightArrow: return "→"
        case .upArrow:    return "↑"
        case .downArrow:  return "↓"
        default:          return String(key.character).uppercased()
        }
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
