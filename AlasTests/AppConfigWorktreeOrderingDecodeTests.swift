import Testing
import Foundation
@testable import Alas

@Suite struct AppConfigWorktreeOrderingDecodeTests {
    @Test func defaultsUseLastUpdateDesc() {
        #expect(AppConfig.defaults.worktrees.defaultOrdering == .lastUpdateDesc)
    }

    @Test func decodingOlderConfigWithoutDefaultOrderingFallsBack() throws {
        // Older AppConfig blobs persisted before this feature have no
        // defaultOrdering key. Decoding must succeed and yield .lastUpdateDesc.
        let json = """
        {
          "rootPath": "~/.alas/worktrees",
          "pathTemplate": "{worktreeRoot}/{repo}/{branch}",
          "branchPrefix": "feature/",
          "baseBranch": "main",
          "trackUpstream": true,
          "deleteBranchOnRemove": true,
          "autoFetch": true,
          "fetchIntervalMinutes": 5,
          "pruneStale": false,
          "fetchRemoteBeforeCreate": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.Worktrees.self, from: json)
        #expect(decoded.defaultOrdering == .lastUpdateDesc)
    }

    @Test func decodingUnknownDefaultOrderingFallsBack() throws {
        let json = """
        {
          "rootPath": "~/.alas/worktrees",
          "pathTemplate": "{worktreeRoot}/{repo}/{branch}",
          "branchPrefix": "feature/",
          "baseBranch": "main",
          "trackUpstream": true,
          "deleteBranchOnRemove": true,
          "autoFetch": true,
          "fetchIntervalMinutes": 5,
          "pruneStale": false,
          "fetchRemoteBeforeCreate": false,
          "defaultOrdering": "no-such-mode"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.Worktrees.self, from: json)
        #expect(decoded.defaultOrdering == .lastUpdateDesc)
    }
}
