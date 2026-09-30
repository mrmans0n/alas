import Foundation
import Testing
@testable import Alas

struct AppStateRemoteWorktreePathTests {
    @Test func remoteWorktreeDestinationReplacesLocalHomePrefix() {
        let path = AppState.destinationPathReplacingLocalHome(
            "/Users/local/.alas/worktrees/repo-feature",
            localHome: "/Users/local",
            remoteHome: "/home/remote"
        )

        #expect(path == "/home/remote/.alas/worktrees/repo-feature")
    }

    @Test func remoteWorktreeDestinationKeepsNonHomeAbsolutePath() {
        let path = AppState.destinationPathReplacingLocalHome(
            "/srv/worktrees/repo-feature",
            localHome: "/Users/local",
            remoteHome: "/home/remote"
        )

        #expect(path == "/srv/worktrees/repo-feature")
    }

    /// Startup recovery matches an interrupted delegation by this path, so it
    /// must have the created worktree's form: virtual for a remote project.
    @Test(arguments: [
        ("/srv/repo", "/srv/worktrees/repo-feature"),
        ("/.alas-remote/mini/srv/repo", "/.alas-remote/mini/srv/worktrees/repo-feature"),
    ])
    func delegatedDestinationHasTheCreatedWorktreesForm(projectPath: String, expected: String) {
        let destination = AppState.delegatedWorktreeDestination(
            rendered: URL(fileURLWithPath: "/srv/worktrees/repo-feature"),
            projectPath: projectPath
        )

        #expect(destination.path == expected)
    }

    @Test func remoteSaveAsNormalizesRelativePath() throws {
        let path = try AppState.normalizedRemoteRelativePath(" nested\\file.txt ")

        #expect(path == "nested/file.txt")
    }

    @Test func remoteSaveAsRejectsAbsoluteOrEscapingPaths() {
        #expect(throws: (any Error).self) {
            try AppState.normalizedRemoteRelativePath("/tmp/file.txt")
        }
        #expect(throws: (any Error).self) {
            try AppState.normalizedRemoteRelativePath("../file.txt")
        }
    }
}
