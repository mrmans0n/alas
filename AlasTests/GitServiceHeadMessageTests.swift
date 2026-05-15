import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceHeadMessageTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-hm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        return dir
    }

    @Test func returnsNilOnUnbornBranch() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let msg = try await svc.headMessage(worktreePath: repo)
        #expect(msg == nil)
    }

    @Test func returnsSubjectAndBody() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "-q", "--allow-empty",
                                   "-m", "feat: hello", "-m", "body here\nmulti line"],
                                  cwd: repo)
        let svc = GitService()
        let msg = try await svc.headMessage(worktreePath: repo)
        #expect(msg?.subject == "feat: hello")
        #expect(msg?.body == "body here\nmulti line")
    }

    @Test func returnsSubjectWithEmptyBody() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "only subject"], cwd: repo)
        let svc = GitService()
        let msg = try await svc.headMessage(worktreePath: repo)
        #expect(msg?.subject == "only subject")
        #expect(msg?.body == "")
    }
}
