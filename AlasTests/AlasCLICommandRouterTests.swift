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

    @Test func resolvesOriginFromCwdWhenNoSession() async throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var opened: [(worktreeId: String, relativePath: String)] = []
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in nil },
            originatingWorktree: { _ in nil },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { relativePath, worktreeId in opened.append((worktreeId, relativePath)) },
            openExternalFile: { _, _ in Issue.record("expected relative open") },
            activateApp: {}
        )
        let response = await router.handle(.init(
            version: 1, sessionId: nil, cwd: root.path,
            command: .open(paths: [root.appendingPathComponent("a.txt").path])
        ))
        #expect(response == .ok)
        #expect(opened.first?.relativePath == "a.txt")
    }

    @Test func notifyRoutesToOriginatingSessionAndWorktree() async throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var captured: (sessionId: String?, worktreeId: String, body: String, title: String?, level: AlasCLINotifyLevel)?
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "acp-1" ? "wt1" : nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            notifySession: { sessionId, origin, body, title, level in
                captured = (sessionId, origin.id, body, title, level)
                return .ok
            },
            activateApp: {}
        )

        let response = await router.handle(.init(
            version: 1,
            sessionId: "acp-1",
            cwd: nil,
            command: .notify(body: "Blocked", title: "Need input", level: .attention)
        ))

        #expect(response == .ok)
        #expect(captured?.sessionId == "acp-1")
        #expect(captured?.worktreeId == "wt1")
        #expect(captured?.body == "Blocked")
        #expect(captured?.title == "Need input")
        #expect(captured?.level == .attention)
    }

    @Test func resolvesOriginFromSymlinkedWorktreeRootCwd() async throws {
        let realRoot = try makeFile("repo/a.txt").deletingLastPathComponent()
        let logicalRoot = realRoot.deletingLastPathComponent().appendingPathComponent("logical-repo")
        try FileManager.default.createSymbolicLink(at: logicalRoot, withDestinationURL: realRoot)
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: realRoot, status: .clean, lastActivity: Date()
        )
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in nil },
            originatingWorktree: { _ in nil },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: {}
        )
        // cwd is the symlink pointing at the worktree root (logical $PWD).
        let owned = await router.handle(.init(version: 1, sessionId: nil, cwd: logicalRoot.path, command: .resolve))
        #expect(owned == .ok)
    }

    @Test func resolveCommandReturnsOkWhenCwdOwned() async throws {
        let root = try makeFile("repo/a.txt").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in nil },
            originatingWorktree: { _ in nil },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: {}
        )
        let owned = await router.handle(.init(version: 1, sessionId: nil, cwd: root.path, command: .resolve))
        #expect(owned == .ok)
        let notOwned = await router.handle(.init(version: 1, sessionId: nil, cwd: "/nope", command: .resolve))
        if case .error = notOwned {} else { Issue.record("expected error for unowned cwd") }
    }

    @Test func resolvesExactNestedWorktreeRootOverParentContainingMatch() async throws {
        let root = try makeFile("repo/pkg/tool/file.txt")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nestedRoot = root.appendingPathComponent("pkg/tool")
        let parent = Worktree(
            id: "parent", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let nested = Worktree(
            id: "nested", projectId: "p1", name: "tool", branch: "tool",
            path: nestedRoot, status: .clean, lastActivity: Date()
        )
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in nil },
            originatingWorktree: { _ in nil },
            visibleWorktrees: { [parent, nested] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: {}
        )

        // cwd is exactly the nested worktree's root, which is also strictly
        // inside the parent's tree. The nested worktree, not the parent, must
        // be treated as the origin.
        let response = await router.handle(.init(
            version: 1, sessionId: nil, cwd: nestedRoot.path, command: .worktree(.list)
        ))

        guard case .text(let rows) = response else {
            Issue.record("expected text response, got \(response)")
            return
        }
        let currentRows = rows.filter { $0.hasPrefix("*") }
        #expect(currentRows.count == 1)
        #expect(currentRows.first?.contains(nestedRoot.path) == true)
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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges(worktree: nil))))

        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        let expectedSession = ReviewDraftSessionID.localChanges(
            worktreeID: current.id, worktreePath: current.path, scope: .all
        )
        let object = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: String]
        #expect(object?["session_id"] == expectedSession.rawValue)
        #expect(opened == current.id)
        #expect(activationCount == 1)
    }

    @Test func opensProviderReviewFromOrigin() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        var opened: (origin: Worktree, target: String)?
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current],
            openReview: { origin, target in
                opened = (origin, target)
                return .ok
            }
        )

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.target("123", worktree: nil))))

        #expect(response == .ok)
        #expect(opened?.origin == current)
        #expect(opened?.target == "123")
    }

    @Test func reviewLocalHonorsWorktreeOverride() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let sibling = Self.worktree(branch: "feature-x", path: "/tmp/repo-feature-x", projectId: "p1")
        var reviewedIn: Worktree?
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current, sibling],
            openReviewChanges: { reviewedIn = $0 }
        )

        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.localChanges(worktree: "feature-x"))
        ))

        if case .error(let message) = response { Issue.record("unexpected error: \(message)") }
        #expect(reviewedIn?.branch == "feature-x")
    }

    @Test func reviewWithUnknownWorktreeOverrideErrors() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current]
        )

        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.localChanges(worktree: "nope"))
        ))

        guard case .error(let message) = response else {
            Issue.record("expected error")
            return
        }
        #expect(message.contains("unknown worktree"))
    }

    @Test func reviewTargetHonorsWorktreeOverride() async throws {
        let current = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let sibling = Self.worktree(branch: "feature-x", path: "/tmp/repo-feature-x", projectId: "p1")
        var reviewedIn: Worktree?
        var reviewedTarget: String?
        let router = Self.router(
            origin: current,
            visibleWorktrees: [current, sibling],
            openReview: { worktree, target in
                reviewedIn = worktree
                reviewedTarget = target
                return .ok
            }
        )

        _ = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.target("main..HEAD", worktree: "feature-x"))
        ))

        #expect(reviewedIn?.branch == "feature-x")
        #expect(reviewedTarget == "main..HEAD")
    }

    private func makeDraftComment(
        id: String,
        worktreeID: String,
        state: ReviewDraftCommentState = .active
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: .localChanges(
                worktreeID: worktreeID,
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "review", path: "a.swift"),
            path: "a.swift",
            originalPath: nil,
            side: .new,
            startLine: 5,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "look at this",
            state: state,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test func reviewCommentWireDTODescribesNonLineAnchors() {
        var fileComment = makeDraftComment(id: "file", worktreeID: "wt1")
        fileComment.anchor = .file
        var imageComment = makeDraftComment(id: "image", worktreeID: "wt1")
        imageComment.anchor = .image(side: .new, normalizedX: 0.625, normalizedY: 0.25)

        let file = ReviewCommentWireDTO(fileComment)
        let image = ReviewCommentWireDTO(imageComment)

        #expect(file.anchorKind == "file")
        #expect(file.startLine == nil)
        #expect(image.anchorKind == "image")
        #expect(image.xPercent == 62.5)
        #expect(image.yPercent == 25)
    }

    private func makeReviewRouter(
        worktree: Worktree,
        store: ReviewDraftCommentStore,
        sessionStore: ReviewSessionStore? = nil,
        onChange: @escaping () -> Void = {},
        gitStatus: @escaping (URL) async throws -> [ChangedFile] = { _ in [] },
        providerReviewOriginalPath: @escaping (ReviewDraftSessionID, String) async -> String? = { _, _ in nil },
        visibleWorktrees: [Worktree]? = nil
    ) -> AlasCLICommandRouter {
        AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "s1" ? worktree.id : nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { visibleWorktrees ?? [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            draftCommentStore: { store },
            reviewSessionStore: { sessionStore ?? ReviewSessionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")) },
            notifyReviewCommentsChanged: onChange,
            gitStatus: gitStatus,
            providerReviewOriginalPath: providerReviewOriginalPath,
            activateApp: {}
        )
    }

    @Test func listsActiveReviewCommentsForTheOriginWorktree() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        try store.save(makeDraftComment(id: "mine", worktreeID: "wt1"))
        try store.save(makeDraftComment(id: "resolved", worktreeID: "wt1", state: .resolved))
        try store.save(makeDraftComment(id: "other", worktreeID: "wt2"))

        let router = makeReviewRouter(worktree: worktree, store: store)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.comments(sessionID: nil, state: .active))
        ))

        guard case .text(let lines) = response, let line = lines.first else {
            Issue.record("expected .text response, got \(response)")
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode([ReviewCommentWireDTO].self, from: Data(line.utf8))
        #expect(decoded.map(\.id) == ["mine"])
        #expect(decoded[0].author.kind == "user")
        #expect(decoded[0].state == "active")

        let all = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.comments(sessionID: nil, state: .all))
        ))
        guard case .text(let allLines) = all, let allLine = allLines.first else {
            Issue.record("expected .text response")
            return
        }
        let allDecoded = try decoder.decode([ReviewCommentWireDTO].self, from: Data(allLine.utf8))
        #expect(Set(allDecoded.map(\.id)) == ["mine", "resolved"])
    }

    @Test func reviewCommentsIgnoresAnExplicitSessionIDFromAnotherWorktree() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let foreignComment = makeDraftComment(id: "foreign", worktreeID: "wt2")
        try store.save(foreignComment)

        let router = makeReviewRouter(worktree: worktree, store: store)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.comments(sessionID: foreignComment.sessionID.rawValue, state: .all))
        ))

        guard case .text(let lines) = response, let line = lines.first else {
            Issue.record("expected .text response, got \(response)")
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode([ReviewCommentWireDTO].self, from: Data(line.utf8))
        #expect(decoded.isEmpty)
    }

    @Test func reviewCommentsAcceptsAnExplicitSessionIDFromASiblingWorktreeInTheSameProject() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let sibling = Worktree(
            id: "wt2", projectId: "p1", name: "feature", branch: "feature",
            path: URL(fileURLWithPath: "/tmp/sibling-repo"), status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let siblingComment = makeDraftComment(id: "sibling-comment", worktreeID: "wt2")
        try store.save(siblingComment)

        let router = makeReviewRouter(worktree: worktree, store: store, visibleWorktrees: [worktree, sibling])
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.comments(sessionID: siblingComment.sessionID.rawValue, state: .all))
        ))

        guard case .text(let lines) = response, let line = lines.first else {
            Issue.record("expected .text response, got \(response)")
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode([ReviewCommentWireDTO].self, from: Data(line.utf8))
        #expect(decoded.map(\.id) == ["sibling-comment"])
    }

    @Test func commentAddResolvesPathAgainstTheSiblingWorktreeForASiblingSession() async throws {
        let originRoot = try makeFile("origin/a.swift").deletingLastPathComponent()
        let siblingRoot = try makeFile("sibling/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: originRoot, status: .clean, lastActivity: Date()
        )
        let sibling = Worktree(
            id: "wt2", projectId: "p1", name: "feature", branch: "feature",
            path: siblingRoot, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let session = ReviewDraftSessionID.localChanges(worktreeID: "wt2", worktreePath: siblingRoot, scope: .all)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)]
            },
            visibleWorktrees: [worktree, sibling]
        )
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: siblingRoot.appendingPathComponent("a.swift").path,
                startLine: 4, endLine: nil, side: nil,
                body: "sibling comment", sessionID: session.rawValue
            ))
        ))

        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        #expect(lines[1].contains("comment_id"))
        let saved = try store.load(sessionID: session)
        #expect(saved.count == 1)
        #expect(saved[0].path == "a.swift")
        #expect(saved[0].fileID == DiffReviewFileID(namespace: "unstaged", path: "a.swift"))
    }

    /// Regression test: the CLI (`alas review comment`) always absolutizes a
    /// relative `path` against the calling terminal's own cwd, regardless of
    /// which worktree the review session actually targets. When a session was
    /// opened against a sibling worktree via `--worktree`, but the comment is
    /// later filed from a terminal still rooted in `origin`, the path the CLI
    /// hands Swift is absolute and rooted in `origin`, not the sibling — even
    /// though the user typed an ordinary relative path. Recovering that
    /// relative form by relativizing against `origin` instead (once the
    /// primary attempt against the sibling fails) must still succeed.
    @Test func commentAddRecoversARelativePathWhenTheAbsolutizedPathIsRootedInTheOriginWorktree() async throws {
        let originRoot = try makeFile("origin/a.swift").deletingLastPathComponent()
        let siblingRoot = try makeFile("sibling/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: originRoot, status: .clean, lastActivity: Date()
        )
        let sibling = Worktree(
            id: "wt2", projectId: "p1", name: "feature", branch: "feature",
            path: siblingRoot, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let session = ReviewDraftSessionID.localChanges(worktreeID: "wt2", worktreePath: siblingRoot, scope: .all)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [ChangedFile(path: "Sources/Foo.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)]
            },
            visibleWorktrees: [worktree, sibling]
        )
        // Simulates exactly what the CLI parser produces: it absolutizes the
        // bare relative path "Sources/Foo.swift" against the caller's cwd
        // (`origin`), even though `sessionID` targets the sibling session.
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: originRoot.appendingPathComponent("Sources/Foo.swift").path,
                startLine: 10, endLine: nil, side: nil,
                body: "recovered path comment", sessionID: session.rawValue
            ))
        ))

        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        #expect(lines[1].contains("comment_id"))
        let saved = try store.load(sessionID: session)
        #expect(saved.count == 1)
        #expect(saved[0].path == "Sources/Foo.swift")
    }

    @Test func reviewFinishSucceedsForASiblingWorktreeSession() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let siblingRoot = URL(fileURLWithPath: "/tmp/sibling-repo")
        let sibling = Worktree(
            id: "wt2", projectId: "p1", name: "feature", branch: "feature",
            path: siblingRoot, status: .clean, lastActivity: Date()
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionStore = ReviewSessionStore(url: directory.appendingPathComponent("sessions.json"))
        let target = ReviewSessionTarget.localChanges(worktreeID: "wt2", repositoryPath: siblingRoot, scope: .all)
        try sessionStore.save(ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        var changed = 0

        let router = makeReviewRouter(
            worktree: worktree,
            store: ReviewDraftCommentStore(url: directory.appendingPathComponent("drafts.json")),
            sessionStore: sessionStore,
            onChange: { changed += 1 },
            visibleWorktrees: [worktree, sibling]
        )

        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.finish(
                sessionID: target.draftSessionID.rawValue,
                verdict: .approve,
                summary: ""
            ))
        ))

        #expect(response == .ok)
        #expect(changed == 1)
        let record = try #require(try sessionStore.load(id: target.id))
        #expect(record.status == .reviewed)
        #expect(record.verdict?.verdict == .approve)
    }

    @Test func replyAndResolveSucceedForACommentOwnedBySiblingWorktreeSession() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let sibling = Worktree(
            id: "wt2", projectId: "p1", name: "feature", branch: "feature",
            path: URL(fileURLWithPath: "/tmp/sibling-repo"), status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        try store.save(makeDraftComment(id: "sibling-c1", worktreeID: "wt2"))

        let router = makeReviewRouter(worktree: worktree, store: store, visibleWorktrees: [worktree, sibling])

        let replyResponse = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.reply(commentID: "sibling-c1", body: "on it"))
        ))
        #expect(replyResponse == .ok)
        let afterReply = try #require(try store.find(commentID: "sibling-c1"))
        #expect(afterReply.allReplies.map(\.bodyMarkdown) == ["on it"])

        let resolveResponse = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.resolve(commentID: "sibling-c1", reply: nil, reopen: false))
        ))
        #expect(resolveResponse == .ok)
        let afterResolve = try #require(try store.find(commentID: "sibling-c1"))
        #expect(afterResolve.state == .resolved)
        #expect(afterResolve.resolvedBy?.isAgent == true)
    }

    /// Regression test: `origin` can be a worktree the user has hidden for
    /// this project, which `visibleWorktrees()` (and thus `projectWorktrees`)
    /// excludes — but the CLI still resolves `origin` itself directly via
    /// `sessionId`/`cwd`, independent of visibility. A plain review session
    /// with no `--worktree` override, opened and used from that same hidden
    /// worktree, must keep resolving even though `origin` is absent from
    /// `projectWorktrees`.
    @Test func reviewFinishSucceedsForASessionOwnedByAHiddenOriginWorktree() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var changed = 0

        // `origin` ("wt1") is deliberately absent from `visibleWorktrees`,
        // simulating a worktree hidden for this project — `projectWorktrees`
        // built from it is empty.
        let router = makeReviewRouter(
            worktree: worktree,
            store: ReviewDraftCommentStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("drafts.json")),
            onChange: { changed += 1 },
            visibleWorktrees: []
        )

        let sessionID = ReviewDraftSessionID.localChanges(worktreeID: "wt1", worktreePath: root, scope: .all)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.finish(
                sessionID: sessionID.rawValue,
                verdict: .approve,
                summary: ""
            ))
        ))

        #expect(response == .ok)
        #expect(changed == 1)
    }

    @Test func commentAddFilesAgentCommentIntoLocalChangesSession() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)]
            }
        )
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "a.swift", startLine: 4, endLine: nil, side: nil, body: "add a guard", sessionID: nil
            ))
        ))

        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        #expect(lines[1].contains("comment_id"))
        let expectedSession = ReviewDraftSessionID.localChanges(
            worktreeID: "wt1", worktreePath: root, scope: .all
        )
        let saved = try store.load(sessionID: expectedSession)
        #expect(saved.count == 1)
        #expect(saved[0].effectiveAuthor.isAgent)
        #expect(saved[0].path == "a.swift")
        #expect(saved[0].side == .new)
        #expect(saved[0].startLine == 4)
        #expect(saved[0].fileID == DiffReviewFileID(namespace: "unstaged", path: "a.swift"))
    }

    @Test func commentAddStampsOriginalPathForProviderReviewRenamedFile() async throws {
        let root = try makeFile("repo/Sources/New.swift").deletingLastPathComponent().deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt1", provider: .gitlab, host: "gitlab.com", repositorySlug: "group/repo", number: 42
        )
        var resolverCalls: [(ReviewDraftSessionID, String)] = []

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            providerReviewOriginalPath: { sessionID, path in
                resolverCalls.append((sessionID, path))
                return path == "Sources/New.swift" ? "Sources/Old.swift" : nil
            }
        )
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "Sources/New.swift", startLine: 3, endLine: nil, side: nil,
                body: "renamed file comment", sessionID: session.rawValue
            ))
        ))

        guard case .text = response else {
            Issue.record("expected .text response, got \(response)")
            return
        }
        #expect(resolverCalls.count == 1)
        #expect(resolverCalls.first?.1 == "Sources/New.swift")
        let saved = try store.load(sessionID: session)
        #expect(saved.count == 1)
        #expect(saved[0].originalPath == "Sources/Old.swift")
    }

    @Test func commentAddLeavesOriginalPathNilWhenResolverReturnsNil() async throws {
        let root = try makeFile("repo/Sources/New.swift").deletingLastPathComponent().deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt1", provider: .gitlab, host: "gitlab.com", repositorySlug: "group/repo", number: 7
        )

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            providerReviewOriginalPath: { _, _ in nil }
        )
        _ = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "Sources/New.swift", startLine: 3, endLine: nil, side: nil,
                body: "unmatched", sessionID: session.rawValue
            ))
        ))

        let saved = try store.load(sessionID: session)
        #expect(saved.count == 1)
        #expect(saved[0].originalPath == nil)
    }

    @Test func commentAddDoesNotResolveOriginalPathForGitHubReview() async throws {
        let root = try makeFile("repo/Sources/New.swift").deletingLastPathComponent().deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt1", provider: .github, host: "github.com", repositorySlug: "org/repo", number: 7
        )
        var resolverCalled = false

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            providerReviewOriginalPath: { _, _ in
                resolverCalled = true
                return "Sources/Old.swift"
            }
        )
        _ = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "Sources/New.swift", startLine: 3, endLine: nil, side: nil,
                body: "github comment", sessionID: session.rawValue
            ))
        ))

        // GitHub publishing ignores originalPath, so the resolver (which loads
        // the provider diff) must not run for a GitHub review.
        #expect(!resolverCalled)
        let saved = try store.load(sessionID: session)
        #expect(saved.count == 1)
        #expect(saved[0].originalPath == nil)
    }

    @Test func commentAddDoesNotResolveOriginalPathForLocalChangesSession() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        var resolverCalled = false

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)]
            },
            providerReviewOriginalPath: { _, _ in
                resolverCalled = true
                return "Sources/Old.swift"
            }
        )
        _ = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "a.swift", startLine: 1, endLine: nil, side: nil, body: "local", sessionID: nil
            ))
        ))

        #expect(!resolverCalled)
        let expectedSession = ReviewDraftSessionID.localChanges(worktreeID: "wt1", worktreePath: root, scope: .all)
        let saved = try store.load(sessionID: expectedSession)
        #expect(saved.count == 1)
        #expect(saved[0].originalPath == nil)
    }

    @Test func commentAddPrefersUnstagedWhenPathIsBothStagedAndUnstaged() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [
                    ChangedFile(path: "a.swift", status: "M", stage: .staged, add: 1, del: 0, renameFrom: nil),
                    ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil),
                ]
            }
        )
        _ = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "a.swift", startLine: 4, endLine: nil, side: nil, body: "add a guard", sessionID: nil
            ))
        ))

        let expectedSession = ReviewDraftSessionID.localChanges(
            worktreeID: "wt1", worktreePath: root, scope: .all
        )
        let saved = try store.load(sessionID: expectedSession)
        #expect(saved.first?.fileID == DiffReviewFileID(namespace: "unstaged", path: "a.swift"))
    }

    @Test func commentAddHonorsAStagedOnlySessionScopeOverUnstagedGitStatus() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let stagedSession = ReviewDraftSessionID.localChanges(worktreeID: "wt1", worktreePath: root, scope: .staged)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [
                    ChangedFile(path: "a.swift", status: "M", stage: .staged, add: 1, del: 0, renameFrom: nil),
                    ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil),
                ]
            }
        )
        _ = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "a.swift", startLine: 4, endLine: nil, side: nil, body: "add a guard",
                sessionID: stagedSession.rawValue
            ))
        ))

        let saved = try store.load(sessionID: stagedSession)
        #expect(saved.first?.fileID == DiffReviewFileID(namespace: "staged", path: "a.swift"))
    }

    @Test func commentAddRejectsPathOutsideAStagedOnlySessionScope() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let stagedSession = ReviewDraftSessionID.localChanges(worktreeID: "wt1", worktreePath: root, scope: .staged)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)]
            }
        )
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "a.swift", startLine: 4, endLine: nil, side: nil, body: "add a guard",
                sessionID: stagedSession.rawValue
            ))
        ))

        guard case .error(let message) = response else {
            Issue.record("expected error, got \(response)")
            return
        }
        #expect(message.contains("no staged changes found"))
        #expect(try store.load(sessionID: stagedSession).isEmpty)
    }

    @Test func commentAddRejectsPathWithNoLocalChanges() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)

        let router = makeReviewRouter(worktree: worktree, store: store, gitStatus: { _ in [] })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "a.swift", startLine: 4, endLine: nil, side: nil, body: "add a guard", sessionID: nil
            ))
        ))

        guard case .error(let message) = response else {
            Issue.record("expected error, got \(response)")
            return
        }
        #expect(message.contains("no local changes found"))
        #expect(try store.load(sessionID: .localChanges(worktreeID: "wt1", worktreePath: root, scope: .all)).isEmpty)
    }

    @Test func commentAddRejectsAnAbsolutePathOutsideTheWorktree() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        // A session kind that doesn't need a git-status lookup to resolve
        // its namespace, so an out-of-worktree path can't slip through by
        // virtue of the local-changes git-status check happening to reject
        // it for an unrelated reason.
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt1", repositoryPath: root, sha: "abc123", title: "Review abc123"
        )

        let router = makeReviewRouter(worktree: worktree, store: store)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "/tmp/some-other-repo/foo.swift", startLine: 1, endLine: nil, side: nil,
                body: "add a guard", sessionID: target.draftSessionID.rawValue
            ))
        ))

        guard case .error(let message) = response else {
            Issue.record("expected error, got \(response)")
            return
        }
        #expect(message.contains("inside the worktree"))
        #expect(try store.load(sessionID: target.draftSessionID).isEmpty)
    }

    @Test func worktreeRelativePathNormalizesAlreadyRelativePaths() {
        #expect(AlasActionService.worktreeRelativePath("./Sources/App.swift", worktreeRoot: URL(fileURLWithPath: "/repo")) == "Sources/App.swift")
        #expect(AlasActionService.worktreeRelativePath("Sources/../Sources/App.swift", worktreeRoot: URL(fileURLWithPath: "/repo")) == "Sources/App.swift")
        #expect(AlasActionService.worktreeRelativePath("Sources//App.swift", worktreeRoot: URL(fileURLWithPath: "/repo")) == "Sources/App.swift")
        #expect(AlasActionService.worktreeRelativePath("a.swift", worktreeRoot: URL(fileURLWithPath: "/repo")) == "a.swift")
        // A leading `..` can't climb above the (already worktree-relative)
        // root — it's dropped rather than followed.
        #expect(AlasActionService.worktreeRelativePath("../a.swift", worktreeRoot: URL(fileURLWithPath: "/repo")) == "a.swift")
    }

    @Test func commentAddFilesAgentCommentAtNormalizedPathForDotSlashInput() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)]
            }
        )
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "./a.swift", startLine: 1, endLine: nil, side: nil, body: "add a guard", sessionID: nil
            ))
        ))

        guard case .text = response else {
            Issue.record("expected .text response, got \(response)")
            return
        }
        let expectedSession = ReviewDraftSessionID.localChanges(worktreeID: "wt1", worktreePath: root, scope: .all)
        let saved = try store.load(sessionID: expectedSession)
        #expect(saved.count == 1)
        #expect(saved[0].path == "a.swift")
    }

    @Test func worktreeRelativePathResolvesCaseVariantRootOnACaseInsensitiveVolume() throws {
        // On the default case-insensitive-but-case-preserving macOS volume,
        // a case-variant of the tracked root's name (e.g. the shell's $PWD
        // differs only in casing) refers to the identical directory. A
        // string-prefix check can't see that; file identity can.
        let realRoot = try makeFile("case-repo/Sources/App.swift")
            .deletingLastPathComponent().deletingLastPathComponent()
        let variantRoot = realRoot.deletingLastPathComponent()
            .appendingPathComponent(realRoot.lastPathComponent.uppercased())
        let variantPath = variantRoot.appendingPathComponent("Sources/App.swift").path

        #expect(
            AlasActionService.worktreeRelativePath(variantPath, worktreeRoot: realRoot)
                == "Sources/App.swift"
        )
    }

    @Test func worktreeRelativePathResolvesSymlinkedRootAgainstTheRealWorktreePath() throws {
        // resolvingSymlinksInPath() needs the file to actually exist to
        // resolve the intermediate symlink, matching the real scenario:
        // agents comment on files that exist in the working tree.
        let realRoot = try makeFile("repo/Sources/App.swift").deletingLastPathComponent().deletingLastPathComponent()
        let logicalRoot = realRoot.deletingLastPathComponent().appendingPathComponent("logical-repo")
        try FileManager.default.createSymbolicLink(at: logicalRoot, withDestinationURL: realRoot)

        // The CLI absolutizes against the caller's logical $PWD, which
        // preserves the symlink the user cd'd through.
        let pathUnderSymlink = logicalRoot.appendingPathComponent("Sources/App.swift").path

        #expect(
            AlasActionService.worktreeRelativePath(pathUnderSymlink, worktreeRoot: realRoot)
                == "Sources/App.swift"
        )
    }

    @Test func commentAddFilesIntoTheCorrectSessionWhenRunFromASymlinkedWorktree() async throws {
        let realRoot = try makeFile("repo/Sources/App.swift").deletingLastPathComponent().deletingLastPathComponent()
        let logicalRoot = realRoot.deletingLastPathComponent().appendingPathComponent("logical-repo")
        try FileManager.default.createSymbolicLink(at: logicalRoot, withDestinationURL: realRoot)
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: realRoot, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)

        let router = makeReviewRouter(
            worktree: worktree, store: store,
            gitStatus: { _ in
                [ChangedFile(path: "Sources/App.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)]
            }
        )
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: logicalRoot.appendingPathComponent("Sources/App.swift").path,
                startLine: 1, endLine: nil, side: nil, body: "add a guard", sessionID: nil
            ))
        ))

        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        let expectedSession = ReviewDraftSessionID.localChanges(
            worktreeID: "wt1", worktreePath: realRoot, scope: .all
        )
        let saved = try store.load(sessionID: expectedSession)
        #expect(saved.count == 1)
        #expect(saved[0].path == "Sources/App.swift")
        #expect(saved[0].fileID == DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"))
    }

    @Test func commentAddRejectsSessionIDFromAnotherWorktree() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        let foreignSession = ReviewDraftSessionID.localChanges(
            worktreeID: "wt2", worktreePath: URL(fileURLWithPath: "/other-repo"), scope: .all
        )

        let router = makeReviewRouter(worktree: worktree, store: store)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.commentAdd(
                path: "a.swift", startLine: 4, endLine: nil, side: nil, body: "sneaky",
                sessionID: foreignSession.rawValue
            ))
        ))

        guard case .error(let message) = response else {
            Issue.record("expected error, got \(response)")
            return
        }
        #expect(message.contains("unknown review session id"))
        #expect(try store.load(sessionID: foreignSession).isEmpty)
    }

    @Test func reviewLocalReturnsItsSessionID() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        var openedReview = false
        var router = makeReviewRouter(
            worktree: worktree,
            store: ReviewDraftCommentStore(
                url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            )
        )
        router.openReviewChanges = { _ in openedReview = true }

        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges(worktree: nil))
        ))

        #expect(openedReview)
        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        let expected = ReviewDraftSessionID.localChanges(worktreeID: "wt1", worktreePath: root, scope: .all)
        #expect(lines[1].contains(#""session_id":"#))
        let object = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: String]
        #expect(object?["session_id"] == expected.rawValue)
    }

    @Test func reviewFinishRecordsVerdictForTheRequestedSession() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionStore = ReviewSessionStore(url: directory.appendingPathComponent("sessions.json"))
        let target = ReviewSessionTarget.localChanges(worktreeID: "wt1", repositoryPath: root, scope: .all)
        try sessionStore.save(ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        var changed = 0
        let router = makeReviewRouter(
            worktree: worktree,
            store: ReviewDraftCommentStore(url: directory.appendingPathComponent("drafts.json")),
            sessionStore: sessionStore,
            onChange: { changed += 1 }
        )

        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.finish(
                sessionID: target.draftSessionID.rawValue,
                verdict: .requestChanges,
                summary: "Fix the race."
            ))
        ))

        #expect(response == .ok)
        #expect(changed == 1)
        let record = try #require(try sessionStore.load(id: target.id))
        #expect(record.status == .reviewed)
        #expect(record.verdict?.verdict == .requestChanges)
        #expect(record.verdict?.summary == "Fix the race.")
        #expect(try sessionStore.findActive(targetID: target.id) == nil)
    }

    @Test func reviewFinishRejectsChangeRequestWithoutSummary() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let sessionStore = ReviewSessionStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        )
        let router = makeReviewRouter(
            worktree: worktree,
            store: ReviewDraftCommentStore(
                url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            ),
            sessionStore: sessionStore
        )

        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.finish(sessionID: nil, verdict: .requestChanges, summary: "  "))
        ))

        #expect(response == .error("request_changes requires a non-empty summary"))
        let target = ReviewSessionTarget.localChanges(worktreeID: "wt1", repositoryPath: root, scope: .all)
        #expect(try sessionStore.load(id: target.id) == nil)
    }

    @Test func replyAppendsAgentReplyAndNotifies() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        try store.save(makeDraftComment(id: "c1", worktreeID: "wt1"))
        var changed = 0

        let router = makeReviewRouter(worktree: worktree, store: store, onChange: { changed += 1 })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.reply(commentID: "c1", body: "on it"))
        ))

        #expect(response == .ok)
        #expect(changed == 1)
        let comment = try #require(try store.find(commentID: "c1"))
        #expect(comment.allReplies.count == 1)
        #expect(comment.allReplies[0].bodyMarkdown == "on it")
        #expect(comment.allReplies[0].author.isAgent)
    }

    @Test func resolveSetsStateProvenanceAndAddressesHandoffs() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ReviewDraftCommentStore(url: dir.appendingPathComponent("drafts.json"))
        let sessionStore = ReviewSessionStore(url: dir.appendingPathComponent("sessions.json"))
        let comment = makeDraftComment(id: "c1", worktreeID: "wt1")
        try store.save(comment)
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        try sessionStore.save(ReviewSessionRecord(
            id: target.id,
            target: target,
            status: .sent,
            handoffs: [ReviewFeedbackHandoff(
                id: "h1",
                sessionID: target.id,
                commentIDs: ["c1"],
                target: .newChat(agentID: "claude", title: "New chat"),
                createdAt: Date(timeIntervalSince1970: 1),
                promptRevision: "rev",
                status: .sent
            )],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        ))

        let router = makeReviewRouter(worktree: worktree, store: store, sessionStore: sessionStore)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.resolve(commentID: "c1", reply: "fixed in abc123", reopen: false))
        ))

        #expect(response == .ok)
        let updated = try #require(try store.find(commentID: "c1"))
        #expect(updated.state == .resolved)
        #expect(updated.resolvedBy?.isAgent == true)
        #expect(updated.allReplies.map(\.bodyMarkdown) == ["fixed in abc123"])
        let record = try #require(try sessionStore.load(id: target.id))
        #expect(record.status == .addressed)
        #expect(record.handoffs.map(\.status) == [.addressed])
    }

    @Test func reopeningAResolvedCommentDemotesAnAddressedHandoff() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ReviewDraftCommentStore(url: dir.appendingPathComponent("drafts.json"))
        let sessionStore = ReviewSessionStore(url: dir.appendingPathComponent("sessions.json"))
        var comment = makeDraftComment(id: "c1", worktreeID: "wt1", state: .resolved)
        comment.resolvedBy = .agent(name: "Agent")
        try store.save(comment)
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        try sessionStore.save(ReviewSessionRecord(
            id: target.id,
            target: target,
            status: .addressed,
            handoffs: [ReviewFeedbackHandoff(
                id: "h1",
                sessionID: target.id,
                commentIDs: ["c1"],
                target: .newChat(agentID: "claude", title: "New chat"),
                createdAt: Date(timeIntervalSince1970: 1),
                promptRevision: "rev",
                status: .addressed
            )],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        ))

        let router = makeReviewRouter(worktree: worktree, store: store, sessionStore: sessionStore)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.resolve(commentID: "c1", reply: nil, reopen: true))
        ))

        #expect(response == .ok)
        let updated = try #require(try store.find(commentID: "c1"))
        #expect(updated.state == .active)
        #expect(updated.resolvedBy == nil)
        let record = try #require(try sessionStore.load(id: target.id))
        #expect(record.status == .sent)
        #expect(record.handoffs.map(\.status) == [.sent])
    }

    private struct FailingReviewSessionPersistenceStore: PersistenceStoreProtocol {
        struct Failure: Error {}
        func write<T: Encodable>(_ value: T, to url: URL) throws { throw Failure() }
        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? { throw Failure() }
    }

    @Test func resolveSucceedsAndNotifiesEvenWhenHandoffRecomputationFails() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ReviewDraftCommentStore(url: dir.appendingPathComponent("drafts.json"))
        try store.save(makeDraftComment(id: "c1", worktreeID: "wt1"))
        let brokenSessionStore = ReviewSessionStore(
            store: FailingReviewSessionPersistenceStore(),
            url: dir.appendingPathComponent("sessions.json")
        )
        var changed = 0

        let router = makeReviewRouter(
            worktree: worktree, store: store, sessionStore: brokenSessionStore, onChange: { changed += 1 }
        )
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.resolve(commentID: "c1", reply: "fixed", reopen: false))
        ))

        #expect(response == .ok)
        #expect(changed == 1)
        let updated = try #require(try store.find(commentID: "c1"))
        #expect(updated.state == .resolved)
        #expect(updated.allReplies.map(\.bodyMarkdown) == ["fixed"])
    }

    @Test func mutationsRejectCommentsFromOtherWorktrees() async throws {
        let root = try makeFile("repo/a.swift").deletingLastPathComponent()
        let worktree = Worktree(
            id: "wt1", projectId: "p1", name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("drafts.json")
        let store = ReviewDraftCommentStore(url: storeURL)
        try store.save(makeDraftComment(id: "foreign", worktreeID: "wt2"))

        let router = makeReviewRouter(worktree: worktree, store: store)
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.resolve(commentID: "foreign", reply: nil, reopen: false))
        ))

        guard case .error(let message) = response else {
            Issue.record("expected error, got \(response)")
            return
        }
        #expect(message.contains("unknown review comment id"))
    }

    @Test func sessionCommandsForwardTheirResolvedACPOrigin() async throws {
        let worktree = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let origin = ACPOrchestrationSessionOrigin(
            sessionId: "acp-1",
            projectId: "p1",
            worktreeId: worktree.id
        )
        var listedOrigin: ACPOrchestrationSessionOrigin?
        var created: (origin: ACPOrchestrationSessionOrigin, request: ACPDelegatedSessionNewRequest)?
        var sent: (origin: ACPOrchestrationSessionOrigin, request: ACPDelegatedSessionMessageRequest)?
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in worktree.id },
            resolveACPSessionOrigin: { $0 == "acp-1" ? origin : nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            listDelegatedSessions: { resolvedOrigin in
                listedOrigin = resolvedOrigin
                return .text([#"{"sessions":[]}"#])
            },
            createDelegatedSession: { resolvedOrigin, request in
                created = (resolvedOrigin, request)
                return .text([#"{"session_id":"child"}"#])
            },
            sendDelegatedSessionMessage: { resolvedOrigin, request in
                sent = (resolvedOrigin, request)
                return .text([#"{"queued":true}"#])
            },
            activateApp: {}
        )

        let list = await router.handle(.init(version: 1, sessionId: "acp-1", cwd: nil, command: .sessionList))
        let create = await router.handle(.init(
            version: 1,
            sessionId: "acp-1",
            cwd: nil,
            command: .sessionNew(
                prompt: "Implement this",
                agentID: "codex",
                worktree: .new(branch: "child", base: "origin/main")
            )
        ))
        let send = await router.handle(.init(
            version: 1,
            sessionId: "acp-1",
            cwd: nil,
            command: .sessionSend(sessionID: "child", prompt: "Please continue")
        ))

        #expect(listedOrigin == origin)
        #expect(created?.origin == origin)
        #expect(created?.request == ACPDelegatedSessionNewRequest(
            prompt: "Implement this",
            agentId: "codex",
            worktree: .new(branch: "child", base: "origin/main")
        ))
        #expect(sent?.origin == origin)
        #expect(sent?.request == ACPDelegatedSessionMessageRequest(
            targetSessionId: "child",
            prompt: "Please continue"
        ))
        #expect(list == .text([#"{"sessions":[]}"#]))
        #expect(create == .text([#"{"session_id":"child"}"#]))
        #expect(send == .text([#"{"queued":true}"#]))
    }

    @Test func sessionCommandsRequireAnOriginatingACPSession() async throws {
        let worktree = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "terminal-1" ? worktree.id : nil },
            resolveACPSessionOrigin: { _ in nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: {}
        )

        let terminal = await router.handle(.init(
            version: 1, sessionId: "terminal-1", cwd: nil, command: .sessionList
        ))
        let directory = await router.handle(.init(
            version: 1, sessionId: nil, cwd: worktree.path.path, command: .sessionList
        ))

        #expect(terminal == .error("session commands require an originating ACP session"))
        #expect(directory == .error("session commands require an originating ACP session"))
    }

    private static func router(
        origin: Worktree,
        visibleWorktrees: [Worktree],
        focusWorktree: @escaping (Worktree) -> Void = { _ in },
        createWorktree: @escaping (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in .ok },
        deleteWorktree: @escaping (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in .ok },
        openReviewChanges: @escaping (Worktree) -> Void = { _ in },
        openReview: @escaping (Worktree, String) async -> AlasCLIResponse = { _, _ in .ok },
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
            openReview: openReview,
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
