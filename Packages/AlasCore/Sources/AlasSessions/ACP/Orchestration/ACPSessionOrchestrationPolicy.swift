import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// See `ACPSessionOrchestrationPolicy.deferredOutcomeStep`.
public enum ACPDeferredChildOutcomeStep: Equatable, Sendable {
    case wait
    case deliver
    case discard
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
    /// silently, failed, or stopped without success wakes the parent.
    /// Cancellation remains a notice, without an automatic follow-up turn.
    public static func outcomeDisposition(
        result: ACPTurnCompletion.Result,
        lastParentReportAt: Int64?,
        turnStartedAt: Int64
    ) -> ACPChildOutcomeDisposition {
        switch result {
        case .failed, .stopped:
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

    /// Whether a child's finished turn waits before its parent hears of it.
    /// A turn that settled at its result while the child's own children or
    /// autonomous follow-up still run would report interim text ("started a
    /// background agent…"); the answer comes once that work ends. Failed,
    /// stopped, cancelled and limited turns report at once.
    public static func defersOutcome(result: ACPTurnCompletion.Result, activity: ACPSessionActivity?) -> Bool {
        guard case .completed = result else { return false }
        return activity?.backgroundWorking == true
    }

    /// What a deferred outcome does as the child's state changes. It is
    /// delivered once all work has finished. A prompt sent to the child since
    /// supersedes it: that turn reports on its own. A child whose agent
    /// stopped (closed, detached or restarting) or whose session left this
    /// instance drops it, as a runner stopped mid-turn reports no turn.
    public static func deferredOutcomeStep(
        activity: ACPSessionActivity?,
        agentReady: Bool,
        promptSentSince: Bool
    ) -> ACPDeferredChildOutcomeStep {
        guard !promptSentSince, agentReady, let activity else { return .discard }
        return activity.allWorkFinished ? .deliver : .wait
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

    /// A child whose turn settled at its result is still running while its
    /// background work runs, so a wait does not return interim text. A
    /// foreground blocker still reads as awaiting input: only the user can
    /// clear it, and the parent should hear about it.
    public static func runtimeState(activity: ACPSessionActivity) -> ACPOrchestrationRuntimeState {
        switch activity.foreground {
        case .idle: activity.backgroundWorking ? .running : .idle
        case .sending, .streaming: .running
        case .awaitingPermission, .awaitingInput: .awaitingInput
        }
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
