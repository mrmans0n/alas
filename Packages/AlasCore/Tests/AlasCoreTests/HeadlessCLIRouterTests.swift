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
        .review(.localChanges(worktree: nil)),
        .review(.commentAdd(path: "a", startLine: 1, endLine: nil, side: nil, body: "b", sessionID: nil)),
        .review(.finish(sessionID: nil, verdict: .comment, summary: "")),
    ]

    /// Agents and anonymous shell callers (cwd only) get the same refusal.
    @Test(arguments: screenBound, [String?.none, "acp-1"])
    func screenBoundCommandsAreRefusedOnAHeadlessHost(command: AlasCLIRequest.Command, session: String?) async {
        let router = AlasCLICommandRouter.headless(host: AlasHost(core: AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch())))
        let response = await router.handle(.init(version: 1, sessionId: session, cwd: "/srv/a", command: command))
        #expect(response == .error("Not available on a headless host."))
    }
}
