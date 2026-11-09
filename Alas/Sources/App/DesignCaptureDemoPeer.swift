#if DEBUG
import Foundation

/// Two scripted paired Macs for design captures, answering in-process what the
/// native peer views ask a real peer. Nothing listens, pairs or touches the
/// keychain: `DesignCaptureBridge` installs this behind a Debug-only seam.
@MainActor
final class DesignCaptureDemoPeer: FederatedPeerLinks {
    static let studio = FederatedPeerInfo(serverId: "demo-studio", name: "Studio Mac")
    static let air = FederatedPeerInfo(serverId: "demo-air", name: "MacBook Air")

    private struct DemoWorktree {
        let serverId: String
        let projectId: String
        let projectName: String
        let name: String
        let branch: String
        let path: String
        let isMain: Bool
        let added: Int
        let deleted: Int
        let changedFiles: Int
        var id: String { Worktree.makeId(path: URL(fileURLWithPath: path)) }
    }

    private struct DemoSession {
        let id: String
        let title: String
        let agentId: String
        let status: String
        let worktree: DemoWorktree
        let age: Int64
    }

    private static let invoicePath = "src/billing/InvoiceExporter.swift"

    private static let worktrees: [DemoWorktree] = [
        .init(serverId: studio.serverId, projectId: "demo-lantern", projectName: "lantern", name: "lantern", branch: "main",
              path: "/Users/demo/Code/lantern", isMain: true, added: 0, deleted: 0, changedFiles: 0),
        .init(serverId: studio.serverId, projectId: "demo-lantern", projectName: "lantern", name: "invoice-export",
              branch: "feat/invoice-export", path: "/Users/demo/Code/lantern/.worktrees/invoice-export",
              isMain: false, added: 48, deleted: 6, changedFiles: 3),
        .init(serverId: studio.serverId, projectId: "demo-lantern", projectName: "lantern", name: "retry-backoff-jitter",
              branch: "fix/retry-backoff-jitter", path: "/Users/demo/Code/lantern/.worktrees/retry-backoff-jitter",
              isMain: false, added: 3, deleted: 1, changedFiles: 1),
        .init(serverId: studio.serverId, projectId: "demo-lantern", projectName: "lantern", name: "team-invites",
              branch: "feat/team-invites", path: "/Users/demo/Code/lantern/.worktrees/team-invites",
              isMain: false, added: 212, deleted: 40, changedFiles: 7),
        .init(serverId: air.serverId, projectId: "demo-lantern-air", projectName: "lantern", name: "lantern", branch: "main",
              path: "/Users/demo/Developer/lantern", isMain: true, added: 0, deleted: 0, changedFiles: 0),
        .init(serverId: air.serverId, projectId: "demo-lantern-air", projectName: "lantern", name: "usage-charts",
              branch: "feat/usage-charts", path: "/Users/demo/Developer/lantern/.worktrees/usage-charts",
              isMain: false, added: 96, deleted: 12, changedFiles: 4),
    ]

    private static let sessions: [DemoSession] = [
        .init(id: "invoice", title: "Add CSV export for invoices", agentId: "claude", status: "streaming",
              worktree: worktrees[1], age: 40),
        .init(id: "retry", title: "Add jitter to retry backoff", agentId: "claude", status: "awaitingPermission",
              worktree: worktrees[2], age: 300),
        .init(id: "review", title: "Review the billing changes", agentId: "codex", status: "idle",
              worktree: worktrees[0], age: 5400),
        .init(id: "charts", title: "Empty state for usage charts", agentId: "claude", status: "idle",
              worktree: worktrees[5], age: 900),
    ]

    private static let consoleId = "demo-console-tests"

    // MARK: Links

    var sessionCarryingPeers: [FederatedPeerInfo] = []
    var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?

    private let anchor = Date()
    private weak var hosts: NativePeerHosts?
    private weak var consoles: NativePeerConsoles?

    func peerSupports(_ capability: String, serverId: String) -> Bool { true }

    func sendToPeer(_ message: RemoteClientMessage, serverId: String) {
        // Answers arrive asynchronously, as they would over a socket.
        Task { @MainActor [weak self] in self?.answer(message, serverId: serverId) }
    }

