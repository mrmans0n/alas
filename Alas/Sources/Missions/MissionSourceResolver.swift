import Foundation

@MainActor
struct MissionSourceResolver {
    struct Environment {
        let projects: () -> [ProjectConfig]
        let selectedProjectID: () -> String?
        let remotes: @Sendable (ProjectConfig) async throws -> [GitRemote]
        let providers: MissionSourceProviderRegistry
    }

    let environment: Environment

    func resolve(_ rawReference: String) async throws -> ResolvedMissionSource {
        let reference = try MissionSourceReference.parse(rawReference)
        return try await environment.providers.resolve(
            reference,
            projects: environment.projects(),
            selectedProjectID: environment.selectedProjectID(),
            remotes: environment.remotes
        )
    }
}
