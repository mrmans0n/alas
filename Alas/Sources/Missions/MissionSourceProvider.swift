import Foundation

enum MissionSourceReference: Equatable, Sendable {
    case short(number: Int)
    case url(URL)

    static func parse(_ rawReference: String) throws -> Self {
        let raw = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortValue = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if let number = Int(shortValue), number > 0, !shortValue.contains("/") {
            return .short(number: number)
        }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              let url = components.url
        else {
            throw CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
        }
        return .url(url)
    }
}

struct ResolvedMissionSource: Equatable, Sendable {
    var source: MissionSourceSnapshot
    let repositoryLocator: MissionRepositoryLocator?
    let candidateProjectIDs: [String]
    let selectedProjectID: String?
}

struct MissionSourceResolutionFailure: LocalizedError, Sendable {
    let fallback: ResolvedMissionSource
    let message: String

    var errorDescription: String? { message }
}

protocol MissionSourceProviding: Sendable {
    var id: MissionSourceProviderID { get }
    func recognizes(_ reference: MissionSourceReference) -> Bool
    func resolve(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource
    func refresh(
        _ source: MissionSourceSnapshot,
        project: ProjectConfig,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> MissionSourceSnapshot
}

struct MissionSourceProviderRegistry: Sendable {
    private let providers: [any MissionSourceProviding]

    init(_ providers: [any MissionSourceProviding]) {
        self.providers = providers.filter { $0.id != .manual } + providers.filter { $0.id == .manual }
    }

    func resolve(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource {
        guard let provider = providers.first(where: { $0.recognizes(reference) }) else {
            throw CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
        }
        return try await provider.resolve(reference, projects: projects, selectedProjectID: selectedProjectID, remotes: remotes)
    }
}

struct ManualMissionSourceProvider: MissionSourceProviding {
    let id: MissionSourceProviderID = .manual

    func recognizes(_ reference: MissionSourceReference) -> Bool {
        guard case .url = reference else { return false }
        return true
    }

    func resolve(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource {
        guard case .url(let url) = reference else {
            throw CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
        }
        let source = try Self.snapshot(for: url)
        return .init(
            source: source,
            repositoryLocator: nil,
            candidateProjectIDs: projects.map(\.id),
            selectedProjectID: selectedProjectID
        )
    }

    func refresh(
        _ source: MissionSourceSnapshot,
        project: ProjectConfig,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> MissionSourceSnapshot {
        source
    }

    static func snapshot(
        for url: URL,
        identity: MissionSourceIdentity? = nil,
        repositoryLocator: MissionRepositoryLocator? = nil,
        displayReference: String? = nil,
        isRefreshable: Bool = false
    ) throws -> MissionSourceSnapshot {
        let canonicalURL = try canonicalURL(url)
        return .init(
            identity: identity ?? .init(providerID: .manual, stableID: canonicalURL.absoluteString),
            canonicalURL: canonicalURL,
            providerLabel: repositoryLocator?.provider.displayName ?? "Manual",
            displayReference: displayReference,
            repositoryLocator: repositoryLocator,
            title: "",
            body: "",
            state: .unknown,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: .now,
            refreshError: nil,
            contentOrigin: .manual,
            isEditable: true,
            isRefreshable: isRefreshable
        )
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else {
            throw CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
        }
        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.fragment = nil
        guard let canonicalURL = components.url else {
            throw CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
        }
        return canonicalURL
    }
}

struct CodeHostMissionSourceProvider: MissionSourceProviding {
    let id: MissionSourceProviderID = .github
    private let providers: CodeHostIssueProviderRegistry

    init(providers: CodeHostIssueProviderRegistry) {
        self.providers = providers
    }

    func recognizes(_ reference: MissionSourceReference) -> Bool {
        switch reference {
        case .short:
            return true
        case .url(let url):
            return (try? MissionIssueInput.parse(url.absoluteString)) != nil
        }
    }

    func resolve(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource {
        let resolver = CodeHostIssueResolver(environment: .init(
            projects: { projects },
            selectedProjectId: { selectedProjectID },
            remotes: remotes,
            providers: providers
        ))
        do {
            let result = try await resolver.resolve(rawReference(for: reference))
            let source = MissionSourceSnapshot(issue: result.snapshot)
            return .init(
                source: source,
                repositoryLocator: source.repositoryLocator,
                candidateProjectIDs: result.candidateProjectIds,
                selectedProjectID: result.selectedProjectId
            )
        } catch {
            guard Self.isFetchFailure(error),
                  let fallback = try? manualFallback(for: reference, projects: projects, selectedProjectID: selectedProjectID)
            else {
                throw error
            }
            throw MissionSourceResolutionFailure(fallback: fallback, message: error.userFacingMessage)
        }
    }

    func refresh(
        _ source: MissionSourceSnapshot,
        project: ProjectConfig,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> MissionSourceSnapshot {
        guard let issue = MissionIssueSnapshot(source: source),
              let locator = source.repositoryLocator,
              let remote = CodeHostRemoteDetector.detectAllMatching(try await remotes(project), kind: locator.provider).first(where: {
                  $0.host.caseInsensitiveCompare(locator.host) == .orderedSame
                      && $0.repositorySlug.caseInsensitiveCompare(locator.repositorySlug) == .orderedSame
              }),
              let provider = providers.provider(for: remote.kind)
        else {
            throw CodeHostProviderError.malformedOutput("The source repository is no longer configured for this project.")
        }
        let cwd = URL(fileURLWithPath: project.path)
        guard await provider.isAvailable(cwd: cwd) else {
            throw CodeHostProviderError.cliMissing(provider.executable)
        }
        guard await provider.isAuthenticated(remote: remote, cwd: cwd) else {
            throw CodeHostProviderError.unauthenticated(remote.host)
        }
        return .init(issue: try await provider.issue(remote: remote, number: issue.identity.number, cwd: cwd))
    }

    private func manualFallback(
        for reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?
    ) throws -> ResolvedMissionSource {
        guard case .url(let inputURL) = reference,
              case let .url(kind, host, slug, number) = try MissionIssueInput.parse(inputURL.absoluteString)
        else {
            throw CodeHostProviderError.malformedOutput("A manual fallback is only available for code host URLs.")
        }
        let providerID: MissionSourceProviderID = kind == .github ? .github : .gitlab
        let identity = MissionSourceIdentity(
            providerID: providerID,
            stableID: "\(host)/\(slug)#\(number)".lowercased()
        )
        let locator = MissionRepositoryLocator(provider: kind, host: host, repositorySlug: slug)
        let source = try ManualMissionSourceProvider.snapshot(
            for: inputURL,
            identity: identity,
            repositoryLocator: locator,
            displayReference: "#\(number)",
            isRefreshable: true
        )
        return .init(
            source: source,
            repositoryLocator: locator,
            candidateProjectIDs: projects.map(\.id),
            selectedProjectID: selectedProjectID
        )
    }

    private func rawReference(for reference: MissionSourceReference) -> String {
        switch reference {
        case .short(let number): "#\(number)"
        case .url(let url): url.absoluteString
        }
    }

    private static func isFetchFailure(_ error: Error) -> Bool {
        if error is CodeHostIssueProviderError { return true }
        guard let error = error as? CodeHostProviderError else { return false }
        switch error {
        case .cliMissing, .unauthenticated, .commandFailed:
            true
        case .unsupportedProvider, .malformedOutput:
            false
        }
    }
}

private extension Error {
    var userFacingMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
