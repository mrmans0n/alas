import Testing
import Foundation
@testable import Alas

struct WorktreeCleanupConfigTests {
    @Test func cleanupIdleDaysDefaultsToFourteen() {
        let worktrees = AppConfig.Worktrees(
            rootPath: "/tmp",
            pathTemplate: "{branch}",
            branchPrefix: "",
            baseBranch: "main",
            trackUpstream: true,
            deleteBranchOnRemove: false,
            autoFetch: false,
            fetchIntervalMinutes: 10,
            pruneStale: false
        )
        #expect(worktrees.cleanupIdleDays == 14)
    }

    /// Config files written before this key existed must keep loading.
    @Test func cleanupIdleDaysToleratesConfigThatPredatesTheKey() throws {
        let json = """
        {
          "rootPath": "/tmp",
          "pathTemplate": "{branch}",
          "branchPrefix": "",
          "baseBranch": "main",
          "trackUpstream": true,
          "deleteBranchOnRemove": false,
          "autoFetch": false,
          "fetchIntervalMinutes": 10,
          "pruneStale": false
        }
        """
        let decoded = try JSONDecoder().decode(
            AppConfig.Worktrees.self,
            from: Data(json.utf8)
        )
        #expect(decoded.cleanupIdleDays == 14)
    }

    @Test func cleanupIdleDaysRoundTrips() throws {
        var worktrees = AppConfig.Worktrees(
            rootPath: "/tmp",
            pathTemplate: "{branch}",
            branchPrefix: "",
            baseBranch: "main",
            trackUpstream: true,
            deleteBranchOnRemove: false,
            autoFetch: false,
            fetchIntervalMinutes: 10,
            pruneStale: false
        )
        worktrees.cleanupIdleDays = 30
        let data = try JSONEncoder().encode(worktrees)
        let decoded = try JSONDecoder().decode(AppConfig.Worktrees.self, from: data)
        #expect(decoded.cleanupIdleDays == 30)
    }
}
