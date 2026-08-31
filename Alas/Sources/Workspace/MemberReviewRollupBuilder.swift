import Foundation

protocol WorkspaceReviewSessionReading {
    func list(worktreeID: String) throws -> [ReviewSessionRecord]
    func list(
        worktreeID: String,
        projectID: String,
        executionLocation: ExecutionLocation,
        repositoryPath: String
    ) throws -> [ReviewSessionRecord]
}

protocol WorkspaceGGStackReading {
    func stack(worktreeID: String) throws -> GGStack?
    func stack(worktreeID: String, projectID: String, executionLocation: ExecutionLocation, repositoryPath: String) throws -> GGStack?
}

extension ReviewSessionStore: WorkspaceReviewSessionReading {}

extension WorkspaceReviewSessionReading {
    func list(
        worktreeID: String,
        projectID: String,
        executionLocation: ExecutionLocation,
        repositoryPath: String
    ) throws -> [ReviewSessionRecord] {
        try list(worktreeID: worktreeID).filter {
            $0.target.repositoryPath.standardizedFileURL.path == URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        }
    }
}

extension WorkspaceGGStackReading {
    func stack(worktreeID: String, projectID: String, executionLocation: ExecutionLocation, repositoryPath: String) throws -> GGStack? {
        try stack(worktreeID: worktreeID)
    }
}

struct WorkspaceReviewAction: Equatable {
    var memberID: UUID
    var worktreeID: String
    var reviewSessionID: ReviewSessionID
    var sharedCheckoutBranch: String?
}

struct WorkspaceReviewActionHandler {
    var load: (ReviewSessionID) throws -> ReviewSessionRecord?
    var open: (String, ReviewSessionRecord) -> Void

    init(
        load: @escaping (ReviewSessionID) throws -> ReviewSessionRecord? = { try ReviewSessionStore().load(id: $0) },
        open: @escaping (String, ReviewSessionRecord) -> Void
    ) {
        self.load = load
        self.open = open
    }

    func open(_ action: WorkspaceReviewAction) {
        guard let record = try? load(action.reviewSessionID) else { return }
        open(action.worktreeID, record)
    }
}

struct WorkspaceMemberReviewRollup: Equatable {
    struct Member: Equatable, Identifiable {
        var id: UUID { memberID }
        var memberID: UUID
        var projectID: String
        var title: String
        var availability: WorkspaceCheckoutMemberAvailability
        var worktreeID: String
        var reviews: [ReviewSessionRecord]
        var ggStack: GGStack?
        var unpublishedStackEntries: [GGStackEntry]
        var reviewActions: [WorkspaceReviewAction]
    }

    var members: [Member]
    var completionState: String?
}

struct MemberReviewRollupBuilder {
    var reviews: any WorkspaceReviewSessionReading
    var gg: any WorkspaceGGStackReading

    init(reviews: any WorkspaceReviewSessionReading = ReviewSessionStore(), gg: any WorkspaceGGStackReading = EmptyWorkspaceGGStackReader()) {
        self.reviews = reviews
        self.gg = gg
    }

    func build(for checkout: WorkspaceCheckout) throws -> WorkspaceMemberReviewRollup {
        let members = try checkout.members.map { member in
            let worktreeID = member.worktreePath
            let isAvailable = member.availability == .available
            let reviewRecords = isAvailable ? try reviews.list(
                worktreeID: worktreeID,
                projectID: member.projectID,
                executionLocation: checkout.executionLocation,
                repositoryPath: member.worktreePath
            ) : []
            let stack = isAvailable ? try gg.stack(
                worktreeID: worktreeID,
                projectID: member.projectID,
                executionLocation: checkout.executionLocation,
                repositoryPath: member.worktreePath
            ) : nil
            let unpublished = stack?.entries
                .sorted { $0.position < $1.position }
                .filter { $0.prNumber == nil } ?? []
            return WorkspaceMemberReviewRollup.Member(
                memberID: member.id,
                projectID: member.projectID,
                title: member.fallbackProjectName,
                availability: member.availability,
                worktreeID: worktreeID,
                reviews: reviewRecords,
                ggStack: stack,
                unpublishedStackEntries: unpublished,
                reviewActions: reviewRecords.map {
                    WorkspaceReviewAction(
                        memberID: member.id,
                        worktreeID: worktreeID,
                        reviewSessionID: $0.id,
                        sharedCheckoutBranch: nil
                    )
                }
            )
        }
        return WorkspaceMemberReviewRollup(members: members, completionState: nil)
    }
}

private struct EmptyWorkspaceGGStackReader: WorkspaceGGStackReading {
    func stack(worktreeID: String) throws -> GGStack? { nil }
}
