import Foundation
import Testing
@testable import Alas

@Suite("Repository import")
struct RepositoryImportServiceTests {
    @Test("GitHub catalog flattens paginated account repositories")
    func parsesGitHubCatalog() throws {
        let json = #"[[{"full_name":"team/private-repo","name":"private-repo","private":true,"archived":false}],[{"full_name":"me/archive","name":"archive","private":false,"archived":true}]]"#

        let repositories = try RepositoryImportService.parseGitHubRepositories(json)

        #expect(repositories == [
            RemoteRepository(
                host: .github,
                fullName: "team/private-repo",
                name: "private-repo",
                visibility: "Private",
                isArchived: false
            ),
            RemoteRepository(
                host: .github,
                fullName: "me/archive",
                name: "archive",
                visibility: "Public",
                isArchived: true
            ),
        ])
    }

    @Test("GitLab catalog decodes account repositories")
    func parsesGitLabCatalog() throws {
        let json = #"[{"path_with_namespace":"group/tool","path":"tool","visibility":"private","archived":false}]"#

        #expect(try RepositoryImportService.parseGitLabRepositories(json) == [
            RemoteRepository(
                host: .gitlab,
                fullName: "group/tool",
                name: "tool",
                visibility: "Private",
                isArchived: false
            ),
        ])
    }

    @Test("Repository search ignores case")
    func filtersCatalog() {
        let repositories = [
            RemoteRepository(host: .github, fullName: "team/Alpha", name: "Alpha", visibility: "Private", isArchived: false),
            RemoteRepository(host: .github, fullName: "me/beta", name: "beta", visibility: "Public", isArchived: false),
        ]

        #expect(RepositoryImportService.filter(repositories, query: "TEAM") == [repositories[0]])
        #expect(RepositoryImportService.filter(repositories, query: "  ") == repositories)
    }

    @Test("Repository name supports URL and SCP remotes")
    func derivesRepositoryName() {
        #expect(RepositoryImportService.repositoryName(from: "https://codeberg.org/team/tool.git") == "tool")
        #expect(RepositoryImportService.repositoryName(from: "git@codeberg.org:team/widget.git") == "widget")
        #expect(RepositoryImportService.repositoryName(from: "") == nil)
    }

    @Test("Clone commands preserve each source's authentication")
    func buildsCloneCommands() {
        let destination = URL(fileURLWithPath: "/tmp/tool")

        #expect(RepositoryImportService.cloneInvocation(for: .github("team/tool"), destination: destination)
            == RepositoryCloneInvocation(executable: "gh", arguments: ["repo", "clone", "team/tool", "/tmp/tool"]))
        #expect(RepositoryImportService.cloneInvocation(for: .gitlab("group/tool"), destination: destination)
            == RepositoryCloneInvocation(executable: "glab", arguments: ["repo", "clone", "group/tool", "/tmp/tool"]))
        #expect(RepositoryImportService.cloneInvocation(for: .gitURL("git@example.com:team/tool.git"), destination: destination)
            == RepositoryCloneInvocation(executable: "git", arguments: ["clone", "--", "git@example.com:team/tool.git", "/tmp/tool"]))
    }

    @Test("Failed clone preserves a destination created by another process")
    func failedCloneCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("tool")
        let marker = destination.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RepositoryImportService { _, arguments, _ in
            let cloneTarget = URL(fileURLWithPath: arguments.last ?? "")
            try FileManager.default.createDirectory(at: cloneTarget, withIntermediateDirectories: true)
            try "partial".write(
                to: cloneTarget.appendingPathComponent("partial.txt"),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "keep".write(to: marker, atomically: true, encoding: .utf8)
            return ProcessResult(exitCode: 1, stdout: "", stderr: "clone failed")
        }

        await #expect(throws: RepositoryImportError.self) {
            try await service.clone(.gitURL("https://example.com/team/tool.git"), to: destination)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".tool.clone-") }
        #expect(leftovers.isEmpty)
    }

    @Test("Generic Git source clones a local repository")
    func clonesLocalRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = root.appendingPathComponent("remote.git")
        let destination = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialized = try await Process.git(["init", "--bare", remote.path])
        #expect(initialized.exitCode == 0)

        try await RepositoryImportService().clone(.gitURL(remote.path), to: destination)

        let checked = try await Process.git(["rev-parse", "--is-inside-work-tree"], cwd: destination)
        #expect(checked.exitCode == 0)
        #expect(checked.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }

    @Test("CLI errors include setup commands")
    func setupErrors() {
        #expect(RepositoryImportError.cliMissing(.github).localizedDescription.contains("brew install gh"))
        #expect(RepositoryImportError.unauthenticated(.gitlab).localizedDescription.contains("glab auth login --hostname gitlab.com"))
    }
}
