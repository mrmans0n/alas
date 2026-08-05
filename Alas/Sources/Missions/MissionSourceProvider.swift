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
        var lastManualFallback: MissionSourceResolutionFailure?
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
            } catch let error as MissionSourceResolutionFailure where reference.isShort {
                lastManualFallback = error
                lastError = error
            }
        }
        throw lastManualFallback ?? lastError ?? CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")
    }
}

private extension MissionSourceReference {
    var isShort: Bool {
        guard case .short = self else { return false }
        return true
    }
}

struct ManualMissionSourceProvider: MissionSourceProviding {
    let id: MissionSourceProviderID = .manual
    private let metadataFetcher: WebPageMetadataFetcher?

    init(metadataFetcher: WebPageMetadataFetcher? = nil) {
        self.metadataFetcher = metadataFetcher
    }

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
        let metadata = (try? await metadataFetcher?.metadata(for: url))
            .flatMap { Self.metadataDescribingInput($0, inputURL: url) }
        let source = try Self.snapshot(
            for: url,
            displayReference: metadata?.displayReference,
            providerLabel: metadata?.providerLabel,
            title: metadata?.title ?? "",
            body: metadata?.summary ?? ""
        )
        let inferredProjectID: String?
        if let metadata {
            inferredProjectID = await self.inferredProjectID(
                for: metadata,
                projects: projects,
                remotes: remotes
            )
        } else {
            inferredProjectID = nil
        }
        return .init(
            source: source,
            repositoryLocator: nil,
            candidateProjectIDs: projects.map(\.id),
            selectedProjectID: inferredProjectID ?? selectedProjectID
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
        providerLabel: String? = nil,
        title: String = "",
        body: String = "",
        isRefreshable: Bool = false
    ) throws -> MissionSourceSnapshot {
        let canonicalURL = try canonicalURL(url)
        return .init(
            identity: identity ?? .init(providerID: .manual, stableID: canonicalURL.absoluteString),
            canonicalURL: canonicalURL,
            providerLabel: providerLabel
                ?? repositoryLocator?.provider.displayName
                ?? URLComponents(url: canonicalURL, resolvingAgainstBaseURL: false)?.host
                ?? "Manual",
            displayReference: displayReference,
            repositoryLocator: repositoryLocator,
            title: title,
            body: body,
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

    private func inferredProjectID(
        for metadata: WebPageMetadata,
        projects: [ProjectConfig],
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async -> String? {
        let context = "\(metadata.title)\n\(metadata.summary)"
        var scores: [(id: String, score: Int)] = []
        for project in projects {
            var score = Self.projectNameScore(project, context: context)
            if let projectRemotes = try? await remotes(project) {
                for remote in CodeHostRemoteDetector.detectAll(from: projectRemotes) {
                    score = max(score, Self.remoteScore(remote, metadata: metadata))
                }
            }
            if score > 0 {
                scores.append((project.id, score))
            }
        }
        guard let highest = scores.map(\.score).max() else { return nil }
        let best = scores.filter { $0.score == highest }
        return best.count == 1 ? best[0].id : nil
    }

    private static func metadataDescribingInput(
        _ metadata: WebPageMetadata,
        inputURL: URL
    ) -> WebPageMetadata? {
        guard !looksLikeAuthenticationPage(metadata),
              canonicalURL(metadata.canonicalURL, describes: inputURL, displayReference: metadata.displayReference)
        else { return nil }
        return metadata
    }

    private static func canonicalURL(
        _ canonicalURL: URL,
        describes inputURL: URL,
        displayReference: String?
    ) -> Bool {
        guard canonicalURL.host?.caseInsensitiveCompare(inputURL.host ?? "") == .orderedSame else {
            return false
        }
        if normalizedPath(canonicalURL.path) == normalizedPath(inputURL.path) {
            return true
        }
        guard let displayReference, !displayReference.isEmpty else { return false }
        return inputURL.absoluteString.range(
            of: displayReference,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private static func looksLikeAuthenticationPage(_ metadata: WebPageMetadata) -> Bool {
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return false }
        let authenticationTitles = [
            "log in",
            "login",
            "sign in",
            "signin",
            "authentication required",
        ]
        return authenticationTitles.contains { title == $0 || title.hasPrefix("\($0) ") || title.hasPrefix("\($0) -") }
    }

    private static func projectNameScore(_ project: ProjectConfig, context: String) -> Int {
        let names = Set([
            project.name.trimmingCharacters(in: .whitespacesAndNewlines),
            URL(fileURLWithPath: project.path).lastPathComponent,
        ])
        return names.contains { name in
            name.count >= 3 && context.range(
                of: name,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        } ? 10 : 0
    }

    private static func remoteScore(
        _ remote: CodeHostRemote,
        metadata: WebPageMetadata
    ) -> Int {
        let remoteHost = remote.webURL.host?.lowercased()
        let remotePath = normalizedRepositoryPath(remote.webURL.path)
        if metadata.links.contains(where: { link in
            guard link.host?.lowercased() == remoteHost else { return false }
            let linkPath = normalizedRepositoryPath(link.path)
            return linkPath == remotePath || linkPath.hasPrefix("\(remotePath)/")
        }) {
            return 100
        }
        let context = "\(metadata.title)\n\(metadata.summary)"
        return context.range(
            of: remote.repositorySlug,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == nil ? 0 : 50
    }

    private static func normalizedRepositoryPath(_ path: String) -> String {
        var normalized = normalizedPath(path)
        if normalized.lowercased().hasSuffix(".git") {
            normalized.removeLast(4)
        }
        return normalized.lowercased()
    }

    private static func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
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
        components.user = nil
        components.password = nil
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
    private let supportedRoutingKinds: Set<CodeHostKind>

    init(kind: CodeHostKind = .github, providers: CodeHostIssueProviderRegistry) {
        self.kind = kind
        id = kind.missionSourceProviderID
        supportedRoutingKinds = providers.supportedKinds
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
        try await validateShortReferenceRemoteKind(
            reference,
            projects: projects,
            selectedProjectID: selectedProjectID,
            remotes: remotes
        )
        let adapterKind = kind
        let adapterRemotes: @Sendable (ProjectConfig) async throws -> [GitRemote] = { project in
            let projectRemotes = try await remotes(project)
            if reference.isShort,
               project.id == selectedProjectID,
               let preferredRemote = Self.preferredUnclassifiedFetchRemote(projectRemotes)
            {
                return [preferredRemote]
            }
            return projectRemotes.filter { remote in
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
            guard let fallback = try? await manualFallback(
                for: reference,
                projects: projects,
                selectedProjectID: selectedProjectID,
                remotes: adapterRemotes
            ),
                Self.shouldOfferManualFallback(for: reference, after: error)
            else {
                throw error
            }
            throw MissionSourceResolutionFailure(fallback: fallback, message: error.userFacingMessage)
        }
    }

    private func validateShortReferenceRemoteKind(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws {
        guard case .short = reference else { return }
        guard let selectedProjectID,
              let project = projects.first(where: { $0.id == selectedProjectID })
        else { return }
        let projectRemotes = try await remotes(project)
        guard let preferredRemote = Self.preferredFetchRemote(projectRemotes),
              let preferred = CodeHostRemoteDetector.detect(
                  from: [preferredRemote]
              )
        else { return }
        guard preferred.kind == kind else {
            throw CodeHostProviderError.malformedOutput("The selected project has no supported code host remote.")
        }
    }

    private static func preferredFetchRemote(_ remotes: [GitRemote]) -> GitRemote? {
        let fetchRemotes = remotes
            .filter { $0.direction == .fetch }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.name == "origin" ? 0 : 1
                let rhsPriority = rhs.name == "origin" ? 0 : 1
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.name < rhs.name
            }
        return fetchRemotes.first
    }

    private static func preferredUnclassifiedFetchRemote(
        _ remotes: [GitRemote]
    ) -> GitRemote? {
        guard let preferred = preferredFetchRemote(remotes),
              CodeHostRemoteDetector.detect(from: [preferred]) == nil
        else { return nil }
        return preferred
    }

    func refresh(
        _ source: MissionSourceSnapshot,
        project: ProjectConfig,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> MissionSourceSnapshot {
        guard let issue = MissionIssueSnapshot(source: source),
              let locator = source.repositoryLocator,
              let provider = providers.provider(for: locator.provider)
        else {
            throw CodeHostProviderError.malformedOutput("The source repository is no longer configured for this project.")
        }
        let candidates = CodeHostRemoteDetector
            .detectAllMatching(try await remotes(project), kind: locator.provider)
            .filter { $0.host.caseInsensitiveCompare(locator.host) == .orderedSame }
        guard let authenticationRemote = candidates.first else {
            throw CodeHostProviderError.malformedOutput("The source repository is no longer configured for this project.")
        }
        let queryRemote = Self.queryRemote(locator: locator, candidates: candidates)
        let cwd = URL(fileURLWithPath: project.path)
        guard await provider.isAvailable(cwd: cwd) else {
            throw CodeHostProviderError.cliMissing(provider.executable)
        }
        guard await provider.isAuthenticated(remote: authenticationRemote, cwd: cwd) else {
            throw CodeHostProviderError.unauthenticated(authenticationRemote.host)
        }
        let snapshot = try await provider.issue(remote: queryRemote, number: issue.identity.number, cwd: cwd)
        guard snapshot.identity.provider == locator.provider,
              snapshot.identity.host.caseInsensitiveCompare(locator.host) == .orderedSame,
              candidates.contains(where: { candidate in
                  candidate.repositorySlug.caseInsensitiveCompare(snapshot.identity.repositorySlug) == .orderedSame
              })
        else {
            throw CodeHostProviderError.malformedOutput(
                "The Mission source repository no longer matches a configured project remote."
            )
        }
        return .init(issue: snapshot)
    }
    static func queryRemote(
        locator: MissionRepositoryLocator,
        candidates: [CodeHostRemote]
    ) -> CodeHostRemote {
        guard let currentRemote = candidates.first else {
            preconditionFailure("A Mission source query requires an authenticated remote.")
        }
        return candidates.first { candidate in
            candidate.repositorySlug.caseInsensitiveCompare(locator.repositorySlug) == .orderedSame
        } ?? legacyRemote(locator: locator, using: currentRemote)
    }

    private static func legacyRemote(
        locator: MissionRepositoryLocator,
        using currentRemote: CodeHostRemote
    ) -> CodeHostRemote {
        let parts = locator.repositorySlug.split(separator: "/").map(String.init)
        let owner = parts.dropLast().joined(separator: "/")
        let repository = parts.last ?? locator.repositorySlug
        var components = URLComponents()
        components.scheme = currentRemote.webURL.scheme ?? "https"
        components.host = currentRemote.webURL.host ?? locator.host
        components.port = currentRemote.webURL.port
        components.path = "/\(locator.repositorySlug)"
        return CodeHostRemote(
            kind: locator.provider,
            host: locator.host,
            owner: owner,
            repository: repository,
            remoteName: currentRemote.remoteName,
            webURL: components.url ?? currentRemote.webURL
        )
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
            let matchingProjects = await matchingProjects(
                projects,
                kind: kind,
                host: host,
                slug: slug,
                remotes: remotes
            )
            let fallbackProjects = matchingProjects.isEmpty ? projects : matchingProjects
            let fallbackSelectedProjectID = fallbackProjects.contains { $0.id == selectedProjectID }
                ? selectedProjectID
                : fallbackProjects.first?.id
            return try fallback(
                url: inputURL,
                kind: kind,
                host: host,
                slug: slug,
                number: number,
                projects: fallbackProjects,
                selectedProjectID: fallbackSelectedProjectID
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

    private func matchingProjects(
        _ projects: [ProjectConfig],
        kind: CodeHostKind,
        host: String,
        slug: String,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async -> [ProjectConfig] {
        var matches: [ProjectConfig] = []
        for project in projects {
            guard let projectRemotes = try? await remotes(project),
                  CodeHostRemoteDetector.detectAllMatching(projectRemotes, kind: kind).contains(where: { remote in
                      remote.host.caseInsensitiveCompare(host) == .orderedSame
                          && remote.repositorySlug.caseInsensitiveCompare(slug) == .orderedSame
                  })
            else { continue }
            matches.append(project)
        }
        return matches
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

    private static func shouldOfferManualFallback(
        for reference: MissionSourceReference,
        after error: Error
    ) -> Bool {
        if error.isMissingConfiguredRemote { return false }
        if isFetchFailure(error) { return true }
        if case .url = reference { return true }
        return false
    }
}

private extension Error {
    var userFacingMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }

    var isMissingConfiguredRemote: Bool {
        (self as? CodeHostProviderError)?.isMissingConfiguredRemote ?? false
    }
}

private extension CodeHostProviderError {
    var isMissingConfiguredRemote: Bool {
        guard case .malformedOutput(let message) = self else { return false }
        return message == "The selected project has no supported code host remote."
            || message == "No configured project matches this issue repository."
    }
}
