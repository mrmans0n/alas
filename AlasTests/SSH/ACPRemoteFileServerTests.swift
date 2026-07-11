import Testing
@testable import Alas

struct ACPRemoteFileServerTests {
    private let server = ACPRemoteFileServer(host: "devbox", worktreeRoot: "/srv/repo")

    @Test func containsPathsInsideRoot() throws {
        #expect(try server.resolveInsideWorktree(path: "src/main.swift") == "/srv/repo/src/main.swift")
        #expect(try server.resolveInsideWorktree(path: "/srv/repo/a.txt") == "/srv/repo/a.txt")
    }

    @Test func normalizesDotSegments() throws {
        #expect(try server.resolveInsideWorktree(path: "src/../src/./m.swift") == "/srv/repo/src/m.swift")
    }

    @Test func rejectsEscapes() {
        #expect(throws: (any Error).self) { try server.resolveInsideWorktree(path: "../outside") }
        #expect(throws: (any Error).self) { try server.resolveInsideWorktree(path: "/srv/repo-other/x") }
    }
}
