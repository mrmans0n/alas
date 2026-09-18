import SwiftUI
import AppKit

struct RunReportTabView: View {
    let state: AppState
    let tabState: RunReportTabState

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
            Divider()
            reportOutput(entry.output)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func reportHeader(_ entry: RunHistoryEntry) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.scriptName)
                        .font(.headline)
                    Text("\(entry.branch) • \(entry.target.hostLabel) • \(entry.finishedAt.formatted(date: .abbreviated, time: .shortened)) • \(RunTabPresentation.format(duration: entry.duration))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(outcomeText(entry.outcome))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(outcomeColor(entry.outcome).opacity(0.16), in: Capsule())
                    .foregroundStyle(outcomeColor(entry.outcome))
            }
            if case let .available(text, _) = entry.output {
                Button("Copy Output") { Clipboard.copy(text) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
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
        case .succeeded: .green
        case .failed: .red
        case .stopped: .orange
        case .unknown: .secondary
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
