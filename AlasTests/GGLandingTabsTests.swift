import Foundation
import Testing
@testable import Alas

@MainActor
struct GGLandingTabsTests {
    @Test func openOrFocusLandingDedupesByProject() {
        let manager = TabsManager(store: LandingMemoryStore())
        let first = manager.openOrFocusGGLanding(worktreeId: "w", projectId: "p", stackName: "feature")
        _ = manager.appendTerminal(worktreeId: "w", title: "shell", sessionId: "s")
        let second = manager.openOrFocusGGLanding(worktreeId: "w", projectId: "p", stackName: "feature")
        #expect(first.id == "gg-land:p")
        #expect(first.id == second.id)
        #expect(first.title == "Land · feature")
        #expect(!first.isRestorable)
        #expect(manager.tabs(forWorktree: "w").count == 2)
        #expect(manager.activeTabId(forWorktree: "w") == first.id)
    }

    @Test(arguments: [false, true])
    func landingTabIsNotRestored(withTerminal: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TabsManager(tabsDirectory: directory)
        let terminal = withTerminal
            ? manager.appendTerminal(worktreeId: "w", title: "shell", sessionId: "s") : nil
        let landing = manager.openOrFocusGGLanding(worktreeId: "w", projectId: "p", stackName: "feature")
        let persisted = try PersistenceStore().readIfExists(TabsFile.self, from: directory.appendingPathComponent("w.json"))
        #expect(persisted?.activeTabId == terminal?.id)
        #expect(manager.activeTabId(forWorktree: "w") == landing.id)
        let reloaded = TabsManager(tabsDirectory: directory)
        reloaded.loadAll(worktreeIds: ["w"])
        #expect(reloaded.tabs(forWorktree: "w").map(\.id) == (terminal.map { [$0.id] } ?? []))
        #expect(reloaded.activeTabId(forWorktree: "w") == terminal?.id)
    }

    @Test func nextSessionMovesProjectTabToItsInitiatingWorktree() {
        let manager = TabsManager(store: LandingMemoryStore())
        _ = manager.openOrFocusGGLanding(worktreeId: "old", projectId: "p", stackName: "first")
        let next = manager.openOrFocusGGLanding(worktreeId: "new", projectId: "p", stackName: "second")
        #expect(manager.tabs(forWorktree: "old").isEmpty)
        #expect(manager.tabs(forWorktree: "new") == [next])
        #expect(next.title == "Land · second")
        let renamed = manager.openOrFocusGGLanding(worktreeId: "new", projectId: "p", stackName: "third")
        #expect(renamed.title == "Land · third")
        #expect(manager.tabs(forWorktree: "new").count == 1)
    }
}

private struct LandingMemoryStore: PersistenceStoreProtocol {
    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? { nil }
    func write<T: Encodable>(_ value: T, to url: URL) throws {}
}
