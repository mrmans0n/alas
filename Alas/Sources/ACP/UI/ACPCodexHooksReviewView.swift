import SwiftUI

struct ACPCodexHooksReviewView: View {
    @ObservedObject var coordinator: ACPCodexHooksReviewCoordinator
    @Environment(\.theme) private var theme

    var body: some View {
        if let presentation = coordinator.presentation {
            VStack(alignment: .leading, spacing: 0) {
                header(presentation)
                introduction(presentation)
                if let snapshot = presentation.snapshot {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rows(snapshot)) { row in
                                CodexHookReviewRow(
                                    hook: row.hook,
                                    isUnique: snapshot.isUnique(row.hook.identity),
                                    isSelected: Binding(
                                        get: { coordinator.selection.contains(row.hook.identity) },
                                        set: { coordinator.setSelected(row.hook.identity, selected: $0, presentationID: presentation.id) }
                                    )
                                )
                            }
                            ForEach(diagnostics(snapshot)) { diagnostic in
                                diagnosticMessage(diagnostic.text, isError: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 280)
                    .disabled(presentation.isBusy)
                }
                if let error = presentation.error {
                    diagnosticMessage(error, isError: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                trustScope(presentation)
                actions(presentation)
            }
            .frame(maxWidth: 640)
            .background(
                LinearGradient(
                    colors: [theme.color("bg-2").opacity(0.6), theme.color("bg-1").opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .background(theme.color("bg-1"))
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
            }
            .shadow(color: theme.color("accent").opacity(0.10), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .tint(theme.color("accent"))
        }
    }

    private func header(_ presentation: ACPCodexHooksReviewCoordinator.Presentation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(theme.color("accent").opacity(0.18), in: .rect(cornerRadius: 4))
                .accessibilityHidden(true)
            Text("Codex hooks")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            if presentation.isBusy {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Checking hooks")
            } else {
                Circle().fill(theme.color("accent")).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                Text(presentation.isBusy ? "Checking hooks" : "Awaiting review")
                Text(presentation.isBusy ? "Checking" : "Review")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            Button("Refresh hooks", systemImage: "arrow.clockwise") {
                Task { await coordinator.refresh(presentationID: presentation.id) }
            }
            .disabled(presentation.isBusy)
            .help("Refresh hooks")
            Button("Cancel session startup", systemImage: "xmark") {
                coordinator.cancel(presentationID: presentation.id)
            }
            .help("Cancel session startup")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("accent"))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.color("accent").opacity(0.08))
    }

    private func introduction(_ presentation: ACPCodexHooksReviewCoordinator.Presentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Review startup hooks")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            Text("Choose which hooks to trust before starting your session.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .accessibilityHidden(true)
                Text("\(presentation.context.host) · \((presentation.context.cwd as NSString).lastPathComponent)")
                    .help(presentation.context.cwd)
                if let home = presentation.snapshot?.codexHome {
                    Text("·")
                    Text(home)
                        .font(.system(size: 10.5, design: .monospaced))
                        .truncationMode(.middle)
                        .help(home)
                }
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .padding(.top, 4)
        }
        .foregroundStyle(theme.color("fg-muted"))
        .padding(12)
    }

    private func trustScope(_ presentation: ACPCodexHooksReviewCoordinator.Presentation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(theme.color("accent"))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Trust applies across projects and Codex CLI.")
                    .foregroundStyle(theme.color("fg"))
                Text("Codex saves trusted hashes in this Codex home.")
                DisclosureGroup("Trust scope and paths") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Codex stores trust in CODEX_HOME/config.toml. Trusting a changed hook replaces the previous trusted hash for the same key.")
                        Text("Execution host: \(presentation.context.host)")
                        Text("Working directory: \(presentation.context.cwd)")
                        if let home = presentation.snapshot?.codexHome {
                            Text("Codex home: \(home)")
                        } else {
                            Text("The adapter has not reported its Codex home.")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(theme.color("fg-muted"))
        .lineSpacing(2)
        .padding(12)
    }

    private func actions(_ presentation: ACPCodexHooksReviewCoordinator.Presentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                continueButton(presentation)
                trustButton(presentation)
            }
            VStack(alignment: .trailing, spacing: 8) {
                continueButton(presentation)
                trustButton(presentation)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-1").opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5)
        }
    }

    private func continueButton(_ presentation: ACPCodexHooksReviewCoordinator.Presentation) -> some View {
        Button("Continue without trusting") {
            coordinator.continueWithoutTrusting(presentationID: presentation.id)
        }
        .buttonStyle(CodexHookReviewButtonStyle(isPrimary: false))
        .disabled(presentation.isBusy || presentation.snapshot == nil)
    }

    private func trustButton(_ presentation: ACPCodexHooksReviewCoordinator.Presentation) -> some View {
        let count = coordinator.selection.count
        let title = count == 0 ? "Trust selected & continue" : "Trust \(count) \(count == 1 ? "hook" : "hooks") & continue"
        return Button(title) {
            Task { await coordinator.trustSelectedAndContinue(presentationID: presentation.id) }
        }
        .buttonStyle(CodexHookReviewButtonStyle(isPrimary: true))
        .disabled(presentation.isBusy || coordinator.selection.isEmpty)
    }

    private func diagnosticMessage(_ text: String, isError: Bool) -> some View {
        Label {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isError ? "exclamationmark.circle" : "exclamationmark.triangle")
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.color(isError ? "del" : "warn"))
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(isError ? "del" : "warn").opacity(0.08), in: .rect(cornerRadius: 7))
    }

    private struct Diagnostic: Identifiable {
        let id: String
        let text: String
    }
    private func diagnostics(_ snapshot: ACPCodexHooksList) -> [Diagnostic] {
        var occurrences: [String: Int] = [:]
        return (snapshot.warnings + snapshot.errors.map { "\($0.path)\n\($0.message)" }).map { text in
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            return Diagnostic(id: "\(text)\u{0}\(occurrence)", text: text)
        }
    }

    private struct Row: Identifiable {
        let id: String
        let hook: ACPCodexHook
    }
    private func rows(_ snapshot: ACPCodexHooksList) -> [Row] {
        var occurrences: [ACPCodexHookIdentity: Int] = [:]
        return snapshot.hooks.map { hook in
            let occurrence = occurrences[hook.identity, default: 0]
            occurrences[hook.identity] = occurrence + 1
            return Row(id: "\(hook.key)\u{0}\(hook.currentHash)\u{0}\(occurrence)", hook: hook)
        }
    }
}

private struct CodexHookReviewRow: View {
    let hook: ACPCodexHook
    let isUnique: Bool
    @Binding var isSelected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: $isSelected) {
                    Text("\(eventTitle) · \(handlerTitle)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.color("fg"))
                }
                .toggleStyle(.checkbox)
                .disabled(!hook.canTrust || !isUnique)
                .accessibilityLabel("Trust \(eventTitle) hook, \(hook.key)")
                Spacer(minLength: 0)
                Text(hook.trustStatus.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.10), in: .rect(cornerRadius: 4))
            }
            Text(target)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(hook.source == "sessionFlags" ? "Launch configuration" : hook.source)
                Text("·")
                Text(shortKey).font(.system(size: 10.5, design: .monospaced))
                    .truncationMode(.middle)
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .help(hook.key)
            if !hook.isKnown || !isUnique {
                Label("Unknown or duplicate definition. This hook cannot be trusted here.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.color("warn"))
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(target)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.color("fg"))
                    detail("Key", hook.key)
                    detail("Source", "\(hook.sourcePath) · \(hook.source)")
                    detail("Event", "\(hook.eventName) · \(hook.handlerType)")
                    detail("Hash", hook.currentHash)
                    detail("Status", "\(hook.trustStatus) · \(hook.enabled ? "Enabled" : "Disabled") · \(hook.isManaged ? "Managed" : "Unmanaged")")
                    detail("Order", "\(hook.displayOrder)")
                    if let matcher = hook.matcher { detail("Matcher", matcher) }
                    detail("Timeout", "\(hook.timeoutSec) seconds")
                    if let async = hook.async { detail("Async", async ? "Yes" : "No") }
                    if let limit = hook.additionalContextLimit { detail("Context", "\(limit)") }
                    if let status = hook.statusMessage { detail("Message", status) }
                    if let plugin = hook.pluginId { detail("Plugin", plugin) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(theme.color("fg-muted"))
        .padding(10)
        .background(theme.color(isSelected ? "accent" : "bg-0").opacity(isSelected ? 0.08 : 0.45), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.color(isSelected ? "accent" : "line").opacity(isSelected ? 0.5 : 1), lineWidth: 0.5)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(theme.color("fg-dim")).frame(width: 48, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusColor: Color {
        switch hook.trustStatus {
        case "modified": theme.color("warn")
        case "trusted", "managed": theme.color("add")
        default: theme.color("fg-muted")
        }
    }

    private var shortKey: String {
        let prefix = hook.sourcePath + ":"
        return hook.key.hasPrefix(prefix) ? String(hook.key.dropFirst(prefix.count)) : hook.key
    }

    private var eventTitle: String {
        switch hook.eventName {
        case "preToolUse": "Before tool use"
        case "permissionRequest": "Permission request"
        case "postToolUse": "After tool use"
        case "preCompact": "Before compaction"
        case "postCompact": "After compaction"
        case "sessionStart": "Session start"
        case "sessionEnd": "Session end"
        case "userPromptSubmit": "Prompt submission"
        case "subagentStart": "Subagent start"
        case "subagentStop": "Subagent stop"
        case "stop": "Stop"
        case "interrupt": "Interrupt"
        default: hook.eventName
        }
    }

    private var handlerTitle: String {
        switch hook.handlerType {
        case "mcpTool": "MCP tool"
        default: hook.handlerType.capitalized
        }
    }

    private var target: String {
        switch hook.handlerType {
        case "command": hook.command ?? "Command unavailable"
        case "mcpTool": "\(hook.server ?? "Unknown server") / \(hook.tool ?? "Unknown tool")"
        case "prompt", "agent": "The adapter does not expose the full definition. Review its metadata and hash."
        default: "Handler details unavailable"
        }
    }
}

private struct CodexHookReviewButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(theme.color(isPrimary && isEnabled ? "bg-0" : "fg"))
            .background(theme.color(isPrimary && isEnabled ? "accent" : "bg-3"), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color(isPrimary && isEnabled ? "accent" : "line"), lineWidth: 0.5)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
