import SwiftUI
import AppKit

struct RunReportTabView: View {
    let state: AppState
    let tabState: RunReportTabState

    @Environment(\.theme) private var theme
    @State private var content = RunReportContent.loading

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView("Loading run report…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .report(entry):
                report(entry)
            case .missing:
                unavailable(
                    title: "Run report unavailable",
                    message: "This completed run is no longer in history. It may have been cleared or pruned."
                )
            case let .error(message):
                unavailable(title: "Could not load run report", message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(tabState.id):\(state.runHistoryRevision(worktreeID: tabState.worktreeId))") {
            await load()
        }
    }

    @ViewBuilder
    private func report(_ entry: RunHistoryEntry) -> some View {
        VStack(spacing: 0) {
            reportHeader(entry)
            reportOutput(entry.output)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func reportHeader(_ entry: RunHistoryEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.scriptName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                    outcomePill(entry.outcome)
                }
                Text(headerDetail(entry))
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.target.workingDirectory)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let endpoint = entry.endpoint {
                    Text(endpoint.absoluteString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if case let .available(text, _) = entry.output {
                Button("Copy Output") { Clipboard.copy(text) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    /// Matches the app's status-pill style (see `AgentTabPresentation`).
    private func outcomePill(_ outcome: RunOutcome) -> some View {
        let color = outcomeColor(outcome)
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(outcomeText(outcome))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Outcome: \(outcomeText(outcome))")
    }

    private func headerDetail(_ entry: RunHistoryEntry) -> String {
        [
            entry.branch,
            entry.target.hostLabel,
            entry.finishedAt.formatted(date: .abbreviated, time: .shortened),
            RunTabPresentation.format(duration: entry.duration),
        ].joined(separator: " · ")
    }

    @ViewBuilder
    private func reportOutput(_ output: RunHistoryOutput) -> some View {
        switch RunReportOutputPresentation.make(for: output) {
        case let .document(text, isTruncated):
            VStack(spacing: 0) {
                if isTruncated {
                    Label("Showing the final 1 MiB of output", systemImage: "scissors")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.quaternary)
                }
                ReadonlyTextView(
                    text: text,
                    font: CenterTypography.resolveCodeFont(
                        family: state.config.code.fontFamily,
                        size: CGFloat(state.config.code.fontSize)
                    ),
                    textColor: .labelColor,
                    backgroundColor: .clear
                )
            }
        case .unavailable:
            Text("Output could not be captured for this run.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func unavailable(title: String, message: String) -> some View {
        ContentUnavailableView(title, systemImage: "terminal", description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func outcomeText(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .succeeded: "Succeeded"
        case let .failed(exitCode): "Failed (exit \(exitCode))"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
    }

    private func outcomeColor(_ outcome: RunOutcome) -> Color {
        switch outcome {
        case .succeeded: theme.color("add")
        case .failed: theme.color("del")
        case .stopped: theme.color("warn")
        case .unknown: theme.color("fg-faint")
        }
    }

    @MainActor
    private func load() async {
        if let entry = state.transientRunReport(worktreeID: tabState.worktreeId, runID: tabState.runID) {
            content = .report(entry)
            return
        }
        guard let history = state.runHistoryStore else {
            content = .error("Run history storage is unavailable.")
            return
        }
        do {
            content = try await history.entry(id: tabState.runID).map(RunReportContent.report) ?? .missing
        } catch {
            content = .error(error.localizedDescription)
        }
    }
}

private enum RunReportContent: Equatable {
    case loading
    case report(RunHistoryEntry)
    case missing
    case error(String)
}
