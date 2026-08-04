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

@MainActor
struct MissionIssueResolver {
    struct Environment {
        let projects: () -> [ProjectConfig]
        let selectedProjectId: () -> String?
        let remotes: @Sendable (ProjectConfig) async throws -> [GitRemote]
        let providers: CodeHostIssueProviderRegistry
    }

    let environment: Environment

    func resolve(_ rawReference: String) async throws -> ResolvedMissionIssue {
        let resolver = MissionSourceResolver(environment: .init(
            projects: environment.projects,
            selectedProjectID: environment.selectedProjectId,
            remotes: environment.remotes,
            providers: .init([
                CodeHostMissionSourceProvider(providers: environment.providers),
                ManualMissionSourceProvider(),
            ])
        ))
        let result = try await resolver.resolve(rawReference)
        guard let snapshot = MissionIssueSnapshot(source: result.source),
              let selectedProjectID = result.selectedProjectID,
              let project = environment.projects().first(where: { $0.id == selectedProjectID }),
              let locator = result.repositoryLocator,
              let remote = CodeHostRemoteDetector.detectAllMatching(try await environment.remotes(project), kind: locator.provider).first(where: {
                  $0.host.caseInsensitiveCompare(locator.host) == .orderedSame
                      && $0.repositorySlug.caseInsensitiveCompare(locator.repositorySlug) == .orderedSame
              })
        else {
            throw CodeHostProviderError.malformedOutput("The resolved source is not a configured code host issue.")
        }
        return .init(
            snapshot: snapshot,
            remote: remote,
            candidateProjectIds: result.candidateProjectIDs,
            selectedProjectId: selectedProjectID
        )
    }
}