    /// Builds the client, wires its host and console channels back to this
    /// peer, and brings both Macs online. The returned client is not started.
    func makeClient(consoles makeConsoles: (_ send: @escaping @MainActor (String, RemoteClientMessage) -> Void) -> NativePeerConsoles)
        -> NativePeerSessions
    {
        let hosts = NativePeerHosts(
            send: { [weak self] serverId, message in self?.answerHost(message, serverId: serverId) },
            supports: { _, _ in true }
        )
        let consoles = makeConsoles { [weak self] serverId, message in
            Task { @MainActor [weak self] in self?.answer(message, serverId: serverId) }
        }
        self.hosts = hosts
        self.consoles = consoles
        let provider = FederatedSessionsProvider(links: self)
        return NativePeerSessions(
            federation: provider,
            peers: { [weak self] in
                (self?.sessionCarryingPeers ?? []).map { .init(serverId: $0.serverId, name: $0.name, state: "online") }
            },
            consoles: consoles,
            hosts: hosts
        )
    }

    /// Both Macs go online with their projects and sessions. Call after the
    /// client has started, so it is listening.
    func bringOnline() {
        for peer in [Self.studio, Self.air] {
            sessionCarryingPeers.append(peer)
            onFederationEvent?(.availabilityChanged(serverId: peer.serverId))
            deliver(.projectList(projects: projects(of: peer.serverId)), from: peer.serverId)
            deliver(.sessionList(sessions: sessionRows(of: peer.serverId)), from: peer.serverId)
        }
    }

    private func deliver(_ message: RemoteServerMessage, from serverId: String) {
        onFederationEvent?(.message(serverId: serverId, message))
    }

    // MARK: Session-scoped requests

    private func answer(_ message: RemoteClientMessage, serverId: String) {
        switch message {
        case .listSessions:
            deliver(.sessionList(sessions: sessionRows(of: serverId)), from: serverId)
        case .listProjects:
            deliver(.projectList(projects: projects(of: serverId)), from: serverId)
        case .listWorktrees:
            deliver(.worktreeList(worktrees: Self.worktrees.filter { $0.serverId == serverId }.map { worktree in
                RemoteWorktreeOption(
                    id: worktree.id, projectName: worktree.projectName, worktreeName: worktree.name, branch: worktree.branch,
                    path: worktree.path, metricsAvailable: true, comparisonRef: "origin/main", commitCount: worktree.isMain ? 0 : 2,
                    changedFileCount: worktree.changedFiles, addedLines: worktree.added, deletedLines: worktree.deleted,
                    conflictCount: 0, projectId: worktree.projectId)
            }), from: serverId)
        case .listAgents:
            deliver(.agentList(agents: [
                RemoteAgentOption(
                    id: "claude", name: "Claude", isDefault: true,
                    models: [.init(id: "opus", name: "Opus"), .init(id: "sonnet", name: "Sonnet")],
                    efforts: [.init(id: "medium", name: "Medium"), .init(id: "high", name: "High")]),
                RemoteAgentOption(id: "codex", name: "Codex", isDefault: false),
            ]), from: serverId)
        case .listBranches(let projectId):
            deliver(.branchList(
                projectId: projectId, branches: ["main", "develop", "feat/invoice-export", "feat/team-invites"],
                preferredBase: "main"), from: serverId)
        case .subscribe(let sessionId):
            subscribe(sessionId: sessionId, serverId: serverId)
        case .listChanges(let sessionId, _):
            deliver(changeList(id: sessionId), from: serverId)
        case .fileDiff(let sessionId, let path, let stage, _):
            deliver(fileDiff(id: sessionId, path: path, stage: stage), from: serverId)
        case .listFiles(let sessionId, let path, _):
            deliver(fileTree(id: sessionId, path: path), from: serverId)
        case .readFile(let sessionId, let path):
            deliver(.fileContents(sessionId: sessionId, path: path, text: Self.fileText(path), truncated: false), from: serverId)
        case .console(let request):
            answerConsole(request, serverId: serverId)
        default:
            break
        }
    }

    private func projects(of serverId: String) -> [RemoteProjectOption] {
        let ids = Set(Self.worktrees.filter { $0.serverId == serverId }.map(\.projectId))
        return Self.worktrees.filter { $0.serverId == serverId && ids.contains($0.projectId) }
            .reduce(into: [RemoteProjectOption]()) { rows, worktree in
                if !rows.contains(where: { $0.id == worktree.projectId }) {
                    rows.append(.init(id: worktree.projectId, name: worktree.projectName))
                }
            }
    }

