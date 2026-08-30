import Foundation
import Testing
@testable import Alas

@Suite("Workspace Work Items")
struct WorkspaceWorkItemTests {
    @Test func manualAndProviderSnapshotsPersistWithHostingMemberMetadata() async throws {
        let store = WorkspaceStore(url: temporaryURL())
        let checkout = Self.checkout()
        try await store.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        let controller = WorkspaceWorkItemController(store: store)

        let manual = Self.issue(
            stableID: "manual-1",
            title: "Manual rollout",
            origin: .manual,
            locator: nil,
            refreshable: false
        )
        let provider = Self.issue(
            stableID: "github.com/acme/app#1091",
            title: "Persistent workspaces",
            origin: .provider,
            locator: .init(provider: .github, host: "github.com", repositorySlug: "acme/app"),
            refreshable: true
        )

        try await controller.attach(manual, to: checkout.id, hostingMemberID: nil)
        try await controller.attach(provider, to: checkout.id, hostingMemberID: checkout.members[0].id)

        let reloaded = try #require(await store.checkout(id: checkout.id))
        #expect(reloaded.workItems.map(\.snapshot.title) == ["Manual rollout", "Persistent workspaces"])
        #expect(reloaded.workItems[0].contentOrigin == .manual)
        #expect(reloaded.workItems[1].hostingMemberID == checkout.members[0].id)
    }

    @Test func refreshFailureKeepsLastGoodSnapshotAndRecordsError() async throws {
        let store = WorkspaceStore(url: temporaryURL())
        var checkout = Self.checkout()
        let original = Self.issue(stableID: "github.com/acme/app#1091", title: "Original", origin: .provider, locator: .init(provider: .github, host: "github.com", repositorySlug: "acme/app"), refreshable: true)
        let workItem = WorkItemSnapshot(snapshot: original, hostingMemberID: checkout.members[0].id)
        checkout.workItems = [workItem]
        try await store.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        let controller = WorkspaceWorkItemController(
            store: store,
            refresher: FailingWorkItemRefresher()
        )

        try await controller.refresh(workItem.id, in: checkout.id)

        let refreshed = try #require(await store.checkout(id: checkout.id)?.workItems.first)
        #expect(refreshed.snapshot.title == "Original")
        #expect(refreshed.snapshot.refreshError == "Provider unavailable")
        #expect(refreshed.lastGoodSnapshot.title == "Original")
    }

    @Test func replaceEditAndDetachAreExplicitAtomicMutations() async throws {
        let store = WorkspaceStore(url: temporaryURL())
        var checkout = Self.checkout()
        let first = WorkItemSnapshot(snapshot: Self.issue(stableID: "manual-1", title: "One", origin: .manual, locator: nil, refreshable: false), hostingMemberID: nil)
        checkout.workItems = [first]
        try await store.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        let controller = WorkspaceWorkItemController(store: store)

        let replacement = Self.issue(stableID: "manual-2", title: "Two", origin: .manual, locator: nil, refreshable: false)
        try await controller.replace(first.id, in: checkout.id, with: replacement, hostingMemberID: checkout.members[1].id)
        try await controller.edit(first.id, in: checkout.id, title: "Edited", body: "Updated body")
        try await controller.detach(first.id, from: checkout.id)

        let reloaded = try #require(await store.checkout(id: checkout.id))
        #expect(reloaded.workItems.isEmpty)
    }

    @Test func exactRepositoryHostingMatchAndAmbiguousChoice() {
        let members = [
            Self.member(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, projectID: "app", root: "/repos/app"),
            Self.member(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, projectID: "api", root: "/repos/api"),
        ]
        let projects = [
            ProjectConfig(id: "app", name: "App", path: "/repos/app", color: "#fff", addedAt: .distantPast),
            ProjectConfig(id: "api", name: "API", path: "/repos/api", color: "#fff", addedAt: .distantPast),
        ]
        let issue = Self.issue(stableID: "github.com/acme/app#1091", title: "Issue", origin: .provider, locator: .init(provider: .github, host: "github.com", repositorySlug: "acme/app"), refreshable: true)

        let single = WorkspaceWorkItemController.hostingCandidates(for: issue, members: members, projects: projects, remotes: ["app": ["git@github.com:acme/app.git"], "api": ["git@github.com:acme/api.git"]])
        #expect(single == [.exact(members[0].id)])

        let ambiguous = WorkspaceWorkItemController.hostingCandidates(for: issue, members: members, projects: projects, remotes: ["app": ["git@github.com:acme/app.git"], "api": ["https://github.com/acme/app.git"]])
        #expect(ambiguous == [.ambiguous([members[0].id, members[1].id])])

        let unavailable = WorkspaceWorkItemController.hostingCandidates(for: issue, members: members, projects: projects, remotes: ["app": ["git@github.com:other/app.git"]])
        #expect(unavailable == [.unavailable])
    }

    private static func checkout() -> WorkspaceCheckout {
        WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .local, branch: "release/1091", rootPath: "/checkouts/release", members: [
            member(projectID: "app", root: "/repos/app"),
            member(projectID: "api", root: "/repos/api"),
        ])
    }

    private static func member(id: UUID = UUID(), projectID: String, root: String) -> WorkspaceCheckoutMember {
        WorkspaceCheckoutMember(
            id: id,
            workspaceMemberID: UUID(),
            projectID: projectID,
            fallbackProjectName: projectID.uppercased(),
            fallbackRepositoryRoot: root,
            worktreePath: "/checkouts/release/\(projectID)",
            availability: .available,
            checkpoint: .setupComplete
        )
    }

    private static func issue(stableID: String, title: String, origin: IssueContentOrigin, locator: IssueRepositoryLocator?, refreshable: Bool) -> IssueSnapshot {
        IssueSnapshot(
            identity: .init(providerID: origin == .manual ? .manual : .github, stableID: stableID),
            canonicalURL: URL(string: "https://example.com/\(stableID)")!,
            providerLabel: origin == .manual ? "Manual" : "GitHub",
            displayReference: "#1091",
            repositoryLocator: locator,
            title: title,
            body: "Body",
            state: .open,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: Date(timeIntervalSince1970: 1),
            refreshError: nil,
            contentOrigin: origin,
            isEditable: origin == .manual,
            isRefreshable: refreshable
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("workspaces.json")
    }
}

private struct FailingWorkItemRefresher: WorkspaceWorkItemRefreshing {
    func refresh(_ snapshot: IssueSnapshot, hostingMemberID: UUID?) async throws -> IssueSnapshot {
        throw WorkspaceWorkItemError.refreshFailed("Provider unavailable")
    }
}
