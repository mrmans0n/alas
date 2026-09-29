import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct RemoteFileSearchGateTests {
    @Test func fffBackendDeclinesRemoteWorktrees() async throws {
        let backend = FffFileSearchBackend()
        let worktree = SearchWorktree(
            id: "wt",
            projectId: "p",
            displayName: "remote",
            absolutePath: URL(fileURLWithPath: RemotePath.virtual(host: "devbox", realPath: "/srv/remote-gate-test"))
        )
        let result = try await backend.search(query: "main", worktree: worktree, limit: 50)
        #expect(result == nil)
    }
}