    private func summary(_ worktree: DemoWorktree) -> RemoteWorktreeSummary {
        RemoteWorktreeSummary(
            projectName: worktree.projectName, worktreeName: worktree.name, branch: worktree.branch, path: worktree.path,
            metricsAvailable: true, comparisonRef: "origin/main", commitCount: worktree.isMain ? 0 : 2,
            changedFileCount: worktree.changedFiles, addedLines: worktree.added, deletedLines: worktree.deleted,
            conflictCount: 0, isMain: worktree.isMain)
    }

    private func sessionRows(of serverId: String) -> [RemoteSessionSummary] {
        Self.sessions.filter { $0.worktree.serverId == serverId }.enumerated().map { index, session in
            RemoteSessionSummary(
                id: session.id, title: session.title, agentId: session.agentId, status: session.status, canDrive: true,
                tabIndex: index, projectId: session.worktree.projectId, worktreeId: session.worktree.id,
                updatedAt: Int64(anchor.timeIntervalSince1970) - session.age, worktree: summary(session.worktree))
        }
    }

    // MARK: Transcripts

    private func subscribe(sessionId id: String, serverId: String) {
        guard let session = Self.sessions.first(where: { $0.id == id }) else { return }
        let rows = Self.transcript(for: session.id)
        deliver(.sessionConfig(RemoteSessionConfig(
            sessionId: id, models: [.init(id: "opus", name: "Opus"), .init(id: "sonnet", name: "Sonnet")],
            modes: [.init(id: "default", name: "Default"), .init(id: "plan", name: "Plan")],
            currentModel: "opus", currentMode: "default", autoRunEnabled: false, acceptsImages: true,
            usage: RemoteUsage(
                modelName: "Opus", context: RemoteContextWindow(used: 74_000, size: 200_000),
                lastTurn: [], cumulative: []))), from: serverId)
        deliver(.transcriptSnapshot(
            sessionId: id, streamingState: session.status == "streaming" ? "streaming" : "idle", canDrive: true,
            messages: rows, firstIndex: 0, totalCount: rows.count, epoch: 1, revision: 0), from: serverId)
        deliver(.queueState(sessionId: id, items: []), from: serverId)
        if session.status == "awaitingPermission" {
            deliver(.permissionRequest(sessionId: id, payload: RemotePermissionPayload(
                requestId: 7, toolName: "Bash",
                options: [
                    .init(optionId: "allow", name: "Allow once", kind: "allow_once"),
                    .init(optionId: "always", name: "Always allow", kind: "allow_always"),
                    .init(optionId: "reject", name: "Reject", kind: "reject_once"),
                ],
                title: "Run command?", reason: "Runs the retry tests with the new jitter.",
                commandSummary: "swift test --filter RetryPolicyTests")), from: serverId)
        }
    }

    private static func row(_ index: Int, _ kind: String, text: String? = nil, json: String? = nil) -> RemoteWireMessage {
        RemoteWireMessage(stableId: "demo-\(kind)-\(index)", kind: kind, text: text, json: json, index: index)
    }

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func toolCall(_ id: String, _ title: String, kind: String, name: String, status: String, content: String)
        -> String
    {
        json(["toolCallId": id, "title": title, "kind": kind, "name": name, "status": status, "content": content])
    }

