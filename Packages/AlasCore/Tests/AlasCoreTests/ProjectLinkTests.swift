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

    // MARK: - ProjectsManager

    private static func project(
        _ id: String, path: String, host: String? = nil, kind: ProjectKind = .git, linkedTo: String? = nil
    ) -> ProjectConfig {
        var project = ProjectConfig(
            id: id, name: id, path: path, color: "blue", addedAt: Date(timeIntervalSince1970: 0),
            host: host, kind: kind
        )
        project.linkedProjectId = linkedTo
        return project
    }

    private static func row(_ path: String, in projectId: String) -> Worktree {
        let url = URL(fileURLWithPath: path)
        return Worktree(
            id: Worktree.makeId(path: url), projectId: projectId, name: path, branch: path,
            path: url, status: .clean, lastActivity: Date(timeIntervalSince1970: 0)
        )
    }

    private static let devbox = RemotePath.virtual(host: "devbox", realPath: "/srv/r")

    @MainActor
    @Test func settingsComeFromThePrimary() {
        let manager = ProjectsManager(persistedProjects: [
            Self.project("L", path: "/l"),
            Self.project("R", path: Self.devbox, host: "devbox", linkedTo: "L"),
        ])
        #expect(manager.settingsProject(for: "R")?.id == "L")
        #expect(manager.settingsProject(for: "L")?.id == "L")
        #expect(manager.primaryProjects.map(\.id) == ["L"])
        #expect(manager.linkedProjects(of: "L").map(\.id) == ["R"])
    }

    struct LinkCase: CustomTestStringConvertible, Sendable {
        let name: String
        let record: String
        let primary: String
        let links: Bool
        var testDescription: String { name }
    }

    @MainActor
    @Test(arguments: [
        LinkCase(name: "local record", record: "L2", primary: "L", links: false),
        LinkCase(name: "folder record", record: "RF", primary: "L", links: false),
        LinkCase(name: "hosted primary", record: "R2", primary: "R3", links: false),
        LinkCase(name: "folder primary", record: "R2", primary: "LF", links: false),
        LinkCase(name: "host already linked", record: "R3", primary: "L", links: false),
        LinkCase(name: "valid pair", record: "R2", primary: "L", links: true),
    ])
    func linkRefusesInvalidPairs(_ row: LinkCase) {
        let manager = ProjectsManager(persistedProjects: [
            Self.project("L", path: "/l"),
            Self.project("L2", path: "/l2"),
            Self.project("LF", path: "/lf", kind: .folder),
            Self.project("R", path: Self.devbox, host: "devbox", linkedTo: "L"),
            Self.project("R2", path: RemotePath.virtual(host: "mini", realPath: "/r"), host: "mini"),
            Self.project("R3", path: RemotePath.virtual(host: "devbox", realPath: "/r3"), host: "devbox"),
            Self.project("RF", path: RemotePath.virtual(host: "mini", realPath: "/f"), host: "mini", kind: .folder),
        ])
        manager.link(row.record, to: row.primary)
        let linked = manager.projects.first { $0.id == row.record }?.linkedProjectId
        #expect(linked == (row.links ? row.primary : nil))
    }

    @MainActor
    @Test func removingThePrimaryUnlinksItsRecords() {
        let manager = ProjectsManager(persistedProjects: [
            Self.project("L", path: "/l"),
            Self.project("R", path: Self.devbox, host: "devbox", linkedTo: "L"),
        ])
        manager.removeProject(id: "L")
        #expect(manager.projects.first?.linkedProjectId == nil)
        #expect(manager.primaryProjects.map(\.id) == ["R"])
    }

    @MainActor
    @Test func mergedWorktreesFollowThePrimarysManualOrder() {
        let localMain = Self.row("/l", in: "L")
        let localFeature = Self.row("/l-wts/a", in: "L")
        let remoteMain = Self.row(Self.devbox, in: "R")
        let remoteFeature = Self.row(Self.devbox + "-wts/b", in: "R")
        var primary = Self.project("L", path: "/l")
        primary.worktreeOrder = [remoteFeature.id, localFeature.id]
        primary.worktreeOrderIsManual = true
        let manager = ProjectsManager(persistedProjects: [
            primary,
            Self.project("R", path: Self.devbox, host: "devbox", linkedTo: "L"),
        ])
        // The local rows load first, before the remote ones are known.
        for row in [localMain, localFeature, remoteMain, remoteFeature] {
            manager.insertOptimisticWorktree(row)
            manager.setOperationState(for: row, state: nil)
        }
        #expect(manager.visibleWorktrees(includingLinkedTo: "L").map(\.id)
            == [localMain.id, remoteFeature.id, localFeature.id, remoteMain.id])

        manager.reorderWorktree(projectId: "L", movingId: localFeature.id, destinationId: remoteFeature.id)
        #expect(manager.visibleWorktrees(includingLinkedTo: "L").map(\.id)
            == [localMain.id, localFeature.id, remoteFeature.id, remoteMain.id])
    }
}
