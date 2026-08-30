import Foundation
import Testing
@testable import Alas

@Suite("Workspace member review rollup")
struct WorkspaceMemberReviewRollupTests {
    @Test func buildsMemberOrderedReadOnlyProjection() throws {
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .local, branch: "release/1091", rootPath: "/checkouts/release", members: [
            Self.member(id: uuid(1), projectID: "app", name: "App", worktreeID: "/checkouts/release/app"),
            Self.member(id: uuid(2), projectID: "api", name: "API", worktreeID: "/checkouts/release/api"),
            Self.member(id: uuid(3), projectID: "web", name: "Web", worktreeID: "/checkouts/release/web", availability: .unavailable),
        ])
        let reviews = InMemoryWorkspaceReviewSessionReader(records: [
            Self.record(id: "api-review", worktreeID: "/checkouts/release/api", status: .active, updatedAt: 20),
            Self.record(id: "app-review", worktreeID: "/checkouts/release/app", status: .reviewed, updatedAt: 10),
        ])
        let gg = InMemoryWorkspaceGGStackReader(stacks: [
            "/checkouts/release/app": GGStack(name: "app-stack", base: "main", totalCommits: 2, syncedCommits: 1, currentPosition: 2, behindBase: 0, entries: [
                GGStackEntry(position: 1, sha: "aaa", title: "Base", prNumber: 10, prState: .merged, approved: true, ciStatus: .success),
                GGStackEntry(position: 2, sha: "bbb", title: "Feature", prNumber: nil, prState: nil, approved: false, ciStatus: nil, isCurrent: true),
            ])
        ])

        let rollup = try MemberReviewRollupBuilder(reviews: reviews, gg: gg).build(for: checkout)

        #expect(rollup.members.map(\.memberID) == [uuid(1), uuid(2), uuid(3)])
        #expect(rollup.members[0].reviews.map(\.id.rawValue) == ["app-review"])
        #expect(rollup.members[0].ggStack?.entries.map(\.sha) == ["aaa", "bbb"])
        #expect(rollup.members[0].unpublishedStackEntries.map(\.sha) == ["bbb"])
        #expect(rollup.members[1].reviews.map(\.id.rawValue) == ["api-review"])
        #expect(rollup.members[2].availability == .unavailable)
        #expect(rollup.completionState == nil)
        #expect(awaitingMutationCount(reviews, gg) == 0)
    }

    @Test func sessionContextRefreshKeepsReviewActionsExactMemberOwned() throws {
        let memberID = uuid(1)
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .local, branch: "shared-branch", rootPath: "/checkouts/release", members: [
            Self.member(id: memberID, projectID: "app", name: "App", worktreeID: "/checkouts/release/app"),
        ])
        let record = Self.record(id: "branch-review", worktreeID: "/checkouts/release/app", status: .active, updatedAt: 1)
        let rollup = try MemberReviewRollupBuilder(
            reviews: InMemoryWorkspaceReviewSessionReader(records: [record]),
            gg: InMemoryWorkspaceGGStackReader(stacks: [:])
        ).build(for: checkout)

        let action = try #require(rollup.members.first?.reviewActions.first)
        #expect(action.memberID == memberID)
        #expect(action.worktreeID == "/checkouts/release/app")
        #expect(action.reviewSessionID == record.id)
        #expect(action.sharedCheckoutBranch == nil)
    }

    private static func member(id: UUID, projectID: String, name: String, worktreeID: String, availability: WorkspaceCheckoutMemberAvailability = .available) -> WorkspaceCheckoutMember {
        WorkspaceCheckoutMember(id: id, workspaceMemberID: UUID(), projectID: projectID, fallbackProjectName: name, fallbackRepositoryRoot: "/repos/\(projectID)", worktreePath: worktreeID, availability: availability, checkpoint: .setupComplete)
    }

    private static func record(id: String, worktreeID: String, status: ReviewSessionStatus, updatedAt: TimeInterval) -> ReviewSessionRecord {
        let target = ReviewSessionTarget.branch(worktreeID: worktreeID, repositoryPath: URL(fileURLWithPath: worktreeID), base: "main", head: "feature", title: "Review \(id)")
        return ReviewSessionRecord(id: ReviewSessionID(rawValue: id), target: target, status: status, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: updatedAt))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", value))")!
    }

    private func awaitingMutationCount(_ reviews: InMemoryWorkspaceReviewSessionReader, _ gg: InMemoryWorkspaceGGStackReader) -> Int {
        reviews.mutationCount + gg.mutationCount
    }
}

private struct InMemoryWorkspaceReviewSessionReader: WorkspaceReviewSessionReading {
    var records: [ReviewSessionRecord]
    var mutationCount = 0

    func list(worktreeID: String) throws -> [ReviewSessionRecord] {
        records.filter { $0.target.worktreeID == worktreeID }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

private struct InMemoryWorkspaceGGStackReader: WorkspaceGGStackReading {
    var stacks: [String: GGStack]
    var mutationCount = 0

    func stack(worktreeID: String) throws -> GGStack? {
        stacks[worktreeID]
    }
}