    private static func transcript(for id: String) -> [RemoteWireMessage] {
        switch id {
        case "invoice":
            return [
                row(0, "user", text: "Add a CSV export for invoices. Stream large exports to disk and keep the column order stable."),
                row(1, "agent", text: "I'll start by reading how invoices are modelled, then add an exporter next to it."),
                row(2, "toolCall", json: toolCall(
                    "t1", "Read src/billing/Invoice.swift", kind: "read", name: "Read", status: "completed",
                    content: "struct Invoice {\n    let id: String\n    let customer: String\n    let totalCents: Int\n    let issuedAt: Date\n}")),
                row(3, "plan", json: json([
                    ["content": "Model the CSV columns", "status": "completed"],
                    ["content": "Write InvoiceExporter with streaming output", "status": "in_progress"],
                    ["content": "Escape quotes and newlines", "status": "pending"],
                    ["content": "Cover the exporter with tests", "status": "pending"],
                ])),
                row(4, "fileEdit", json: json([
                    "path": invoicePath, "added": 48, "removed": 6,
                    "oldText": "", "newText": fileText(invoicePath),
                ])),
                row(5, "toolCall", json: toolCall(
                    "t2", "swift test --filter InvoiceExporterTests", kind: "execute", name: "Bash", status: "completed",
                    content: "Test Suite 'InvoiceExporterTests' passed\n    Executed 6 tests, with 0 failures in 0.412 seconds")),
                row(6, "agent", text: "The exporter writes one row per invoice and flushes every 500 rows, so memory stays flat on large accounts.\n\nNext I'll escape embedded quotes and newlines, then add the failing-case tests."),
            ]
        case "retry":
            return [
                row(0, "user", text: "Retries all fire at once after an outage. Add jitter to the backoff."),
                row(1, "agent", text: "The backoff in `RetryPolicy` is deterministic, so every client retries on the same schedule. I'll add full jitter and a seeded generator for tests."),
                row(2, "fileEdit", json: json([
                    "path": "src/jobs/RetryPolicy.swift", "added": 3, "removed": 1,
                    "oldText": "let delay = base * pow(2, Double(attempt))\n",
                    "newText": "let ceiling = base * pow(2, Double(attempt))\nlet delay = Double.random(in: 0...ceiling, using: &generator)\n",
                ])),
                row(3, "agent", text: "Now I'll run the retry tests against the new schedule."),
            ]
        default:
            return [
                row(0, "user", text: "Anything risky in the billing changes?"),
                row(1, "agent", text: "Two things worth a second look: the exporter trusts `Invoice.customer` to be single-line, and `totalCents` is formatted without a locale. Neither blocks the change."),
            ]
        }
    }

    // MARK: Workspace

    private func changeList(id: String) -> RemoteServerMessage {
        .changeList(
            sessionId: id, comparisonRef: "origin/main", metricsAvailable: true,
            files: [
                .init(path: Self.invoicePath, status: "A", add: 36, del: 0, conflict: nil, renameFrom: nil),
                .init(path: "src/billing/Invoice.swift", status: "M", add: 9, del: 5, conflict: nil, renameFrom: nil),
                .init(path: "tests/InvoiceExporterTests.swift", status: "A", add: 3, del: 1, conflict: nil, renameFrom: nil),
            ],
            staged: [.init(path: "tests/InvoiceExporterTests.swift", status: "A", add: 3, del: 1, conflict: nil, renameFrom: nil)],
            unstaged: [
                .init(path: Self.invoicePath, status: "A", add: 36, del: 0, conflict: nil, renameFrom: nil),
                .init(path: "src/billing/Invoice.swift", status: "M", add: 9, del: 5, conflict: nil, renameFrom: nil),
            ],
            commits: [
                .init(sha: "9f3c2a1d", shortSha: "9f3c2a1", subject: "feat(billing): model the invoice CSV columns", author: "Nacho", add: 18, del: 2),
                .init(sha: "4be81c07", shortSha: "4be81c0", subject: "refactor(billing): split Invoice from its totals", author: "Nacho", add: 30, del: 4),
            ],
            truncated: false)
    }

