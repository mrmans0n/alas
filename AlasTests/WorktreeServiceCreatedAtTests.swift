import Testing
import Foundation
@testable import Alas

@Suite struct WorktreeServiceCreatedAtTests {
    @Test func parsePorcelainPopulatesCreatedAtFromFilesystem() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-ctime-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // The directory was just created; .creationDate should be near now.
        let porcelain = """
        worktree \(tmp.path)
        branch refs/heads/feat
        """
        let parsed = WorktreeService.parsePorcelain(porcelain, projectId: "p1")
        #expect(parsed.count == 1)
        let wt = parsed[0]
        // createdAt must be set to something more recent than distantPast,
        // and within the last 60 seconds.
        #expect(wt.createdAt > Date(timeIntervalSinceNow: -60))
        #expect(wt.createdAt <= Date().addingTimeInterval(1))
    }

    @Test func decodingOlderWorktreeWithoutCreatedAtFallsBackToLastActivity() throws {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "id": "/tmp/x",
          "projectId": "p1",
          "name": "feat",
          "branch": "feat",
          "path": "file:///tmp/x",
          "status": "clean",
          "lastActivity": \(ts.timeIntervalSinceReferenceDate),
          "addedLines": 0,
          "deletedLines": 0
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let wt = try decoder.decode(Worktree.self, from: json)
        #expect(wt.createdAt == wt.lastActivity)
    }
}
