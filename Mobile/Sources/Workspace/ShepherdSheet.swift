import AlasRemoteKit
import SwiftUI

/// The session's pull request as the Mac's Ship popover shows it: the request's header, checks and
/// threads, or a stack's entries, the shepherd's state and switches; Ship with Agent without one.
struct ShepherdSheet: View {
    let workspace: SessionWorkspace
    let isBusy: Bool
    @Environment(\.dismiss) private var dismiss
    /// Shows a refusal on the pill, which outlives this sheet.
    let reportError: (String) -> Void

    var body: some View {
        let shepherd = workspace.shepherd
        NavigationStack {
            Form {
                if let shepherd {
                    if let detail = shepherd.detail, let entries = detail.stackEntries {
                        stackHeader(detail)
                        StackEntriesSection(entries: entries)
                        statusSection(shepherd, detail: detail, isStack: true)
                    } else if let detail = shepherd.detail {
                        RequestHeaderSection(number: shepherd.number, detail: detail)
                        ChecksSection(checks: detail.checks)
                        if detail.openThreads != nil { reviewsSection(detail) }
                        statusSection(shepherd, detail: detail, isStack: false)
                    } else {
                        statusSection(shepherd, detail: nil, isStack: false)
                    }
                    actionsSection(shepherd)
                } else {
                    unboundContent
                }
            }
            .navigationTitle(shepherd?.number ?? "Ship")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .onAppear { workspace.refreshShepherd() }
    }

    // MARK: Bound

    private func stackHeader(_ detail: RemoteShepherd.Detail) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.branch ?? "Stack").font(.headline)
                Text(detail.provider).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reviewsSection(_ detail: RemoteShepherd.Detail) -> some View {
        Section("Reviews") {
            Label(Self.reviewLine(open: detail.openThreads ?? 0, trusted: detail.trustedThreads ?? 0),
                  systemImage: "text.bubble")
        }
    }

    /// `ShepherdPopover.reviewLines`' wording.
    private static func reviewLine(open: Int, trusted: Int) -> String {
        open == 0
            ? "No open review threads"
            : "\(open) open thread\(open == 1 ? "" : "s"), \(trusted) from trusted reviewers"
    }

