import Foundation

@MainActor
public struct IssueResolver: Sendable {
    public struct Environment {
        public let projects: () -> [ProjectConfig]
        public let selectedProjectID: () -> String?
        public let remotes: @Sendable (ProjectConfig) async throws -> [GitRemote]
        public let providers: IssueProviderRegistry

        public init(projects: @escaping () -> [ProjectConfig], selectedProjectID: @escaping () -> String?, remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote], providers: IssueProviderRegistry) {
            self.projects = projects
            self.selectedProjectID = selectedProjectID
            self.remotes = remotes
            self.providers = providers
        }
    }

    public let environment: Environment

    public func resolve(_ rawReference: String) async throws -> ResolvedIssue {
        let reference = try IssueReference.parse(rawReference)
        return try await environment.providers.resolve(
            reference,
            projects: environment.projects(),
            selectedProjectID: environment.selectedProjectID(),
            remotes: environment.remotes
        )
    }

    public init(environment: Environment) {
        self.environment = environment
    }
}
