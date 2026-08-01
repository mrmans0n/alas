import Foundation

struct ACPWorktreeSessionRequest: Equatable, Sendable {
    let worktreeId: String
    let sessionID: ACPSession.ID
    let agentId: String
    let promptID: UUID
    let prompt: String
}

enum ACPBootstrapReadyState: Equatable, Sendable {
    case ready
    case needsSetup(String)
    case needsAuthentication(String)
    case failed(String)
}

struct ACPWorktreeSessionBootstrapError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class ACPWorktreeSessionBootstrapper {
    struct Environment {
        let sessionExists: (String, ACPSession.ID) async -> Bool
        let prepareSession: (String, ACPSession.ID, String) async throws -> Void
        let enqueuePrompt: (String, ACPSession.ID, UUID, String) async -> Bool
        let attach: (String, ACPSession.ID, Bool) async -> Void
        let readyState: (String, ACPSession.ID) -> ACPBootstrapReadyState
    }

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func start(_ request: ACPWorktreeSessionRequest) async throws -> ACPSession.ID {
        let sessionAlreadyExists = await environment.sessionExists(request.worktreeId, request.sessionID)
        do {
            try await environment.prepareSession(
                request.worktreeId,
                request.sessionID,
                request.agentId
            )
        } catch {
            throw ACPWorktreeSessionBootstrapError(message: error.localizedDescription)
        }

        guard await environment.enqueuePrompt(
            request.worktreeId,
            request.sessionID,
            request.promptID,
            request.prompt
        ) else {
            throw ACPWorktreeSessionBootstrapError(message: "Could not queue initial prompt.")
        }

        await environment.attach(request.worktreeId, request.sessionID, !sessionAlreadyExists)
        switch environment.readyState(request.worktreeId, request.sessionID) {
        case .ready:
            return request.sessionID
        case .needsSetup(let reason), .needsAuthentication(let reason), .failed(let reason):
            throw ACPWorktreeSessionBootstrapError(message: reason)
        }
    }
}
