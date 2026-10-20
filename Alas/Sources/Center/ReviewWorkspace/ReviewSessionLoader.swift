import Foundation

struct ReviewSessionProviderContext: Equatable, Sendable {
    let remote: CodeHostRemote
    let reviewRequest: ReviewRequest
}

struct ReviewSessionProviderLoadedSession {
    let loadedSession: DiffReviewLoadedSession
    let providerContext: ReviewSessionProviderContext
}

struct ReviewSessionLoadedContext {
    let session: DiffReviewLoadedSession
    let feedbackTarget: ReviewFeedbackTarget
    let providerContext: ReviewSessionProviderContext?
    /// The working tree this diff showed, as a git tree, when its right-hand
    /// side is the whole working tree. Sending feedback on it advances the
    /// worktree's "since last review" baseline; nil leaves the baseline alone.
    var reviewedWorkingTree: String? = nil

    func replacingFeedbackTarget(for target: ReviewSessionTarget) -> ReviewSessionLoadedContext {
        ReviewSessionLoadedContext(
            session: session,
            feedbackTarget: ReviewSessionLoadedContext.feedbackTarget(for: target),
            providerContext: providerContext,
            reviewedWorkingTree: reviewedWorkingTree
        )
    }

    static func feedbackTarget(for target: ReviewSessionTarget) -> ReviewFeedbackTarget {
        ReviewFeedbackTarget(
            title: target.title,
            repositoryPath: target.repositoryPath.path,
            providerDescription: target.providerDescription,
            sourceDescription: target.sourceDescription,
            sessionDescription: "Review session: \(target.title)",
            revisionDescription: target.revisionDescription,
            priorHandoffDescription: nil,
            reopenAction: .reviewSession(target)
        )
    }
}

/// Receives a review's files as pending sections while their diffs load.
typealias ReviewSessionFileListHandler = @MainActor (DiffReviewLoadedSession) -> Void

