import Testing
@testable import Alas

struct ACPRemoteFileServerTests {
    private let server = ACPRemoteFileServer(host: "devbox", worktreeRoot: "/srv/repo")

    @Test func containsPathsInsideRoot() throws {
        #expect(try server.lexicallyResolveInsideWorktree(path: "src/main.swift") == "/srv/repo/src/main.swift")
        #expect(try server.lexicallyResolveInsideWorktree(path: "/srv/repo/a.txt") == "/srv/repo/a.txt")
    }

    @Test func normalizesDotSegments() throws {
        #expect(try server.lexicallyResolveInsideWorktree(path: "src/../src/./m.swift") == "/srv/repo/src/m.swift")
    }

    @Test func rejectsEscapes() {
        #expect(throws: (any Error).self) { try server.lexicallyResolveInsideWorktree(path: "../outside") }
        #expect(throws: (any Error).self) { try server.lexicallyResolveInsideWorktree(path: "/srv/repo-other/x") }
    }

    @Test func containmentProbeUsesPhysicalParentCheck() {
        let command = server.containmentProbeCommand(path: "/srv/repo/link/passwd")

        #expect(command.contains("root='/srv/repo'"))
        #expect(command.contains("target='/srv/repo/link/passwd'"))
        #expect(command.contains("pwd -P"))
        #expect(command.contains("existing_phys"))
        #expect(command.contains("exit 6"))
    }

    @Test func sharedContainmentHelperUsesSameProbe() {
        let command = RemotePathContainment.containmentProbeCommand(
            path: "/srv/repo/link/passwd",
            worktreeRoot: "/srv/repo"
        )

        #expect(command == server.containmentProbeCommand(path: "/srv/repo/link/passwd"))
    }
}
