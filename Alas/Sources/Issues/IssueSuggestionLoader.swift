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
        guard let remote = CodeHostRemoteDetector.detect(
            from: remotes,
            supportedKinds: environment.providers.supportedKinds
        ) else {
            throw CodeHostProviderError.malformedOutput("The selected project has no supported code host remote.")
        }
        guard let provider = environment.providers.provider(for: remote.kind) else {
            throw CodeHostProviderError.unsupportedProvider(remote.kind)
        }
        let cwd = URL(fileURLWithPath: project.path)
        guard await provider.isAvailable(cwd: cwd) else {
            throw CodeHostProviderError.cliMissing(provider.executable)
        }
        guard await provider.isAuthenticated(remote: remote, cwd: cwd) else {
            throw CodeHostProviderError.unauthenticated(remote.host)
        }
        return try await provider.openIssues(remote: remote, limit: limit, cwd: cwd)
    }
}