    @ViewBuilder
    private func statusSection(_ shepherd: RemoteShepherd, detail: RemoteShepherd.Detail?, isStack: Bool) -> some View {
        let disabled = shepherd.isFinished || workspace.shepherdRunning != nil
        Section {
            Label {
                Text(shepherd.phaseLine ?? shepherd.tooltip)
            } icon: {
                Image(systemName: ShepherdPill.badgeSymbol(shepherd.badge))
                    .foregroundStyle(ShepherdPill.color(shepherd.badge))
            }
            if let detail, detail.fixAttemptBudget > 0 {
                Text("Attempt \(detail.fixAttempts) of \(detail.fixAttemptBudget)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if detail == nil, shepherd.phaseLine != nil, !shepherd.tooltip.isEmpty {
                Text(shepherd.tooltip).font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        } footer: {
            if isStack {
                Text("The stack lands with Land in the stack drawer; the shepherd never merges it.")
            }
        }
        if let autoFix = shepherd.autoFix {
            Section {
                Toggle("Auto-fix", isOn: Binding(
                    get: { autoFix }, set: { run($0 ? .enableAutoFix : .disableAutoFix) }))
                    .disabled(disabled)
            } footer: {
                Text("CI failures, conflicts and reviewer threads go back to this session")
            }
        }
        if let autoMerge = shepherd.autoMerge {
            Section {
                Toggle("Auto-merge", isOn: Binding(
                    get: { autoMerge }, set: { run($0 ? .enableAutoMerge : .disableAutoMerge) }))
                    .disabled(disabled)
            } footer: {
                Text("Squash-merge once checks, reviewers and the head are settled")
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ shepherd: RemoteShepherd) -> some View {
        let actions = RemoteShepherd.offered(for: shepherd)
        if !actions.isEmpty {
            Section {
                ForEach(actions, id: \.self) { action in
                    Button(role: action == .stop ? .destructive : nil) { run(action) } label: {
                        Label(action == .stop ? "Stop Shepherding" : "Resume",
                              systemImage: action == .stop ? "stop" : "play")
                    }
                    .disabled(workspace.shepherdRunning != nil)
                }
            }
        }
    }

    // MARK: Unbound

    @ViewBuilder
    private var unboundContent: some View {
        let invites = ShepherdPill.invitesShip(shepherd: nil, isBusy: isBusy)
        Section {
            Text(workspace.shipsStack
                ? "The agent publishes every stack entry as its own pull request."
                : "The agent writes the description and opens the pull request on the code host.")
            Text("Alas watches CI and reviews, and sends failures back to this session.")
                .foregroundStyle(.secondary)
        }
        Section {
            Button {
                ship()
            } label: {
                HStack {
                    Spacer()
                    if workspace.shepherdRunning == .ship {
                        ProgressView()
                    } else {
                        Label("Ship with Agent",
                              systemImage: workspace.shipsStack ? "square.stack.3d.up.fill" : "paperplane.fill")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(!invites || workspace.shepherdRunning != nil)
        } footer: {
            if isBusy { Text("Available after the current turn") }
        }
    }

    // MARK: Actions

    private func run(_ action: RemoteShepherdAction) {
        Task {
            if let refusal = await workspace.shepherd(action) { reportError(refusal) }
        }
    }

    private func ship() {
        Task {
            if let refusal = await workspace.shepherd(.ship) {
                reportError(refusal)
            } else {
                dismiss()
            }
        }
    }
}

/// The request's number, title, route and a link to it.
private struct RequestHeaderSection: View {
    let number: String?
    let detail: RemoteShepherd.Detail

    var body: some View {
        let caption = [detail.branch, detail.headSHA.map { String($0.prefix(7)) }, detail.provider]
            .compactMap { $0 }
            .joined(separator: " · ")
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let number {
                        Text(number)
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    if let title = detail.title {
                        Text(title).font(.body.weight(.semibold))
                    }
                }
                Text(caption)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let url = detail.url {
                Link(destination: url) {
                    Label("Open \(detail.requestLabel) in Browser", systemImage: "arrow.up.right.square")
                }
            }
        }
    }
}

/// One row per CI check, tinted by its `ReviewCheckBucket`.
private struct ChecksSection: View {
    let checks: [RemoteShepherd.Check]?

    var body: some View {
        Section("Checks") {
            if let checks {
                if checks.isEmpty {
                    Label("No CI checks", systemImage: "checkmark.seal")
                } else {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        row(check)
                    }
                }
            } else {
                Label("Waiting for the first status check.", systemImage: "hourglass")
            }
        }
    }

    @ViewBuilder
    private func row(_ check: RemoteShepherd.Check) -> some View {
        let label = Label {
            Text(check.name).foregroundStyle(.primary)
        } icon: {
            Image(systemName: Self.symbol(check.bucket)).foregroundStyle(Self.tint(check.bucket))
        }
        if let url = check.url {
            Link(destination: url) { label }
        } else {
            label
        }
    }

    private static func symbol(_ bucket: String) -> String {
        switch bucket {
        case "pass": "checkmark.circle.fill"
        case "fail": "xmark.circle.fill"
        case "pending": "clock"
        default: "minus.circle"
        }
    }

    private static func tint(_ bucket: String) -> Color {
        switch bucket {
        case "pass": .green
        case "fail": .red
        case "pending": .yellow
        default: .secondary
        }
    }
}

/// A shepherded stack's entries, highest position first as the host sends them.
private struct StackEntriesSection: View {
    let entries: [RemoteShepherd.StackEntry]

    var body: some View {
        Section("Entries") {
            ForEach(entries, id: \.number) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: ShepherdPill.badgeSymbol(entry.badge))
                        .foregroundStyle(ShepherdPill.color(entry.badge))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(entry.position)").foregroundStyle(.secondary).monospacedDigit()
                            if let url = entry.url {
                                Link(entry.number, destination: url).font(.body.monospaced())
                            } else {
                                Text(entry.number).font(.body.monospaced())
                            }
                            Text(entry.title).lineLimit(1)
                        }
                        Text(entry.phaseLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
