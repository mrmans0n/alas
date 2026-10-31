import AlasCore
import Foundation
import Testing

/// Pins the git state a snapshot derives instead of asking git for it
/// directly: HEAD entries come from the index and the staged diff, not
/// `ls-tree`, and the branch from `rev-parse`, not `symbolic-ref`.
struct WorktreeSnapshotGitReadTests {
    @Test func headEntriesAndBranchMatchGitsOwnReads() async throws {
        let repo = try await Repository.make("""
        printf 'one\\ntwo\\nthree\\nfour\\n' > renamed.txt; printf 'one\\ntwo\\nthree\\nfour\\n' > edited.txt
        echo x > unstaged.txt; echo x > tool.sh; echo x > link; echo x > dropped.txt; echo x > dir; echo x > shared.txt
        commit
        git mv renamed.txt moved.txt
        git mv edited.txt edited-moved.txt; echo five >> edited-moved.txt; git add edited-moved.txt; echo six >> edited-moved.txt
        echo y >> unstaged.txt; chmod +x tool.sh; git add tool.sh; rm link; ln -s tool.sh link; git add link
        git rm -q --cached dropped.txt; git rm -q --cached dir; rm dir; mkdir dir; echo z > dir/inner.txt; git add dir/inner.txt
        echo new > staged-new.txt; git add staged-new.txt; echo u > untracked.txt
        git tag main
        """)
        defer { repo.remove() }

        let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target, includingPaths: ["shared.txt"])

        #expect(snapshot.branch == (try await repo.git(["symbolic-ref", "--short", "HEAD"])))
        #expect(snapshot.branch == "heads/main")
        #expect(Set(snapshot.paths.keys) == ["moved.txt", "renamed.txt", "edited-moved.txt", "edited.txt", "unstaged.txt", "tool.sh",
                                             "link", "dropped.txt", "dir", "dir/inner.txt", "staged-new.txt", "untracked.txt", "shared.txt"])
        for (path, state) in snapshot.paths {
            let record = try await repo.git(["ls-tree", "-z", "HEAD", "--", path])
            guard !record.isEmpty else {
                #expect(state.head == .absent, "\(path)")
                continue
            }
            let fields = record.split(separator: "\t")[0].split(separator: " ")
            let blob = try #require(snapshot.gitBlobReferences[String(fields[2])], "\(path)")
            let expected: CheckpointFileState = fields[0] == "120000" ? .symlink(blob: blob) : .regular(blob: blob, executable: fields[0] == "100755")
            #expect(state.head == expected, "\(path)")
        }
    }

    @Test(arguments: [("detached", "commit; git checkout -q --detach", "(detached)"), ("unborn", "git add -A", "main"),
                      ("ref named HEAD", "commit; git update-ref refs/heads/HEAD main", "main")])
    func branchOfHeadWithoutBranchTip(name: String, script: String, branch: String) async throws {
        let repo = try await Repository.make("echo x > a.txt; " + script, unborn: true)
        defer { repo.remove() }

        #expect(try await WorktreeStateSnapshotter.live.snapshot(target: repo.target).branch == branch)
    }

    /// Intent-to-add paths are named as stored, never quoted, including ones
    /// starting with a space, and capture leaves their intent in the index.
    @Test func intentToAddPathsFailCaptureByTheirOwnNames() async throws {
        let repo = try await Repository.make("echo x > ' lead.txt'; echo x > 'é.txt'; git add -N ' lead.txt' 'é.txt'")
        defer { repo.remove() }

        await #expect(throws: CheckpointSnapshotError.unsupportedPaths([" lead.txt", "é.txt"])) {
            try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
        }

        #expect(try await repo.git(["ls-files", "--debug", "--", " lead.txt"]).contains("flags: 2000"))
    }

    private struct Repository {
        let root: URL
        let target: CheckpointWorktreeTarget

        /// A repository built by `script`, run in its root with a `commit`
        /// function that commits everything.
        static func make(_ script: String, unborn: Bool = false) async throws -> Self {
            let base = URL(fileURLWithPath: "/private/tmp/checkpoint-snapshot-\(UUID().uuidString)")
            let root = base.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if unborn {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } else {
                try await GitTemplate.repository(at: root)
            }
            let setup = Process()
            setup.executableURL = URL(fileURLWithPath: "/bin/sh")
            setup.arguments = ["-c", """
                set -e; cd "$1"; [ -d .git ] || git init -q -b main
                commit() { git add -A; git -c user.name=Test -c user.email=test@example.com commit -qm commit; }
                """ + "\n" + script, "sh", root.path]
            try setup.run()
            setup.waitUntilExit()
            guard setup.terminationStatus == 0 else { throw CheckpointSnapshotError.invalidGitOutput }
            let lineage = try #require(WorktreeService.localLineageID(forWorktreeAt: root))
            return .init(root: root, target: .init(worktreeID: "w", projectID: "p", path: root, lineageID: lineage, branch: "main",
                                                   repositoryName: "test", workspaceName: nil))
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String {
            let result = try await LiveCheckpointGitRunner().run(args, cwd: root, environment: [:])
            guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
            return result.stdout.trimmingCharacters(in: .newlines)
        }

        func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }
}
