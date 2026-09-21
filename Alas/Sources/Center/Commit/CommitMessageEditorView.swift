import AppKit
import SwiftUI

struct CommitAgentAvailabilityPresentation: Equatable {
    let message: String?
    let showsProgress: Bool
    let showsRetry: Bool
    let canGenerate: Bool

    static func make(
        availability: AgentAvailabilityState,
        target: AgentExecutionTarget
    ) -> Self {
        switch availability {
        case .loading:
            return .init(
                message: hostMessage(target, local: "Checking available agents…", remote: "Checking agents on %@…"),
                showsProgress: true,
                showsRetry: false,
                canGenerate: false
            )
        case .failed(let message):
            return .init(message: message, showsProgress: false, showsRetry: true, canGenerate: false)
        case .available(let agents) where agents.isEmpty:
            return .init(
                message: hostMessage(target, local: "No configured agents found.", remote: "No configured agents found on %@."),
                showsProgress: false,
                showsRetry: false,
                canGenerate: false
            )
        case .available:
            return .init(message: nil, showsProgress: false, showsRetry: false, canGenerate: true)
        }
    }

    private static func hostMessage(_ target: AgentExecutionTarget, local: String, remote: String) -> String {
        guard case .ssh(let host) = target else { return local }
        return String(format: remote, host)
    }
}

struct CommitMessageEditorView: View {
    @Binding var subject: String
    @Binding var bodyText: String
    @Binding var aiToolId: String
    let title: String
    let busy: Bool
    let error: String?
    let agentAvailability: AgentAvailabilityState
    let executionTarget: AgentExecutionTarget
    let onRetryAgentAvailability: () -> Void
    let onGenerate: () -> Void
    let primaryAction: CommitPrimaryAction
    var protectedTrailers: [ProtectedCommitTrailer] = []
    var alternateAction: CommitPrimaryAction? = nil
    var preferredActionPosition: CommitComposerActionPosition = .leading
    var iconName: String = "commit"
    var editorDisabled: Bool = false
    var onDismissError: () -> Void = {}
    var accessory: AnyView? = nil

    @Environment(\.theme) private var theme
    @State private var focused: Field?
    private enum Field: Hashable { case subject, body }

    private func canRun(_ action: CommitPrimaryAction) -> Bool {
        action.isEnabled && !busy
    }

    private func displayedLabel(for action: CommitPrimaryAction) -> String {
        if action.showSavedState, let saved = action.savedLabel {
            return saved
        }
        return action.label
    }

    private var agentPresentation: CommitAgentAvailabilityPresentation {
        CommitAgentAvailabilityPresentation.make(
            availability: agentAvailability,
            target: executionTarget
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if let message = agentPresentation.message {
                agentAvailabilityMessage(message)
            }
            subjectField
            bodyField
            if !protectedTrailers.isEmpty {
                protectedTrailersSection
            }
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
                availableAgents: agentAvailability.agents,
                selectedToolId: $aiToolId,
                busy: busy,
                onGenerate: onGenerate
            )
            .disabled(editorDisabled || !agentPresentation.canGenerate)
            actionButton(primaryAction, position: .leading)
            if let alternateAction {
                actionButton(alternateAction, position: .trailing)
            }
        }
    }

    @ViewBuilder
    private func agentAvailabilityMessage(_ message: String) -> some View {
        HStack(spacing: 6) {
            if agentPresentation.showsProgress {
                ProgressView().controlSize(.small)
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            if agentPresentation.showsRetry {
                AlasButton(title: "Retry", style: .subtle, action: onRetryAgentAvailability)
                    .disabled(busy || editorDisabled)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func actionButton(
        _ action: CommitPrimaryAction,
        position: CommitComposerActionPosition
    ) -> some View {
        let shortcut = shortcut(for: position)
        let isPreferred = alternateAction == nil || position == preferredActionPosition
        let emphasis: CommitComposerActionEmphasis = isPreferred ? .preferred : .subtle
        let enabled = canRun(action)
        Button(action: action.handler) {
            HStack(spacing: 8) {
                Text(displayedLabel(for: action))
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 2) {
                    ForEach(Array(kbdGlyphs(for: shortcut).enumerated()), id: \.offset) { _, glyph in
                        kbdBadge(glyph, emphasis: emphasis)
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 28)
            .foregroundColor(isPreferred ? .white : theme.color("fg"))
            .background(buttonBackground(isPreferred: isPreferred, enabled: enabled))
            .overlay {
                if !isPreferred {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(shortcut)
        .help(action.help ?? displayedLabel(for: action))
        .accessibilityIdentifier(action.accessibilityIdentifier ?? "commit-composer-\(position == .leading ? "primary" : "alternate")")
    }

    private func buttonBackground(isPreferred: Bool, enabled: Bool) -> Color {
        if isPreferred {
            return enabled ? theme.color("accent") : theme.color("accent").opacity(0.4)
        }
        return enabled ? theme.color("field-bg") : theme.color("field-bg").opacity(0.6)
    }

    private func shortcut(for position: CommitComposerActionPosition) -> KeyboardShortcut {
        let base = primaryAction.keyboardShortcut
            .flatMap { ShortcutBinding(keyboardShortcut: $0) }
            ?? ShortcutBinding(key: "return", modifiers: [.command])
        let preferred = alternateAction == nil ? CommitComposerActionPosition.leading : preferredActionPosition
        let binding = CommitComposerActionPair.shortcuts(preferred: preferred, base: base)
            .shortcut(at: position)
        if let shortcut = binding.asKeyboardShortcut() {
            return shortcut
        }
        return KeyboardShortcut(.return, modifiers: .command)
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

    private var protectedTrailersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GG metadata")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color("fg-faint"))
            ForEach(Array(protectedTrailers.enumerated()), id: \.offset) { _, trailer in
                HStack(spacing: 6) {
                    Text(trailer.name)
                        .foregroundStyle(theme.color("fg-faint"))
                    Text(trailer.value)
                        .foregroundStyle(theme.color("fg-dim"))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.color("field-bg").opacity(0.55))
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
    private func kbdBadge(_ text: String, emphasis: CommitComposerActionEmphasis) -> some View {
        let style = emphasis.badgeStyle
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .frame(minWidth: 14, minHeight: 14)
            .padding(.horizontal, 3)
            .background(badgeColor(style.background).opacity(style.backgroundOpacity))
            .foregroundColor(badgeColor(style.foreground).opacity(style.foregroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func badgeColor(_ color: CommitComposerActionBadgeColor) -> Color {
        switch color {
        case .systemWhite: return .white
        case .systemBlack: return .black
        case .theme(let token): return theme.color(token)
        }
    }
}
