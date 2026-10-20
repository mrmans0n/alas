import Foundation
import AlasFoundation
import AlasModel

public enum LocalTextJobPriority: Int, Sendable {
    case background
    case automatic
    case userInitiated
}

public enum LocalTextCaller: Hashable, Sendable {
    case nextPrompt
    case sessionSummary(UUID)
    /// Background recap precompute, keyed by the ACP session id.
    case sessionRecapPrecompute(String)
    case worktreeName
    case worktreeExplainer
    case sessionTitle
    case mergeConflictExplanation
    case runFailureBrief
    case commitMessage
    case changeSummary
    case attentionRollUp
}

public struct LocalTextMessage: Equatable, Sendable {
    public enum Role: String, Sendable {
        case system
        case user
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct LocalTextGenerationRequest: Sendable {
    public let messageCandidates: [[LocalTextMessage]]
    public let inputTokenLimit: Int
    public let maxTokens: Int
    public let temperature: Float
    public let prefillStepSize: Int
    public let timeout: Duration

    public init(messageCandidates: [[LocalTextMessage]], inputTokenLimit: Int, maxTokens: Int, temperature: Float, prefillStepSize: Int, timeout: Duration) {
        self.messageCandidates = messageCandidates
        self.inputTokenLimit = inputTokenLimit
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.prefillStepSize = prefillStepSize
        self.timeout = timeout
    }
}

public struct LocalTextGenerationResult: Equatable, Sendable {
    public let text: String
    public let selectedCandidateIndex: Int

    public init(text: String, selectedCandidateIndex: Int) {
        self.text = text
        self.selectedCandidateIndex = selectedCandidateIndex
    }
}

public enum LocalTextInferenceFailure: Error, Equatable, Sendable {
    case unsupported
    case unavailable
    case inputTooLarge
    case timedOut
    case cancelled
    case preempted
    case generationFailed
}

public protocol LocalTextGenerating: Sendable {
    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult
    func cancel(caller: LocalTextCaller) async
    func cancelAndUnload() async
}

/// Makes the on-device text engine. The app installs its MLX-backed engine
/// from `PlatformServices.install()`; without one, every request fails as
/// unsupported.
public enum LocalTextEngine {
    @MainActor public static var make: (LocalTextModelStore) -> any LocalTextGenerating = { _ in UnsupportedLocalText() }
}

private struct UnsupportedLocalText: LocalTextGenerating {
    func generate(_: LocalTextGenerationRequest, caller _: LocalTextCaller,
                  priority _: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        throw LocalTextInferenceFailure.unsupported
    }

    func cancel(caller _: LocalTextCaller) async {}
    func cancelAndUnload() async {}
}
