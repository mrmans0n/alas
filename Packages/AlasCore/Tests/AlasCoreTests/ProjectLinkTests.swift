import Foundation
import Testing
@_spi(Testing) import AlasCore

struct ProjectLinkTests {
    struct MatchCase: CustomTestStringConvertible, Sendable {
        let name: String
        let remote: String
        let locals: [(id: String, origin: String?)]
        let expected: String?
        var testDescription: String { name }
    }

    @Test(arguments: [
        MatchCase(
            name: "one clone",
            remote: "git@github.com:o/r.git",
            locals: [("a", "https://github.com/o/r"), ("b", "https://github.com/o/x")],
            expected: "a"
        ),
        MatchCase(
            name: "two clones",
            remote: "git@github.com:o/r.git",
            locals: [("a", "https://github.com/o/r"), ("b", "ssh://git@github.com/o/r.git")],
            expected: nil
        ),
        MatchCase(
            name: "remote without host",
            remote: "/srv/r.git",
            locals: [("a", "/srv/r.git")],
            expected: nil
        ),
        MatchCase(
            name: "local without origin",
            remote: "git@github.com:o/r.git",
            locals: [("a", nil), ("b", "https://github.com/o/r")],
            expected: "b"
        ),
    ])
    func matchFindsTheOneLocalClone(_ row: MatchCase) {
        #expect(ProjectLink.match(remoteOrigin: row.remote, locals: row.locals) == row.expected)
    }

    @Test func linkedProjectIdRoundTripsAndIsOmittedWhenNil() throws {
        var project = ProjectConfig(
            id: "r", name: "r", path: "/srv/r", color: "blue",
            addedAt: Date(timeIntervalSince1970: 0), host: "devbox"
        )
        let unlinked = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        #expect(unlinked?["linkedProjectId"] == nil)

        project.linkedProjectId = "local"
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(project))
        #expect(decoded.linkedProjectId == "local")
    }
}