    private func fileDiff(id: String, path: String, stage: String?) -> RemoteServerMessage {
        let lines: [RemoteDiffLine] = [
            .init(kind: "context", text: "import Foundation", oldNumber: 1, newNumber: 1),
            .init(kind: "context", text: "", oldNumber: 2, newNumber: 2),
            .init(kind: "delete", text: "struct Invoice {", oldNumber: 3, newNumber: nil),
            .init(kind: "add", text: "struct Invoice: Sendable {", oldNumber: nil, newNumber: 3),
            .init(kind: "context", text: "    let id: String", oldNumber: 4, newNumber: 4),
            .init(kind: "context", text: "    let customer: String", oldNumber: 5, newNumber: 5),
            .init(kind: "delete", text: "    let total: Double", oldNumber: 6, newNumber: nil),
            .init(kind: "add", text: "    let totalCents: Int", oldNumber: nil, newNumber: 6),
            .init(kind: "add", text: "    let issuedAt: Date", oldNumber: nil, newNumber: 7),
            .init(kind: "context", text: "}", oldNumber: 7, newNumber: 8),
        ]
        let second: [RemoteDiffLine] = [
            .init(kind: "context", text: "extension Invoice {", oldNumber: 20, newNumber: 21),
            .init(kind: "delete", text: "    var display: String { \"\\(customer): \\(total)\" }", oldNumber: 21, newNumber: nil),
            .init(kind: "add", text: "    var display: String {", oldNumber: nil, newNumber: 22),
            .init(kind: "add", text: "        \"\\(customer): \\(Double(totalCents) / 100)\"", oldNumber: nil, newNumber: 23),
            .init(kind: "add", text: "    }", oldNumber: nil, newNumber: 24),
            .init(kind: "context", text: "}", oldNumber: 22, newNumber: 25),
        ]
        return .fileDiffResult(sessionId: id, path: path, stage: stage, hunks: [
            RemoteDiffHunk(header: "@@ -1,7 +1,8 @@", oldStart: 1, newStart: 1, lines: lines),
            RemoteDiffHunk(header: "@@ -20,3 +21,6 @@ extension Invoice", oldStart: 20, newStart: 21, lines: second),
        ], truncated: false)
    }

    private func fileTree(id: String, path: String?) -> RemoteServerMessage {
        func dir(_ path: String) -> RemoteFileNode {
            .init(name: (path as NSString).lastPathComponent, path: path, kind: "dir", badge: nil, childrenState: "notLoaded", isSubmodule: false)
        }
        func file(_ path: String, badge: String? = nil) -> RemoteFileNode {
            .init(name: (path as NSString).lastPathComponent, path: path, kind: "file", badge: badge, childrenState: "loaded", isSubmodule: false)
        }
        switch path {
        case "src/billing":
            return .fileTree(sessionId: id, path: path, nodes: [
                file("src/billing/Invoice.swift", badge: "M"), file(Self.invoicePath, badge: "A"),
            ], truncated: false)
        case nil:
            return .fileTree(sessionId: id, path: nil, nodes: [dir("docs"), dir("src"), dir("tests"), file("README.md")], truncated: false)
        default:
            return .fileTree(sessionId: id, path: path, nodes: [], truncated: false)
        }
    }

    private static func fileText(_ path: String) -> String {
        if path == invoicePath {
            return """
            import Foundation

            /// Writes invoices as CSV, one row each, flushing in batches so a
            /// large account never holds the whole file in memory.
            struct InvoiceExporter {
                static let header = ["id", "customer", "total", "issued"]
                let flushEvery = 500

                func export(_ invoices: some Sequence<Invoice>, to handle: FileHandle) throws {
                    try handle.write(contentsOf: Data((Self.header.joined(separator: ",") + "\\n").utf8))
                    var pending = ""
                    var count = 0
                    for invoice in invoices {
                        pending += row(for: invoice) + "\\n"
                        count += 1
                        if count.isMultiple(of: flushEvery) {
                            try handle.write(contentsOf: Data(pending.utf8))
                            pending = ""
                        }
                    }
                    try handle.write(contentsOf: Data(pending.utf8))
                }

                private func row(for invoice: Invoice) -> String {
                    [invoice.id, escape(invoice.customer), String(invoice.totalCents), invoice.issuedAt.formatted(.iso8601)]
                        .joined(separator: ",")
                }

                private func escape(_ field: String) -> String {
                    guard field.contains(where: { ",\\"\\n".contains($0) }) else { return field }
                    return "\\"" + field.replacingOccurrences(of: "\\"", with: "\\"\\"") + "\\""
                }
            }

            """
        }
        return "# Lantern\n\nInvoices and usage billing for small teams.\n"
    }

    // MARK: Host channel

    private func answerHost(_ message: HostClientMessage, serverId: String) {
        let result: HostResponse? = switch message.request {
        case .snapshot: .snapshot(snapshot: hostSnapshot(serverId: serverId))
        case .subscribeAccepting: .subscribed
        case .readWorktree(let worktree, let read): .worktreeRead(reply: workspaceReply(id: worktree.path, read: read))
        default: nil
        }
        guard let result else { return }
        Task { @MainActor [weak self] in
            self?.hosts?.receive(serverId: serverId, .response(id: message.id, result: result))
        }
    }

