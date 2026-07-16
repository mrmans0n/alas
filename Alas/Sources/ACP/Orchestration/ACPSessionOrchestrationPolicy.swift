import Foundation

enum ACPOrchestrationRelationship: String, Equatable, Sendable {
    case parent
    case child
}

enum ACPOrchestrationPublicState: String, Equatable, Sendable {
    case creatingWorktree = "creating_worktree"
    case starting
    case idle
    case running
    case awaitingInput = "awaiting_input"
    case failed
    case closed
}

enum ACPOrchestrationRuntimeState: Equatable, Sendable {
    case idle
    case running
    case awaitingInput
    case closed
}

struct ACPOrchestrationVisibleSession: Equatable, Sendable {
    let sessionId: String
    let relationship: ACPOrchestrationRelationship?
}

struct ACPOrchestrationAgent: Equatable, Sendable {
    let id: String
    let isEnabled: Bool
    let isACPCapable: Bool
}

enum ACPSessionOrchestrationPolicy {
    enum Error: Swift.Error, Equatable {
        case delegatedSessionCannotCreateChild
        case crossProjectTarget
        case targetIsNotDirectRelative
        case agentUnavailable(String)
        case blankPrompt
    }

    static func authorizeCreate(parent: ACPDelegationRecord?) -> Result<Void, Error> {
        guard parent == nil else {
            return .failure(.delegatedSessionCannotCreateChild)
        }

        return .success(())
    }

    static func authorizeSend(
        callerSessionId: String,
        callerProjectId: String,
        targetSessionId: String,
        targetProjectId: String,
        callerParent: ACPDelegationRecord?,
        targetParent: ACPDelegationRecord?
    ) -> Result<ACPOrchestrationRelationship, Error> {
        guard callerProjectId == targetProjectId,
              callerParent?.projectId == nil || callerParent?.projectId == callerProjectId,
              targetParent?.projectId == nil || targetParent?.projectId == targetProjectId else {
            return .failure(.crossProjectTarget)
        }

        if targetParent?.parentSessionId == callerSessionId {
            return .success(.child)
        }

        if callerParent?.parentSessionId == targetSessionId {
            return .success(.parent)
        }

        return .failure(.targetIsNotDirectRelative)
    }

    static func acceptsMessages(target: ACPDelegationRecord?) -> Bool {
        guard let target else { return true }
        return target.phase != .failed && target.phase != .closed
    }

    static func visibleSessions(
        callerSessionId: String,
        parent: ACPDelegationRecord?,
        children: [ACPDelegationRecord]
    ) -> [ACPOrchestrationVisibleSession] {
        var sessions = [ACPOrchestrationVisibleSession(sessionId: callerSessionId, relationship: nil)]

        if let parent {
            sessions.append(.init(sessionId: parent.parentSessionId, relationship: .parent))
        }

        sessions.append(contentsOf: children.map {
            ACPOrchestrationVisibleSession(sessionId: $0.childSessionId, relationship: .child)
        })

        return sessions
    }

    static func resolveAgent(
        requestedId: String?,
        parentAgentId: String,
        available: [ACPOrchestrationAgent]
    ) throws -> String {
        let requestedId = requestedId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentId = requestedId?.isEmpty == false ? requestedId! : parentAgentId

        guard available.contains(where: {
            $0.id == agentId && $0.isEnabled && $0.isACPCapable
        }) else {
            throw Error.agentUnavailable(agentId)
        }

        return agentId
    }

    static func validatedPrompt(_ prompt: String) throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw Error.blankPrompt
        }

        return prompt
    }

    static func publicState(
        phase: ACPDelegationPhase,
        runtime: ACPOrchestrationRuntimeState?,
        archived: Bool
    ) -> ACPOrchestrationPublicState {
        if archived || phase == .closed || runtime == .closed {
            return .closed
        }

        switch phase {
        case .creatingWorktree:
            return .creatingWorktree
        case .starting:
            return .starting
        case .failed:
            return .failed
        case .ready:
            switch runtime {
            case .running:
                return .running
            case .awaitingInput:
                return .awaitingInput
            case .idle, .none:
                return .idle
            case .closed:
                return .closed
            }
        case .closed:
            return .closed
        }
    }
}
