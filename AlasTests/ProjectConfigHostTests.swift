import Foundation
import Testing
@testable import Alas

struct ProjectConfigHostTests {
    private func makeProject(host: String? = nil) -> ProjectConfig {
        ProjectConfig(
            id: "test-id", name: "Repo", path: "/srv/repo", color: "blue",
            addedAt: Date(timeIntervalSince1970: 0), host: host
        )
    }

    @Test func legacyJSONDecodesWithNilHost() throws {
        let data = try JSONEncoder().encode(makeProject())
        #expect(try JSONDecoder().decode(ProjectConfig.self, from: data).host == nil)
    }

    @Test func nilHostIsOmittedFromEncoding() throws {
        let data = try JSONEncoder().encode(makeProject())
        #expect(!(try #require(String(data: data, encoding: .utf8))).contains("\"host\""))
    }

    @Test func hostRoundTrips() throws {
        let data = try JSONEncoder().encode(makeProject(host: "devbox"))
        #expect(try JSONDecoder().decode(ProjectConfig.self, from: data).host == "devbox")
    }
}
