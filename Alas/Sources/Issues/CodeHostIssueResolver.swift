import Foundation

enum CodeHostIssueInput: Equatable, Sendable {
    case short(number: Int)
    case url(kind: CodeHostKind, host: String, repositorySlug: String, number: Int)

    static func parse(_ rawReference: String) throws -> Self {
        switch try IssueReference.parse(rawReference) {
        case .short(let number):
            return .short(number: number)
        case .url(let url):
            return try parseCodeHostURL(url)
        }
    }

    private static func parseCodeHostURL(_ url: URL) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw CodeHostProviderError.malformedOutput("Enter a GitHub or GitLab issue URL.")
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

struct ResolvedCodeHostIssue: Equatable, Sendable {
    let snapshot: CodeHostIssueSnapshot
    let remote: CodeHostRemote
    let candidateProjectIds: [String]
    let selectedProjectId: String
}

struct CodeHostIssueResolver {
    struct Environment {
        let projects: () -> [ProjectConfig]
        let selectedProjectId: () -> String?
        let remotes: (ProjectConfig) async throws -> [GitRemote]
        let providers: CodeHostIssueProviderRegistry
    }

    let environment: Environment

    func resolve(_ rawReference: String) async throws -> ResolvedCodeHostIssue {
        switch try CodeHostIssueInput.parse(rawReference) {
        case .short(let number):
            guard let selectedID = environment.selectedProjectId(),
                  let project = environment.projects().first(where: { $0.id == selectedID })
            else {
                throw CodeHostProviderError.malformedOutput("Select a project before resolving an issue.")
            }
            let remotes = try await environment.remotes(project)
            let candidates = Self.candidateRemotes(
                remotes,
                supportedKinds: environment.providers.supportedKinds
            )
            guard !candidates.isEmpty else {
                throw CodeHostProviderError.malformedOutput("The selected project has no supported code host remote.")
            }
            var lastError: Error?
            for remote in candidates {
                do {
                    let probed = try await resolve(
                        number: number,
                        remote: remote,
                        candidates: [project.id],
                        selectedProjectId: project.id,
                        cwd: project.path
                    )
                    return try Self.canonicalResult(
                        probed,
                        number: number,
                        projectRemotes: [(project, candidates)],
                        preferredProjectID: project.id
                    )
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? CodeHostProviderError.malformedOutput("The selected project has no supported code host remote.")

        case .url(let kind, let host, let slug, let number):
            var projectRemotes: [(project: ProjectConfig, remotes: [CodeHostRemote])] = []
            for project in environment.projects() {
                guard let remotes = try? await environment.remotes(project) else {
                    continue
                }
                let detected = CodeHostRemoteDetector.detectAllMatching(remotes, kind: kind)
                if !detected.isEmpty {
                    projectRemotes.append((project, detected))
                }
            }

            let exactMatches = projectRemotes.compactMap { entry -> (project: ProjectConfig, remote: CodeHostRemote)? in
                guard let remote = entry.remotes.first(where: {
                    Self.matches(remote: $0, kind: kind, host: host, slug: slug)
                }) else { return nil }
                return (entry.project, remote)
            }
            var exactMatchError: Error?
            if !exactMatches.isEmpty {
                do {
                    let probed = try await resolve(
                        number: number,
                        matches: exactMatches,
                        preferredProjectID: environment.selectedProjectId()
                    )
                    return try Self.canonicalResult(
                        probed,
                        number: number,
                        projectRemotes: projectRemotes,
                        preferredProjectID: probed.selectedProjectId
                    )
                } catch {
                    exactMatchError = error
                }
            }

            let sameHostProjects = projectRemotes.filter { entry in
                entry.remotes.contains { remote in
                    remote.host.caseInsensitiveCompare(host) == .orderedSame
                }
            }
            guard !sameHostProjects.isEmpty else {
                throw CodeHostProviderError.malformedOutput("No configured project matches this issue repository.")
            }

            let selectedID = environment.selectedProjectId()
            let preferred = sameHostProjects.first { $0.project.id == selectedID }
            let orderedProjects = preferred.map { preferred in
                [preferred] + sameHostProjects.filter { $0.project.id != preferred.project.id }
            } ?? sameHostProjects
            var lastError: Error?
            for entry in orderedProjects {
                guard let authenticationRemote = entry.remotes.first(where: {
                    $0.host.caseInsensitiveCompare(host) == .orderedSame
                }), let probeRemote = Self.redirectProbeRemote(
                    kind: kind,
                    host: host,
                    slug: slug,
                    remoteName: authenticationRemote.remoteName
                ) else { continue }
                do {
                    let probed = try await resolve(
                        number: number,
                        remote: probeRemote,
                        candidates: [],
                        selectedProjectId: entry.project.id,
                        cwd: entry.project.path
                    )
                    return try Self.canonicalResult(
                        probed,
                        number: number,
                        projectRemotes: projectRemotes,
                        preferredProjectID: entry.project.id
                    )
                } catch {
                    lastError = error
                }
            }
            throw exactMatchError ?? lastError ?? CodeHostProviderError.malformedOutput("No configured project can resolve this issue.")
        }
    }

    private func resolve(number: Int, remote: CodeHostRemote, candidates: [String], selectedProjectId: String, cwd: String) async throws -> ResolvedCodeHostIssue {
        guard let provider = environment.providers.provider(for: remote.kind) else {
            throw CodeHostProviderError.unsupportedProvider(remote.kind)
        }
        let url = URL(fileURLWithPath: cwd)
        guard await provider.isAvailable(cwd: url) else { throw CodeHostProviderError.cliMissing(provider.executable) }
        guard await provider.isAuthenticated(remote: remote, cwd: url) else { throw CodeHostProviderError.unauthenticated(remote.host) }
        let snapshot = try await provider.issue(remote: remote, number: number, cwd: url)
        return ResolvedCodeHostIssue(snapshot: snapshot, remote: remote, candidateProjectIds: candidates, selectedProjectId: selectedProjectId)
    }

    private func resolve(
        number: Int,
        matches: [(project: ProjectConfig, remote: CodeHostRemote)],
        preferredProjectID: String?
    ) async throws -> ResolvedCodeHostIssue {
        let preferred = matches.first { $0.project.id == preferredProjectID }
        let orderedMatches = preferred.map { preferred in
            [preferred] + matches.filter { $0.project.id != preferred.project.id }
        } ?? matches
        let candidateProjectIDs = matches.map(\.project.id)
        var lastError: Error?
        for match in orderedMatches {
            do {
                return try await resolve(
                    number: number,
                    remote: match.remote,
                    candidates: candidateProjectIDs,
                    selectedProjectId: match.project.id,
                    cwd: match.project.path
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CodeHostProviderError.malformedOutput("No configured project can resolve this issue.")
    }

    private static func matches(remote: CodeHostRemote, kind: CodeHostKind, host: String, slug: String) -> Bool {
        remote.kind == kind && remote.host.caseInsensitiveCompare(host) == .orderedSame && remote.repositorySlug.caseInsensitiveCompare(slug) == .orderedSame
    }

    private static func canonicalResult(
        _ probed: ResolvedCodeHostIssue,
        number: Int,
        projectRemotes: [(project: ProjectConfig, remotes: [CodeHostRemote])],
        preferredProjectID: String
    ) throws -> ResolvedCodeHostIssue {
        let canonicalMatches = projectRemotes.flatMap { candidate in
            candidate.remotes.compactMap { remote -> (project: ProjectConfig, remote: CodeHostRemote)? in
                guard matches(
                    remote: remote,
                    kind: probed.snapshot.identity.provider,
                    host: probed.snapshot.identity.host,
                    slug: probed.snapshot.identity.repositorySlug
                ) else { return nil }
                return (candidate.project, remote)
            }
        }
        guard probed.snapshot.identity.number == number,
              !canonicalMatches.isEmpty
        else {
            throw CodeHostProviderError.malformedOutput(
                "The redirected issue repository does not match a configured project."
            )
        }
        let selectedMatch = canonicalMatches.first { $0.project.id == preferredProjectID }
            ?? canonicalMatches[0]
        var candidateProjectIDs: [String] = []
        for match in canonicalMatches where !candidateProjectIDs.contains(match.project.id) {
            candidateProjectIDs.append(match.project.id)
        }
        return ResolvedCodeHostIssue(
            snapshot: probed.snapshot,
            remote: selectedMatch.remote,
            candidateProjectIds: candidateProjectIDs,
            selectedProjectId: selectedMatch.project.id
        )
    }

    private static func redirectProbeRemote(
        kind: CodeHostKind,
        host: String,
        slug: String,
        remoteName: String
    ) -> CodeHostRemote? {
        let parts = slug.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              let repository = parts.last,
              let webURL = URL(string: "https://\(host)/\(slug)")
        else { return nil }
        return CodeHostRemote(
            kind: kind,
            host: host,
            owner: parts.dropLast().joined(separator: "/"),
            repository: repository,
            remoteName: remoteName,
            webURL: webURL
        )
    }

    private static func candidateRemotes(
        _ remotes: [GitRemote],
        supportedKinds: Set<CodeHostKind>
    ) -> [CodeHostRemote] {
        var candidates: [CodeHostRemote] = []
        if let detected = CodeHostRemoteDetector.detect(
            from: remotes,
            supportedKinds: supportedKinds
        ) {
            candidates.append(detected)
        }
        for remote in remotes {
            for kind in supportedKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let detected = CodeHostRemoteDetector.detect(from: [remote], matching: kind),
                      !candidates.contains(detected)
                else { continue }
                candidates.append(detected)
            }
        }
        return candidates
    }
}

extension CodeHostRemoteDetector {
    static func detectAllMatching(_ remotes: [GitRemote], kind: CodeHostKind) -> [CodeHostRemote] {
        remotes.compactMap { remote in
            detect(from: [remote], matching: kind)
        }
    }
}
