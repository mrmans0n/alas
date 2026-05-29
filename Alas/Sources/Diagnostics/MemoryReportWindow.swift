#if DEBUG
import AppKit
import SwiftUI

/// Debug-only window showing the most recent MemoryDiagnostics snapshot, sorted
/// by transcript bytes descending. Refreshes whenever `diagnostics.latest`
/// publishes — i.e. every tick.
@MainActor
struct MemoryReportView: View {
    @ObservedObject var diagnostics: MemoryDiagnostics

    /// Row wrapper to give `PerSession` an Identifiable conformance for `Table`.
    /// The `sessionId` alone may not be unique across worktrees, so the id
    /// composites the worktree id and the session id.
    private struct Row: Identifiable {
        let inner: MemorySnapshot.PerSession
        var id: String { "\(inner.worktreeId)|\(inner.sessionId)" }
    }

    private var rows: [Row] {
        (diagnostics.latest?.perSession ?? [])
            .sorted { $0.transcriptBytes > $1.transcriptBytes }
            .map { Row(inner: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snap = diagnostics.latest {
                Text(snap.oneLineLog())
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Divider()
                Table(rows) {
                    TableColumn("Worktree") { Text($0.inner.worktreeId).font(.system(.body, design: .monospaced)) }
                    TableColumn("Session") { Text($0.inner.sessionId.prefix(8) + "…").font(.system(.body, design: .monospaced)) }
                    TableColumn("Tx") { Text(MemorySnapshot.formatBinary($0.inner.transcriptBytes)) }
                    TableColumn("Md") { Text(MemorySnapshot.formatBinary($0.inner.markdownCacheBytes)) }
                    TableColumn("Msgs") { Text("\($0.inner.messageCount)") }
                    TableColumn("Attached") { Text($0.inner.attached ? "yes" : "no") }
                }
            } else {
                Text("Awaiting first tick…")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh now") {
                    diagnostics.refreshNow()
                }
                Spacer()
                Text("Updates every ~30s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
    }
}

@MainActor
final class MemoryReportWindowController: NSObject, NSWindowDelegate {
    static let shared = MemoryReportWindowController()
    private var window: NSWindow?

    func show(diagnostics: MemoryDiagnostics) {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Memory report"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: MemoryReportView(diagnostics: diagnostics))
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            window = nil
        }
    }
}

@MainActor
func openMemoryReport(state: AppState) {
    MemoryReportWindowController.shared.show(diagnostics: state.memoryDiagnostics)
}
#endif
