import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct GitServiceCommitEditingTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@example.com"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "Tester"], cwd: dir)
        return dir
    }

    private func write(_ repo: URL, _ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func commit(_ repo: URL, subject: String, files: [String: String]) async throws -> String {
        for (path, text) in files { try write(repo, path, text) }
        _ = try await Process.git(["add", "--"] + Array(files.keys), cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", subject], cwd: repo)
        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subjects(_ repo: URL) async throws -> [String] {
        let result = try await Process.git(["log", "--reverse", "--pretty=format:%s"], cwd: repo)
        return result.stdout.split(separator: "\n").map(String.init)
    }

    private func authorDate(_ repo: URL, _ sha: String) async throws -> String {
        let result = try await Process.git(["show", "-s", "--format=%aI", sha], cwd: repo)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func head(_ repo: URL) async throws -> String {
        let result = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func commitEditRecoveryMessagesTellUserWhatToDo() {
        #expect(CommitEditError.dirtyWorktree.errorDescription == "Commit editing requires a clean worktree and index. Commit, stash, or discard current changes before editing history.")
        #expect(CommitEditError.operationInProgress.errorDescription == "Finish or abort the current merge, rebase, cherry-pick, or revert before editing a commit.")
        #expect(CommitEditError.targetNotAboveFold.errorDescription == "This commit is no longer above the comparison fold. Refresh and choose a local commit.")
    }

    @Test func rewordAboveFoldCommitPreservesDescendant() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "old target", files: ["a.txt": "a1\n"])
        let descendant = try await commit(repo, subject: "descendant", files: ["b.txt": "b1\n"])

        let result = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .message(subject: "new target", body: "body text")
        )

        #expect(result.currentSha != target)
        #expect(result.shaMap[target] == result.currentSha)
        #expect(result.shaMap[descendant] != nil)
        #expect(try await subjects(repo) == ["base", "new target", "descendant"])
        let body = try await Process.git(["log", "-1", "--pretty=format:%b", result.currentSha], cwd: repo)
        #expect(body.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "body text")
    }

    @Test func concurrentEditsForSameWorktreeAreSerialized() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "old target", files: ["a.txt": "a1\n"])
        _ = try await commit(repo, subject: "descendant", files: ["b.txt": "b1\n"])

        async let first = captureResult {
            try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: target,
                action: .message(subject: "first target", body: "")
            )
        }
        async let second = captureResult {
            try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: target,
                action: .message(subject: "second target", body: "")
            )
        }

        let results = await [first, second]
        let successes = results.compactMap { try? $0.get() }
        let failures = results.compactMap { result -> CommitEditError? in
            guard case .failure(let error) = result else { return nil }
            return error as? CommitEditError
        }

        #expect(successes.count == 1)
        #expect(failures == [.targetNotAboveFold])
        #expect(try await subjects(repo).filter { $0.hasSuffix(" target") }.count == 1)
    }

    private func captureResult<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    @Test func rawCommitSubjectPreservesConventionalScopeAndBreakingMarker() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let target = try await commit(repo, subject: "feat(ui)!: add button", files: ["button.txt": "button\n"])

        let subject = try await GitService().rawCommitSubject(at: repo, sha: target)

        #expect(subject == "feat(ui)!: add button")
    }

    @Test func rewordRejectsBelowFoldCommit() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        _ = try await commit(repo, subject: "above", files: ["a.txt": "a\n"])

        await #expect(throws: CommitEditError.self) {
            _ = try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: base,
                action: .message(subject: "bad", body: "")
            )
        }
    }

    @Test func rewordRejectsDirtyWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "target", files: ["a.txt": "a\n"])
        try write(repo, "dirty.txt", "dirty\n")

        await #expect(throws: CommitEditError.self) {
            _ = try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: target,
                action: .message(subject: "new", body: "")
            )
        }
    }

    @Test func rewordPreservesAuthorDate() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        try write(repo, "dated.txt", "dated\n")
        _ = try await Process.git(["add", "--", "dated.txt"], cwd: repo)
        _ = try await Process.git([
            "commit", "-q", "--date", "2001-02-03T04:05:06+00:00", "-m", "dated"
        ], cwd: repo)
        let target = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalAuthorDate = try await authorDate(repo, target)

        let result = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .message(subject: "new dated", body: "")
        )

        #expect(try await authorDate(repo, result.currentSha) == originalAuthorDate)
    }

    @Test func rewordEmptyTargetCommitPreservesDescendantOrder() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "empty target"], cwd: repo)
        let target = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let descendant = try await commit(repo, subject: "descendant", files: ["d.txt": "d\n"])

        let result = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .message(subject: "new empty", body: "")
        )

        #expect(result.shaMap[target] == result.currentSha)
        #expect(result.shaMap[descendant] != nil)
        #expect(try await subjects(repo) == ["base", "new empty", "descendant"])
    }

    @Test func rewordTargetWithEmptyDescendantReplaysEmptyDescendant() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "target", files: ["target.txt": "target\n"])
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "empty descendant"], cwd: repo)
        let descendant = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .message(subject: "new target", body: "")
        )

        #expect(result.shaMap[descendant] != nil)
        #expect(try await subjects(repo) == ["base", "new target", "empty descendant"])
    }

    @Test func dropModifiedFileRemovesOnlyTargetCommitContribution() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["a.txt": "base\n"])
        let target = try await commit(repo, subject: "target", files: ["a.txt": "target\n", "c.txt": "keep\n"])
        _ = try await commit(repo, subject: "descendant", files: ["b.txt": "desc\n"])

        _ = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .dropFile(path: "a.txt")
        )

        let content = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(content == "base\n")
        let keptContent = try String(contentsOf: repo.appendingPathComponent("c.txt"), encoding: .utf8)
        #expect(keptContent == "keep\n")
        #expect(try await subjects(repo) == ["base", "target", "descendant"])
    }

    @Test func dropFilePreservesDescendantThatBecomesRedundant() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["a.txt": "base\n"])
        let target = try await commit(repo, subject: "target", files: ["a.txt": "target\n", "keep.txt": "keep\n"])
        let descendant = try await commit(repo, subject: "restore base", files: ["a.txt": "base\n"])

        let result = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .dropFile(path: "a.txt")
        )

        #expect(result.shaMap[descendant] != nil)
        #expect(try await subjects(repo) == ["base", "target", "restore base"])
        let content = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(content == "base\n")
    }

    @Test func dropAddedFileThatWouldEmptyCommitIsRejected() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "target", files: ["new.txt": "new\n"])

        await #expect(throws: CommitEditError.self) {
            _ = try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: target,
                action: .dropFile(path: "new.txt")
            )
        }
    }

    @Test func dropHunkRemovesOnlySelectedHunk() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["a.txt": "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"])
        let target = try await commit(repo, subject: "target", files: ["a.txt": "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n"])
        let rawDiff = try await Process.git(["diff", "\(target)^", target, "--", "a.txt"], cwd: repo)
        let parsed = DiffParser.parse(rawDiff.stdout)
        #expect(parsed.hunks.count == 2)

        _ = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .dropHunk(path: "a.txt", hunk: parsed.hunks[0])
        )

        let content = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(content == "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n")
    }

    @Test func dropHunkRejectsAddedFileAndLeavesRepoUnchanged() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "target", files: ["new.txt": "new\n", "keep.txt": "keep\n"])
        let beforeHead = try await head(repo)
        let rawDiff = try await Process.git(["diff", "\(target)^", target, "--", "new.txt"], cwd: repo)
        let parsed = DiffParser.parse(rawDiff.stdout)
        #expect(parsed.hunks.count == 1)

        do {
            _ = try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: target,
                action: .dropHunk(path: "new.txt", hunk: parsed.hunks[0])
            )
            Issue.record("Expected added-file hunk drop to be rejected")
        } catch let error as CommitEditError {
            #expect(error == .unsupportedAction)
        }

        #expect(try await head(repo) == beforeHead)
        #expect(try await subjects(repo) == ["base", "target"])
        let content = try String(contentsOf: repo.appendingPathComponent("new.txt"), encoding: .utf8)
        #expect(content == "new\n")
    }

    @Test func dropHunkRejectsDeletedFileAndLeavesRepoUnchanged() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["a.txt": "one\ntwo\n"])
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
        try write(repo, "keep.txt", "keep\n")
        _ = try await Process.git(["add", "--", "a.txt", "keep.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "target"], cwd: repo)
        let target = try await head(repo)
        let beforeHead = target
        let rawDiff = try await Process.git(["diff", "\(target)^", target, "--", "a.txt"], cwd: repo)
        let parsed = DiffParser.parse(rawDiff.stdout)
        #expect(parsed.hunks.count == 1)

        do {
            _ = try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: target,
                action: .dropHunk(path: "a.txt", hunk: parsed.hunks[0])
            )
            Issue.record("Expected deleted-file hunk drop to be rejected")
        } catch let error as CommitEditError {
            #expect(error == .unsupportedAction)
        }

        #expect(try await head(repo) == beforeHead)
        #expect(try await subjects(repo) == ["base", "target"])
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path))
    }
}
