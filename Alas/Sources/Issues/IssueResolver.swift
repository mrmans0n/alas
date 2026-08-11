import Foundation

@MainActor
struct IssueResolver {
    struct Environment {
        let projects: () -> [ProjectConfig]
        let selectedProjectID: () -> String?
        let remotes: @Sendable (ProjectConfig) async throws -> [GitRemote]
        let providers: IssueProviderRegistry
    }

    let environment: Environment

    func resolve(_ rawReference: String) async throws -> ResolvedIssue {
        let reference = try IssueReference.parse(rawReference)
        return try await environment.providers.resolve(
            reference,
            projects: environment.projects(),
            selectedProjectID: environment.selectedProjectID(),
            remotes: environment.remotes
        )
    }
}
