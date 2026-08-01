import Foundation

enum MissionIssueInput: Equatable, Sendable {
    case short(number: Int)
    case url(kind: CodeHostKind, host: String, repositorySlug: String, number: Int)

    static func parse(_ rawReference: String) throws -> Self {
        let raw = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortValue = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if let number = Int(shortValue), number > 0, !shortValue.contains("/") {
            return .short(number: number)
        }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            throw CodeHostProviderError.malformedOutput("Enter an issue number or a supported issue URL.")
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 4, parts[2] == "issues", let number = Int(parts[3]), number > 0 {
            return .url(kind: .github, host: host, repositorySlug: "\(parts[0])/\(parts[1])", number: number)
        }
        if let marker = parts.firstIndex(of: "-"), marker >= 2,
           parts.count == marker + 3, parts[marker + 1] == "issues",
           let number = Int(parts[marker + 2]), number > 0 {
            return .url(kind: .gitlab, host: host, repositorySlug: parts[..<marker].joined(separator: "/"), number: number)
        }
        throw CodeHostProviderError.malformedOutput("Enter a GitHub or GitLab issue URL.")
    }
}

struct ResolvedMissionIssue: Equatable, Sendable {
    let snapshot: MissionIssueSnapshot
    let remote: CodeHostRemote
    let candidateProjectIds: [String]
    let selectedProjectId: String
}

@MainActor
struct MissionIssueResolver {
    struct Environment {
        let projects: () -> [ProjectConfig]
        let selectedProjectId: () -> String?
        let remotes: (ProjectConfig) async throws -> [GitRemote]
        let providers: CodeHostIssueProviderRegistry
    }

    let environment: Environment

    func resolve(_ rawReference: String) async throws -> ResolvedMissionIssue {
        switch try MissionIssueInput.parse(rawReference) {
        case .short(let number):
            guard let selectedID = environment.selectedProjectId(),
                  let project = environment.projects().first(where: { $0.id == selectedID })
            else {
                throw CodeHostProviderError.malformedOutput("Select a project before resolving an issue.")
            }
            let remotes = try await environment.remotes(project)
            guard let remote = CodeHostRemoteDetector.detect(from: remotes) else {
                throw CodeHostProviderError.malformedOutput("The selected project has no supported code host remote.")
            }
            return try await resolve(number: number, remote: remote, candidates: [project.id], selectedProjectId: project.id, cwd: project.path)

        case .url(let kind, let host, let slug, let number):
            var matches: [(project: ProjectConfig, remote: CodeHostRemote)] = []
            for project in environment.projects() {
                let remotes = try await environment.remotes(project)
                if let remote = CodeHostRemoteDetector.detectAllMatching(remotes, kind: kind)
                    .first(where: { Self.matches(remote: $0, kind: kind, host: host, slug: slug) }) {
                    matches.append((project, remote))
                }
            }
            guard !matches.isEmpty else {
                throw CodeHostProviderError.malformedOutput("No configured project matches this issue repository.")
            }
            let selectedID = environment.selectedProjectId()
            let preferred = matches.first { $0.project.id == selectedID } ?? matches[0]
            return try await resolve(
                number: number,
                remote: preferred.remote,
                candidates: matches.map(\.project.id),
                selectedProjectId: preferred.project.id,
                cwd: preferred.project.path
            )
        }
    }

    private func resolve(number: Int, remote: CodeHostRemote, candidates: [String], selectedProjectId: String, cwd: String) async throws -> ResolvedMissionIssue {
        guard let provider = environment.providers.provider(for: remote.kind) else {
            throw CodeHostProviderError.unsupportedProvider(remote.kind)
        }
        let url = URL(fileURLWithPath: cwd)
        guard await provider.isAvailable(cwd: url) else { throw CodeHostProviderError.cliMissing(provider.executable) }
        guard await provider.isAuthenticated(remote: remote, cwd: url) else { throw CodeHostProviderError.unauthenticated(remote.host) }
        let snapshot = try await provider.issue(remote: remote, number: number, cwd: url)
        return ResolvedMissionIssue(snapshot: snapshot, remote: remote, candidateProjectIds: candidates, selectedProjectId: selectedProjectId)
    }

    private static func matches(remote: CodeHostRemote, kind: CodeHostKind, host: String, slug: String) -> Bool {
        remote.kind == kind && remote.host.caseInsensitiveCompare(host) == .orderedSame && remote.repositorySlug.caseInsensitiveCompare(slug) == .orderedSame
    }
}

private extension CodeHostRemoteDetector {
    static func detectAllMatching(_ remotes: [GitRemote], kind: CodeHostKind) -> [CodeHostRemote] {
        remotes.compactMap { remote in
            detect(from: [remote], matching: kind)
        }
    }
}
