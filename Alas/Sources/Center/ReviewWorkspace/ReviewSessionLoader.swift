import Foundation

struct ReviewSessionLoadedContext {
    let session: DiffReviewLoadedSession
    let feedbackTarget: ReviewFeedbackTarget
}

struct ReviewSessionLoader {
    var localChanges: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var draftCommit: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var commit: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var commitRange: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var branch: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var reviewRequest: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession
    var draftReviewRequest: (ReviewSessionTarget) async throws -> DiffReviewLoadedSession

    init(
        localChanges: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        draftCommit: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commit: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        commitRange: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        branch: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
        reviewRequest: @escaping (ReviewSessionTarget) async throws -> DiffReviewLoadedSession = { _ in throw ReviewSessionLoaderError.unsupportedTarget },
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
    static func production(appState: AppState, worktree: Worktree) -> ReviewSessionLoader {
        _ = appState
        let changesLoader = ReviewChangesLoader()

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
            }
        )
    }

    func load(target: ReviewSessionTarget) async throws -> ReviewSessionLoadedContext {
        try Task.checkCancellation()

        let session: DiffReviewLoadedSession
        switch target.kind {
        case .localChanges:
            session = try await localChanges(target)
        case .draftCommit:
            session = try await draftCommit(target)
        case .commit:
            session = try await commit(target)
        case .commitRange:
            session = try await commitRange(target)
        case .branch:
            session = try await branch(target)
        case .reviewRequest:
            session = try await reviewRequest(target)
        case .draftReviewRequest:
            session = try await draftReviewRequest(target)
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
            )
        )
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
