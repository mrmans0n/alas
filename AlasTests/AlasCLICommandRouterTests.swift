import Foundation
import Testing
@testable import Alas

@MainActor
struct AlasCLICommandRouterTests {
    private func makeFile(_ name: String, contents: String = "x\n") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cli-router-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func opensInWorktreeFileByRelativePath() throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var opened: [(worktreeId: String, relativePath: String)] = []

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "s1" ? "wt1" : nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { relativePath, worktreeId in opened.append((worktreeId, relativePath)) },
            openExternalFile: { _, _ in Issue.record("expected relative open") },
            activateApp: {}
        )

        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [root.appendingPathComponent("a.txt").path]))

        #expect(response == .ok)
        #expect(opened.count == 1)
        #expect(opened[0].worktreeId == "wt1")
        #expect(opened[0].relativePath == "a.txt")
    }

    @Test func opensNestedWorktreeFileInMostSpecificVisibleWorktree() throws {
        let root = try makeFile("repo/packages/tool/file.txt")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nestedRoot = root.appendingPathComponent("packages/tool")
        let parent = Worktree(
            id: "parent", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let nested = Worktree(
            id: "nested", projectId: "p1", name: "tool", branch: "tool",
            path: nestedRoot, status: .clean, lastActivity: Date()
        )
        var opened: [(worktreeId: String, relativePath: String)] = []

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "parent" },
            originatingWorktree: { _ in parent },
            visibleWorktrees: { [parent, nested] },
            openRelativeFile: { relativePath, worktreeId in opened.append((worktreeId, relativePath)) },
            openExternalFile: { _, _ in Issue.record("expected relative open") },
            activateApp: {}
        )

        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [nestedRoot.appendingPathComponent("file.txt").path]))

        #expect(response == .ok)
        #expect(opened.count == 1)
        #expect(opened[0].worktreeId == "nested")
        #expect(opened[0].relativePath == "file.txt")
    }

    @Test func opensExternalFileOwnedByOriginatingWorktree() throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let external = try makeFile("external/note.txt")
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var externalOpens: [(worktreeId: String, url: URL)] = []

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "s1" ? "wt1" : nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in Issue.record("expected external open") },
            openExternalFile: { url, worktreeId in externalOpens.append((worktreeId, url)) },
            activateApp: {}
        )

        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [external.path]))

        #expect(response == .ok)
        #expect(externalOpens.count == 1)
        #expect(externalOpens[0].worktreeId == "wt1")
        #expect(externalOpens[0].url.standardizedFileURL.path == external.standardizedFileURL.path)
    }

    @Test func rejectsUnsafePrefixMatch() throws {
        let repo = try makeFile("repo/a.txt").deletingLastPathComponent()
        let sibling = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + "-copy")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingFile = sibling.appendingPathComponent("a.txt")
        try "x\n".write(to: siblingFile, atomically: true, encoding: .utf8)
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: repo, status: .clean, lastActivity: Date()
        )
        var externalCount = 0

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in Issue.record("must not treat sibling as in-worktree") },
            openExternalFile: { _, _ in externalCount += 1 },
            activateApp: {}
        )

        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [siblingFile.path]))

        #expect(response == .ok)
        #expect(externalCount == 1)
    }

    @Test func rejectsMissingFilesAndDirectories() throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: {}
        )

        let missing = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [root.appendingPathComponent("missing.txt").path]))
        let directory = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [root.path]))

        guard case .error(let missingMessage) = missing else {
            Issue.record("expected missing file error")
            return
        }
        guard case .error(let directoryMessage) = directory else {
            Issue.record("expected directory error")
            return
        }
        #expect(missingMessage.contains("does not exist"))
        #expect(directoryMessage.contains("is a directory"))
    }

    @Test func returnsCombinedErrorForMissingFilesAndDirectoriesInOneRequest() throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let missingPath = root.appendingPathComponent("missing.txt").path

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in Issue.record("expected no opens") },
            openExternalFile: { _, _ in Issue.record("expected no opens") },
            activateApp: { Issue.record("expected no activation") }
        )

        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [missingPath, root.path]))

        guard case .error(let message) = response else {
            Issue.record("expected combined error")
            return
        }
        #expect(message.contains("\(missingPath) does not exist."))
        #expect(message.contains("\(root.path) is a directory."))
    }

    @Test func activatesAfterSuccessfulOpen() throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var activationCount = 0

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: { activationCount += 1 }
        )

        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [root.appendingPathComponent("a.txt").path]))

        #expect(response == .ok)
        #expect(activationCount == 1)
    }

    @Test func doesNotActivateWhenAllPathsFail() throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var activationCount = 0

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in Issue.record("expected no opens") },
            openExternalFile: { _, _ in Issue.record("expected no opens") },
            activateApp: { activationCount += 1 }
        )

        _ = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [root.appendingPathComponent("missing.txt").path, root.path]))

        #expect(activationCount == 0)
    }

    @Test func activatesOnceForMultiFileRequest() throws {
        let first = try makeFile("repo/a.txt")
        let root = first.deletingLastPathComponent()
        let second = root.appendingPathComponent("b.txt")
        try "x\n".write(to: second, atomically: true, encoding: .utf8)
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var activationCount = 0

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: { activationCount += 1 }
        )

        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [first.path, second.path]))

        #expect(response == .ok)
        #expect(activationCount == 1)
    }
}
