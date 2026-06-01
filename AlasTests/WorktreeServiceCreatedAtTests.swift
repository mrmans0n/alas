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

    @Test func lastActivityUsesHeadMtimeForMainWorktree() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-head-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Simulate a main worktree: .git is a directory containing HEAD.
        let gitDir = tmp.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let headPath = gitDir.appendingPathComponent("HEAD").path
        fm.createFile(atPath: headPath, contents: Data("ref: refs/heads/main\n".utf8))

        // Set a known mtime on HEAD that's distinct from the dir mtime.
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: target], ofItemAtPath: headPath)

        let result = WorktreeService.lastActivity(forWorktreeAt: tmp)
        #expect(result == target)
    }

    @Test func lastActivityResolvesGitdirFileForLinkedWorktree() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-head-linked-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        // Linked worktree layout:
        //   tmp/main-repo/.git/worktrees/feat/HEAD   ← the real HEAD
        //   tmp/wt-feat/.git                          ← file: "gitdir: <abs-path-to-above-dir>"
        let mainRepo = tmp.appendingPathComponent("main-repo")
        let wtDir = tmp.appendingPathComponent("wt-feat")
        let gitdir = mainRepo.appendingPathComponent(".git/worktrees/feat")
        try fm.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wtDir, withIntermediateDirectories: true)

        let headPath = gitdir.appendingPathComponent("HEAD").path
        fm.createFile(atPath: headPath, contents: Data("ref: refs/heads/feat\n".utf8))
        let dotGitFile = wtDir.appendingPathComponent(".git").path
        fm.createFile(atPath: dotGitFile, contents: Data("gitdir: \(gitdir.path)\n".utf8))

        let target = Date(timeIntervalSince1970: 1_710_000_000)
        try fm.setAttributes([.modificationDate: target], ofItemAtPath: headPath)

        let result = WorktreeService.lastActivity(forWorktreeAt: wtDir)
        #expect(result == target)
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
