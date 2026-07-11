import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct RemoteFileSearchGateTests {
    @Test func fffBackendDeclinesRemoteWorktrees() async throws {
        RemoteHostRegistry.shared.register(root: "/srv/remote-gate-test", host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: "/srv/remote-gate-test") }

        let backend = FffFileSearchBackend()
        let worktree = SearchWorktree(
            id: "wt",
            projectId: "p",
            displayName: "remote",
            absolutePath: URL(fileURLWithPath: "/srv/remote-gate-test")
        )
        let result = try await backend.search(query: "main", worktree: worktree, limit: 50)
        #expect(result == nil)
    }
}
