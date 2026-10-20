import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

public struct ACPWorktreeSessionRequest: Equatable, Sendable {
    public let worktreeId: String
    public let sessionID: ACPSession.ID
    public let agentId: String
    public let promptID: UUID
    public let prompt: String?

    public init(worktreeId: String, sessionID: ACPSession.ID, agentId: String, promptID: UUID, prompt: String?) {
        self.worktreeId = worktreeId
        self.sessionID = sessionID
        self.agentId = agentId
        self.promptID = promptID
        self.prompt = prompt
    }
}

@MainActor
public final class ACPWorktreeSessionBootstrapper {
    public struct Environment {
        public let sessionExists: (String, ACPSession.ID) async -> Bool
        public let prepareSession: (String, ACPSession.ID, String) async throws -> Void
        public let enqueuePrompt: (String, ACPSession.ID, UUID, String) async -> Bool
        public let attach: (String, ACPSession.ID, Bool) async -> Void
        public let readyState: (String, ACPSession.ID) -> ACPBootstrapReadyState

        public init(sessionExists: @escaping (String, ACPSession.ID) async -> Bool, prepareSession: @escaping (String, ACPSession.ID, String) async throws -> Void, enqueuePrompt: @escaping (String, ACPSession.ID, UUID, String) async -> Bool, attach: @escaping (String, ACPSession.ID, Bool) async -> Void, readyState: @escaping (String, ACPSession.ID) -> ACPBootstrapReadyState) {
            self.sessionExists = sessionExists
            self.prepareSession = prepareSession
            self.enqueuePrompt = enqueuePrompt
            self.attach = attach
            self.readyState = readyState
        }
    }

    private let environment: Environment

    private struct StartKey: Hashable {
        let worktreeId: String
        let sessionID: ACPSession.ID

        public init(worktreeId: String, sessionID: ACPSession.ID) {
            self.worktreeId = worktreeId
            self.sessionID = sessionID
        }
    }

    private static var inFlightStarts: [StartKey: Task<ACPSession.ID, Error>] = [:]

    public init(environment: Environment) {
        self.environment = environment
    }

    public func start(_ request: ACPWorktreeSessionRequest) async throws -> ACPSession.ID {
        let key = StartKey(worktreeId: request.worktreeId, sessionID: request.sessionID)
        if let inFlight = Self.inFlightStarts[key] {
            return try await inFlight.value
        }
        let environment = environment
        let task = Task { @MainActor in
            try await Self.start(request, in: environment)
        }
        Self.inFlightStarts[key] = task
        defer { Self.inFlightStarts[key] = nil }
        return try await task.value
    }

    private static func start(
        _ request: ACPWorktreeSessionRequest,
        in environment: Environment
    ) async throws -> ACPSession.ID {
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

        if let prompt = request.prompt {
            guard await environment.enqueuePrompt(
                request.worktreeId,
                request.sessionID,
                request.promptID,
                prompt
            ) else {
                throw ACPWorktreeSessionBootstrapError(message: "Could not queue initial prompt.")
            }
        }

        await environment.attach(request.worktreeId, request.sessionID, !sessionAlreadyExists)
        switch environment.readyState(request.worktreeId, request.sessionID) {
        case .ready:
            return request.sessionID
        case .needsSetup(let reason), .needsAuthentication(let reason), .failed(let reason):
            throw ACPWorktreeSessionBootstrapError(
                message: reason,
                consumedInitialPrompt: request.prompt != nil
            )
        }
    }
}