    private func hostSnapshot(serverId: String) -> HostSnapshot {
        let mine = Self.worktrees.filter { $0.serverId == serverId }
        var seen = Set<String>()
        let projects = mine.compactMap { worktree -> ProjectSnapshot? in
            guard seen.insert(worktree.projectId).inserted else { return nil }
            let root = mine.first { $0.projectId == worktree.projectId && $0.isMain }?.path ?? worktree.path
            return ProjectSnapshot(ProjectConfig(
                id: worktree.projectId, name: worktree.projectName, path: root, color: "blue", addedAt: .distantPast))
        }
        return HostSnapshot(
            cursor: HostCursor(generation: UUID(), sequence: 0), projects: projects,
            worktrees: mine.map { worktree in
                WorktreeSnapshot(
                    worktree: Worktree(
                        id: worktree.id, projectId: worktree.projectId, name: worktree.name, branch: worktree.branch,
                        path: URL(fileURLWithPath: worktree.path), isMainWorktree: worktree.isMain,
                        status: worktree.changedFiles > 0 ? .dirty : .clean,
                        lastActivity: anchor.addingTimeInterval(-600), addedLines: worktree.added, deletedLines: worktree.deleted),
                    operation: nil, isArchived: false)
            },
            workspaceCheckouts: [], runs: [], sessions: [])
    }

    private func workspaceReply(id: String, read: HostWorktreeRead) -> RemoteServerMessage {
        switch read {
        case .changes: changeList(id: id)
        case .fileDiff(let path, let stage, _): fileDiff(id: id, path: path, stage: stage)
        case .files(let path, _): fileTree(id: id, path: path)
        case .file(let path): .fileContents(sessionId: id, path: path, text: Self.fileText(path), truncated: false)
        default: .fileUnavailable(sessionId: id, path: "", reason: .unknown, byteSize: nil, message: nil)
        }
    }

    // MARK: Consoles

    private func answerConsole(_ request: PeerConsoleRequest, serverId: String) {
        let events: [PeerConsoleEvent]
        switch request {
        case .list:
            let tree = Self.worktrees[1]
            events = [.list(consoles: serverId == Self.studio.serverId ? [
                PeerConsoleSummary(
                    consoleId: Self.consoleId, title: "swift test", worktreeId: tree.id, projectId: tree.projectId,
                    projectName: tree.projectName, worktreeName: tree.name, rows: 24, columns: 100,
                    worktree: summary(tree), tabIndex: 1),
            ] : [])]
        case .attach(_, let attachmentId, _):
            events = [
                .attached(attachmentId: attachmentId, rows: 24, columns: 100,
                          control: PeerConsoleControl(owner: .host, generation: 1, change: .current)),
                .snapshot(attachmentId: attachmentId, sequence: 0, reason: .initial, data: Data(Self.consoleScreen.utf8)),
            ]
        default:
            events = []
        }
        for event in events {
            consoles?.receive(serverId: serverId, event)
        }
    }

    private static let consoleScreen: String = {
        let green = "\u{1B}[32m", dim = "\u{1B}[2m", reset = "\u{1B}[0m", bold = "\u{1B}[1m"
        let lines = [
            "\(bold)nacho@studio\(reset) \(dim)~/Code/lantern/.worktrees/invoice-export\(reset) \(green)feat/invoice-export\(reset)",
            "$ swift test --filter InvoiceExporterTests",
            "\(dim)[1/3] Compiling lantern InvoiceExporter.swift\(reset)",
            "\(dim)[2/3] Linking lanternPackageTests\(reset)",
            "Test Suite 'InvoiceExporterTests' started",
            "\(green)Test Case 'writesHeaderFirst' passed\(reset) (0.004 seconds)",
            "\(green)Test Case 'flushesEveryFiveHundredRows' passed\(reset) (0.211 seconds)",
            "\(green)Test Case 'escapesEmbeddedQuotes' passed\(reset) (0.003 seconds)",
            "\(green)Test Case 'keepsColumnOrderStable' passed\(reset) (0.002 seconds)",
            "\(bold)Executed 4 tests, with 0 failures in 0.412 seconds\(reset)",
            "$ ",
        ]
        return lines.joined(separator: "\r\n")
    }()
}
#endif
