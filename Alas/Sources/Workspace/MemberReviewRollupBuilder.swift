import Foundation

protocol WorkspaceReviewSessionReading {
    func list(worktreeID: String) throws -> [ReviewSessionRecord]
}

protocol WorkspaceGGStackReading {
    func stack(worktreeID: String) throws -> GGStack?
}

extension ReviewSessionStore: WorkspaceReviewSessionReading {}

struct WorkspaceReviewAction: Equatable {
    var memberID: UUID
    var worktreeID: String
    var reviewSessionID: ReviewSessionID
    var sharedCheckoutBranch: String?
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
            let reviewRecords = isAvailable ? try reviews.list(worktreeID: worktreeID) : []
            let stack = isAvailable ? try gg.stack(worktreeID: worktreeID) : nil
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
