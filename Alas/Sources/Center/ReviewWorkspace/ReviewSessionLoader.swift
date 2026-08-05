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
}

enum ReviewSessionLauncher {
    @MainActor
    @discardableResult
    static func openOrFocus(
        target: ReviewSessionTarget,
        now: () -> Date = Date.init,
        findActive: (ReviewSessionID) throws -> ReviewSessionRecord?,
        save: (ReviewSessionRecord) throws -> Void,
        open: (ReviewSessionRecord) -> Void,
        onFailure: ((any Error) -> Void)? = nil
    ) -> Bool {
        do {
            if let record = try findActive(target.id) {
                open(record)
                return true
            }

            let createdAt = now()
            let record = ReviewSessionRecord(
                id: target.id,
                target: target,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            try save(record)
            open(record)
            return true
        } catch {
            onFailure?(error)
            return false
        }
    }
}

struct ReviewSessionLoader {
    var localChanges: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var draftCommit: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var commit: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var commitRange: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var branch: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var reviewRequest: (ReviewSessionTarget) async throws -> ReviewSessionProviderLoadedSession
    var draftReviewRequest: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession

    init(
        localChanges: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        draftCommit: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commit: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commitRange: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        branch: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        reviewRequest: @escaping (ReviewSessionTarget) async throws -> ReviewSessionProviderLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        draftReviewRequest: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget }
    ) {
        self.localChanges = localChanges
        self.draftCommit = draftCommit
        self.commit = commit
        self.commitRange = commitRange
        self.branch = branch
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
            localChanges: { target in
                let session = try await changesLoader.load(worktreePath: worktree.path)
                guard case .localChanges(let scope) = target.payload else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                return filterLocalChanges(session, scope: scope)
            },
            draftCommit: { _ in
                let session = try await changesLoader.load(worktreePath: worktree.path)
                return filterLocalChanges(session, scope: .staged)
            },
            commit: { target in
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
                    }
                )
            },
            commitRange: { target in
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
                    }
                )
            },
            branch: { target in
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
                    }
                )
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

    func load(target: ReviewSessionTarget) async throws -> ReviewSessionLoadedContext {
        try Task.checkCancellation()

        let session: DiffReviewLoadedSession
        let providerContext: ReviewSessionProviderContext?
        switch target.kind {
        case .localChanges:
            session = try await localChanges(target)
            providerContext = nil
        case .draftCommit:
            session = try await draftCommit(target)
            providerContext = nil
        case .commit:
            session = try await commit(target)
            providerContext = nil
        case .trackedCommit:
            session = try await commit(target)
            providerContext = nil
        case .commitRange:
            session = try await commitRange(target)
            providerContext = nil
        case .branch:
            session = try await branch(target)
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
            feedbackTarget: ReviewFeedbackTarget(
                title: target.title,
                repositoryPath: target.repositoryPath.path,
                providerDescription: target.providerDescription,
                sourceDescription: target.sourceDescription,
                sessionDescription: "Review session: \(target.title)",
                revisionDescription: target.revisionDescription,
                priorHandoffDescription: nil
            ),
            providerContext: providerContext
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
