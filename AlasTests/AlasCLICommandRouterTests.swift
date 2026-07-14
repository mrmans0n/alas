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

    @Test func opensInWorktreeFileByRelativePath() async throws {
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [root.appendingPathComponent("a.txt").path])))

        #expect(response == .ok)
        #expect(opened.count == 1)
        #expect(opened[0].worktreeId == "wt1")
        #expect(opened[0].relativePath == "a.txt")
    }

    @Test func opensNestedWorktreeFileInMostSpecificVisibleWorktree() async throws {
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [nestedRoot.appendingPathComponent("file.txt").path])))

        #expect(response == .ok)
        #expect(opened.count == 1)
        #expect(opened[0].worktreeId == "nested")
        #expect(opened[0].relativePath == "file.txt")
    }

    @Test func opensSymlinkedLogicalWorktreePathByRelativePath() async throws {
        let realRoot = try makeFile("repo/Sources/App.swift")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let logicalRoot = realRoot.deletingLastPathComponent().appendingPathComponent("logical-repo")
        try FileManager.default.createSymbolicLink(at: logicalRoot, withDestinationURL: realRoot)
        let logicalFile = logicalRoot.appendingPathComponent("Sources/App.swift")
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: realRoot, status: .clean, lastActivity: Date()
        )
        var opened: [(worktreeId: String, relativePath: String)] = []

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { relativePath, worktreeId in opened.append((worktreeId, relativePath)) },
            openExternalFile: { _, _ in Issue.record("expected relative open") },
            activateApp: {}
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [logicalFile.path])))

        #expect(response == .ok)
        #expect(opened.count == 1)
        #expect(opened[0].worktreeId == "wt1")
        #expect(opened[0].relativePath == "Sources/App.swift")
    }

    @Test func opensCaseVariantWorktreePathByRelativePathOnCaseInsensitiveVolumes() async throws {
        let realRoot = try makeFile("repo/Sources/App.swift")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let caseVariantRoot = realRoot.deletingLastPathComponent().appendingPathComponent(realRoot.lastPathComponent.uppercased())
        let caseVariantFile = caseVariantRoot.appendingPathComponent("Sources/App.swift")
        guard FileManager.default.fileExists(atPath: caseVariantFile.path) else {
            return
        }
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: realRoot, status: .clean, lastActivity: Date()
        )
        var opened: [(worktreeId: String, relativePath: String)] = []

        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in "wt1" },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { relativePath, worktreeId in opened.append((worktreeId, relativePath)) },
            openExternalFile: { _, _ in Issue.record("expected relative open") },
            activateApp: {}
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [caseVariantFile.path])))

        #expect(response == .ok)
        #expect(opened.count == 1)
        #expect(opened[0].worktreeId == "wt1")
        #expect(opened[0].relativePath == "Sources/App.swift")
    }

    @Test func opensExternalFileOwnedByOriginatingWorktree() async throws {
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [external.path])))

        #expect(response == .ok)
        #expect(externalOpens.count == 1)
        #expect(externalOpens[0].worktreeId == "wt1")
        #expect(externalOpens[0].url.standardizedFileURL.path == external.standardizedFileURL.path)
    }

    @Test func rejectsUnsafePrefixMatch() async throws {
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [siblingFile.path])))

        #expect(response == .ok)
        #expect(externalCount == 1)
    }

    @Test func rejectsMissingFilesAndDirectories() async throws {
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

        let missing = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [root.appendingPathComponent("missing.txt").path])))
        let directory = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [root.path])))

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

    @Test func returnsCombinedErrorForMissingFilesAndDirectoriesInOneRequest() async throws {
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [missingPath, root.path])))

        guard case .error(let message) = response else {
            Issue.record("expected combined error")
            return
        }
        #expect(message.contains("\(missingPath) does not exist."))
        #expect(message.contains("\(root.path) is a directory."))
    }

    @Test func activatesAfterSuccessfulOpen() async throws {
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [root.appendingPathComponent("a.txt").path])))

        #expect(response == .ok)
        #expect(activationCount == 1)
    }

    @Test func doesNotActivateWhenAllPathsFail() async throws {
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

        _ = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [root.appendingPathComponent("missing.txt").path, root.path])))

        #expect(activationCount == 0)
    }

    @Test func activatesOnceForMultiFileRequest() async throws {
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [first.path, second.path])))

        #expect(response == .ok)
        #expect(activationCount == 1)
    }

    @Test func listsCurrentProjectWorktrees() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let other = Self.worktree(branch: "feature/review", path: "/tmp/review", projectId: "p1")
        let differentProject = Self.worktree(branch: "main", path: "/tmp/other", projectId: "p2")
        let router = Self.router(origin: current, visibleWorktrees: [current, other, differentProject])

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.list)))

        #expect(response == .text(AlasCLIWorktreeResolver.rows(worktrees: [current, other], currentWorktreeId: current.id)))
    }

    @Test func switchesMatchedWorktree() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let target = Self.worktree(branch: "feature/review", path: "/tmp/review", projectId: "p1")
        var focused: (id: String, projectId: String)?
        var activationCount = 0
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current, target],
            focusWorktree: { focused = ($0.id, $0.projectId) },
            activateApp: { activationCount += 1 }
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.switch(target: "feature"))))

        #expect(response == .ok)
        #expect(focused?.id == target.id)
        #expect(focused?.projectId == "p1")
        #expect(activationCount == 1)
    }

    @Test func returnsWorktreeResolutionErrors() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let first = Self.worktree(branch: "feature/a", path: "/tmp/a", projectId: "p1")
        let second = Self.worktree(branch: "feature/b", path: "/tmp/b", projectId: "p1")
        let router = Self.router(origin: current, visibleWorktrees: [current, first, second])

        let missing = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.switch(target: "missing"))))
        let ambiguous = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "feature", force: false, keepBranch: false))))

        #expect(missing == .error("unknown worktree \"missing\""))
        #expect(ambiguous == .error("ambiguous worktree \"feature\"; matches: feature/a, feature/b"))
    }

    @Test func createsNewWorktreeFromOrigin() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        var created: (origin: Worktree, branch: String, base: String?)?
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current],
            createWorktree: { origin, branch, base in
                created = (origin, branch, base)
                return .text(["created"])
            }
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.new(branch: "feature/cli", base: "main"))))

        #expect(response == .text(["created"]))
        #expect(created?.origin == current)
        #expect(created?.branch == "feature/cli")
        #expect(created?.base == "main")
    }

    @Test func deletesMatchedWorktree() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let target = Self.worktree(branch: "feature/review", path: "/tmp/review", projectId: "p1")
        var deleted: (worktree: Worktree, force: Bool, keepBranch: Bool)?
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current, target],
            deleteWorktree: { worktree, force, keepBranch in
                deleted = (worktree, force, keepBranch)
                return .ok
            }
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "feature", force: true, keepBranch: true))))

        #expect(response == .ok)
        #expect(deleted?.worktree == target)
        #expect(deleted?.force == true)
        #expect(deleted?.keepBranch == true)
    }

    @Test func opensLocalReviewChanges() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        var opened: String?
        var activationCount = 0
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current],
            openReviewChanges: { opened = $0.id },
            activateApp: { activationCount += 1 }
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges)))

        #expect(response == .ok)
        #expect(opened == current.id)
        #expect(activationCount == 1)
    }

    @Test func opensProviderReviewFromOrigin() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        var opened: (origin: Worktree, target: String)?
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current],
            openProviderReview: { origin, target in
                opened = (origin, target)
                return .ok
            }
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.provider(target: "123"))))

        #expect(response == .ok)
        #expect(opened?.origin == current)
        #expect(opened?.target == "123")
    }

    private static func router(
        origin: Worktree,
        visibleWorktrees: [Worktree],
        focusWorktree: @escaping (Worktree) -> Void = { _ in },
        createWorktree: @escaping (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in .ok },
        deleteWorktree: @escaping (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in .ok },
        openReviewChanges: @escaping (Worktree) -> Void = { _ in },
        openProviderReview: @escaping (Worktree, String) async -> AlasCLIResponse = { _, _ in .ok },
        activateApp: @escaping () -> Void = {}
    ) -> AlasCLICommandRouter {
        AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "s1" ? origin.id : nil },
            originatingWorktree: { $0 == origin.id ? origin : nil },
            visibleWorktrees: { visibleWorktrees },
            openRelativeFile: { _, _ in Issue.record("expected no relative file open") },
            openExternalFile: { _, _ in Issue.record("expected no external file open") },
            focusWorktree: focusWorktree,
            createWorktree: createWorktree,
            deleteWorktree: deleteWorktree,
            openReviewChanges: openReviewChanges,
            openProviderReview: openProviderReview,
            activateApp: activateApp
        )
    }

    private static func worktree(branch: String, path: String, projectId: String) -> Worktree {
        Worktree(
            id: Worktree.makeId(path: URL(fileURLWithPath: path)),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: URL(fileURLWithPath: path),
            status: .clean,
            lastActivity: Date()
        )
    }
}
