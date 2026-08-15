import Foundation

struct IssueSuggestionLoader: Sendable {
    struct Environment: Sendable {
        let projects: @Sendable () -> [ProjectConfig]
        let remotes: @Sendable (ProjectConfig) async throws -> [GitRemote]
        let providers: CodeHostIssueProviderRegistry
    }

    let environment: Environment

    func suggestions(projectID: String, limit: Int = 50) async throws -> [CodeHostIssueSuggestion] {
        guard let project = environment.projects().first(where: { $0.id == projectID }) else {
            throw CodeHostProviderError.malformedOutput("The selected project is no longer available.")
        }
        let remotes = try await environment.remotes(project)
        let candidates = candidateRemotes(remotes)
        guard !candidates.isEmpty else {
            throw CodeHostProviderError.malformedOutput("The selected project has no supported code host remote.")
        }
        let cwd = URL(fileURLWithPath: project.path)
        var lastError: Error?
        for remote in candidates {
            guard let provider = environment.providers.provider(for: remote.kind) else { continue }
            guard await provider.isAvailable(cwd: cwd) else {
                lastError = CodeHostProviderError.cliMissing(provider.executable)
                continue
            }
            guard await provider.isAuthenticated(remote: remote, cwd: cwd) else {
                lastError = CodeHostProviderError.unauthenticated(remote.host)
                continue
            }
            return try await provider.openIssues(remote: remote, limit: limit, cwd: cwd)
        }
        throw lastError ?? CodeHostProviderError.malformedOutput("The selected project has no supported code host remote.")
    }

    private func candidateRemotes(_ remotes: [GitRemote]) -> [CodeHostRemote] {
        var candidates: [CodeHostRemote] = []
        if let detected = CodeHostRemoteDetector.detect(
            from: remotes,
            supportedKinds: environment.providers.supportedKinds
        ) {
            candidates.append(detected)
        }
        for remote in remotes {
            for kind in environment.providers.supportedKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let detected = CodeHostRemoteDetector.detect(from: [remote], matching: kind),
                      !candidates.contains(detected)
                else { continue }
                candidates.append(detected)
            }
        }
        return candidates
    }
}