/// `@unchecked Sendable` is sound because these closures are nonisolated by
/// type but built (in `.production`) from a `@MainActor` context; any
/// actor-isolated state they capture (e.g. `AppState`) is only ever touched
/// by hopping back to that actor (`Task { @MainActor in ... }` or an
/// explicitly `@MainActor`-typed callback), so no capture is mutated
/// concurrently. This lets `load(target:)` stay nonisolated (callable from
/// anywhere) while still being safe to hold on a `@MainActor` view.
struct ReviewSessionLoader: @unchecked Sendable {
    var localChanges: (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession
    var draftCommit: (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession
    var commit: (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession
    var commitRange: (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession
    var branch: (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession
    /// Diffs from a fixed left side to `current`, the working tree snapshot:
    /// `.branchWithLocalChanges` and `.sinceSnapshot` targets.
    var workingTreeRange: (_ target: ReviewSessionTarget, _ current: String, _ onFileList: ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession
    /// Writes the working tree as a git tree object.
    var snapshotWorkingTree: (URL) async throws -> String
    /// The snapshot a full local-changes review shows, nil when it hides
    /// conflicted files the snapshot would include.
    var snapshotLocalChanges: (URL) async throws -> String?
    var reviewRequest: (ReviewSessionTarget) async throws -> ReviewSessionProviderLoadedSession
    var draftReviewRequest: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession

    init(
        localChanges: @escaping (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession = { _, _ in throw ReviewSessionLoaderError.unsupportedTarget },
        draftCommit: @escaping (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession = { _, _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commit: @escaping (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession = { _, _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commitRange: @escaping (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession = { _, _ in throw ReviewSessionLoaderError.unsupportedTarget },
        branch: @escaping (ReviewSessionTarget, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession = { _, _ in throw ReviewSessionLoaderError.unsupportedTarget },
        workingTreeRange: @escaping (ReviewSessionTarget, String, ReviewSessionFileListHandler?) async throws -> DiffReviewLoadedSession = { _, _, _ in throw ReviewSessionLoaderError.unsupportedTarget },
        snapshotWorkingTree: @escaping (URL) async throws -> String = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        snapshotLocalChanges: @escaping (URL) async throws -> String? = { _ in nil },
        reviewRequest: @escaping (ReviewSessionTarget) async throws -> ReviewSessionProviderLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        draftReviewRequest: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget }
    ) {
        self.localChanges = localChanges
        self.draftCommit = draftCommit
        self.commit = commit
        self.commitRange = commitRange
        self.branch = branch
        self.workingTreeRange = workingTreeRange
        self.snapshotWorkingTree = snapshotWorkingTree
        self.snapshotLocalChanges = snapshotLocalChanges
        self.reviewRequest = reviewRequest
        self.draftReviewRequest = draftReviewRequest
    }

    @MainActor
    static func production(
        appState: AppState,
        worktree: Worktree,
        providerRegistry: CodeHostProviderRegistry = .live()
    ) -> ReviewSessionLoader {
        let changesLoader = ReviewChangesLoader()
        let git = GitService()
        let commitLoader = CommitReviewLoader(git: git)
        let rangeLoader = RangeReviewLoader(git: git)

        return ReviewSessionLoader(
            localChanges: { target, onFileList in
                guard case .localChanges(let scope) = target.payload else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                let session = try await changesLoader.load(
                    worktreePath: worktree.path,
                    onFileList: filteringFileList(onFileList, scope: scope)
                )
                return filterLocalChanges(session, scope: scope)
            },
            draftCommit: { _, onFileList in
                let session = try await changesLoader.load(
                    worktreePath: worktree.path,
                    onFileList: filteringFileList(onFileList, scope: .staged)
                )
                return filterLocalChanges(session, scope: .staged)
            },
            commit: { target, onFileList in
                let sha: String
                switch target.payload {
                case .commit(let commitSHA):
                    sha = commitSHA
                case .trackedCommit(let revision):
                    sha = revision.resolvedSHA
                default:
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                let details = try await git.commitDetails(at: target.repositoryPath, sha: sha)
                return try await commitLoader.load(
                    worktreePath: target.repositoryPath,
                    sha: sha,
                    files: details.files,
                    openFileForPath: { path in
                        openFileAction(
                            appState: appState,
                            worktreeID: target.worktreeID,
                            worktreePath: target.repositoryPath,
                            relativePath: path
                        )
                    },
                    onFileList: onFileList
                )
            },
            commitRange: { target, onFileList in
                guard case .commitRange(let base, let head) = target.payload else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                let files = try await git.rangeChangedFiles(at: target.repositoryPath, base: base, head: head, threeDot: false)
                return try await rangeLoader.load(
                    worktreePath: target.repositoryPath,
                    base: base, head: head, threeDot: false,
                    files: files,
                    openFileForPath: { path in
                        openFileAction(appState: appState, worktreeID: target.worktreeID, worktreePath: target.repositoryPath, relativePath: path)
                    },
                    onFileList: onFileList
                )
            },
            branch: { target, onFileList in
                guard case .branch(let base, let head) = target.payload else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                let files = try await git.rangeChangedFiles(at: target.repositoryPath, base: base, head: head, threeDot: true)
                return try await rangeLoader.load(
                    worktreePath: target.repositoryPath,
                    base: base, head: head, threeDot: true,
                    files: files,
                    openFileForPath: { path in
                        openFileAction(appState: appState, worktreeID: target.worktreeID, worktreePath: target.repositoryPath, relativePath: path)
                    },
                    onFileList: onFileList
                )
            },
            workingTreeRange: { target, current, onFileList in
                // Both sides are trees: a plain `git diff <ref>` goes through
                // the index and misreads untracked files on the left as deleted.
                let left: String
                switch target.payload {
                case .branchWithLocalChanges(let base):
                    left = try await git.resolvedRangeTrees(
                        worktreePath: target.repositoryPath, base: base, head: "HEAD", threeDot: true
                    ).before
                case .sinceSnapshot(let tree):
                    left = tree
                default:
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                let files = try await git.rangeChangedFiles(at: target.repositoryPath, base: left, head: current, threeDot: false)
                return try await rangeLoader.load(
                    worktreePath: target.repositoryPath,
                    base: left, head: current, threeDot: false,
                    files: files,
                    openFileForPath: { path in
                        openFileAction(appState: appState, worktreeID: target.worktreeID, worktreePath: target.repositoryPath, relativePath: path)
                    },
                    onFileList: onFileList
                )
            },
            snapshotWorkingTree: { path in
                try await git.workingTreeSnapshot(worktreePath: path)
            },
            snapshotLocalChanges: { path in
                try await git.localChangesReviewSnapshot(worktreePath: path)
            },
            reviewRequest: { target in
                guard case .reviewRequest(let providerKind, let host, let repositorySlug, let number, _) = target.payload,
                      let provider = providerRegistry.provider(for: providerKind),
                      let separatorIndex = repositorySlug.lastIndex(of: "/")
                else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                let owner = String(repositorySlug[..<separatorIndex])
                let repository = String(repositorySlug[repositorySlug.index(after: separatorIndex)...])
                guard !owner.isEmpty, !repository.isEmpty else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                let remote = CodeHostRemote(
                    kind: providerKind,
                    host: host,
                    owner: owner,
                    repository: repository,
                    remoteName: "origin",
                    webURL: target.providerURL ?? URL(string: "https://\(host)/\(repositorySlug)")!
                )
                let request = try await provider.reviewRequest(remote: remote, number: number, cwd: target.repositoryPath)
                let loadedSession = try await ReviewRequestDiffLoader(provider: provider).load(
                    remote: remote,
                    request: request,
                    cwd: target.repositoryPath
                )
                return ReviewSessionProviderLoadedSession(
                    loadedSession: loadedSession,
                    providerContext: ReviewSessionProviderContext(remote: remote, reviewRequest: request)
                )
            },
            draftReviewRequest: { target in
                guard case .draftReviewRequest(_, _, let base, let head, let headSHA) = target.payload else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                try await validateCurrentHead(
                    worktreePath: target.repositoryPath,
                    expectedBranch: head,
                    expectedSHA: headSHA
                )
                let context = try await git.reviewRequestDraftContext(
                    worktreePath: target.repositoryPath,
                    baseRef: base
                )
                let resolvedHeadRef = headSHA.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
                let imageRevisions = try await git.resolvedRangeTrees(
                    worktreePath: target.repositoryPath,
                    base: base,
                    head: resolvedHeadRef,
                    threeDot: true
                )
                return try await DraftReviewRequestDiffSessionBuilder.build(
                    context: context,
                    worktreePath: target.repositoryPath,
                    openFileForPath: { path in
                        openFileAction(
                            appState: appState,
                            worktreeID: target.worktreeID,
                            worktreePath: target.repositoryPath,
                            relativePath: path
                        )
                    },
                    contextProviderForPath: { path, originalPath in
                        return DiffReviewContextProvider {
                            try await GitService().refContextSnapshot(
                                worktreePath: target.repositoryPath,
                                baseRef: base,
                                headRef: resolvedHeadRef,
                                file: path,
                                originalPath: originalPath
                            )
                        }
                    },
                    imageProviderForFile: { file in
                        git.rangeImageProvider(
                            worktreePath: target.repositoryPath,
                            revisions: imageRevisions,
                            file: file
                        )
                    }
                )
            }
        )
    }

    /// `onFileList` receives the target's files as pending sections once they
    /// are known and before their diffs finish loading. Hosted review requests
    /// list their files only with the diff, so they never report one.
    func load(
        target: ReviewSessionTarget,
        onFileList: ReviewSessionFileListHandler? = nil
    ) async throws -> ReviewSessionLoadedContext {
        try Task.checkCancellation()

        let session: DiffReviewLoadedSession
        let providerContext: ReviewSessionProviderContext?
        var reviewedWorkingTree: String?
        switch target.kind {
        case .localChanges:
            // Only the full local diff shows the whole working tree. Snapshot
            // before loading: an edit landing in between then shows in this
            // review and again in the next, rather than in neither.
            if case .localChanges(.all) = target.payload, !target.repositoryPath.isRemoteAlasPath {
                reviewedWorkingTree = (try? await snapshotLocalChanges(target.repositoryPath)) ?? nil
            }
            session = try await localChanges(target, onFileList)
            providerContext = nil
        case .draftCommit:
            session = try await draftCommit(target, onFileList)
            providerContext = nil
        case .commit:
            session = try await commit(target, onFileList)
            providerContext = nil
        case .trackedCommit:
            session = try await commit(target, onFileList)
            providerContext = nil
        case .commitRange:
            session = try await commitRange(target, onFileList)
            providerContext = nil
        case .branch:
            session = try await branch(target, onFileList)
            providerContext = nil
        case .branchWithLocalChanges, .sinceSnapshot:
            let current = try await snapshotWorkingTree(target.repositoryPath)
            session = try await workingTreeRange(target, current, onFileList)
            reviewedWorkingTree = current
            providerContext = nil
        case .reviewRequest:
            let loaded = try await reviewRequest(target)
            session = loaded.loadedSession
            providerContext = loaded.providerContext
        case .draftReviewRequest:
            session = try await draftReviewRequest(target)
            providerContext = nil
        }

        try Task.checkCancellation()

        return ReviewSessionLoadedContext(
            session: session,
            feedbackTarget: ReviewSessionLoadedContext.feedbackTarget(for: target),
            providerContext: providerContext,
            reviewedWorkingTree: reviewedWorkingTree
        )
    }

    private static func openFileAction(
        appState: AppState,
        worktreeID: String,
        worktreePath: URL,
        relativePath: String
    ) -> (() -> Void)? {
        guard DiffOpenFileAvailability.isAvailable(worktreePath: worktreePath, relativePath: relativePath) else {
            return nil
        }
        return {
            Task { @MainActor in
                appState.openFile(relativePath: relativePath, worktreeId: worktreeID)
            }
        }
    }

    private static func validateCurrentHead(
        worktreePath: URL,
        expectedBranch: String,
        expectedSHA: String?
    ) async throws {
        let branch = try await Process.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktreePath)
        guard branch.exitCode == 0 else { throw ReviewSessionLoaderError.unsupportedTarget }
        let currentBranch = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == expectedBranch || expectedBranch == "HEAD" else {
            throw ReviewSessionLoaderError.unsupportedTarget
        }

        guard let expectedSHA, !expectedSHA.isEmpty else { return }
        let head = try await Process.git(["rev-parse", "HEAD"], cwd: worktreePath)
        guard head.exitCode == 0 else { throw ReviewSessionLoaderError.unsupportedTarget }
        let currentSHA = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentSHA == expectedSHA || currentSHA.hasPrefix(expectedSHA) else {
            throw ReviewSessionLoaderError.unsupportedTarget
        }
    }

    private static func filteringFileList(
        _ handler: ReviewSessionFileListHandler?,
        scope: ReviewDraftLocalChangesScope
    ) -> ReviewSessionFileListHandler? {
        guard let handler else { return nil }
        return { handler(filterLocalChanges($0, scope: scope)) }
    }

    private static func filterLocalChanges(
        _ session: DiffReviewLoadedSession,
        scope: ReviewDraftLocalChangesScope
    ) -> DiffReviewLoadedSession {
        let files: [DiffReviewFileSectionModel]
        switch scope {
        case .all:
            files = session.files
        case .unstaged:
            files = session.files.filter { $0.summary.namespace == ReviewChangesSource.unstaged.rawValue }
        case .staged:
            files = session.files.filter { $0.summary.namespace == ReviewChangesSource.staged.rawValue }
        }
        return DiffReviewLoadedSession(
            files: files,
            summary: DiffReviewSessionModel(files: files.map(\.summary), groupsEnabled: true)
        )
    }
}

enum ReviewSessionLoaderError: Error, Equatable {
    case unsupportedTarget
}
