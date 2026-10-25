import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

@MainActor
struct HeadlessCLIRouterTests {
    nonisolated static let screenBound: [AlasCLIRequest.Command] = [
        .open(paths: ["/srv/a"]), .openAt(path: "/srv/a", line: 1, endLine: nil),
        .preview(.init(action: .list)), .computer(.init(action: .apps)), .worktree(.switch(target: "main")),
        .workspace(.list), .workspace(.show(checkoutID: UUID())),
    ]

    /// Agents and anonymous shell callers (cwd only) get the same refusal.
    @Test(arguments: screenBound, [String?.none, "acp-1"])
    func screenBoundCommandsAreRefusedOnAHeadlessHost(command: AlasCLIRequest.Command, session: String?) async {
        let router = AlasCLICommandRouter.headless(host: AlasHost(core: AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch())))
        let response = await router.handle(.init(version: 1, sessionId: session, cwd: "/srv/a", command: command))
        #expect(response == .error("Not available on a headless host."))
    }

    /// A paired Mac shows the local-changes review, so the host lists it
    /// once an agent opens it.
    @Test func reviewingLocalChangesOnAHeadlessHostListsIt() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("alas-headless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let project = ProjectConfig(id: "p", name: "p", path: path.path, color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let core = AlasCoreContext(
            projects: projects, runHistoryStore: nil, attentionStore: .scratch(),
            reviewDrafts: ReviewDraftCommentStore(url: path.appendingPathComponent("review-drafts.json")),
            reviewSessions: ReviewSessionStore(url: path.appendingPathComponent("review-sessions.json"))
        )
        let router = AlasCLICommandRouter.headless(host: AlasHost(core: core))

        let response = await router.handle(.init(version: 1, sessionId: nil, cwd: path.path, command: .review(.localChanges(worktree: nil))))

        let sessionID = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: path, scope: .all)
        #expect(response == .text([
            "Opened review of local changes in Alas.",
            ReviewsAPI.jsonLine(["session_id": sessionID.rawValue]),
        ]))
        #expect(core.openedLocalChangesReviews[worktree.id] != nil)
    }
}
