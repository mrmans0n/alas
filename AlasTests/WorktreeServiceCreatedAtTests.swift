import Testing
import Foundation
@testable import Alas

@Suite struct WorktreeServiceCreatedAtTests {
    @Test func parsePorcelainOmitsPrunableWorktrees() {
        let porcelain = """
        worktree /tmp/main
        HEAD abc123
        branch refs/heads/main

        worktree /tmp/deleted
        HEAD def456
        branch refs/heads/feature/deleted
        prunable gitdir file points to non-existent location

        """

        let parsed = WorktreeService.parsePorcelain(porcelain, projectId: "p1")

        #expect(parsed.map(\.branch) == ["main"])
        #expect(parsed.map(\.path.path) == ["/tmp/main"])
    }

    @Test func parsePorcelainOmitsAbsentLockedWorktrees() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-locked-missing-\(UUID().uuidString)")
        let porcelain = """
        worktree /tmp/main
        HEAD abc123
        branch refs/heads/main

        worktree \(missing.path)
        HEAD def456
        branch refs/heads/feature/locked
        locked

        """

        let parsed = WorktreeService.parsePorcelain(porcelain, projectId: "p1")

        #expect(parsed.map(\.branch) == ["main"])
    }

    @Test func parsePorcelainPreservesRemoteLockedWorktreesWithoutLocalPaths() {
        let porcelain = """
        worktree /srv/alas/main
        HEAD abc123
        branch refs/heads/main

        worktree /srv/alas/worktrees/feature
        HEAD def456
        branch refs/heads/feature/locked
        locked

        """

        let parsed = WorktreeService.parsePorcelain(porcelain, projectId: "p1", isRemote: true)

        #expect(parsed.map(\.branch) == ["main", "feature/locked"])
    }

    @Test func parsePorcelainOmitsRemoteLockedWorktreesConfirmedAbsent() {
        let missingPath = "/srv/alas/worktrees/missing"
        let porcelain = """
        worktree /srv/alas/main
        branch refs/heads/main

        worktree \(missingPath)
        branch refs/heads/feature/missing
        locked

        """

        let parsed = WorktreeService.parsePorcelain(
            porcelain,
            projectId: "p1",
            isRemote: true,
            absentLockedPaths: [missingPath]
        )

        #expect(parsed.map(\.branch) == ["main"])
    }

    @Test func remoteMissingLockedRegistrationIsEligibleForRecovery() {
        let destination = URL(fileURLWithPath: "/srv/alas/worktrees/missing")
        let porcelain = """
        worktree \(destination.path)
        branch refs/heads/feature/missing
        locked

        """

        #expect(WorktreeService.staleRegistration(
            porcelain,
            destination: destination,
            lockedDestinationIsMissing: true
        ) == .locked)
        #expect(WorktreeService.staleRegistration(
            porcelain,
            destination: destination,
            lockedDestinationIsMissing: false
        ) == nil)
    }

    @Test func parsePorcelainMarksOnlyGitsFirstWorktreeAsMain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-main-identity-\(UUID().uuidString)")
        let main = root.appendingPathComponent("main")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let porcelain = """
        worktree \(main.path)
        branch refs/heads/main

        worktree \(linked.path)
        branch refs/heads/feature
        """

        let parsed = WorktreeService.parsePorcelain(porcelain, projectId: "p1")

        #expect(parsed.map(\.isMainWorktree) == [true, false])
    }

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

    @Test func localLineageUsesTheStableGitMarkerIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("alas-lineage-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let marker = root.appendingPathComponent(".git")
        #expect(fm.createFile(atPath: marker.path, contents: Data("gitdir: /tmp/admin\n".utf8)))

        let original = try #require(WorktreeService.localLineageID(forWorktreeAt: root))
        #expect(fm.createFile(atPath: root.appendingPathComponent("new-file").path, contents: Data()))
        #expect(WorktreeService.localLineageID(forWorktreeAt: root) == original)

        try fm.removeItem(at: marker)
        #expect(fm.createFile(atPath: marker.path, contents: Data("gitdir: /tmp/recreated\n".utf8)))
        #expect(WorktreeService.localLineageID(forWorktreeAt: root) != original)
    }

    @Test func lastActivityFollowsSymbolicHeadToBranchRefMain() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-act-symref-main-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let gitDir = tmp.appendingPathComponent(".git")
        let refsDir = gitDir.appendingPathComponent("refs/heads")
        try fm.createDirectory(at: refsDir, withIntermediateDirectories: true)

        let headPath = gitDir.appendingPathComponent("HEAD").path
        fm.createFile(atPath: headPath, contents: Data("ref: refs/heads/main\n".utf8))

        let refPath = refsDir.appendingPathComponent("main").path
        fm.createFile(atPath: refPath, contents: Data("0000000000000000000000000000000000000000\n".utf8))

        let target = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: target], ofItemAtPath: refPath)
        // Set HEAD to a different mtime to prove we're not using HEAD.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: headPath)

        #expect(WorktreeService.lastActivity(forWorktreeAt: tmp) == target)
    }

    @Test func lastActivityFollowsSymbolicHeadToBranchRefLinked() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-act-symref-linked-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let mainRepo = tmp.appendingPathComponent("main-repo")
        let wt = tmp.appendingPathComponent("wt-feat")
        let mainGit = mainRepo.appendingPathComponent(".git")
        let wtGitdir = mainGit.appendingPathComponent("worktrees/feat")
        let refsDir = mainGit.appendingPathComponent("refs/heads")
        try fm.createDirectory(at: wtGitdir, withIntermediateDirectories: true)
        try fm.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)

        fm.createFile(atPath: wtGitdir.appendingPathComponent("HEAD").path,
                      contents: Data("ref: refs/heads/feat\n".utf8))
        // commondir points back to mainGit (relative).
        fm.createFile(atPath: wtGitdir.appendingPathComponent("commondir").path,
                      contents: Data("../..\n".utf8))
        // .git file in the worktree points to gitdir.
        fm.createFile(atPath: wt.appendingPathComponent(".git").path,
                      contents: Data("gitdir: \(wtGitdir.path)\n".utf8))

        let refPath = refsDir.appendingPathComponent("feat").path
        fm.createFile(atPath: refPath, contents: Data("0000000000000000000000000000000000000000\n".utf8))
        let target = Date(timeIntervalSince1970: 1_710_000_000)
        try fm.setAttributes([.modificationDate: target], ofItemAtPath: refPath)

        #expect(WorktreeService.lastActivity(forWorktreeAt: wt) == target)
    }

    @Test func lastActivityUsesHeadMtimeForDetachedHead() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-act-detached-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let gitDir = tmp.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let headPath = gitDir.appendingPathComponent("HEAD").path
        // Detached: raw SHA, no "ref: " prefix.
        fm.createFile(atPath: headPath, contents: Data("0000000000000000000000000000000000000000\n".utf8))
        let target = Date(timeIntervalSince1970: 1_720_000_000)
        try fm.setAttributes([.modificationDate: target], ofItemAtPath: headPath)

        #expect(WorktreeService.lastActivity(forWorktreeAt: tmp) == target)
    }

    @Test func lastActivityFallsBackToPackedRefsWhenLooseRefMissing() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-act-packed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let gitDir = tmp.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        fm.createFile(atPath: gitDir.appendingPathComponent("HEAD").path,
                      contents: Data("ref: refs/heads/packed\n".utf8))
        // No loose ref file at refs/heads/packed.
        let packedPath = gitDir.appendingPathComponent("packed-refs").path
        fm.createFile(atPath: packedPath,
                      contents: Data("# pack-refs with: peeled fully-peeled sorted\n0000000000000000000000000000000000000000 refs/heads/packed\n".utf8))
        let target = Date(timeIntervalSince1970: 1_730_000_000)
        try fm.setAttributes([.modificationDate: target], ofItemAtPath: packedPath)

        #expect(WorktreeService.lastActivity(forWorktreeAt: tmp) == target)
    }

    @Test func lastActivityResolvesRelativeGitdirPath() throws {
        // Submodule layout: ".git" file contains a *relative* gitdir path.
        //   parent/sub/.git           ← "gitdir: ../.git/modules/sub"
        //   parent/.git/modules/sub/  ← actual gitdir
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alas-act-relgit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let parent = tmp.appendingPathComponent("parent")
        let sub = parent.appendingPathComponent("sub")
        let modulesGit = parent.appendingPathComponent(".git/modules/sub")
        let refsDir = modulesGit.appendingPathComponent("refs/heads")
        try fm.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)

        fm.createFile(atPath: modulesGit.appendingPathComponent("HEAD").path,
                      contents: Data("ref: refs/heads/main\n".utf8))
        fm.createFile(atPath: sub.appendingPathComponent(".git").path,
                      contents: Data("gitdir: ../.git/modules/sub\n".utf8))

        let refPath = refsDir.appendingPathComponent("main").path
        fm.createFile(atPath: refPath, contents: Data("0000000000000000000000000000000000000000\n".utf8))
        let target = Date(timeIntervalSince1970: 1_740_000_000)
        try fm.setAttributes([.modificationDate: target], ofItemAtPath: refPath)

        #expect(WorktreeService.lastActivity(forWorktreeAt: sub) == target)
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
