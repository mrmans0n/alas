import Foundation
import Testing
@testable import Alas

@MainActor
struct RepoHookTrustPersistenceTests {
    @Test func olderProjectFilesDecodeWithoutHookApprovals() throws {
        let json = """
        {
          "id": "project-1",
          "name": "Alpha",
          "path": "/tmp/alpha",
          "color": "#5fb7c4",
          "addedAt": 0
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let project = try decoder.decode(ProjectConfig.self, from: json)

        #expect(project.approvedRepoHookHashes.isEmpty)
    }

    @Test func approvalHashesEncodeSortedAndWithoutDuplicates() throws {
        let project = project(hashes: ["z", "a", "z"])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        #expect(decoded.approvedRepoHookHashes == ["a", "z"])
    }

    @Test func emptyApprovalHashesAreNotPersisted() throws {
        let data = try JSONEncoder().encode(project(hashes: []))
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains("approvedRepoHookHashes"))
    }

    @Test func managerApprovesEachHashOnceAndKeepsProjectsIsolated() {
        let manager = ProjectsManager(persistedProjects: [project(id: "one"), project(id: "two")])

        #expect(manager.approveRepoHook(projectId: "one", hash: "hash"))
        #expect(!manager.approveRepoHook(projectId: "one", hash: "hash"))
        #expect(manager.isRepoHookApproved(projectId: "one", hash: "hash"))
        #expect(!manager.isRepoHookApproved(projectId: "two", hash: "hash"))
        #expect(manager.revokeRepoHookApproval(projectId: "one", hash: "hash"))
        #expect(!manager.isRepoHookApproved(projectId: "one", hash: "hash"))
    }

    @Test func pendingApprovalsAreClearedWhenRepositoryTargetChanges() {
        let local = RepoHookApprovalTarget(
            projectID: "pending",
            path: URL(fileURLWithPath: "/tmp/alpha"),
            host: nil
        )
        let remote = RepoHookApprovalTarget(
            projectID: "pending",
            path: URL(fileURLWithPath: "/tmp/alpha"),
            host: "build-host"
        )
        let remoteWithoutHost = RepoHookApprovalTarget(
            projectID: "pending",
            path: URL(fileURLWithPath: "/tmp/alpha"),
            host: ""
        )
        let otherRepository = RepoHookApprovalTarget(
            projectID: "pending",
            path: URL(fileURLWithPath: "/tmp/beta"),
            host: "build-host"
        )
        var pending = PendingRepoHookApprovals()
        pending.select(local)
        pending.approve("hook-a", for: local)
        #expect(pending.contains("hook-a", for: local))

        pending.select(remoteWithoutHost)
        #expect(!pending.contains("hook-a", for: remoteWithoutHost))
        pending.approve("hook-empty-host", for: remoteWithoutHost)

        pending.select(remote)
        #expect(!pending.contains("hook-empty-host", for: remote))
        pending.approve("hook-b", for: remote)
        pending.select(otherRepository)

        #expect(pending.approvedHashes(for: otherRepository).isEmpty)
    }

    private func project(id: String = "project-1", hashes: [String] = []) -> ProjectConfig {
        ProjectConfig(
            id: id,
            name: "Alpha",
            path: "/tmp/alpha",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            approvedRepoHookHashes: hashes
        )
    }
}
