import SwiftUI

/// What the activity pill and its run list can do. Runs are addressed by
/// script key, reports by run ID, failures by failure ID.
struct RunActivityActions {
    var stop: (String) -> Void = { _ in }
    var restart: (String) -> Void = { _ in }
    var showOutput: (String) -> Void = { _ in }
    var showReport: (String) -> Void = { _ in }
    var dismissFailure: (String) -> Void = { _ in }
}

/// Xcode-style activity pill beside ▶: what is running, for how long, and
/// how the last run ended. Clicking it opens the run list.
struct RunActivityPill: View {
    let input: RunActivityInput
    let actions: RunActivityActions

    @Environment(\.theme) private var theme
    @State private var showsRuns = false
    /// Bumped when a success linger ends so `body` re-reads the clock.
    @State private var clockTick = 0

    var body: some View {
        let _ = clockTick
        let presentation = RunActivityPresentation.make(input: input, now: Date())
        if presentation.pill != .none {
            pill(presentation)
        }
    }

    private func pill(_ presentation: RunActivityPresentation) -> some View {
        HStack(spacing: 2) {
            Button { showsRuns.toggle() } label: {
                HStack(spacing: 5) {
                    leadingMark(presentation)
                    summary(presentation.pill)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show runs")
            trailingButton(presentation.pill)
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.color(isFailure(presentation.pill) ? "del" : "fg"))
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 20)
        .frame(maxWidth: 160)
        .background(Capsule().fill(tint(presentation.pill).opacity(0.14)))
        .background(Capsule().fill(theme.color("bg-2")))
        .popover(isPresented: $showsRuns, arrowEdge: .bottom) {
            RunActivityList(rows: presentation.rows, actions: actions) { showsRuns = false }
        }
        .task(id: presentation.expiresAt) {
            guard let expiresAt = presentation.expiresAt else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
            } catch {
                return
            }
            clockTick &+= 1
        }
        .accessibilityIdentifier("run-activity-pill")
    }

    @ViewBuilder
    private func leadingMark(_ presentation: RunActivityPresentation) -> some View {
        switch presentation.pill {
        case .starting:
            ProgressView().controlSize(.mini)
        case .running, .runningMany:
            Circle()
                .fill(theme.color(presentation.hasUndismissedFailure ? "del" : "add"))
                .frame(width: 7, height: 7)
        case .succeeded:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.color("add"))
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func summary(_ pill: RunActivityPresentation.Pill) -> some View {
        switch pill {
        case .starting(_, let name):
            Text(name).lineLimit(1)
            Text("Starting…").foregroundStyle(theme.color("fg-muted"))
        case .running(_, let name, let startedAt):
            Text(name).lineLimit(1)
            Text(startedAt, style: .timer).monospacedDigit().foregroundStyle(theme.color("fg-muted"))
        case .runningMany(let count):
            Text("\(count) running")
        case .succeeded(let name, let duration):
            Text(name).lineLimit(1)
            Text(Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                .foregroundStyle(theme.color("fg-muted"))
        case .failed(_, _, let name, let exitCode):
            Text(name).lineLimit(1)
            Text("exit \(exitCode)").opacity(0.75)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func trailingButton(_ pill: RunActivityPresentation.Pill) -> some View {
        switch pill {
        case .starting(let scriptKey, _), .running(let scriptKey, _, _):
            iconButton("stop.fill", help: "Stop") { actions.stop(scriptKey) }
        case .runningMany:
            iconButton("chevron.down", help: "Show runs") { showsRuns.toggle() }
        case .failed(let failureID, _, _, _):
            iconButton("xmark", help: "Dismiss") { actions.dismissFailure(failureID) }
        case .succeeded, .none:
            EmptyView()
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("fg-muted"))
        .help(help)
    }

    private func isFailure(_ pill: RunActivityPresentation.Pill) -> Bool {
        if case .failed = pill { return true }
        return false
    }

    private func tint(_ pill: RunActivityPresentation.Pill) -> Color {
        switch pill {
        case .failed: theme.color("del")
        case .succeeded: theme.color("add")
        default: .clear
        }
    }
}

/// The popover behind the pill: active runs, then undismissed failures.
private struct RunActivityList: View {
    let rows: [RunActivityPresentation.Row]
    let actions: RunActivityActions
    let dismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    mark(row.kind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 12)).lineLimit(1)
                        detail(row)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("fg-muted"))
                    }
                    Spacer(minLength: 12)
                    ForEach(row.actions, id: \.self) { action in
                        Button(action.title) { perform(action, on: row) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .padding(6)
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private func mark(_ kind: RunActivityPresentation.Row.Kind) -> some View {
        switch kind {
        case .starting:
            ProgressView().controlSize(.mini)
        case .running:
            Circle().fill(theme.color("add")).frame(width: 7, height: 7)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.color("del"))
        }
    }

    @ViewBuilder
    private func detail(_ row: RunActivityPresentation.Row) -> some View {
        switch row.kind {
        case .starting:
            Text("Starting…")
        case .running:
            Text(row.since, style: .timer).monospacedDigit()
        case .failed(let exitCode):
            Text("exit \(exitCode) · \(row.since, style: .relative) ago")
        }
    }

    private func perform(_ action: RunActivityPresentation.RowAction, on row: RunActivityPresentation.Row) {
        dismiss()
        switch action {
        case .output:          actions.showOutput(row.scriptKey)
        case .restart, .rerun: actions.restart(row.scriptKey)
        case .stop:            actions.stop(row.scriptKey)
        case .report:          actions.showReport(row.runID)
        }
    }
}
