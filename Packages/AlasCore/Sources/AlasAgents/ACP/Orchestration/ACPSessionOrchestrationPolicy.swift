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

public enum ACPSessionOrchestrationPolicy: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case delegatedSessionCannotCreateChild
        case crossProjectTarget
        case targetIsNotDirectRelative
        case agentUnavailable(String)
        case blankPrompt
    }

    public static func authorizeCreate(parent: ACPDelegationRecord?) -> Result<Void, Error> {
        guard parent == nil else {
            return .failure(.delegatedSessionCannotCreateChild)
        }

        return .success(())
    }

    public static func authorizeSend(
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

    /// A child with a model selection takes inbox prompts only once it is
    /// `.ready`: its initial prompt must be first and on the selected model,
    /// and the start path drains the inbox after that transition. A child that
    /// failed before then may never have applied the selection, so its held
    /// messages are never delivered (`markChildFailed` discards them).
    public static func defersInboxDelivery(target: ACPDelegationRecord?) -> Bool {
        guard let target, target.modelSelection != nil else { return false }
        return target.phase != .ready
    }

    /// The delegated source message id of a child's initial prompt.
    public static func initialPromptMessageId(childSessionId: String) -> String {
        "initial-\(childSessionId)"
    }

    /// What an attach does with a session's prompt hold, from its delegation:
    /// arm it while the selection is being applied, and once the child
    /// failed with a selection, drop the parent's initial prompt before
    /// lifting it, so the prompt never runs on the agent's default model.
    public static func selectionHoldDecision(target: ACPDelegationRecord?) -> ACPDelegatedSelectionHoldDecision {
        if holdsPromptDispatch(target: target) { return .hold }
        if let target, target.modelSelection != nil, target.phase == .failed {
            return .discard(initialPromptMessageId: initialPromptMessageId(childSessionId: target.childSessionId))
        }
        return .release
    }

    /// Whether a child's session must hold every prompt, the composer's
    /// included, because its model selection is still being applied. Unlike
    /// `defersInboxDelivery` this ends at `.failed`: the parent's prompt is
    /// dropped then, and what a human types in the tab is theirs to send.
    public static func holdsPromptDispatch(target: ACPDelegationRecord?) -> Bool {
        guard let target, target.modelSelection != nil else { return false }
        return target.phase == .creatingWorktree || target.phase == .starting
    }

    /// `session_wait` and `session_interrupt` act on a turn only its direct
    /// parent started, so they reach direct children only; a child cannot
    /// stop or block on its parent.
    public static func authorizeChildControl(
        callerSessionId: String,
        callerProjectId: String,
        target: ACPDelegationRecord?
    ) -> Result<Void, Error> {
        guard let target, target.parentSessionId == callerSessionId else {
            return .failure(.targetIsNotDirectRelative)
        }
        guard target.projectId == callerProjectId else {
            return .failure(.crossProjectTarget)
        }
        return .success(())
    }

    /// Whether `session_wait` can stop waiting on a child: it is not still
    /// starting, has no turn running, and has no prompt left to run. A queued
    /// prompt or undelivered inbox message counts as work, so a wait right
    /// after `session_send` does not return before that turn has run. A
    /// child blocked on a permission or question is settled: only the user
    /// can unblock it, and the caller should hear about it.
    public static func waitSettled(
        phase: ACPDelegationPhase,
        runtime: ACPOrchestrationRuntimeState?,
        hasPendingPrompts: Bool
    ) -> Bool {
        switch phase {
        case .creatingWorktree, .starting:
            return false
        case .failed, .closed:
            return true
        case .ready:
            switch runtime {
            case .running:
                return false
            case .awaitingInput, .closed:
                return true
            case .idle, .none:
                return !hasPendingPrompts
            }
        }
    }

    /// Whether a session's queue holds a turn still to run or finish. A
    /// prompt held for the user's Retry, or scheduled for later, is not one
    /// a wait can see end.
    public static func queueOwesTurn(_ queue: [QueuedPrompt]) -> Bool {
        queue.contains { $0.lastError == nil && $0.scheduledAt == nil }
    }

    public static func acceptsMessages(target: ACPDelegationRecord?) -> Bool {
        guard let target else { return true }
        return target.phase != .failed && target.phase != .closed
    }

    public static func visibleSessions(
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

    public static func resolveAgent(
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

    /// The ACP agents a caller may see as delegation targets, in configured
    /// order. Agents without an ACP launcher are omitted outright: they can
    /// never be spawned. `configured` must reflect current Settings, so an
    /// agent disabled a moment ago is reported disabled even before install
    /// detection re-runs. Models are only ever those the agent advertised.
    public static func delegationAgents(
        configured: [AgentDefinition],
        acpAgentIDs: Set<String>,
        availability: AgentAvailabilityState,
        catalog: (String) -> (models: [ACPAgentModelCatalog.Model], report: ACPAgentModelCatalog.LaunchReport)
    ) -> [ACPDelegationAgentSummary] {
        configured.filter { acpAgentIDs.contains($0.id) }.map { agent in
            let agentAvailability: ACPDelegationAgentAvailability
            if !agent.isEnabled {
                agentAvailability = .disabled
            } else {
                switch availability {
                case .available(let installed):
                    agentAvailability = installed.contains { $0.id == agent.id } ? .available : .notInstalled
                case .loading, .failed:
                    agentAvailability = .unknown
                }
            }
            let (models, report) = catalog(agent.id)
            let state: ACPDelegationModelCatalogState
            if !models.isEmpty {
                state = report == .advertisedModels ? .known : .stale
            } else {
                state = report == .advertisedNone ? .unsupported : .notLoaded
            }
            let selection: ACPDelegationModelSelection = switch state {
            case .known, .stale: .supported
            case .unsupported: .unsupported
            case .notLoaded, .unavailable: .unknown
            }
            let isAvailable = agentAvailability == .available
            return ACPDelegationAgentSummary(
                id: agent.id,
                displayName: agent.displayName,
                available: isAvailable,
                availability: agentAvailability,
                modelSelection: selection,
                modelCatalog: isAvailable
                    ? ACPDelegationModelCatalog(state: state, models: models)
                    : ACPDelegationModelCatalog(state: .unavailable, models: [])
            )
        }
    }

    /// Spawn-time check, before any child record exists. Rejects only what
    /// this launch confirmed on the child's execution host (`launchModels`):
    /// a model id missing from the list the agent advertised there, an agent
    /// that advertised no models there, or reasoning for an agent whose
    /// thinking control is not a config option. Anything unconfirmed (nil)
    /// defers to the live session, which always validates again.
    public static func preflightModelSelection(
        _ selection: ACPDelegatedModelSelection,
        agentId: String,
        launchModels: [ACPAgentModelCatalog.Model]?
    ) -> ACPDelegatedModelSelectionError? {
        if let model = selection.model, let launchModels {
            if launchModels.isEmpty {
                return .modelSelectionUnsupported(agentId: agentId)
            }
            if !launchModels.contains(where: { $0.id == model }) {
                return .unknownModel(agentId: agentId, model: model, available: launchModels.map(\.id))
            }
        }
        if selection.reasoning != nil {
            switch ACPAgentProfiles.routing(for: agentId).thinkingSource {
            case .none, .mode:
                return .reasoningUnsupported(agentId: agentId)
            case .configOption, .heuristic:
                break
            }
        }
        return nil
    }

    /// How to apply a requested model on a live session, from what the agent
    /// advertised in `session/new`. Nil means it is already selected.
    public static func liveModelStep(
        model: String,
        agentId: String,
        chip: ChipSpec?
    ) throws -> ACPDelegatedSelectionStep? {
        guard let chip else { throw ACPDelegatedModelSelectionError.modelSelectionUnsupported(agentId: agentId) }
        guard chip.options.contains(where: { $0.id == model }) else {
            throw ACPDelegatedModelSelectionError.unknownModel(agentId: agentId, model: model, available: chip.options.map(\.id))
        }
        guard chip.currentId != model else { return nil }
        switch chip.source {
        case .model:
            return .setModel(model)
        case .configOption(let id):
            return .setConfigOption(id: id, value: model)
        case .mode:
            throw ACPDelegatedModelSelectionError.modelSelectionUnsupported(agentId: agentId)
        }
    }

    /// Reasoning is only applied through a select config option the agent
    /// advertised, so the acknowledgement is verifiable. Thinking encoded as a
    /// mode (pi) or as model-id variants (Cursor) is rejected, never guessed.
    public static func liveReasoningStep(
        reasoning: String,
        agentId: String,
        chip: ChipSpec?
    ) throws -> ACPDelegatedSelectionStep? {
        guard let chip, case .configOption(let id) = chip.source else {
            throw ACPDelegatedModelSelectionError.reasoningUnsupported(agentId: agentId)
        }
        guard chip.options.contains(where: { $0.id == reasoning }) else {
            throw ACPDelegatedModelSelectionError.unknownReasoning(agentId: agentId, reasoning: reasoning, available: chip.options.map(\.id))
        }
        guard chip.currentId != reasoning else { return nil }
        return .setConfigOption(id: id, value: reasoning)
    }

    public static func validatedPrompt(_ prompt: String) throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw Error.blankPrompt
        }

        return prompt
    }

    /// Hybrid rule: a child that already messaged its parent during the turn
    /// costs the parent nothing more than a notice; a child that ended
    /// silently, or failed, wakes the parent. A cancelled turn means the human
    /// intervened, so it never wakes.
    public static func outcomeDisposition(
        result: ACPTurnCompletion.Result,
        lastParentReportAt: Int64?,
        turnStartedAt: Int64
    ) -> ACPChildOutcomeDisposition {
        switch result {
        case .failed:
            return .wake
        case .cancelled:
            return .notice
        case .limited:
            // The child resumes on its own; the parent shouldn't burn a turn.
            return .notice
        case .completed:
            if let lastParentReportAt, lastParentReportAt >= turnStartedAt {
                return .notice
            }
            return .wake
        }
    }

    /// Whether startup must re-attach a ready delegated child, judged from
    /// its queue head as persisted. A head that was sending or dispatched
    /// when Alas quit is a turn the child's broker may still be running, or
    /// finished while the app was down; a head that never went out is work
    /// the parent is waiting on. Re-attaching resends it under the same
    /// broker operation, so the broker hands back the live or finished turn
    /// and its completion produces the usual parent outcome. A head waiting
    /// on the user's Retry is left for the user, and scheduled prompts have
    /// their own startup path.
    public static func needsRestartAttach(phase: ACPDelegationPhase, queueHead: QueuedPrompt?) -> Bool {
        guard phase == .ready, let head = queueHead, head.scheduledAt == nil else { return false }
        return head.lastError == nil || head.deliveryUncertain
    }

    /// After that re-attach, why the child's pending turn can no longer
    /// report, or nil when it can. A child that did not come back ready
    /// cannot run it; an uncertain head means the broker that ran it is gone
    /// (a new broker generation), and the flusher never resends one on its
    /// own, so without this the parent would wait forever.
    public static func restartedTurnLoss(attachFailure: String?, queueHead: QueuedPrompt?) -> String? {
        if let attachFailure {
            return "Alas restarted and could not reconnect to the delegated session: \(attachFailure)"
        }
        if queueHead?.deliveryUncertain == true {
            return "Alas restarted while the delegated session was working, and its turn could not be recovered."
        }
        return nil
    }

    /// Escalate only while the child is still blocked on the SAME request.
    /// Matching the specific key matters: a child that cleared one prompt and
    /// hit another is blocked, but not on the thing the parent was told about,
    /// and a second block raises its own notice and escalation.
    public static func escalation(
        blocker: ACPChildBlocker,
        liveBlockedRequestKeys: Set<String>
    ) -> ACPBlockerEscalation {
        liveBlockedRequestKeys.contains(blocker.requestKey) ? .wake : .stillHandled
    }

    public static func publicState(
        phase: ACPDelegationPhase,
        runtime: ACPOrchestrationRuntimeState?,
        archived: Bool
    ) -> ACPOrchestrationPublicState {
        switch phase {
        case .creatingWorktree:
            return .creatingWorktree
        case .starting:
            return .starting
        case .failed:
            return .failed
        case .ready:
            if archived || runtime == .closed {
                return .closed
            }
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
