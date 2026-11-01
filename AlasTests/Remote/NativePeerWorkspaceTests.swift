import Foundation
import Testing
@testable import Alas
@_spi(Testing) import AlasCore

private let planStash = HostStashRef(ref: "stash@{0}", sha: "abc")
private let planCheckpoint = CheckpointID()

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

    enum VersionStep: Sendable, CaseIterable { case reopenSameFile, openOtherFile, unversionedReply }

    /// The version an editor opens on outlives a reload of the same file, not a switch to
    /// another one or a reply the host would not save.
    @Test(arguments: VersionStep.allCases)
    func documentVersionLastsOnlyWhileTheSameFileReloadsWithOne(_ step: VersionStep) {
        let version = WorktreeFileVersion(contentHash: "h1", modified: .distantPast)
        var workspace = NativePeerWorkspace()
        workspace.beginDocument(.file(path: "a.swift"))
        _ = workspace.apply(.fileContents(sessionId: "B:s", path: "a.swift", text: "a", truncated: false, version: version))
        switch step {
        case .reopenSameFile: workspace.beginDocument(.file(path: "a.swift"))
        case .openOtherFile: workspace.beginDocument(.file(path: "b.swift"))
        case .unversionedReply: _ = workspace.apply(.fileContents(sessionId: "B:s", path: "a.swift", text: "b", truncated: false))
        }
        #expect(workspace.documentVersion == (step == .reopenSameFile ? version : nil))
    }

    /// A binary refusal, an image or known binary over the cap, and a known binary read as text show
    /// the placeholder card with their size; other text shows, and other refusals keep the note.
    /// `reason` nil is a text reply; `tooLarge` is the card's flag, nil for no card.
    @Test(arguments: [
        ("a.dat", RemoteFileAccessReason.binary as RemoteFileAccessReason?, false as Bool?),
        ("a.png", .tooLarge, true),
        ("a.pdf", .tooLarge, false),
        ("a.pdf", nil, false),
        ("a.log", .tooLarge, nil),
        ("a.png", .notFound, nil),
        ("a.txt", nil, nil),
    ])
    func fileReplyShowsTheBinaryCardWithItsSize(path: String, reason: RemoteFileAccessReason?, tooLarge: Bool?) {
        var workspace = NativePeerWorkspace()
        workspace.beginDocument(.file(path: path))
        let reply: RemoteServerMessage = if let refusal = reason {
            .fileUnavailable(sessionId: "B:s", path: path, reason: refusal, byteSize: 3, message: nil)
        } else {
            .fileContents(sessionId: "B:s", path: path, text: "abc", truncated: false)
        }
        _ = workspace.apply(reply)
        let expected: NativePeerWorkspace.Load<NativePeerWorkspace.DocumentContent> = if let flag = tooLarge {
            .loaded(.binary(byteSize: 3, tooLarge: flag))
        } else if let refusal = reason {
            .failed(NativePeerWorkspace.describe(refusal, message: nil))
        } else {
            .loaded(.text("abc", truncated: false))
        }
        #expect(workspace.documentContent == expected)
    }

    /// An image side the host refused says why: its own message first, else the reason, with the
    /// size of one too large to preview.
    @Test(arguments: [
        (RemoteFileAccessReason.tooLarge, 6_200_000 as Int?, nil as String?,
         "Too large to preview (\(NativePeerWorkspace.formattedByteSize(6_200_000)))."),
        (.tooLarge, nil, nil, "Too large to preview."),
        (.notFound, nil, nil, "The host doesn't have this revision of the file."),
        (.pathRejected, nil, "", "The host refused to read this file."),
        (.notFound, nil, "This stash changed since it was listed.\n", "This stash changed since it was listed."),
        (.gitFailed, nil, "\n  fatal: bad object\nhint: run fsck\n", "Git failed on the host: fatal: bad object"),
        (.gitFailed, nil, String(repeating: "x", count: 250), "Git failed on the host: \(String(repeating: "x", count: 200))…"),
        (.unknown, nil, nil, "The host couldn't read this image."),
    ])
    func refusedImageSideSaysWhy(reason: RemoteFileAccessReason, byteSize: Int?, message: String?, expected: String) {
        #expect(NativePeerWorkspace.imageFailure(reason, byteSize: byteSize, message: message) == expected)
    }

    typealias PlanSide = NativePeerWorkspace.ImageDiffPlan.Side

    /// An image diff reads the sides local's image diffs compare: index to working tree when
    /// unstaged, HEAD to index when staged, the comparison ref to the working tree for the branch,
    /// a commit's parent to itself, a stash's base to its saved or untracked file, a checkpoint's
    /// file to the working tree; the old path for a rename, and no side an add or delete lacks.
    @Test(arguments: [
        (NativePeerWorkspace.Document.diff(path: "a.png", stage: .unstaged), "M", nil as String?,
         PlanSide(path: "a.png", revision: .index) as PlanSide?, PlanSide(path: "a.png", revision: nil) as PlanSide?,
         ImageDiffPairKind.modified),
        (.diff(path: "a.png", stage: .staged), "M", nil, PlanSide(path: "a.png", revision: .head),
         PlanSide(path: "a.png", revision: .index), .modified),
        (.diff(path: "a.png", stage: nil), "M", nil, PlanSide(path: "a.png", revision: .base(comparisonMode: .manual)),
         PlanSide(path: "a.png", revision: nil), .modified),
        (.commitDiff(path: "a.png", sha: "abc"), "M", nil, PlanSide(path: "a.png", revision: .parent(sha: "abc")),
         PlanSide(path: "a.png", revision: .commit(sha: "abc")), .modified),
        (.commitDiff(path: "new.png", sha: "abc"), "R", "old.png", PlanSide(path: "old.png", revision: .parent(sha: "abc")),
         PlanSide(path: "new.png", revision: .commit(sha: "abc")), .renamed),
        (.diff(path: "a.png", stage: .staged), "A", nil, nil, PlanSide(path: "a.png", revision: .index), .added),
        (.diff(path: "a.png", stage: .unstaged), "D", nil, PlanSide(path: "a.png", revision: .index), nil, .deleted),
        (.stashDiff(file: GitStashFile(path: "a.png", status: "M", add: 0, del: 0), stash: planStash), "M", nil,
         PlanSide(path: "a.png", revision: .stashBase(planStash)),
         PlanSide(path: "a.png", revision: .stash(planStash, untracked: false)), .modified),
        (.stashDiff(file: GitStashFile(path: "a.png", status: "A", add: 0, del: 0, isUntracked: true), stash: planStash), "A", nil,
         nil, PlanSide(path: "a.png", revision: .stash(planStash, untracked: true)), .added),
        (.checkpointDiff(path: "a.png", checkpointID: planCheckpoint), "M", nil,
         PlanSide(path: "a.png", revision: .checkpoint(id: planCheckpoint)), PlanSide(path: "a.png", revision: nil),
         .modified),
    ])
    func imageDiffReadsTheSidesLocalCompares(
        document: NativePeerWorkspace.Document, status: String, renameFrom: String?,
        before: PlanSide?, after: PlanSide?, kind: ImageDiffPairKind
    ) {
        let plan = NativePeerWorkspace.imageDiffPlan(
            for: document, status: status, renameFrom: renameFrom, comparisonMode: .manual)
        #expect(plan == NativePeerWorkspace.ImageDiffPlan(
            before: before, after: after, kind: kind, oldPath: kind == .renamed ? renameFrom : nil))
    }

    /// A host offers hunk actions on its staged and unstaged diffs only:
    /// unstage on the staged one; stage, and discard unless the file is added,
    /// on the unstaged one. A deletion and a cut-off diff's last hunk are never offered.
    @Test(arguments: [
        (NativePeerWorkspace.Document.diff(path: "a", stage: .unstaged), 3, 3, 0, false, [HostHunkAction.stage, .discard]),
        (.diff(path: "a", stage: .unstaged), 0, 1, 0, false, [.stage]),
        (.diff(path: "a", stage: .unstaged), 1, 0, 0, false, []),
        (.diff(path: "a", stage: .staged), 1, 0, 0, false, []),
        (.diff(path: "a", stage: .staged), 3, 3, 0, false, [.unstage]),
        (.diff(path: "a", stage: .staged), 3, 3, 1, true, []),
        (.diff(path: "a", stage: .unstaged), 3, 3, 0, true, [.stage, .discard]),
        (.diff(path: "a", stage: nil), 3, 3, 0, false, []),
        (.commitDiff(path: "a", sha: "abc"), 3, 3, 0, false, []),
    ])
    func hunkActionsFitTheDiff(
        document: NativePeerWorkspace.Document, oldStart: Int, newStart: Int, index: Int, truncated: Bool,
        expected: [HostHunkAction]
    ) {
        let hunk = ParsedDiff.Hunk(header: "@@", oldStart: oldStart, newStart: newStart, lines: [])
        #expect(document.hunkActions(for: hunk, index: index, of: 2, truncated: truncated) == expected)
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
