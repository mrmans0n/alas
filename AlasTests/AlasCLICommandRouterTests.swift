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

        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges)))

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

    private func makeReviewRouter(
        worktree: Worktree,
        store: ReviewDraftCommentStore,
        sessionStore: ReviewSessionStore? = nil,
        onChange: @escaping () -> Void = {},
        gitStatus: @escaping (URL) async throws -> [ChangedFile] = { _ in [] }
    ) -> AlasCLICommandRouter {
        AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "s1" ? worktree.id : nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            draftCommentStore: { store },
            reviewSessionStore: { sessionStore ?? ReviewSessionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")) },
            notifyReviewCommentsChanged: onChange,
            gitStatus: gitStatus,
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
            version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges)
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
