import Testing
import Foundation
@testable import Alas

@MainActor
struct GGInboxTabsTests {
    @Test(arguments: [
        (GGProjectMode.auto, true, [GGWorktreeMode](), true),
        (.off, true, [], true),
        (.on, false, [], true),
        (.on, false, [.off], true),
        (.off, false, [.on], true),
        (.auto, false, [.off, .on], true),
        (.off, false, [.off, .inherit], false),
        (.auto, false, [], false),
    ])
    func inboxUsesRepositoryCapability(
        projectMode: GGProjectMode,
        repoHasGGConfig: Bool,
        worktreeOverrides: [GGWorktreeMode],
        expected: Bool
    ) {
        #expect(AppState.resolveGGInboxAvailable(
            masterEnabled: true,
            ggInstalled: true,
            isRemoteProject: false,
            projectMode: projectMode,
            repoHasGGConfig: repoHasGGConfig,
            worktreeOverrides: worktreeOverrides
        ) == expected)
    }

    @Test func inboxHardStopsDoNotDependOnCapability() {
        #expect(!AppState.resolveGGInboxAvailable(
            masterEnabled: false,
            ggInstalled: true,
            isRemoteProject: false,
            projectMode: .on,
            repoHasGGConfig: true,
            worktreeOverrides: [.on]
        ))
        #expect(!AppState.resolveGGInboxAvailable(
            masterEnabled: true,
            ggInstalled: false,
            isRemoteProject: false,
            projectMode: .on,
            repoHasGGConfig: true,
            worktreeOverrides: [.on]
        ))
        #expect(!AppState.resolveGGInboxAvailable(
            masterEnabled: true,
            ggInstalled: true,
            isRemoteProject: true,
            projectMode: .on,
            repoHasGGConfig: true,
            worktreeOverrides: [.on]
        ))
    }

    @Test func openOrFocusGGInboxDedupesById() {
        let worktreeId = "gg-inbox-tabs-dedupe"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let first = mgr.openOrFocusGGInbox(worktreeId: worktreeId, projectId: "proj-1", projectName: "Proj One")
        #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)

        _ = mgr.appendTerminal(worktreeId: worktreeId, title: "main", sessionId: "s")
        #expect(mgr.tabs(forWorktree: worktreeId).count == 2)

        let second = mgr.openOrFocusGGInbox(worktreeId: worktreeId, projectId: "proj-1", projectName: "Proj One")
        #expect(mgr.tabs(forWorktree: worktreeId).count == 2)
        #expect(second.id == first.id)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
    }
}
