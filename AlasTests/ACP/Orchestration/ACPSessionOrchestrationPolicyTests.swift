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
        #expect(ACPSessionOrchestrationPolicy.authorizeCreate(parent: nil) == .success(()))
        #expect(
            ACPSessionOrchestrationPolicy.authorizeCreate(parent: child)
                == .failure(.delegatedSessionCannotCreateChild)
        )
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
    func resolvesAgent() {
        let agents = [
            ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true),
            ACPOrchestrationAgent(id: "claude", isEnabled: false, isACPCapable: true),
            ACPOrchestrationAgent(id: "terminal", isEnabled: true, isACPCapable: false),
        ]

        #expect(try ACPSessionOrchestrationPolicy.resolveAgent(
            requestedId: nil,
            parentAgentId: "codex",
            available: agents
        ) == "codex")
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

    @Test("prompt validation rejects blank text")
    func promptValidation() {
        #expect(try ACPSessionOrchestrationPolicy.validatedPrompt("  Task\n") == "Task")
        #expect(throws: ACPSessionOrchestrationPolicy.Error.blankPrompt) {
            _ = try ACPSessionOrchestrationPolicy.validatedPrompt(" \n\t ")
        }
    }

    @Test("projects persisted and runtime state into the public states")
    func publicStateProjection() {
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
}
