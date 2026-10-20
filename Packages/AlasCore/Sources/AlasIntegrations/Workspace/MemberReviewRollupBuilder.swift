import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public protocol WorkspaceReviewSessionReading {
    func list(worktreeID: String) throws -> [ReviewSessionRecord]
    func list(
        worktreeID: String,
        projectID: String,
        executionLocation: ExecutionLocation,
        repositoryPath: String
    ) throws -> [ReviewSessionRecord]
}

public protocol WorkspaceGGStackReading {
    func stack(worktreeID: String) throws -> GGStack?
    func stack(worktreeID: String, projectID: String, executionLocation: ExecutionLocation, repositoryPath: String) throws -> GGStack?
}

extension ReviewSessionStore: WorkspaceReviewSessionReading {}

extension WorkspaceReviewSessionReading {
    public func list(
        worktreeID: String,
        projectID: String,
        executionLocation: ExecutionLocation,
        repositoryPath: String
    ) throws -> [ReviewSessionRecord] {
        let qualifiedWorktreeID = WorkspaceReviewSessionIdentity.worktreeID(
            projectID: projectID,
            executionLocation: executionLocation,
            repositoryPath: repositoryPath
        )
        let normalizedPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        let qualified = try list(worktreeID: qualifiedWorktreeID).filter {
            $0.target.repositoryPath.standardizedFileURL.path == normalizedPath
        }
        let legacy = try list(worktreeID: worktreeID).filter {
            $0.target.repositoryPath.standardizedFileURL.path == URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        }
        var seen: Set<ReviewSessionID> = []
        return (qualified + legacy).filter { record in
            seen.insert(record.id).inserted
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

extension WorkspaceGGStackReading {
    public func stack(worktreeID: String, projectID: String, executionLocation: ExecutionLocation, repositoryPath: String) throws -> GGStack? {
        try stack(worktreeID: worktreeID)
    }
}

public enum WorkspaceReviewSessionIdentity: Sendable {
    public static func worktreeID(projectID: String, executionLocation: ExecutionLocation, repositoryPath: String) -> String {
        let normalizedPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        switch executionLocation.normalized {
        case .local:
            return "workspace-review:local:\(projectID):\(normalizedPath)"
        case .ssh(let host):
            return "workspace-review:ssh:\(host):\(projectID):\(normalizedPath)"
        }
    }
}

public struct WorkspaceReviewAction: Equatable, Sendable {
    public var memberID: UUID
    public var worktreeID: String
    public var reviewSessionID: ReviewSessionID
    public var sharedCheckoutBranch: String?

    public init(memberID: UUID, worktreeID: String, reviewSessionID: ReviewSessionID, sharedCheckoutBranch: String? = nil) {
        self.memberID = memberID
        self.worktreeID = worktreeID
        self.reviewSessionID = reviewSessionID
        self.sharedCheckoutBranch = sharedCheckoutBranch
    }
}

public struct WorkspaceReviewActionHandler {
    public var load: (ReviewSessionID) throws -> ReviewSessionRecord?
    public var open: (String, ReviewSessionRecord) -> Void

    public init(
        load: @escaping (ReviewSessionID) throws -> ReviewSessionRecord? = { try ReviewSessionStore().load(id: $0) },
        open: @escaping (String, ReviewSessionRecord) -> Void
    ) {
        self.load = load
        self.open = open
    }

    public func open(_ action: WorkspaceReviewAction) {
        guard let record = try? load(action.reviewSessionID) else { return }
        open(action.worktreeID, record)
    }
}

public struct WorkspaceMemberReviewRollup: Equatable, Sendable {
    public struct Member: Equatable, Identifiable, Sendable {
        public var id: UUID { memberID }
        public var memberID: UUID
        public var projectID: String
        public var title: String
        public var availability: WorkspaceCheckoutMemberAvailability
        public var worktreeID: String
        public var reviews: [ReviewSessionRecord]
        public var ggStack: GGStack?
        public var unpublishedStackEntries: [GGStackEntry]
        public var reviewActions: [WorkspaceReviewAction]

        public init(memberID: UUID, projectID: String, title: String, availability: WorkspaceCheckoutMemberAvailability, worktreeID: String, reviews: [ReviewSessionRecord], ggStack: GGStack? = nil, unpublishedStackEntries: [GGStackEntry], reviewActions: [WorkspaceReviewAction]) {
            self.memberID = memberID
            self.projectID = projectID
            self.title = title
            self.availability = availability
            self.worktreeID = worktreeID
            self.reviews = reviews
            self.ggStack = ggStack
            self.unpublishedStackEntries = unpublishedStackEntries
            self.reviewActions = reviewActions
        }
    }

    public var members: [Member]
    public var completionState: String?

    public init(members: [Member], completionState: String? = nil) {
        self.members = members
        self.completionState = completionState
    }
}

public struct MemberReviewRollupBuilder {
    public var reviews: any WorkspaceReviewSessionReading
    public var gg: any WorkspaceGGStackReading

    public init(reviews: any WorkspaceReviewSessionReading = ReviewSessionStore(), gg: any WorkspaceGGStackReading = EmptyWorkspaceGGStackReader()) {
        self.reviews = reviews
        self.gg = gg
    }

    public func build(for checkout: WorkspaceCheckout) throws -> WorkspaceMemberReviewRollup {
        let members = try checkout.members.map { member in
            // Reviews, stacks, and tabs are keyed by the in-app (virtual for
            // ssh) worktree path, not the member's real host path.
            let worktreeID = checkout.inAppWorktreePath(member.worktreePath)
            let isAvailable = member.availability == .available
            let reviewRecords = isAvailable ? try reviews.list(
                worktreeID: worktreeID,
                projectID: member.projectID,
                executionLocation: checkout.executionLocation,
                repositoryPath: worktreeID
            ) : []
            let stack = isAvailable ? try gg.stack(
                worktreeID: worktreeID,
                projectID: member.projectID,
                executionLocation: checkout.executionLocation,
                repositoryPath: worktreeID
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

public struct WorkspaceCachedGGStackReader: WorkspaceGGStackReading, Sendable {
    public var stacksByWorktreeID: [String: GGStack]

    public func stack(worktreeID: String) throws -> GGStack? {
        stacksByWorktreeID[worktreeID]
    }

    public func stack(worktreeID: String, projectID: String, executionLocation: ExecutionLocation, repositoryPath: String) throws -> GGStack? {
        let qualifiedWorktreeID = WorkspaceReviewSessionIdentity.worktreeID(
            projectID: projectID,
            executionLocation: executionLocation,
            repositoryPath: repositoryPath
        )
        return stacksByWorktreeID[qualifiedWorktreeID]
    }

    public init(stacksByWorktreeID: [String: GGStack]) {
        self.stacksByWorktreeID = stacksByWorktreeID
    }
}

public struct EmptyWorkspaceGGStackReader: WorkspaceGGStackReading {
    public init() {}

    public func stack(worktreeID: String) throws -> GGStack? { nil }
}
