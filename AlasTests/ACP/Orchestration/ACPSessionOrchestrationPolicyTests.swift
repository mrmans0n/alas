import Foundation
import Testing
@testable import Alas

@Suite("ACP session orchestration policy")
struct ACPSessionOrchestrationPolicyTests {
    private let child = ACPDelegationRecord(
        childSessionId: "child",
        parentSessionId: "parent",
        projectId: "project",
        parentWorktreeId: "parent-worktree",
        childWorktreeId: "child-worktree",
        agentId: "codex",
        worktreeRequest: .existing(worktreeId: "child-worktree"),
        pendingInitialPrompt: nil,
        phase: .ready,
        failureMessage: nil,
        createdAt: 10,
        updatedAt: 20
    )

    @Test("root sessions may create children but delegated children may not")
    func createAuthorization() {
        guard case .success = ACPSessionOrchestrationPolicy.authorizeCreate(parent: nil) else {
            Issue.record("Expected root session creation to succeed")
            return
        }
        guard case .failure(.delegatedSessionCannotCreateChild) = ACPSessionOrchestrationPolicy.authorizeCreate(parent: child) else {
            Issue.record("Expected delegated child creation to be rejected")
            return
        }
    }

    @Test("only direct parent-child edges may send prompts")
    func sendAuthorization() {
        #expect(
            ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: "parent",
                callerProjectId: "project",
                targetSessionId: "child",
                targetProjectId: "project",
                callerParent: nil,
                targetParent: child
            ) == .success(.child)
        )
        #expect(
            ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: "child",
                callerProjectId: "project",
                targetSessionId: "parent",
                targetProjectId: "project",
                callerParent: child,
                targetParent: nil
            ) == .success(.parent)
        )
        #expect(
            ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: "child",
                callerProjectId: "project",
                targetSessionId: "sibling",
                targetProjectId: "project",
                callerParent: child,
                targetParent: ACPDelegationRecord(
                    childSessionId: "sibling",
                    parentSessionId: "parent",
                    projectId: "project",
                    parentWorktreeId: "parent-worktree",
                    childWorktreeId: "sibling-worktree",
                    agentId: "codex",
                    worktreeRequest: .existing(worktreeId: "sibling-worktree"),
                    pendingInitialPrompt: nil,
                    phase: .ready,
                    failureMessage: nil,
                    createdAt: 10,
                    updatedAt: 20
                )
            ) == .failure(.targetIsNotDirectRelative)
        )
    }

    @Test("cross-project targets are rejected before edge evaluation")
    func crossProjectSendIsRejected() {
        #expect(
            ACPSessionOrchestrationPolicy.authorizeSend(
                callerSessionId: "parent",
                callerProjectId: "project-a",
                targetSessionId: "child",
                targetProjectId: "project-b",
                callerParent: nil,
                targetParent: child
            ) == .failure(.crossProjectTarget)
        )
    }

    @Test("failed and closed delegated targets reject messages")
    func failedAndClosedTargetsRejectMessages() {
        var failedChild = child
        failedChild.phase = .failed
        var closedChild = child
        closedChild.phase = .closed

        #expect(!ACPSessionOrchestrationPolicy.acceptsMessages(target: failedChild))
        #expect(!ACPSessionOrchestrationPolicy.acceptsMessages(target: closedChild))
        #expect(ACPSessionOrchestrationPolicy.acceptsMessages(target: child))
        #expect(ACPSessionOrchestrationPolicy.acceptsMessages(target: nil))
    }

    @Test("a selected child holds prompt dispatch only until it is ready or failed", arguments: [
        (ACPDelegationPhase.creatingWorktree, true), (.starting, true), (.ready, false), (.failed, false), (.closed, false),
    ])
    func selectedChildHoldsPromptDispatch(phase: ACPDelegationPhase, holds: Bool) {
        var selected = child
        selected.phase = phase
        selected.modelSelection = ACPDelegatedModelSelection(model: "opus", reasoning: nil)
        var unselected = child
        unselected.phase = phase

        #expect(ACPSessionOrchestrationPolicy.holdsPromptDispatch(target: selected) == holds)
        #expect(!ACPSessionOrchestrationPolicy.holdsPromptDispatch(target: unselected))
    }

    @Test("list visibility contains only self and direct relatives")
    func visibility() {
        let sibling = ACPDelegationRecord(
            childSessionId: "other-child",
            parentSessionId: "parent",
            projectId: "project",
            parentWorktreeId: "parent-worktree",
            childWorktreeId: "other-worktree",
            agentId: "claude",
            worktreeRequest: .existing(worktreeId: "other-worktree"),
            pendingInitialPrompt: nil,
            phase: .ready,
            failureMessage: nil,
            createdAt: 30,
            updatedAt: 30
        )

        #expect(
            ACPSessionOrchestrationPolicy.visibleSessions(
                callerSessionId: "parent",
                parent: nil,
                children: [child, sibling]
            ).map(\.sessionId) == ["parent", "child", "other-child"]
        )
        #expect(
            ACPSessionOrchestrationPolicy.visibleSessions(
                callerSessionId: "child",
                parent: child,
                children: []
            ).map(\.sessionId) == ["child", "parent"]
        )
    }

    @Test("agent resolution inherits parent and rejects unavailable choices")
    func resolvesAgent() throws {
        let agents = [
            ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true),
            ACPOrchestrationAgent(id: "claude", isEnabled: false, isACPCapable: true),
            ACPOrchestrationAgent(id: "terminal", isEnabled: true, isACPCapable: false),
        ]

        let inherited = try ACPSessionOrchestrationPolicy.resolveAgent(
            requestedId: nil,
            parentAgentId: "codex",
            available: agents
        )
        #expect(inherited == "codex")
        #expect(throws: ACPSessionOrchestrationPolicy.Error.agentUnavailable("claude")) {
            _ = try ACPSessionOrchestrationPolicy.resolveAgent(
                requestedId: "claude",
                parentAgentId: "codex",
                available: agents
            )
        }
        #expect(throws: ACPSessionOrchestrationPolicy.Error.agentUnavailable("terminal")) {
            _ = try ACPSessionOrchestrationPolicy.resolveAgent(
                requestedId: "terminal",
                parentAgentId: "codex",
                available: agents
            )
        }
    }

    private static func agent(_ id: String, enabled: Bool = true) throws -> AgentDefinition {
        var agent = try #require(AgentBuiltins.entry(id: id))
        agent.isEnabled = enabled
        return agent
    }

    @Test("delegation discovery offers only enabled, installed ACP agents as candidates")
    func delegationAgentAvailability() throws {
        let custom = AgentDefinition(
            id: "custom-uuid", displayName: "Mine", binary: "mine", binaryOverride: nil,
            promptModeArgs: [], bypassPermissionsFlag: nil, extraTerminalArgs: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let claude = try Self.agent("claude")
        let configured = try [claude, Self.agent("codex"), Self.agent("gemini", enabled: false), custom]
        let remembered = [ACPAgentModelCatalog.Model(id: "opus", name: "Opus")]
        func discover(_ availability: AgentAvailabilityState) -> [ACPDelegationAgentSummary] {
            ACPSessionOrchestrationPolicy.delegationAgents(
                configured: configured,
                acpAgentIDs: ["claude", "codex", "gemini"],
                availability: availability,
                catalog: { _ in (remembered, .advertisedModels) }
            )
        }

        let local = discover(.available([claude, custom]))
        #expect(local.map(\.id) == ["claude", "codex", "gemini"])
        #expect(local.map(\.availability) == [.available, .notInstalled, .disabled])
        #expect(local.map(\.available) == [true, false, false])
        #expect(local.map(\.modelCatalog) == [
            ACPDelegationModelCatalog(state: .known, models: remembered),
            ACPDelegationModelCatalog(state: .unavailable, models: []),
            ACPDelegationModelCatalog(state: .unavailable, models: []),
        ])
        for pending in [AgentAvailabilityState.loading, .failed("ssh timed out")] {
            #expect(discover(pending).map(\.availability) == [.unknown, .unknown, .disabled])
        }
    }

    @Test("delegation discovery reports catalog state without inventing models", arguments: [
        (true, ACPAgentModelCatalog.LaunchReport.advertisedModels, ACPDelegationModelCatalogState.known, ACPDelegationModelSelection.supported),
        (true, .notObserved, .stale, .supported),
        (true, .advertisedNone, .stale, .supported),
        (false, .advertisedNone, .unsupported, .unsupported),
        (false, .notObserved, .notLoaded, .unknown),
    ])
    func delegationModelCatalogState(
        remembered: Bool,
        report: ACPAgentModelCatalog.LaunchReport,
        state: ACPDelegationModelCatalogState,
        selection: ACPDelegationModelSelection
    ) throws {
        let models = remembered ? [ACPAgentModelCatalog.Model(id: "flash", name: "Flash")] : []
        let agent = try Self.agent("gemini")
        let summary = try #require(ACPSessionOrchestrationPolicy.delegationAgents(
            configured: [agent],
            acpAgentIDs: ["gemini"],
            availability: .available([agent]),
            catalog: { _ in (models, report) }
        ).first)
        #expect(summary.modelCatalog == ACPDelegationModelCatalog(state: state, models: models))
        #expect(summary.modelSelection == selection)
    }

    @Test("delegation discovery encodes the documented v1 wire schema")
    func delegationDiscoveryWireSchema() throws {
        let response = ACPDelegationAgentListResponse(
            version: ACPDelegationAgentListResponse.currentVersion,
            callerAgentId: "claude",
            canDelegate: true,
            worktreeId: "wt-1",
            agents: [ACPDelegationAgentSummary(
                id: "gemini", displayName: "Gemini", available: false, availability: .notInstalled,
                modelSelection: .unknown, modelCatalog: ACPDelegationModelCatalog(state: .notLoaded, models: [])
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(response), as: UTF8.self)
        #expect(json == #"{"agents":[{"availability":"not_installed","available":false,"display_name":"Gemini","id":"gemini","model_catalog":{"models":[],"state":"not_loaded"},"model_selection":"unknown"}],"caller_agent_id":"claude","can_delegate":true,"version":1,"worktree_id":"wt-1"}"#)
    }

    @Test("spawn-time model check rejects only what this launch confirmed on the child's host", arguments: [
        // Known model, advertised on that host this launch.
        ("codex", "gpt-5.2", nil, ["gpt-5.2"], nil),
        // Unknown id against a list confirmed there.
        ("codex", "gpt-9", nil, ["gpt-5.2"],
         ACPDelegatedModelSelectionError.unknownModel(agentId: "codex", model: "gpt-9", available: ["gpt-5.2"])),
        // A live session there advertised no models.
        ("codex", "gpt-5.2", nil, [], .modelSelectionUnsupported(agentId: "codex")),
        // Nothing confirmed there (stale or another host's list): the live session decides.
        ("codex", "gpt-9", nil, nil, nil),
        // pi's thinking is a mode, not a config option.
        ("pi", nil, "high", nil, .reasoningUnsupported(agentId: "pi")),
        ("codex", nil, "high", nil, nil),
    ] as [(String, String?, String?, [String]?, ACPDelegatedModelSelectionError?)])
    func preflightModelSelection(
        agentId: String,
        model: String?,
        reasoning: String?,
        launchModels: [String]?,
        expected: ACPDelegatedModelSelectionError?
    ) throws {
        let selection = try #require(ACPDelegatedModelSelection(model: model, reasoning: reasoning))
        #expect(ACPSessionOrchestrationPolicy.preflightModelSelection(
            selection,
            agentId: agentId,
            launchModels: launchModels?.map { .init(id: $0, name: $0) }
        ) == expected)
    }

    @Test("an omitted model and reasoning is no selection at all")
    func omittedSelectionIsNil() {
        #expect(ACPDelegatedModelSelection(model: nil, reasoning: nil) == nil)
    }

    private func chip(_ source: ChipSpec.Source, _ ids: [String], current: String?) -> ChipSpec {
        ChipSpec(source: source, options: ids.map { .init(id: $0, name: $0, description: nil) }, currentId: current)
    }

    @Test("live model selection picks the advertised RPC and never guesses")
    func liveModelStep() throws {
        let policy = ACPSessionOrchestrationPolicy.self
        #expect(try policy.liveModelStep(model: "opus", agentId: "claude",
                                         chip: chip(.model, ["default", "opus"], current: "default")) == .setModel("opus"))
        #expect(try policy.liveModelStep(model: "gpt-5.2", agentId: "codex",
                                         chip: chip(.configOption(id: "model"), ["gpt-5.2", "gpt-5.1"], current: "gpt-5.1"))
                == .setConfigOption(id: "model", value: "gpt-5.2"))
        #expect(try policy.liveModelStep(model: "opus", agentId: "claude",
                                         chip: chip(.model, ["opus"], current: "opus")) == nil)
        #expect(throws: ACPDelegatedModelSelectionError.unknownModel(agentId: "claude", model: "gpt-5.2", available: ["opus"])) {
            try policy.liveModelStep(model: "gpt-5.2", agentId: "claude", chip: chip(.model, ["opus"], current: nil))
        }
        #expect(throws: ACPDelegatedModelSelectionError.modelSelectionUnsupported(agentId: "gemini")) {
            try policy.liveModelStep(model: "pro", agentId: "gemini", chip: nil)
        }
    }

    @Test("live reasoning selection requires an advertised config option")
    func liveReasoningStep() throws {
        let policy = ACPSessionOrchestrationPolicy.self
        #expect(try policy.liveReasoningStep(reasoning: "high", agentId: "codex",
                                             chip: chip(.configOption(id: "reasoning_effort"), ["low", "high"], current: "low"))
                == .setConfigOption(id: "reasoning_effort", value: "high"))
        #expect(throws: ACPDelegatedModelSelectionError.reasoningUnsupported(agentId: "pi")) {
            try policy.liveReasoningStep(reasoning: "high", agentId: "pi", chip: chip(.mode, ["high"], current: nil))
        }
        #expect(throws: ACPDelegatedModelSelectionError.reasoningUnsupported(agentId: "cursor-agent")) {
            try policy.liveReasoningStep(reasoning: "high", agentId: "cursor-agent", chip: chip(.model, ["high"], current: nil))
        }
        #expect(throws: ACPDelegatedModelSelectionError.unknownReasoning(agentId: "codex", reasoning: "max", available: ["low", "high"])) {
            try policy.liveReasoningStep(reasoning: "max", agentId: "codex",
                                         chip: chip(.configOption(id: "reasoning_effort"), ["low", "high"], current: nil))
        }
    }

    @Test("prompt validation rejects blank text")
    func promptValidation() throws {
        let prompt = try ACPSessionOrchestrationPolicy.validatedPrompt("  Task\n")
        #expect(prompt == "Task")
        #expect(throws: ACPSessionOrchestrationPolicy.Error.blankPrompt) {
            _ = try ACPSessionOrchestrationPolicy.validatedPrompt(" \n\t ")
        }
    }

    @Test("projects persisted and runtime state into the public states")
    func publicStateProjection() {
        #expect(ACPOrchestrationPublicState.creatingWorktree.rawValue == "creating_worktree")
        #expect(ACPOrchestrationPublicState.awaitingInput.rawValue == "awaiting_input")
        #expect(ACPSessionOrchestrationPolicy.publicState(
            phase: .creatingWorktree,
            runtime: nil,
            archived: false
        ) == .creatingWorktree)
        #expect(ACPSessionOrchestrationPolicy.publicState(
            phase: .starting,
            runtime: .idle,
            archived: false
        ) == .starting)
        #expect(ACPSessionOrchestrationPolicy.publicState(
            phase: .ready,
            runtime: .running,
            archived: false
        ) == .running)
        #expect(ACPSessionOrchestrationPolicy.publicState(
            phase: .ready,
            runtime: .awaitingInput,
            archived: false
        ) == .awaitingInput)
        #expect(ACPSessionOrchestrationPolicy.publicState(
            phase: .ready,
            runtime: .idle,
            archived: false
        ) == .idle)
        #expect(ACPSessionOrchestrationPolicy.publicState(
            phase: .failed,
            runtime: .running,
            archived: false
        ) == .failed)
        #expect(ACPSessionOrchestrationPolicy.publicState(
            phase: .ready,
            runtime: .idle,
            archived: true
        ) == .closed)
    }

    @Test("only a direct parent in the same project may wait on or interrupt a child", arguments: [
        ("parent", "project", true, nil),
        ("child", "project", false, ACPSessionOrchestrationPolicy.Error.targetIsNotDirectRelative),
        ("sibling", "project", true, .targetIsNotDirectRelative),
        ("parent", "other-project", true, .crossProjectTarget),
    ])
    func childControlAuthorization(
        caller: String, project: String, targetIsChild: Bool,
        expected: ACPSessionOrchestrationPolicy.Error?
    ) {
        // A child addressing its parent finds no delegation record for it.
        let result = ACPSessionOrchestrationPolicy.authorizeChildControl(
            callerSessionId: caller, callerProjectId: project, target: targetIsChild ? child : nil
        )
        switch result {
        case .success: #expect(expected == nil)
        case .failure(let error): #expect(error == expected)
        }
    }

    @Test("a wait settles once a child has no turn running, starting, or queued", arguments: [
        (ACPDelegationPhase.starting, ACPOrchestrationRuntimeState?.none, false, false),
        (.ready, .running, false, false),
        (.ready, .idle, true, false),
        (.ready, .none, true, false),
        (.ready, .idle, false, true),
        (.ready, .awaitingInput, true, true),
        (.failed, .none, true, true),
        (.closed, .running, false, true),
    ])
    func waitSettled(
        phase: ACPDelegationPhase, runtime: ACPOrchestrationRuntimeState?, pending: Bool, settled: Bool
    ) {
        #expect(ACPSessionOrchestrationPolicy.waitSettled(
            phase: phase, runtime: runtime, hasPendingPrompts: pending
        ) == settled)
    }

    @Test("completed turn that reported to the parent only notices")
    func completedReportedNotices() {
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: .completed, lastParentReportAt: 120, turnStartedAt: 100) == .notice)
    }

    @Test("completed turn without a report wakes the parent")
    func completedUnreportedWakes() {
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: .completed, lastParentReportAt: nil, turnStartedAt: 100) == .wake)
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: .completed, lastParentReportAt: 99, turnStartedAt: 100) == .wake)
    }

    @Test("a report at the exact turn start counts as reported")
    func reportAtTurnStartCounts() {
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: .completed, lastParentReportAt: 100, turnStartedAt: 100) == .notice)
    }

    @Test("failed turn always wakes; cancelled and usage-limited turns only notice")
    func failedWakesCancelledNotices() {
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: .failed("boom"), lastParentReportAt: 500, turnStartedAt: 100) == .wake)
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: .cancelled, lastParentReportAt: nil, turnStartedAt: 100) == .notice)
        // A limited child resumes on its own; the parent shouldn't burn a turn.
        #expect(ACPSessionOrchestrationPolicy.outcomeDisposition(
            result: .limited, lastParentReportAt: nil, turnStartedAt: 0) == .notice)
    }

    private static func head(
        status: QueuedPrompt.Status = .pending,
        dispatched: Bool = false,
        lastError: String? = nil,
        uncertain: Bool = false,
        scheduled: Bool = false
    ) -> QueuedPrompt {
        QueuedPrompt(
            blocks: [.text("report back")],
            scheduledAt: scheduled ? Date(timeIntervalSince1970: 1) : nil,
            status: status,
            lastError: lastError ?? (uncertain ? QueuedPrompt.deliveryUncertaintyMessage : nil),
            transcriptRecorded: status == .sending || dispatched,
            dispatchedBrokerGeneration: dispatched ? ACPBrokerGeneration(rawValue: 7) : nil,
            deliveryUncertain: uncertain
        )
    }

    @Test("startup re-attaches a ready child only while its queue head is still owed to the parent", arguments: [
        (ACPDelegationPhase.ready, head(status: .sending, dispatched: true) as QueuedPrompt?, true),
        (.ready, head(dispatched: true), true),
        (.ready, head(), true),
        (.ready, head(uncertain: true), true),
        (.ready, head(lastError: "Rate limited"), false),
        (.ready, head(scheduled: true), false),
        (.ready, nil, false),
        (.failed, head(status: .sending, dispatched: true), false),
    ])
    func restartAttachFollowsTheQueueHead(phase: ACPDelegationPhase, head: QueuedPrompt?, expected: Bool) {
        #expect(ACPSessionOrchestrationPolicy.needsRestartAttach(phase: phase, queueHead: head) == expected)
    }

    @Test("after a restart, a turn is lost only if its child cannot resume it")
    func restartedTurnLoss() {
        #expect(ACPSessionOrchestrationPolicy.restartedTurnLoss(
            attachFailure: nil, queueHead: Self.head(dispatched: true)) == nil)
        #expect(ACPSessionOrchestrationPolicy.restartedTurnLoss(attachFailure: nil, queueHead: nil) == nil)
        #expect(ACPSessionOrchestrationPolicy.restartedTurnLoss(
            attachFailure: nil, queueHead: Self.head(uncertain: true)) != nil)
        let failure = ACPSessionOrchestrationPolicy.restartedTurnLoss(
            attachFailure: "Codex needs authentication.", queueHead: Self.head(dispatched: true))
        #expect(failure?.hasSuffix("Codex needs authentication.") == true)
    }

    private func blocker(_ key: String = "n42") -> ACPChildBlocker {
        .init(sessionId: "child", requestKey: key, kind: .permission, summary: "Write file")
    }

    @Test("escalates only while the same request is still blocked")
    func escalatesOnlyForTheSameRequest() {
        #expect(ACPSessionOrchestrationPolicy.escalation(
            blocker: blocker(), liveBlockedRequestKeys: ["n42"]) == .wake)
        #expect(ACPSessionOrchestrationPolicy.escalation(
            blocker: blocker(), liveBlockedRequestKeys: ["n42", "u123"]) == .wake)
    }

    @Test("does not escalate once the request is resolved")
    func doesNotEscalateWhenResolved() {
        #expect(ACPSessionOrchestrationPolicy.escalation(
            blocker: blocker(), liveBlockedRequestKeys: []) == .stillHandled)
    }

    @Test("a different pending request is not proof the original still blocks")
    func differentKeyDoesNotEscalate() {
        // The child cleared n42 and is now blocked on something else. Waking
        // about n42 would tell the parent the wrong thing.
        #expect(ACPSessionOrchestrationPolicy.escalation(
            blocker: blocker(), liveBlockedRequestKeys: ["n99"]) == .stillHandled)
    }
}
