import SwiftUI

@MainActor
extension LSPServerChipModel {
    var badgeState: LSPBadgeState {
        switch self {
        case .serving(let status):
            switch status.phase {
            case .starting:
                .starting(language: status.language)
            case .indexing(let tasks):
                .indexing(
                    language: status.language,
                    percentage: LSPProgressSummary.percentage(tasks),
                    tooltip: LSPProgressSummary.tooltip(command: status.command, tasks: tasks)
                )
            case .ready:
                .ready(language: status.language, command: status.command)
            case .crashed:
                .problem(language: status.language, reason: .crashed)
            }
        case .unavailable(let language, let reason):
            .problem(language: language, reason: reason.problemReason)
        }
    }

    var headline: String {
        let state: String = switch self {
        case .serving(let status):
            switch status.phase {
            case .starting: "starting"
            case .indexing: "indexing"
            case .ready: "ready"
            case .crashed: "crashed"
            }
        case .unavailable(_, let reason):
            reason.problemReason.text
        }
        return "\(language) · \(state)"
    }
}

/// One server's chip in a diff or review toolbar.
struct LSPServerChip: View {
    let model: LSPServerChipModel
    let appState: AppState

    @State private var popoverOpen = false

    var body: some View {
        let state = model.badgeState
        Button { popoverOpen.toggle() } label: {
            LSPStatusPill(state: state, isHighlighted: popoverOpen)
        }
        .buttonStyle(.plain)
        .help(state.tooltip)
        .accessibilityLabel(Text("Language server status: \(state.label), \(state.tooltip)"))
        .accessibilityHint(Text("Shows details and actions for this language server"))
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            LSPServerChipPopoverBody(model: model, appState: appState) { popoverOpen = false }
                .padding(10)
                .frame(width: 300)
        }
    }
}

/// Header, detail, and actions for one server; shared by chips and the summary list.
struct LSPServerChipPopoverBody: View {
    let model: LSPServerChipModel
    let appState: AppState
    let dismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.headline).font(.system(size: 11, weight: .semibold))
            switch model {
            case .serving(let status):
                Text("\(status.command) · \(Self.location(of: status))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                LSPServerStatusDetail(phase: status.phase)
                HStack(spacing: 8) {
                    Button("Restart server") {
                        Task { await appState.lsp.restart(status: status) }
                        dismiss()
                    }
                    Button("Open settings", action: openSettings)
                }
            case .unavailable(_, let reason):
                Text(reason.explanation).font(.system(size: 11))
                HStack(spacing: 8) {
                    if reason == .notInstalled {
                        Button("Install…", action: openSettings)
                    }
                    Button("Open settings", action: openSettings)
                }
            }
        }
    }

    private func openSettings() {
        appState.pendingSettingsSection = .code
        openWindow(id: "settings")
        dismiss()
    }

    private static func location(of status: LSPServerStatus) -> String {
        if let host = status.remoteHost { return "\(host):\(status.root)" }
        return (status.root as NSString).abbreviatingWithTildeInPath
    }
}
