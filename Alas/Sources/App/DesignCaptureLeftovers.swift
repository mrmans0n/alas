#if DEBUG
import AlasCore
import AppKit
import Network
import SwiftUI

/// Design-capture targets for views no other capture reaches: the run report of a failed run, the
/// web preview, three small dialogs, the computer-use toolbar badge and the space pager. Each one is
/// scripted: nothing runs, no model is called, and the only network is a listener on this Mac's
/// loopback that serves one demo page. Debug builds only, and only on a capture profile.
///
/// - run-report: a failed run's report tab, with a scripted on-device failure brief.
/// - web-preview: the web preview tab on a demo page served from loopback.
/// - run-script-help: the "Help me write this" dialog of the script editor.
/// - new-run-script: the new run script dialog (the real sheet, over the demo repository).
/// - repo-hook-approval: the repository startup hook approval sheet over a demo hook; no hook runs.
/// - computer-use-badge: the badge in the agent toolbar, in its "Using the VM" state.
/// - space-pager: the sidebar's space pager, with two demo spaces added to the profile.
@MainActor
enum DesignCaptureLeftovers {
    static let targets: Set<String> = [
        "run-report", "web-preview", "run-script-help", "new-run-script", "repo-hook-approval",
        "computer-use-badge", "space-pager",
    ]

    static func open(_ target: String, state: AppState) {
        guard DesignCaptureWorkspace.isCaptureInstance, targets.contains(target) else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty || state.selectedWorktreeId.flatMap({ state.worktree(withId: $0) }) == nil {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let worktree = state.selectedWorktreeId.flatMap({ state.worktree(withId: $0) }) else { return }
            let theme = state.themeStore.current
            let scale = DesignScale.resolved(for: state.config.density)
            switch target {
            case "run-report":
                openRunReport(state: state, worktree: worktree)
            case "web-preview":
                if let url = await DemoPageServer.start() { state.openWebPreview(in: worktree, url: url) }
            case "run-script-help":
                DesignCaptureWorkspace.present(
                    RunScriptWritingHelpDialog(fileName: "dev-server.sh") { _ in }
                        .environment(\.theme, theme).environment(\.designScale, scale))
            case "new-run-script":
                state.newRunScript(scope: .repo, in: worktree)
            case "repo-hook-approval":
                DesignCaptureWorkspace.present(
                    RepoHookApprovalSheet(request: hookRequest, queue: RepoHookApprovalQueue())
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .environment(\.theme, theme).environment(\.designScale, scale))
            case "computer-use-badge":
                for case .acpSession(let session) in state.tabs.tabs(forWorktree: worktree.id) {
                    state.vmDrivingSessions.insert(session.sessionId)
                }
            case "space-pager":
                _ = state.spacesManager.addSpace(name: "Side projects", emoji: "🧪")
                _ = state.spacesManager.addSpace(name: "Open source", emoji: "🌱")
            default:
                break
            }
        }
    }

    // MARK: - run-report

    private static let failedOutput = """
    $ npm test -- --ci
    > lantern-web@2.4.1 test
    > jest --ci

     PASS  src/format/currency.test.ts
     PASS  src/billing/proration.test.ts
     FAIL  src/billing/invoice-export.test.ts
      ● invoice export › writes one row per line item

        expect(received).toEqual(expected)

        - Expected  - 1
        + Received  + 1

          Object {
            "currency": "EUR",
        -   "total": "1240.00",
        +   "total": "1240.0",
          }

          41 |     const rows = await exportInvoice(fixture.invoice)
          42 |     expect(rows[0]).toEqual({ currency: "EUR", total: "1240.00" })
        > 43 |     expect(rows[1].total).toBe("86.50")
             |                           ^
          44 |   })

          at Object.<anonymous> (src/billing/invoice-export.test.ts:43:27)

      ● invoice export › rejects an unknown currency

        TypeError: Cannot read properties of undefined (reading 'minorUnits')

          at minorUnits (src/format/currency.ts:18:31)
          at exportInvoice (src/billing/invoice-export.ts:57:20)

    Test Suites: 1 failed, 2 passed, 3 total
    Tests:       2 failed, 14 passed, 16 total
    Time:        4.182 s
    error: script "test" exited with code 1
    """

    private static func openRunReport(state: AppState, worktree: Worktree) {
        let now = Date()
        let runID = "demo-failed-run"
        let entry = RunHistoryEntry(
            id: runID, scriptKey: "repo:test", scriptName: "Test", worktreeID: worktree.id, branch: worktree.branch,
            target: RunExecutionTarget(host: nil, workingDirectory: worktree.path.path), endpoint: nil,
            outcome: .failed(exitCode: 1), startedAt: now.addingTimeInterval(-96), finishedAt: now.addingTimeInterval(-91),
            portConflict: nil, output: .available(text: failedOutput, truncated: false))
        state.openTransientRunReport(entry)
        let failure = RunScriptFailure(
            id: runID, runID: runID, scriptKey: entry.scriptKey, scriptName: entry.scriptName, worktreeID: worktree.id,
            branch: worktree.branch, exitCode: 1, completedAt: entry.finishedAt)
        // A scripted generator stands in for the on-device model.
        state.runFailureBriefs.start(
            failure,
            loadOutput: { entry.output },
            resolveGenerator: {
                { _ in
                    RunFailureBrief(
                        summary: "Two invoice export tests fail.",
                        cause: "The export writes totals without trailing zeros, and an unknown currency has no minor-unit entry, so minorUnits reads a missing value.",
                        checks: [
                            "Check how exportInvoice formats totals in src/billing/invoice-export.ts",
                            "Look at the currency table that minorUnits reads in src/format/currency.ts",
                        ])
                }
            })
    }

