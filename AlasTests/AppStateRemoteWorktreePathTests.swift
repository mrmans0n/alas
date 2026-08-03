import Foundation
import Testing
@testable import Alas

struct AppStateRemoteWorktreePathTests {
    @Test func missionDestinationSkipsRemoteFilesystemCollisions() async throws {
        let requested = URL(fileURLWithPath: "/home/remote/worktrees/fixed")
        var checked: [String] = []

        let available = try await AppState.firstAvailableMissionDestination(
            requested: requested,
            occupiedPaths: [],
            pathExists: { path in
                checked.append(path)
                return path == requested.path
            }
        )

        #expect(available.path == "\(requested.path)-2")
        #expect(checked == [requested.path, "\(requested.path)-2"])
    }

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
