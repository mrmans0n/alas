#if DEBUG
import Foundation
import Observation

/// Design-capture targets for the Attention inbox. The sidebar header reads
/// its aggregation from here instead of the real store while a target is
/// active, so demo rows never reach (or come from) the user's attention
/// store. Debug builds only.
@MainActor
@Observable
final class DesignCaptureAttention {
    static let shared = DesignCaptureAttention()
    static let targets: Set<String> = ["attention-inbox", "attention-rollup"]

    struct Content {
        let aggregation: AttentionAggregation
        let peerRows: [RemoteSessionSummary]
        let cleanupReminders: [WorktreeCleanupReminder]
    }

    private(set) var content: Content?
    /// Set by `attention-rollup`: the inbox runs its roll-up when it appears.
    private(set) var autoSummarize = false

    /// A summarizer that answers with fixed groups instead of running a model.
    func summarizer(engine: any LocalTextGenerating) -> AttentionRollUpSummarizer? {
        guard content != nil else { return nil }
        return AttentionRollUpSummarizer(
            engine: engine,
            isAppleIntelligenceAvailable: { true },
            generateWithAppleIntelligence: { Self.rollUpJSON(for: $0) },
            isMLXAvailable: { false }
        )
    }

    func open(_ target: String, state: AppState) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty || state.projectsManager.worktrees(projectId: state.projects[0].id).isEmpty {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            content = Self.makeContent(state: state)
            autoSummarize = target == "attention-rollup"
            try? await Task.sleep(for: .milliseconds(500))
            state.openAttentionInbox()
        }
    }

    // MARK: - Roll-up

    /// Groups the request's items by kind. The request lists items as
    /// `{"id": n, "kind": "..."}` in inbox order.
    private static func rollUpJSON(for request: LocalTextGenerationRequest) -> String? {
        struct Payload: Decodable {
            struct Item: Decodable { let id: Int; let kind: String }
            let items: [Item]
        }
        guard let user = request.messageCandidates.first?.last(where: { $0.role == .user }),
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(user.content.utf8))
        else { return nil }
        let groups: [(summary: String, kinds: Set<String>)] = [
            ("Agents on four branches are asking for permission or input, or finished a turn.",
             ["agentPermission", "agentAwaiting", "agentFinished"]),
            ("Run scripts and CI checks failed on three branches.",
             ["runScriptFailure", "failedChecks"]),
            ("One worktree has merge conflicts and a reviewer replied to feedback on another.",
             ["conflicts", "reviewReply"]),
            ("The build-box remote host stopped responding.", ["hostDisconnected"]),
        ]
        let encoded = groups.compactMap { group -> [String: Any]? in
            let ids = payload.items.filter { group.kinds.contains($0.kind) }.map(\.id)
            return ids.isEmpty ? nil : ["summary": group.summary, "items": ids]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["groups": encoded]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Demo rows

    private static func makeContent(state: AppState) -> Content {
        let now = Date()
        let project = state.projects[0]

        func local(_ branch: String) -> (AttentionWorktreeIdentity, AttentionResolvedWorktree, AttentionWorktreeDisplaySnapshot)? {
            guard let worktree = state.projectsManager.worktrees(projectId: project.id)
                .first(where: { $0.branch == branch }) else { return nil }
            let entry = AttentionWorktree(worktree: worktree, project: project)
            return (.make(worktree: worktree, project: project), entry.resolved, entry.resolved.display)
        }
        // Projects the demo profile does not have, so the inbox spans several.
        func invented(project name: String, branch: String, host: String?)
            -> (AttentionWorktreeIdentity, AttentionResolvedWorktree, AttentionWorktreeDisplaySnapshot) {
            let projectID = "demo-\(name)"
            let path = host == nil ? "/Users/demo/\(name)/\(branch)" : "/srv/\(name)/\(branch)"
            let display = AttentionWorktreeDisplaySnapshot(projectName: name, branch: branch, path: path, host: host)
            let owner = AttentionWorktreeIdentity(
                projectID: projectID, location: host.map { .ssh($0) } ?? .local,
                lineageID: "demo-lineage-\(name)-\(branch)", legacyPath: nil
            )
            return (owner, AttentionResolvedWorktree(id: path, projectID: projectID, display: display), display)
        }

        var counter = 0
        func item(
            _ place: (AttentionWorktreeIdentity, AttentionResolvedWorktree, AttentionWorktreeDisplaySnapshot)?,
            _ kind: AttentionKind, _ title: String, body: String? = nil,
            ago seconds: TimeInterval, _ presentation: AttentionItemPresentation = .live,
            jump: AttentionJumpTarget = .none, acknowledgedAgo: TimeInterval? = nil
        ) -> AttentionItem? {
            guard let place else { return nil }
            counter += 1
            return AttentionItem(
                eventID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", counter)) ?? UUID(),
                sourceKey: AttentionSourceKey(rawValue: "demo:\(counter)"),
                owner: place.0, kind: kind, title: title, body: body,
                occurredAt: now.addingTimeInterval(-seconds), presentation: presentation,
                jumpTarget: jump, display: place.2, worktree: place.1,
                acknowledgedAt: acknowledgedAgo.map { now.addingTimeInterval(-$0) }
            )
        }
        let minute: TimeInterval = 60, hour = 3600 * 1.0, day = 86_400 * 1.0

        let invoice = local("feat/invoice-export")
        let invites = local("feat/team-invites")
        let scroller = local("nacho/refactor-transcript-scroller-row-height-cache")
        let queue = local("refactor/job-queue")
        let charts = local("feat/usage-charts")
        let webhook = local("feat/webhook-signing")
        let retry = local("fix/retry-backoff-jitter")
        let csv = local("fix/csv-escaping")
        let emails = local("feat/dark-mode-emails")
        let apiDocs = local("docs/api-quickstart")
        let orbit = invented(project: "orbit-api", branch: "fix/deploy-lock", host: "build-box")

        let items = [
            item(invoice, .agentPermission, "Claude needs permission",
                 body: "Run `pnpm test --filter billing`", ago: 2 * minute, jump: .session(sessionID: "demo-invoice")),
            item(scroller, .agentAwaiting, "Codex is waiting for input",
                 body: "Should the row-height cache key include the column width?", ago: 5 * minute,
                 jump: .session(sessionID: "demo-scroller")),
            item(charts, .agentFinished, "Claude finished", ago: 9 * minute),
            item(invites, .runScriptFailure, "Tests failed with exit code 1", ago: 14 * minute,
                 jump: .runScriptFailure(failureID: "demo-run-1")),
            item(webhook, .failedChecks, "CI failed", ago: 26 * minute, jump: .reviewRequest(number: 418)),
            item(queue, .conflicts, "3 unresolved conflicts", ago: 47 * minute, jump: .conflicts(path: nil)),
            item(retry, .reviewReply, "Maya replied to review feedback",
                 body: "Jitter should be capped at the base delay, otherwise retries pile up.", ago: hour,
                 jump: .reviewComment(sessionID: "demo-retry", commentID: "c1")),
            item(emails, .agentAwaiting, "Claude is waiting for input", ago: 2 * hour,
                 jump: .session(sessionID: "demo-emails"), acknowledgedAgo: 20 * minute),
            item(orbit, .hostDisconnected, "build-box is unreachable", ago: 3 * hour, jump: .remoteWorktree),
            item(csv, .runScriptFailure, "Lint failed with exit code 2", ago: 31 * hour, .unverified,
                 jump: .runScriptFailure(failureID: "demo-run-2")),
        ].compactMap { $0 }

        let history = [
            item(invoice, .agentPermission, "Claude needed permission", ago: 1 * day + 2 * hour, .historical,
                 jump: .session(sessionID: "demo-invoice"), acknowledgedAgo: 1 * day),
            item(orbit, .hostDisconnected, "build-box was unreachable", ago: 2 * day, .historical,
                 jump: .remoteWorktree),
            item(apiDocs, .runScriptFailure, "Link check failed with exit code 1", ago: 3 * day, .historical,
                 jump: .runScriptFailure(failureID: "demo-run-3")),
        ].compactMap { $0 }

        let unresolved = items.filter { $0.acknowledgedAt == nil }
        var byProject: [String: Int] = [:]
        for entry in unresolved { byProject[entry.owner.projectID, default: 0] += 1 }

        let peer = RemoteSessionSummary(
            id: "demo-peer-1", title: "Migrate billing webhooks", agentId: "claude",
            status: "awaitingPermission", canDrive: true, serverId: "demo-studio", serverName: "Studio Mac"
        )
        return Content(
            aggregation: AttentionAggregation(
                items: items, history: history, unresolvedCount: unresolved.count,
                unresolvedCountByProject: byProject
            ),
            peerRows: [peer],
            cleanupReminders: [WorktreeCleanupReminder(projectId: project.id, projectName: project.name, readyCount: 6)]
        )
    }
}
#endif
