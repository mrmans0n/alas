import Foundation
import Testing
@testable import Alas
@_spi(Testing) import AlasCore

struct NativePeerWorkspaceTests {
    private func changed(_ path: String, add: Int = 1) -> RemoteChangedFile {
        .init(path: path, status: "M", add: add, del: 0, conflict: nil, renameFrom: nil)
    }

    private func dir(_ path: String) -> RemoteFileNode {
        .init(name: (path as NSString).lastPathComponent, path: path, kind: "dir",
              badge: nil, childrenState: "notLoaded", isSubmodule: false)
    }

    private func file(_ path: String) -> RemoteFileNode {
        .init(name: (path as NSString).lastPathComponent, path: path, kind: "file",
              badge: "M", childrenState: "loaded", isSubmodule: false)
    }

    @Test func commitFilesLoadOnceAndRetryAfterDisconnect() {
        var workspace = NativePeerWorkspace()
        let started = workspace.beginCommitFilesLoad(sha: "abc1234")
        let duplicate = workspace.beginCommitFilesLoad(sha: "abc1234")
        #expect(started)
        #expect(!duplicate)
        workspace.markUnavailable()
        let retried = workspace.beginCommitFilesLoad(sha: "abc1234")
        #expect(retried)
        let applied = workspace.apply(.commitFiles(sessionId: "B:s", sha: "abc1234",
            files: [changed("src/a.swift")], truncated: true))
        #expect(applied)
        guard case .loaded(let files) = workspace.commitFiles["abc1234"] else {
            Issue.record("expected loaded commit files")
            return
        }
        #expect(files.files.map(\.path) == ["src/a.swift"])
        #expect(files.truncated)
        let reloaded = workspace.beginCommitFilesLoad(sha: "abc1234")
        #expect(!reloaded)
    }

    @Test func olderPeerCommitRepliesDoNotStartUnsupportedRequests() {
        var workspace = NativePeerWorkspace()
        _ = workspace.apply(.changeList(sessionId: "B:s", comparisonRef: "main", metricsAvailable: true,
            files: [], staged: [], unstaged: [], commits: [
                RemoteCommit(shortSha: "abc1234", subject: "change", author: "author", add: 1, del: 0),
            ], truncated: false))
        let started = workspace.beginCommitFilesLoad(sha: "abc1234")
        #expect(!started)
        guard case .failed = workspace.commitFiles["abc1234"] else {
            Issue.record("expected an unsupported-peer message")
            return
        }
    }

