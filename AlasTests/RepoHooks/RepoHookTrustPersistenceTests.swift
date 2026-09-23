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
