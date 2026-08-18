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
        #expect(file.projects[0].startupScripts == .defaults)
        #expect(file.projects[0].mcpServers == [])
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
