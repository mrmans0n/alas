import Foundation

enum RepositoryHost: String, Equatable, Sendable {
    case github
    case gitlab

    var displayName: String { self == .github ? "GitHub" : "GitLab" }
    var cli: String { self == .github ? "gh" : "glab" }
    var hostname: String { self == .github ? "github.com" : "gitlab.com" }
}

struct RemoteRepository: Equatable, Identifiable, Sendable {
    let host: RepositoryHost
    let fullName: String
    let name: String
    let visibility: String
    let isArchived: Bool

    var id: String { "\(host.rawValue):\(fullName)" }
}

enum RepositoryCloneSource: Equatable, Sendable {
    case github(String)
    case gitlab(String)
    case gitURL(String)
}

struct RepositoryCloneInvocation: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

enum RepositoryImportError: LocalizedError, Equatable {
    case cliMissing(RepositoryHost)
    case unauthenticated(RepositoryHost)
    case destinationExists(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing(let host):
            "`\(host.cli)` is not installed. Run `brew install \(host.cli)`, then retry."
        case .unauthenticated(let host):
            "\(host.displayName) authentication is required. Run `\(host.cli) auth login --hostname \(host.hostname)`, then retry."
        case .destinationExists(let path):
            "A file or folder already exists at \(path). Choose another clone folder."
        case .commandFailed(let detail):
            detail.isEmpty ? "The repository command failed." : detail
        }
    }
}

struct RepositoryImportService {
    typealias Runner = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult

    private let run: Runner

    init(run: @escaping Runner = { executable, arguments, timeout in
        try await RepositoryImportService.runProcess(executable: executable, arguments: arguments, timeout: timeout)
    }) {
        self.run = run
    }

    static func parseGitHubRepositories(_ output: String) throws -> [RemoteRepository] {
        let decoder = JSONDecoder()
        let data = Data(output.utf8)
        let values: [GitHubRepository]
        if let pages = try? decoder.decode([[GitHubRepository]].self, from: data) {
            values = pages.flatMap { $0 }
        } else {
            values = try decoder.decode([GitHubRepository].self, from: data)
        }
        return values.map {
            RemoteRepository(
                host: .github,
                fullName: $0.fullName,
                name: $0.name,
                visibility: $0.isPrivate ? "Private" : "Public",
                isArchived: $0.archived
            )
        }
    }

    static func parseGitLabRepositories(_ output: String) throws -> [RemoteRepository] {
        try JSONDecoder().decode([GitLabRepository].self, from: Data(output.utf8)).map {
            RemoteRepository(
                host: .gitlab,
                fullName: $0.fullName,
                name: $0.name,
                visibility: $0.visibility.capitalized,
                isArchived: $0.archived
            )
        }
    }

    static func filter(_ repositories: [RemoteRepository], query: String) -> [RemoteRepository] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter { $0.fullName.localizedCaseInsensitiveContains(query) }
    }

    static func repositoryName(from remote: String) -> String? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let marker = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[..<marker])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let component = value.split(whereSeparator: { $0 == "/" || $0 == ":" }).last else { return nil }
        let name = component.hasSuffix(".git") ? component.dropLast(4) : component[...]
        return name.isEmpty ? nil : String(name)
    }

    static func cloneInvocation(for source: RepositoryCloneSource, destination: URL) -> RepositoryCloneInvocation {
        switch source {
        case .github(let repository):
            RepositoryCloneInvocation(executable: "gh", arguments: ["repo", "clone", repository, destination.path])
        case .gitlab(let repository):
            RepositoryCloneInvocation(executable: "glab", arguments: ["repo", "clone", repository, destination.path])
        case .gitURL(let remote):
            RepositoryCloneInvocation(executable: "git", arguments: ["clone", "--", remote, destination.path])
        }
    }

    func repositories(for host: RepositoryHost) async throws -> [RemoteRepository] {
        let version = try await run(host.cli, ["--version"], 30)
        guard version.exitCode == 0 else { throw RepositoryImportError.cliMissing(host) }
        let auth = try await run(host.cli, ["auth", "status", "--hostname", host.hostname], 30)
        guard auth.exitCode == 0 else { throw RepositoryImportError.unauthenticated(host) }

        let result: ProcessResult
        switch host {
        case .github:
            result = try await run("gh", [
                "api", "user/repos", "-X", "GET", "-f", "per_page=100",
                "-f", "affiliation=owner,collaborator,organization_member",
                "-f", "sort=updated", "--paginate", "--slurp",
            ], 120)
        case .gitlab:
            result = try await run("glab", [
                "api", "projects?membership=true&simple=true&per_page=100&order_by=last_activity_at&sort=desc",
                "--paginate", "--output", "json",
            ], 120)
        }
        guard result.exitCode == 0 else {
            throw RepositoryImportError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try host == .github
            ? Self.parseGitHubRepositories(result.stdout)
            : Self.parseGitLabRepositories(result.stdout)
    }

    func clone(_ source: RepositoryCloneSource, to destination: URL) async throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RepositoryImportError.destinationExists(destination.path)
        }
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).clone-\(UUID().uuidString)", isDirectory: true)
        let invocation = Self.cloneInvocation(for: source, destination: staging)
        do {
            let result = try await run(invocation.executable, invocation.arguments, 1_800)
            guard result.exitCode == 0 else {
                throw RepositoryImportError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw RepositoryImportError.destinationExists(destination.path)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        var environment = Process.gitEnv()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return try await Process.run(
            "/usr/bin/env",
            args: [executable] + arguments,
            env: environment,
            timeout: timeout
        )
    }
}

private struct GitHubRepository: Decodable {
    let fullName: String
    let name: String
    let isPrivate: Bool
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case name
        case isPrivate = "private"
        case archived
    }
}

private struct GitLabRepository: Decodable {
    let fullName: String
    let name: String
    let visibility: String
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "path_with_namespace"
        case name = "path"
        case visibility
        case archived
    }
}
