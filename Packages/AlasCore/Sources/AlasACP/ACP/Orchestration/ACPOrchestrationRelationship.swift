import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPOrchestrationRelationship: String, Equatable, Sendable {
    case parent
    case child
}

public enum ACPOrchestrationPublicState: String, Equatable, Sendable {
    case creatingWorktree = "creating_worktree"
    case starting
    case idle
    case running
    case awaitingInput = "awaiting_input"
    case failed
    case closed
}

public enum ACPOrchestrationRuntimeState: Equatable, Sendable {
    case idle
    case running
    case awaitingInput
    case closed
}

public struct ACPOrchestrationVisibleSession: Equatable, Sendable {
    public let sessionId: String
    public let relationship: ACPOrchestrationRelationship?

    public init(sessionId: String, relationship: ACPOrchestrationRelationship?) {
        self.sessionId = sessionId
        self.relationship = relationship
    }
}

/// One acknowledged RPC that applies part of a delegated model selection.
public enum ACPDelegatedSelectionStep: Equatable, Sendable {
    case setModel(String)
    case setConfigOption(id: String, value: String)
}

public enum ACPDelegatedSelectionHoldDecision: Equatable, Sendable {
    case hold
    case release
    case discard(initialPromptMessageId: String)
}

public enum ACPDelegatedModelSelectionError: Error, Equatable, LocalizedError, Sendable {
    case modelSelectionUnsupported(agentId: String)
    case unknownModel(agentId: String, model: String, available: [String])
    case reasoningUnsupported(agentId: String)
    case unknownReasoning(agentId: String, reasoning: String, available: [String])
    /// The agent refused or did not apply a change it had advertised.
    case rejected(agentId: String, setting: String, value: String, reason: String)
    case sessionUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelSelectionUnsupported(let agentId):
            return "Agent \(agentId) does not offer model selection."
        case .unknownModel(let agentId, let model, let available):
            return "Model \(model) is not offered by agent \(agentId)." + Self.availableSuffix(available)
        case .reasoningUnsupported(let agentId):
            return "Agent \(agentId) does not expose a reasoning setting Alas can apply."
        case .unknownReasoning(let agentId, let reasoning, let available):
            return "Reasoning \(reasoning) is not offered by agent \(agentId)." + Self.availableSuffix(available)
        case .rejected(let agentId, let setting, let value, let reason):
            return "Agent \(agentId) did not apply \(setting) \(value): \(reason)"
        case .sessionUnavailable:
            return "The delegated session was not ready to apply its model selection."
        }
    }

    private static func availableSuffix(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " Available: \(ids.joined(separator: ", "))."
    }
}

public struct ACPOrchestrationAgent: Equatable, Sendable {
    public let id: String
    public let isEnabled: Bool
    public let isACPCapable: Bool

    public init(id: String, isEnabled: Bool, isACPCapable: Bool) {
        self.id = id
        self.isEnabled = isEnabled
        self.isACPCapable = isACPCapable
    }
}

/// What the parent receives when a delegated child's turn ends.
public enum ACPChildOutcomeDisposition: Equatable, Sendable {
    /// Queue a prompt so the parent runs a turn.
    case wake
    /// Append a passive system notice only.
    case notice
}

/// Whether a blocked child still warrants waking its parent.
public enum ACPBlockerEscalation: Equatable, Sendable {
    case wake
    case stillHandled
}
