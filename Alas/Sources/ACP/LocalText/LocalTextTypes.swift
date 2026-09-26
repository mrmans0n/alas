import Foundation

enum LocalTextJobPriority: Int, Sendable {
    case automatic
    case userInitiated
}

enum LocalTextCaller: Hashable, Sendable {
    case nextPrompt
    case sessionSummary(UUID)
}

struct LocalTextMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case system
        case user
    }

    let role: Role
    let content: String
}

struct LocalTextGenerationRequest: Sendable {
    let messageCandidates: [[LocalTextMessage]]
    let inputTokenLimit: Int
    let maxTokens: Int
    let temperature: Float
    let prefillStepSize: Int
    let timeout: Duration
}

struct LocalTextGenerationResult: Equatable, Sendable {
    let text: String
    let selectedCandidateIndex: Int
}

enum LocalTextInferenceFailure: Error, Equatable, Sendable {
    case unsupported
    case unavailable
    case inputTooLarge
    case timedOut
    case cancelled
    case preempted
    case generationFailed
}

protocol LocalTextGenerating: Sendable {
    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult
    func cancel(caller: LocalTextCaller) async
    func cancelAndUnload() async
}