    @Test func commitDiffRepliesAreScopedToTheSelectedCommit() {
        var workspace = NativePeerWorkspace()
        workspace.beginDocument(.commitDiff(path: "a.swift", sha: "bbb2222"))
        _ = workspace.apply(.commitDiffResult(sessionId: "B:s", sha: "aaa1111", path: "a.swift",
            hunks: [], truncated: false, metadataNote: "old"))
        _ = workspace.apply(.fileDiffResult(sessionId: "B:s", path: "a.swift",
            hunks: [], truncated: false))
        #expect(workspace.documentContent == .loading)
        _ = workspace.apply(.commitDiffResult(sessionId: "B:s", sha: "bbb2222", path: "a.swift",
            hunks: [], truncated: false, metadataNote: "File renamed"))
        #expect(workspace.documentContent == .loaded(.diff(
            ParsedDiff(hunks: [], metadataSummary: "File renamed"), truncated: false)))
    }

    @Test func changeListFillsSectionsAndAFailedRefreshKeepsIt() {
        var workspace = NativePeerWorkspace()
        workspace.beginChangesLoad()
        #expect(workspace.changes == .loading)

        let applied = workspace.apply(.changeList(
            sessionId: "B:s", comparisonRef: "origin/main", metricsAvailable: true,
            files: [changed("a.swift"), changed("b.swift")], staged: [changed("a.swift")],
            unstaged: [changed("b.swift")], commits: [], truncated: false))
        #expect(applied)
        guard case .loaded(let changes) = workspace.changes else {
            Issue.record("expected loaded changes")
            return
        }
        #expect(changes.comparisonRef == "origin/main")
        #expect(changes.branchFiles.map(\.path) == ["a.swift", "b.swift"])
        #expect(changes.staged.map(\.stage) == [.staged])
        #expect(changes.unstaged.map(\.stage) == [.unstaged])

        workspace.beginChangesLoad()
        _ = workspace.apply(.changeListFailed(sessionId: "B:s", reason: .gitFailed, message: nil))
        #expect(workspace.changes == .loaded(changes))
    }

    @Test func lateReplyForAnEarlierDocumentIsIgnored() {
        var workspace = NativePeerWorkspace()
        workspace.beginDocument(.file(path: "a.swift"))
        workspace.beginDocument(.diff(path: "b.swift", stage: .staged))

        _ = workspace.apply(.fileContents(sessionId: "B:s", path: "a.swift", text: "old", truncated: false))
        #expect(workspace.documentContent == .loading)

        let hunk = RemoteDiffHunk(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
            RemoteDiffLine(kind: "delete", text: "x", oldNumber: 1, newNumber: nil),
            RemoteDiffLine(kind: "add", text: "y", oldNumber: nil, newNumber: 1),
        ])
        // Same path, other stage: still not the open document.
        _ = workspace.apply(.fileDiffResult(sessionId: "B:s", path: "b.swift", stage: "unstaged",
                                            hunks: [hunk], truncated: false))
        #expect(workspace.documentContent == .loading)

        _ = workspace.apply(.fileDiffResult(sessionId: "B:s", path: "b.swift", stage: "staged",
                                            hunks: [hunk], truncated: false))
        guard case .loaded(.diff(let diff, truncated: false)) = workspace.documentContent else {
            Issue.record("expected a loaded diff")
            return
        }
        #expect(diff.hunks.first?.lines.map(\.kind) == [.delete, .add])
    }

    @Test func childListingMergesUnderItsDirectoryOnce() {
        var workspace = NativePeerWorkspace()
        let rootLoadStarted = workspace.beginRootLoad()
        #expect(rootLoadStarted)
        let rootLoadStartedAgain = workspace.beginRootLoad()
        #expect(!rootLoadStartedAgain)
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        #expect(workspace.shouldLoadChildren(path: "src", childrenState: .notLoaded))

        let childLoadStarted = workspace.beginChildrenLoad(path: "src")
        #expect(childLoadStarted)
        let childLoadStartedAgain = workspace.beginChildrenLoad(path: "src")
        #expect(!childLoadStartedAgain)
        let revision = workspace.fileTreeRevision
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: "src", nodes: [file("src/main.swift")], truncated: false))

        guard case .loaded(let nodes) = workspace.fileTree else {
            Issue.record("expected a loaded tree")
            return
        }
        #expect(nodes.first?.children?.map(\.path) == ["src/main.swift"])
        #expect(nodes.first?.childrenState == .loaded)
        #expect(workspace.fileTreeRevision != revision)
        #expect(!workspace.shouldLoadChildren(path: "src", childrenState: .loaded))
    }

    @Test func offlineFailsPendingLoadsButKeepsLoadedContent() {
        var workspace = NativePeerWorkspace()
        _ = workspace.beginRootLoad()
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        workspace.beginChangesLoad()
        workspace.beginDocument(.file(path: "README.md"))
        _ = workspace.beginChildrenLoad(path: "src")

        workspace.markUnavailable()

        #expect(workspace.changes == .failed(NativePeerWorkspace.offlineMessage))
        #expect(workspace.documentContent == .failed(NativePeerWorkspace.offlineMessage))
        guard case .loaded = workspace.fileTree else {
            Issue.record("loaded tree should survive")
            return
        }
        // The pending child load is released so a later reconnect can retry it.
        let retried = workspace.beginChildrenLoad(path: "src")
        #expect(retried)
    }

    @Test func childDirectoryLoadShowsLoadingAndFailsVisiblyWhenPeerGoesOffline() {
        var workspace = NativePeerWorkspace()
        _ = workspace.beginRootLoad()
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))

        _ = workspace.beginChildrenLoad(path: "src")
        guard case .loaded(let loadingTree) = workspace.fileTree,
              let loadingNode = RightPaneState.fileTreeNode(at: "src", in: loadingTree) else {
            Issue.record("expected the src node to still be present while loading")
            return
        }
        #expect(loadingNode.childrenState == .loading)

        workspace.markUnavailable()
        guard case .loaded(let failedTree) = workspace.fileTree,
              let failedNode = RightPaneState.fileTreeNode(at: "src", in: failedTree) else {
            Issue.record("expected the src node to still be present after going offline")
            return
        }
        #expect(failedNode.childrenState == .failed)
    }

    @Test func rootRefreshIgnoresAStaleChildReplyThatArrivesBeforeTheRoot() {
        var workspace = NativePeerWorkspace()
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        _ = workspace.beginChildrenLoad(path: "src")

        _ = workspace.beginRootLoad()
        _ = workspace.apply(.fileTree(
            sessionId: "B:s", path: "src", nodes: [file("src/stale.swift")], truncated: false))

        guard case .loaded(let beforeRoot) = workspace.fileTree else {
            Issue.record("expected the previous tree while the root refresh is pending")
            return
        }
        #expect(RightPaneState.fileTreeNode(at: "src/stale.swift", in: beforeRoot) == nil)

        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        #expect(workspace.shouldLoadChildren(path: "src", childrenState: .notLoaded))
    }

    @Test func rootRefreshIgnoresAStaleChildReplyThatArrivesAfterTheRoot() {
        var workspace = NativePeerWorkspace()
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        _ = workspace.beginChildrenLoad(path: "src")

        _ = workspace.beginRootLoad()
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        #expect(!workspace.shouldLoadChildren(path: "src", childrenState: .notLoaded))

        _ = workspace.apply(.fileTree(
            sessionId: "B:s", path: "src", nodes: [file("src/stale.swift")], truncated: false))

        guard case .loaded(let refreshedTree) = workspace.fileTree else {
            Issue.record("expected the refreshed tree")
            return
        }
        #expect(RightPaneState.fileTreeNode(at: "src/stale.swift", in: refreshedTree) == nil)
        #expect(workspace.shouldLoadChildren(path: "src", childrenState: .notLoaded))
    }

    @Test func rootFileTreeTruncationIsPreservedAndClearedOnAFullListing() {
        var workspace = NativePeerWorkspace()
        #expect(!workspace.fileTreeTruncated)

        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: true))
        #expect(workspace.fileTreeTruncated)

        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        #expect(!workspace.fileTreeTruncated)
    }

    @Test func childFileTreeTruncationIsTrackedPerDirectory() {
        var workspace = NativePeerWorkspace()
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        #expect(!workspace.fileTreeTruncated)

        _ = workspace.apply(.fileTree(sessionId: "B:s", path: "src", nodes: [file("src/main.swift")], truncated: true))
        #expect(workspace.fileTreeTruncated)

        _ = workspace.apply(.fileTree(sessionId: "B:s", path: "src", nodes: [file("src/main.swift")], truncated: false))
        #expect(!workspace.fileTreeTruncated)
    }

    enum Kind: Sendable, CaseIterable { case localChanges, commit, commitRange, branch, reviewRequest }

    /// A comment the host files, an agent's or a Mac's, lands on the file and
    /// changed line the Mac builds through the peer loader: the same stage
    /// when one path is both staged and unstaged, and the host's provider
    /// diff for a pull request. `@MainActor`: the host's
    /// `AlasCoreContext` is main-actor isolated.
    @MainActor
    @Test(arguments: Kind.allCases)
    func hostFiledCommentsLandOnTheFileThePeerLoaderBuilds(_ kind: Kind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-peer-review-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: String...) async throws {
            let result = try await Process.git(args, cwd: repo)
            #expect(result.exitCode == 0, "git \(args.joined(separator: " ")): \(result.stderr)")
        }
        func write(_ text: String) throws {
            try text.write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        }
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.email", "test@example.com")
        try await git("config", "user.name", "Test")
        try write("one\ntwo\n")
        try await git("add", "a.txt")
        try await git("commit", "-q", "-m", "base")
        let worktree = Worktree(
            id: Worktree.makeId(path: repo), projectId: "p", name: "main", branch: "main",
            path: repo, status: .clean, lastActivity: .distantPast
        )
        let projects = ProjectsManager(persistedProjects: [
            ProjectConfig(id: "p", name: "p", path: repo.path, color: "blue", addedAt: .distantPast),
        ])
        projects.insertOptimisticWorktree(worktree)
        let core = AlasCoreContext(
            projects: projects,
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
            environment: HeadlessHostEnvironment(),
            reviewDrafts: ReviewDraftCommentStore(url: root.appendingPathComponent("review-drafts.json")),
            reviewSessions: ReviewSessionStore(url: root.appendingPathComponent("review-sessions.json"))
        )
        let reviews = AlasHost(core: core).reviews

        let sessionID: String
        switch kind {
        case .localChanges:
            try write("ONE\ntwo\n")
            try await git("add", "a.txt")
            try write("ONE\nTWO\n")
            // The review is not listed before its first comment, so the Mac
            // files that on the full local-changes review.
            sessionID = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: repo, scope: .all).rawValue
            try await reviews.mutate(.add(
                fileID: DiffReviewFileID(namespace: "staged", path: "a.txt"), path: "a.txt", originalPath: nil,
                anchor: .line(side: .new, startLine: 1, endLine: nil, selectedText: nil), body: "Mac"
            ), sessionID: sessionID, in: worktree, caller: .app)
            // The agent's default stage for a path in both is unstaged.
            _ = await reviews.addComment(
                origin: worktree, path: "a.txt", startLine: 2, endLine: nil, side: nil,
                body: "Agent", sessionID: nil, projectWorktrees: [worktree]
            )
        case .reviewRequest:
            try write("ONE\ntwo\n")
            try await git("commit", "-q", "-am", "edit")
            try await git("remote", "add", "origin", "https://github.com/acme/app.git")
            let diff = try await Process.git(["diff", "HEAD~1", "HEAD"], cwd: repo).stdout
            core.codeHostProviders = CodeHostProviderRegistry(providers: [.github: ReviewSessionLoaderTests.FakeReviewRequestProvider(diff: diff)])
            sessionID = try await reviews.openProviderReview(number: 7, in: worktree, caller: .app).summary.sessionID
            _ = await reviews.addComment(
                origin: worktree, path: "a.txt", startLine: 1, endLine: nil, side: nil,
                body: "Agent", sessionID: sessionID, projectWorktrees: [worktree]
            )
        case .commit, .commitRange, .branch:
            let base = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try write("ONE\ntwo\n")
            try await git("commit", "-q", "-am", "edit")
            let spec = switch kind {
            case .commitRange: "\(base)..HEAD"
            case .branch: "\(base)...HEAD"
            default: "HEAD"
            }
            guard case .success(let opened) = await reviews.open(spec, in: worktree, caller: .app) else {
                Issue.record("expected the \(kind) review opened")
                return
            }
            sessionID = opened.record.target.draftSessionID.rawValue
            _ = await reviews.addComment(
                origin: worktree, path: "a.txt", startLine: 1, endLine: nil, side: nil,
                body: "Agent", sessionID: sessionID, projectWorktrees: [worktree]
            )
        }
        let review = try reviews.read(sessionID, in: worktree)
        #expect(review.comments.count == (kind == .localChanges ? 2 : 1))

        let client = NativePeerReviewGitClient(read: { await core.remoteRead($0, in: worktree, replyingAs: worktree.id) })
        let providerReview: HostProviderReview? = if kind == .reviewRequest {
            try await reviews.providerReview(sessionID, in: worktree, withDiff: true)
        } else {
            nil
        }
        let session = try await ReviewSessionLoader.peer(git: client, providerReview: providerReview)
            .load(target: review.summary.record.target).session

        for comment in review.comments {
            let file = try #require(session.files.first { $0.summary.id == comment.fileID })
            let diff = try #require(file.parsedDiff)
            #expect(diff.hunks.flatMap(\.lines).contains { $0.kind == .add && $0.newNumber == comment.startLine })
        }
    }

    /// A file list or a diff the host cut off is noted, so the review does
    /// not pass for whole.
    @MainActor
    @Test(arguments: [true, false])
    func aTruncatedHostReplyIsReported(listTruncated: Bool) async throws {
        let file = changed("a.txt")
        let client = NativePeerReviewGitClient(read: { read -> RemoteServerMessage? in
            if case .changes = read {
                return .changeList(sessionId: "s", comparisonRef: nil, metricsAvailable: true, files: [],
                                   staged: [], unstaged: [file], commits: [], truncated: listTruncated)
            }
            return .fileDiffResult(sessionId: "s", path: "a.txt", stage: "unstaged", hunks: [], truncated: !listTruncated)
        })

        let session = try await ReviewChangesLoader(git: client).load(worktreePath: URL(fileURLWithPath: "/repo"))

        #expect(session.files.map(\.summary.path) == ["a.txt"])
        #expect(client.notes.truncated)
    }

    /// A host that stops answering fails the review instead of passing it
    /// off as empty; a diff it refuses stays one empty file.
    @MainActor
    @Test(arguments: [true, false])
    func aDiffWithNoReplyFailsTheReview(refused: Bool) async throws {
        let file = changed("a.txt")
        let client = NativePeerReviewGitClient(read: { read -> RemoteServerMessage? in
            if case .changes = read {
                return .changeList(sessionId: "s", comparisonRef: nil, metricsAvailable: true, files: [],
                                   staged: [], unstaged: [file], commits: [], truncated: false)
            }
            return refused ? .fileDiffFailed(sessionId: "s", path: "a.txt", reason: .binary, message: nil) : nil
        })

        let load = { try await ReviewChangesLoader(git: client).load(worktreePath: URL(fileURLWithPath: "/repo")) }

        if refused {
            #expect(try await load().files.map(\.summary.path) == ["a.txt"])
        } else {
            await #expect(throws: NativePeerReviewGitClientError.self) { try await load() }
        }
    }
}