    // MARK: - repo-hook-approval

    private static var hookRequest: RepoHookApprovalRequest {
        let script = """
        #!/bin/sh
        set -eu
        npm ci --prefer-offline
        cp .env.example .env.local
        echo "Workspace ready"
        """
        let hook = RepoHook(
            event: .worktreeCreate, source: .local, bytes: Data(script.utf8), text: script, hash: "demo-hook-hash")
        return RepoHookApprovalRequest(id: UUID(), content: .hook(hook), context: .worktreeCreate)
    }

    // MARK: - web-preview

    /// Serves one page on this Mac's loopback so the web preview has something to load offline.
    @MainActor
    private enum DemoPageServer {
        private static var listener: NWListener?

        /// Touched only on the main queue, where the listener reports its state.
        private final class Once: @unchecked Sendable { var done = false }

        static func start() async -> URL? {
            if let port = listener?.port { return URL(string: "http://127.0.0.1:\(port.rawValue)/") }
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            guard let listener = try? NWListener(using: parameters, on: .any) else { return nil }
            Self.listener = listener
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                    let body = Data(page.utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            return await withCheckedContinuation { continuation in
                let once = Once()
                listener.stateUpdateHandler = { state in
                    guard !once.done else { return }
                    switch state {
                    case .ready:
                        once.done = true
                        continuation.resume(returning: listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/") })
                    case .failed, .cancelled:
                        once.done = true
                        continuation.resume(returning: nil)
                    default:
                        break
                    }
                }
                listener.start(queue: .main)
            }
        }

        private static let page = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Lantern billing</title>
        <style>
        body{margin:0;font:15px -apple-system,system-ui,sans-serif;background:#f6f7f9;color:#1c2330}
        header{display:flex;align-items:center;justify-content:space-between;padding:16px 32px;background:#fff;border-bottom:1px solid #e3e6ec}
        .brand{font-weight:700;font-size:17px}.brand span{color:#e08a2e}
        nav a{margin-left:20px;color:#5a6577;text-decoration:none}nav a.on{color:#1c2330;font-weight:600}
        main{max-width:880px;margin:32px auto;padding:0 24px}
        h1{font-size:22px;margin:0 0 4px}.sub{color:#6b7587;margin:0 0 24px}
        .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:24px}
        .card{background:#fff;border:1px solid #e3e6ec;border-radius:10px;padding:16px}
        .card b{display:block;font-size:24px;margin-top:6px}.card small{color:#6b7587}
        table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e3e6ec;border-radius:10px;overflow:hidden}
        th,td{text-align:left;padding:11px 16px;border-bottom:1px solid #eef0f4}th{font-size:12px;color:#6b7587;text-transform:uppercase;letter-spacing:.04em}
        .pill{padding:2px 9px;border-radius:99px;font-size:12px;font-weight:600}.paid{background:#e2f5e9;color:#1f7a3f}.due{background:#fdf0dc;color:#9a5b0b}.late{background:#fde4e4;color:#a12b2b}
        button{background:#e08a2e;color:#fff;border:0;border-radius:7px;padding:8px 14px;font-weight:600}
        </style></head><body>
        <header><div class="brand">Lantern <span>Billing</span></div><nav><a class="on">Invoices</a><a>Customers</a><a>Reports</a><a>Settings</a></nav></header>
        <main><div style="display:flex;justify-content:space-between;align-items:end"><div><h1>Invoices</h1><p class="sub">November 2026</p></div><button>Export CSV</button></div>
        <div class="cards"><div class="card"><small>Billed</small><b>EUR 48,210</b></div><div class="card"><small>Collected</small><b>EUR 41,870</b></div><div class="card"><small>Overdue</small><b>EUR 2,340</b></div></div>
        <table><tr><th>Invoice</th><th>Customer</th><th>Amount</th><th>Status</th></tr>
        <tr><td>INV-1042</td><td>Northwind Traders</td><td>EUR 1,240.00</td><td><span class="pill paid">Paid</span></td></tr>
        <tr><td>INV-1041</td><td>Fabrikam</td><td>EUR 86.50</td><td><span class="pill due">Due</span></td></tr>
        <tr><td>INV-1040</td><td>Contoso Ltd</td><td>EUR 3,900.00</td><td><span class="pill paid">Paid</span></td></tr>
        <tr><td>INV-1039</td><td>Tailspin Toys</td><td>EUR 612.25</td><td><span class="pill late">Overdue</span></td></tr>
        <tr><td>INV-1038</td><td>Adventure Works</td><td>EUR 2,075.00</td><td><span class="pill due">Due</span></td></tr></table></main>
        </body></html>
        """
    }
}
#endif
