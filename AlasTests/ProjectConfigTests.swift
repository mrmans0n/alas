import Testing
import Foundation
@testable import Alas

struct ProjectConfigTests {
    @Test(arguments: [(nil, false), (nil, true), ("team/{name}-{date}", false)] as [(String?, Bool)])
    func branchTemplateCodingKeepsOlderProjectsUsableAndPersistsOverrides(template: String?, malformed: Bool) throws {
        let project = ProjectConfig(id: "p", name: "Repo", path: "/tmp/repo", color: "#fff", addedAt: .distantPast)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(project)
        ) as? [String: Any])
        object["worktreeBranchTemplate"] = template
        if malformed { object["worktreeBranchTemplate"] = 42 }
        let decoded = try JSONDecoder().decode(
            ProjectConfig.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.worktreeBranchTemplate == template)
        #expect(decoded.id == project.id)
        #expect(try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

    /// Remote projects persisted before virtual paths carry real paths in
    /// every worktree-keyed field; decoding moves them under the host's
    /// namespace and reports the id renames. Local projects are untouched.
    /// A host that is no longer valid fails closed: the project moves under
    /// an unresolvable placeholder host instead of routing locally.
    @Test(arguments: [
        (nil, nil), ("mini", "mini"),
        (".", RemotePath.unavailableHost), ("-oProxyCommand=x", RemotePath.unavailableHost),
        ("mini lan", RemotePath.unavailableHost),
    ] as [(String?, String?)])
    func decodeVirtualizesLegacyRemoteProjectPaths(persistedHost: String?, host: String?) throws {
        let worktree = Worktree(
            id: "/srv/wt/a", projectId: "p", name: "a", branch: "a",
            path: URL(fileURLWithPath: "/srv/wt/a"), status: .clean, lastActivity: .distantPast
        )
        let legacy = ProjectConfig(
            id: "p", name: "P", path: "/srv/repo", color: "#fff", addedAt: .distantPast,
            hiddenWorktreePaths: ["/srv/wt/h"], worktreeOrder: ["/srv/wt/a"],
            cachedWorktrees: [worktree], host: persistedHost, ggWorktreeModes: ["/srv/wt/a": .on]
        )
        let v: (String) -> String = { real in host.map { RemotePath.virtual(host: $0, realPath: real) } ?? real }

        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(legacy))

        #expect(decoded.host == host)
        #expect(RemoteHostRegistry.shared.host(forPath: decoded.path) == host)
        #expect(decoded.path == v("/srv/repo"))
        #expect(decoded.cachedWorktrees.map(\.id) == [v("/srv/wt/a")])
        #expect(decoded.cachedWorktrees.map(\.path.path) == [v("/srv/wt/a")])
        #expect(decoded.hiddenWorktreePaths == [v("/srv/wt/h")])
        #expect(decoded.worktreeOrder == [v("/srv/wt/a")])
        #expect(decoded.ggWorktreeModes == [v("/srv/wt/a"): .on])
        #expect(decoded.legacyWorktreeIDs == (host == nil ? [:] : [
            "/srv/repo": v("/srv/repo"), "/srv/wt/a": v("/srv/wt/a"), "/srv/wt/h": v("/srv/wt/h"),
        ]))

        // Already-virtual values decode unchanged, and the pending id map
        // survives a save until the store migration clears it; projects with
        // nothing pending encode without it.
        let json = try JSONEncoder().encode(decoded)
        #expect(String(decoding: json, as: UTF8.self).contains("pendingLegacyWorktreeIDs") == (host != nil))
        let again = try JSONDecoder().decode(ProjectConfig.self, from: json)
        #expect(again == decoded)
    }

    /// Paths already virtual under a host that is no longer valid move to the
    /// placeholder too, so the path never routes to the raw host.
    @Test func decodeMovesVirtualPathsOfAnInvalidHostToThePlaceholder() throws {
        let legacy = ProjectConfig(
            id: "p", name: "P", path: RemotePath.root + "/mini lan/srv/repo", color: "#fff", addedAt: .distantPast,
            host: "mini lan"
        )

        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(legacy))

        #expect(decoded.path == RemotePath.virtual(host: RemotePath.unavailableHost, realPath: "/srv/repo"))
    }

    /// A host-less project persisted inside the reserved namespace fails
    /// closed under the placeholder host instead of routing to an ssh host
    /// named after its next path component; normal local projects are untouched.
    @Test(arguments: [RemotePath.root + "/x/repo", "/srv/repo"])
    func decodeMovesReservedLocalProjectsUnderThePlaceholder(path: String) throws {
        let worktree = Worktree(
            id: path + "-wt", projectId: "p", name: "wt", branch: "wt",
            path: URL(fileURLWithPath: path + "-wt"), status: .clean, lastActivity: .distantPast
        )
        let legacy = ProjectConfig(
            id: "p", name: "P", path: path, color: "#fff", addedAt: .distantPast, cachedWorktrees: [worktree]
        )
        let reserved = RemotePath.isReserved(path)
        let v: (String) -> String = { reserved ? RemotePath.virtual(host: RemotePath.unavailableHost, realPath: $0) : $0 }

        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(legacy))

        #expect(decoded.host == (reserved ? RemotePath.unavailableHost : nil))
        #expect(decoded.path == v(path))
        #expect(decoded.cachedWorktrees.map(\.id) == [v(path + "-wt")])
        #expect(RemoteHostRegistry.shared.host(forPath: decoded.path) == (reserved ? RemotePath.unavailableHost : nil))
        let again = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(decoded))
        #expect(again.host == decoded.host)
        #expect(again.path == decoded.path)
        #expect(again.cachedWorktrees == decoded.cachedWorktrees)
    }

    /// When a legacy key and its virtual form both exist, the virtual entry is
    /// the newer one and wins. Many keys so a random winner can't pass by luck.
    @Test func decodePrefersVirtualEntryOverLegacyDuplicate() throws {
        var modes: [String: GGWorktreeMode] = [:]
        for i in 0..<20 {
            modes["/srv/wt/\(i)"] = .off
            modes[RemotePath.virtual(host: "mini", realPath: "/srv/wt/\(i)")] = .on
        }
        let legacy = ProjectConfig(
            id: "p", name: "P", path: "/srv/repo", color: "#fff", addedAt: .distantPast,
            host: "mini", ggWorktreeModes: modes
        )

        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(legacy))

        #expect(decoded.ggWorktreeModes.count == 20)
        #expect(decoded.ggWorktreeModes.values.allSatisfy { $0 == .on })
    }

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
        #expect(file.projects[0].startupScripts == .defaults)
        #expect(file.projects[0].mcpServers == [])
    }

    @Test func decodingOlderProjectsFileSuppliesEmptyFileBookmarks() throws {
        // Older projects.json files predate fileBookmarks.
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
        #expect(file.projects[0].fileBookmarks == [])
    }

    @Test func roundTripPreservesFileBookmarkOrder() throws {
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
            fileBookmarks: ["Sources/Center", "docs"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ProjectsFile(projects: [project]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].fileBookmarks == ["Sources/Center", "docs"])
    }

    @Test func encodingOmitsFileBookmarksWhenEmpty() throws {
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ProjectsFile(projects: [project]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("fileBookmarks"))
    }

    @Test func roundTripPreservesHiddenPaths() throws {
        let cachedWorktree = Worktree(
            id: "/tmp/alpha/wt-a",
            projectId: "abc",
            name: "wt-a",
            branch: "wt-a",
            path: URL(fileURLWithPath: "/tmp/alpha/wt-a"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 1)
        )
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
            hiddenWorktreePaths: ["/tmp/alpha/wt-a", "/tmp/alpha/wt-b"],
            cachedWorktrees: [cachedWorktree]
        )
        let file = ProjectsFile(projects: [project])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].hiddenWorktreePaths == ["/tmp/alpha/wt-a", "/tmp/alpha/wt-b"])
        #expect(decoded.projects[0].cachedWorktrees == [cachedWorktree])
    }

    @Test func roundTripPreservesStartupScripts() throws {
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
            startupScripts: ProjectStartupScripts(
                sessionOpenMode: .appendToGlobal,
                sessionOpenScript: "mise install",
                worktreeCreateMode: .overrideGlobal,
                worktreeCreateScript: "pnpm install"
            )
        )
        let file = ProjectsFile(projects: [project])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        let scripts = decoded.projects[0].startupScripts
        #expect(scripts.sessionOpenMode == .appendToGlobal)
        #expect(scripts.sessionOpenScript == "mise install")
        #expect(scripts.worktreeCreateMode == .overrideGlobal)
        #expect(scripts.worktreeCreateScript == "pnpm install")
    }

    @Test func roundTripPreservesMCPServers() throws {
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
            mcpServers: [.stdio(name: "filesystem", command: "npx")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ProjectsFile(projects: [project]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)

        #expect(decoded.projects[0].mcpServers == project.mcpServers)
    }

    @Test func decodingOlderProjectWithHiddenPathsButNoStartupScripts() throws {
        let json = """
        {
          "version": 1,
          "projects": [{
            "id": "abc",
            "name": "alpha",
            "path": "/tmp/alpha",
            "color": "#5fb7c4",
            "addedAt": 0,
            "hiddenWorktreePaths": ["/tmp/alpha/wt"]
          }]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let file = try decoder.decode(ProjectsFile.self, from: json)
        #expect(file.projects.count == 1)
        #expect(file.projects[0].hiddenWorktreePaths == ["/tmp/alpha/wt"])
        #expect(file.projects[0].startupScripts == .defaults)
    }

    @Test func decodingOlderProjectWithoutLaunchDefaultsYieldsNil() throws {
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
        #expect(file.projects[0].worktreeOpenAfterCreate == nil)
        #expect(file.projects[0].worktreeDefaultLauncherMode == nil)
    }

    @Test func roundTripPreservesLaunchDefaults() throws {
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
            worktreeOpenAfterCreate: false,
            worktreeDefaultLauncherMode: .acp
        )
        let file = ProjectsFile(projects: [project])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].worktreeOpenAfterCreate == false)
        #expect(decoded.projects[0].worktreeDefaultLauncherMode == .acp)
    }
}

extension ProjectConfigTests {
    @Test func decodingOlderProjectWithoutIconSynthesizesLetterIcon() throws {
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

        #expect(file.projects[0].icon.mode == .letter)
        #expect(file.projects[0].icon.color == "#5fb7c4")
        #expect(file.projects[0].icon.label == nil)
    }

    @Test func roundTripPreservesProjectIconAndMirrorsLegacyColor() throws {
        let project = ProjectConfig(
            id: "abc",
            name: "alpha",
            path: "/tmp/alpha",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            icon: ProjectIcon(
                mode: .symbol,
                color: "#112233",
                symbolName: "terminal"
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ProjectsFile(projects: [project]))

        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"color\":\"#112233\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].color == "#112233")
        #expect(decoded.projects[0].icon.mode == .symbol)
        #expect(decoded.projects[0].icon.symbolName == "terminal")
    }

    @Test func decodingPartialIconFallsBackToLegacyColor() throws {
        let json = """
        {
          "version": 1,
          "projects": [{
            "id": "abc",
            "name": "alpha",
            "path": "/tmp/alpha",
            "color": "#112233",
            "icon": {
              "mode": "emoji",
              "emoji": "🚀"
            },
            "addedAt": 0
          }]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let file = try decoder.decode(ProjectsFile.self, from: json)

        #expect(file.projects[0].color == "#112233")
        #expect(file.projects[0].icon.color == "#112233")
        #expect(file.projects[0].icon.mode == .emoji)
        #expect(file.projects[0].icon.emoji == "🚀")
    }

    @Test func legacyColorMutationUpdatesIconColorBeforeEncoding() throws {
        var project = ProjectConfig(
            id: "abc",
            name: "alpha",
            path: "/tmp/alpha",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            icon: ProjectIcon(mode: .symbol, color: "#5fb7c4", symbolName: "terminal")
        )

        project.color = "#112233"

        #expect(project.icon.mode == .symbol)
        #expect(project.icon.symbolName == "terminal")
        #expect(project.icon.color == "#112233")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ProjectsFile(projects: [project]))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].icon.color == "#112233")
        #expect(decoded.projects[0].color == "#112233")
    }
}
