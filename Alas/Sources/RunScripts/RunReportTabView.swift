import SwiftUI

struct RunReportTabView: View {
    let state: AppState
    let tabState: RunReportTabState

    @State private var content = RunReportContent.loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch content {
                case .loading:
                    ProgressView("Loading run report…")
                        .frame(maxWidth: .infinity, minHeight: 220)
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
            .frame(maxWidth: 1_000, alignment: .leading)
            .padding(28)
        }
        .task(id: "\(tabState.id):\(state.runHistoryRevision)") {
            await load()
        }
    }

    @ViewBuilder
    private func report(_ entry: RunHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.scriptName)
                        .font(.title2.weight(.semibold))
                    Text("\(entry.branch) • \(entry.target.hostLabel)")
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
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Finished").foregroundStyle(.secondary)
                    Text(entry.finishedAt.formatted(date: .abbreviated, time: .standard))
                }
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    Text(RunTabPresentation.format(duration: entry.duration))
                }
                GridRow {
                    Text("Directory").foregroundStyle(.secondary)
                    Text(entry.target.workingDirectory).textSelection(.enabled)
                }
                if let endpoint = entry.endpoint {
                    GridRow {
                        Text("Endpoint").foregroundStyle(.secondary)
                        Text(endpoint.absoluteString).textSelection(.enabled)
                    }
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output")
                    .font(.headline)
                Spacer()
                if case let .available(text, _) = entry.output {
                    Button("Copy Output") { Clipboard.copy(text) }
                }
            }
            output(entry.output)
        }
    }

    @ViewBuilder
    private func output(_ output: RunHistoryOutput) -> some View {
        switch output {
        case let .available(text, truncated):
            Text(text.isEmpty ? "No output was produced." : text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if truncated {
                Label("Showing the final 1 MiB of output", systemImage: "scissors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            Text("Output could not be captured for this run.")
                .foregroundStyle(.secondary)
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
