import AppKit
import SwiftUI

/// A paired host's Run tab for one of its worktrees: the scripts it lists and
/// its latest runs, with Run, Stop and Rerun sent to the host. A finished
/// run's output opens in a sheet.
struct NativePeerRunTabView: View {
    let hosts: NativePeerHosts
    let serverId: String
    let worktree: PeerHostWorktree
    let hostName: String
    let refreshGeneration: Int
    /// The host's listed consoles, so a run's console can be opened.
    let consoleIds: Set<String>
    let openConsole: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var scripts: [HostRunScript]?
    /// The `serverId|worktreeID` whose listing answered, so a worktree shows
    /// the skeleton until its first answer but a refresh does not.
    @State private var answeredWorktree: String?
    @State private var output: PeerRunOutput?
    /// Scripts with a request still unanswered, so a double click sends one.
    @State private var inFlight: Set<String> = []
    /// Drives the relative timestamps ("3m ago"), as `RunTabView` does.
    @State private var now = Date()
    @State private var ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var worktreeKey: String { "\(serverId)|\(worktree.snapshot.worktree.id)" }

    var body: some View {
        Group {
            if answeredWorktree != worktreeKey {
                RightPaneLoadingSkeletonView(activeTab: .run)
            } else {
                let rows = PeerRuns.rows(
                    scripts: scripts, runs: hosts.runs[serverId] ?? [], worktreeID: worktree.snapshot.worktree.id
                )
                VStack(spacing: 0) {
                    if scripts == nil {
                        NativePeerRailMessage(text: "\(hostName) did not list this worktree's run scripts.")
                    }
                    if rows.isEmpty {
                        if scripts != nil { emptyState }
                    } else {
                        list(rows)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(worktreeKey)|\(refreshGeneration)") {
            let key = worktreeKey
            let listed = await hosts.runScripts(in: worktree, serverId: serverId)
            guard !Task.isCancelled else { return }
            scripts = listed
            answeredWorktree = key
            now = Date()
        }
        .onReceive(ticker) { now = $0 }
        .sheet(item: $output) { output in
            PeerRunOutputSheet(output: output) { self.output = nil }
        }
    }

    private func list(_ rows: [PeerRuns.Row]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(RunScriptScope.allCases, id: \.self) { scope in
                    let scoped = rows.filter { $0.script.scope == scope }
                    if !scoped.isEmpty {
                        RunScopeHeader(title: scope.sectionTitle, count: scoped.count)
                        ForEach(scoped, id: \.script.key) { row in
                            RunRowView(
                                presentation: RunTabPresentation.peerRow(
                                    row, hostName: hostName, consoleIds: consoleIds,
                                    servesForward: hosts.servesForward(serverId: serverId), now: now
                                ),
                                onAction: { perform($0, on: row) }
                            )
                        }
                    }
                }
            }
            .padding(.top, PaneBandLayout.outerVertical)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Icon(name: "play", size: 22, color: theme.color("fg-faint"))
            Text("No run scripts yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text("Add a script to \(RunScriptStore.repoScriptsRelativeDir) on \(hostName) to build, test, or serve this worktree.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func perform(_ action: RunRowAction, on row: PeerRuns.Row) {
        let command: PeerRuns.Command
        switch action {
        case .start: command = .start
        case .stop: command = .stop
        case .restart: command = .restart
        case .showReport(let runID): command = .output(runID: runID)
        case .openTerminal:
            if let sessionID = row.record?.sessionID { openConsole(sessionID) }
            return
        case .openEndpoint(let endpoint):
            openEndpoint(endpoint, of: row)
            return
        case .edit: return
        }
        let key = "\(worktreeKey)|\(row.script.key)"
        guard inFlight.insert(key).inserted else { return }
        let hosts = hosts, worktree = worktree, serverId = serverId
        Task {
            let reply = await hosts.perform(command, on: row, in: worktree, serverId: serverId)
            inFlight.remove(key)
            switch reply {
            case .done: break
            case .refused(let title, let message): hosts.showError(title, message)
            case .output(let presentation):
                guard case .output(let runID) = command else { return }
                output = PeerRunOutput(id: runID, scriptName: row.script.name, presentation: presentation)
            }
        }
    }

    /// A loopback endpoint opens through the host's forward; any other as declared.
    private func openEndpoint(_ endpoint: URL, of row: PeerRuns.Row) {
        guard PeerPortForwardEndpoint.isLoopback(endpoint), let runID = row.record?.id else {
            NSWorkspace.shared.open(endpoint)
            return
        }
        let hosts = hosts, serverId = serverId
        Task {
            guard let local = await hosts.forwardedEndpoint(endpoint, runID: runID, serverId: serverId) else { return }
            NSWorkspace.shared.open(local)
        }
    }
}

private struct PeerRunOutput: Identifiable {
    /// The run's id.
    let id: String
    let scriptName: String
    let presentation: RunReportOutputPresentation
}

private struct PeerRunOutputSheet: View {
    let output: PeerRunOutput
    let onClose: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(output.scriptName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            switch output.presentation {
            case .document(let text, let isTruncated):
                if isTruncated {
                    Text("Only the end of the output was kept.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .unavailable:
                Text("This run's output was not kept.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 480)
    }
}
