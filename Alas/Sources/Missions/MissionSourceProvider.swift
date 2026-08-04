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
    private let providersByID: [MissionSourceProviderID: any MissionSourceProviding]

    init(_ providers: [any MissionSourceProviding]) {
        self.providers = providers.filter { $0.id != .manual } + providers.filter { $0.id == .manual }
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    func provider(for id: MissionSourceProviderID) -> (any MissionSourceProviding)? {
        providersByID[id]
    }

    func resolve(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource {
        let matchingProviders = providers.filter { $0.recognizes(reference) }
        guard !matchingProviders.isEmpty else {
            throw CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
        }
        var lastError: Error?
        for provider in matchingProviders {
            do {
                return try await provider.resolve(
                    reference,
                    projects: projects,
                    selectedProjectID: selectedProjectID,
                    remotes: remotes
                )
            } catch let error as CodeHostProviderError where error.isMissingConfiguredRemote {
                lastError = error
            }
        }
        throw lastError ?? CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
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
    let id: MissionSourceProviderID
    private let kind: CodeHostKind
    private let providers: CodeHostIssueProviderRegistry

    init(kind: CodeHostKind = .github, providers: CodeHostIssueProviderRegistry) {
        self.kind = kind
        id = kind.missionSourceProviderID
        self.providers = .init(providers.provider(for: kind).map { [$0] } ?? [])
    }

    func recognizes(_ reference: MissionSourceReference) -> Bool {
        switch reference {
        case .short:
            return true
        case .url(let url):
            guard case .url(let parsedKind, _, _, _) = try? MissionIssueInput.parse(url.absoluteString) else {
                return false
            }
            return parsedKind == kind
        }
    }

    func resolve(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource {
        let adapterKind = kind
        let adapterRemotes: @Sendable (ProjectConfig) async throws -> [GitRemote] = { project in
            try await remotes(project).filter { remote in
                guard let detected = CodeHostRemoteDetector.detect(from: [remote]) else { return true }
                return detected.kind == adapterKind
            }
        }
        let resolver = CodeHostIssueResolver(environment: .init(
            projects: { projects },
            selectedProjectId: { selectedProjectID },
            remotes: adapterRemotes,
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
                  let fallback = try? await manualFallback(
                      for: reference,
                      projects: projects,
                      selectedProjectID: selectedProjectID,
                      remotes: adapterRemotes
                  )
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
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource {
        switch reference {
        case .url(let inputURL):
            guard case let .url(kind, host, slug, number) = try MissionIssueInput.parse(inputURL.absoluteString) else {
                throw CodeHostProviderError.malformedOutput("A manual fallback is only available for code host URLs.")
            }
            return try fallback(
                url: inputURL,
                kind: kind,
                host: host,
                slug: slug,
                number: number,
                projects: projects,
                selectedProjectID: selectedProjectID
            )
        case .short(let number):
            guard let selectedProjectID,
                  let project = projects.first(where: { $0.id == selectedProjectID }),
                  let remote = CodeHostRemoteDetector.detect(from: try await remotes(project), matching: kind)
            else {
                throw CodeHostProviderError.malformedOutput("A manual fallback is only available for a configured code host remote.")
            }
            let url = issueURL(for: remote, number: number)
            return try fallback(
                url: url,
                kind: remote.kind,
                host: remote.host,
                slug: remote.repositorySlug,
                number: number,
                projects: [project],
                selectedProjectID: selectedProjectID
            )
        }
    }

    private func fallback(
        url: URL,
        kind: CodeHostKind,
        host: String,
        slug: String,
        number: Int,
        projects: [ProjectConfig],
        selectedProjectID: String?
    ) throws -> ResolvedMissionSource {
        let identity = MissionSourceIdentity(
            providerID: kind.missionSourceProviderID,
            stableID: "\(host)/\(slug)#\(number)".lowercased()
        )
        let locator = MissionRepositoryLocator(provider: kind, host: host, repositorySlug: slug)
        let source = try ManualMissionSourceProvider.snapshot(
            for: url,
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

    private func issueURL(for remote: CodeHostRemote, number: Int) -> URL {
        let path = remote.kind == .gitlab ? "-/issues/\(number)" : "issues/\(number)"
        return remote.webURL.appendingPathComponent(path)
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
        return switch error {
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

private extension CodeHostProviderError {
    var isMissingConfiguredRemote: Bool {
        guard case .malformedOutput(let message) = self else { return false }
        return message == "The selected project has no supported code host remote."
    }
}
