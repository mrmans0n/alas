import AlasRemoteKit
import SwiftUI

/// A worktree's terminals on one host: open one, start a new one, or close one.
struct TerminalsList: View {
    let hub: HostHub
    let hostID: UUID
    let worktreeId: String

    @State private var consoles: [PeerConsoleSummary]?
    @State private var listener: ListenerToken?
    /// The `open` this list is waiting on.
    @State private var opening: String?
    /// The console pushed, by id.
    @State private var shown: String?
    @State private var error: String?

    private var mine: [PeerConsoleSummary] {
        (consoles ?? []).filter { $0.worktreeId == worktreeId }
    }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
            }
            ForEach(mine, id: \.consoleId) { console in
                Button { shown = console.consoleId } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        Text(console.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(console.columns)×\(console.rows)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
                .swipeActions {
                    if hub.supports(PeerConsoleCapability.terminateV1, on: hostID) {
                        Button("Close", systemImage: "xmark", role: .destructive) {
                            hub.send(.console(.terminate(consoleId: console.consoleId)), to: hostID)
                        }
                    }
                }
            }
        }
        .overlay {
            if consoles == nil {
                ProgressView()
            } else if mine.isEmpty {
                ContentUnavailableView("No terminals", systemImage: "terminal",
                                       description: Text("Start one to run commands in this worktree on the Mac."))
            }
        }
        .navigationTitle("Terminals")
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if hub.supports(PeerConsoleCapability.openV1, on: hostID) {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Terminal", systemImage: "plus", action: open).disabled(opening != nil)
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let console = consoles?.first(where: { $0.consoleId == id }) {
                TerminalScreen(hub: hub, hostID: hostID, console: console)
            }
        }
        .onAppear {
            listener = hub.addListener(hostID) { message in
                if case .console(let event) = message { handle(event) }
            }
            hub.send(.console(.list), to: hostID)
        }
        .onDisappear { listener = nil }
    }

    private func open() {
        let requestId = UUID().uuidString
        opening = requestId
        error = nil
        // An unapproved session-open hook is skipped, not asked about: approving one belongs on the Mac.
        hub.send(.console(.open(requestId: requestId, worktreeId: worktreeId, repoHook: .skip)), to: hostID)
    }

    private func handle(_ event: PeerConsoleEvent) {
        switch event {
        case .list(let consoles):
            self.consoles = consoles
        case .opened(let requestId, let consoleId) where requestId == opening:
            opening = nil
            // The host lists the new console before it answers.
            shown = consoleId
        case .openFailed(let requestId, let message) where requestId == opening:
            opening = nil
            error = message
        default:
            break
        }
    }
}
