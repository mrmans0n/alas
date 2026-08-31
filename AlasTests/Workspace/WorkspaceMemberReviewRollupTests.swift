import Foundation
import SwiftUI
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

    @MainActor
    @Test func sidebarDetailModelIncludesProductionReviewRollup() throws {
        let memberID = uuid(1)
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .local, branch: "shared-branch", rootPath: "/checkouts/release", members: [
            Self.member(id: memberID, projectID: "app", name: "App", worktreeID: "/checkouts/release/app"),
        ])
        let record = Self.record(id: "active-review", worktreeID: "/checkouts/release/app", status: .active, updatedAt: 1)
        let model = WorkspaceSidebarTree<EmptyView>.detailModel(
            for: checkout,
            rollupBuilder: MemberReviewRollupBuilder(
                reviews: InMemoryWorkspaceReviewSessionReader(records: [record]),
                gg: InMemoryWorkspaceGGStackReader(stacks: [:])
            )
        )

        #expect(model.reviewRollupRows.map(\.memberID) == [memberID])
        #expect(model.reviewRollupRows[0].reviewCount == 1)
        #expect(model.reviewRollupRows[0].reviewActions.map(\.reviewSessionID) == [record.id])
    }

    @Test func reviewActionHandlerOpensThePersistedMemberReviewTab() {
        let record = Self.record(id: "active-review", worktreeID: "/checkouts/release/app", status: .active, updatedAt: 1)
        var opened: [(String, ReviewSessionRecord)] = []
        let handler = WorkspaceReviewActionHandler(
            load: { id in id == record.id ? record : nil },
            open: { worktreeID, loaded in opened.append((worktreeID, loaded)) }
        )

        handler.open(WorkspaceReviewAction(
            memberID: uuid(1),
            worktreeID: "/checkouts/release/app",
            reviewSessionID: record.id,
            sharedCheckoutBranch: nil
        ))

        #expect(opened.map(\.0) == ["/checkouts/release/app"])
        #expect(opened.map(\.1.id) == [record.id])
    }

    @Test func qualifiesReviewAndGGReadersWithCheckoutLocationAndMemberProject() throws {
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .ssh("builder.example"), branch: "shared-branch", rootPath: "/srv/checkouts/release", members: [
            Self.member(id: uuid(1), projectID: "remote-project", name: "Remote", worktreeID: "/srv/checkouts/release/remote"),
        ])
        let record = Self.record(id: "remote-review", worktreeID: "/srv/checkouts/release/remote", status: .active, updatedAt: 1)
        let stack = GGStack(name: "remote-stack", base: "main", totalCommits: 1, syncedCommits: 1, currentPosition: 1, behindBase: 0, entries: [
            GGStackEntry(position: 1, sha: "aaa", title: "Remote", prNumber: nil, prState: nil, approved: false, ciStatus: nil),
        ])
        let reviews = QualifiedWorkspaceReviewSessionReader(record: record)
        let gg = QualifiedWorkspaceGGStackReader(stack: stack)

        let rollup = try MemberReviewRollupBuilder(reviews: reviews, gg: gg).build(for: checkout)

        #expect(rollup.members.first?.reviews.map(\.id.rawValue) == ["remote-review"])
        #expect(rollup.members.first?.ggStack?.name == "remote-stack")
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

private struct QualifiedWorkspaceReviewSessionReader: WorkspaceReviewSessionReading {
    var record: ReviewSessionRecord

    func list(worktreeID: String) throws -> [ReviewSessionRecord] {
        []
    }

    func list(
        worktreeID: String,
        projectID: String,
        executionLocation: ExecutionLocation,
        repositoryPath: String
    ) throws -> [ReviewSessionRecord] {
        guard worktreeID == "/srv/checkouts/release/remote",
              projectID == "remote-project",
              executionLocation == .ssh("builder.example"),
              repositoryPath == "/srv/checkouts/release/remote" else {
            return []
        }
        return [record]
    }
}

private struct QualifiedWorkspaceGGStackReader: WorkspaceGGStackReading {
    var stack: GGStack

    func stack(worktreeID: String) throws -> GGStack? {
        nil
    }

    func stack(worktreeID: String, projectID: String, executionLocation: ExecutionLocation, repositoryPath: String) throws -> GGStack? {
        guard worktreeID == "/srv/checkouts/release/remote",
              projectID == "remote-project",
              executionLocation == .ssh("builder.example"),
              repositoryPath == "/srv/checkouts/release/remote" else {
            return nil
        }
        return stack
    }
}
