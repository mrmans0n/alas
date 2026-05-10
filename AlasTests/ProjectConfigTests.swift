import Testing
import Foundation
@testable import Alas

struct ProjectConfigTests {
    @Test func decodingOlderProjectsFileSuppliesEmptyHiddenPaths() throws {
        // Older projects.json files predate hiddenWorktreePaths.
        let json = """
        {
          "version": 1,
          "projects": [{
            "id": "abc",
            "name": "alpha",
            "path": "/tmp/alpha",
            "color": "#5fb7c4",
            "addedAt": 0
          }]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let file = try decoder.decode(ProjectsFile.self, from: json)
        #expect(file.projects.count == 1)
        #expect(file.projects[0].hiddenWorktreePaths == [])
    }

    @Test func roundTripPreservesHiddenPaths() throws {
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
            hiddenWorktreePaths: ["/tmp/alpha/wt-a", "/tmp/alpha/wt-b"]
        )
        let file = ProjectsFile(projects: [project])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].hiddenWorktreePaths == ["/tmp/alpha/wt-a", "/tmp/alpha/wt-b"])
    }
}
