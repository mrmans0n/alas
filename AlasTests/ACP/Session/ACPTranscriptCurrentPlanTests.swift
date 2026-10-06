import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript.currentPlan")
struct ACPTranscriptCurrentPlanTests {
    private func makeSession(agentId: String = "claude") -> ACPSession {
        ACPSession(id: "s1", agentId: agentId, worktreeId: "wt", title: "t")
    }

    @Test("only matching OMP reminders retain the full todo snapshot", arguments: ["omp", "codex"], [true, false])
    func reminderRetainsCanonicalTodosOnlyForOMP(agentId: String, matchesSnapshot: Bool) throws {
        let session = makeSession(agentId: agentId)
        let snapshot = try JSONDecoder().decode(AnyCodable.self, from: Data(#"""
            {"details":{"storage":"session","op":"done","phases":[{"name":"Work","tasks":[
                {"content":"Implement","status":"completed"},
                {"content":"Old approach","status":"abandoned"},
                {"content":"Credentials","status":"blocked"},
                {"content":"Review","status":"in_progress"}
            ]}]}}
            """#.utf8))
        let fullPlan: [ACPPlanEntry] = [
            .init(content: "Implement", priority: "medium", status: "completed"),
            .init(content: "Old approach", priority: "medium", status: "completed"),
            .init(content: "Credentials", priority: "medium", status: "pending"),
            .init(content: "Review", priority: "medium", status: "in_progress")
        ]
        session.apply(.userMessageChunk(.text("Go")))
        session.apply(.toolCall(.init(
            toolCallId: "todo", title: "Update the checklist", kind: "think", status: "in_progress")))
        session.apply(.toolCallUpdate(.init(toolCallId: "todo", status: "completed", rawOutput: snapshot)))
        session.apply(.plan(fullPlan))
        let reminder = matchesSnapshot ? fullPlan[3] : ACPPlanEntry(
            content: "Different work", priority: "medium", status: "in_progress")
        session.apply(.plan([reminder]))

        let expected = agentId == "omp" && matchesSnapshot ? fullPlan : [reminder]
        #expect(session.transcript.currentPlan == expected.map {
            ACPMessage.PlanItem(content: $0.content, status: $0.status)
        })
    }

    @Test("OMP accepts todo removals and plan clearing", arguments: [false, true])
    func deliberateTodoRemovalReplacesThePlan(clear: Bool) throws {
        let session = makeSession(agentId: "omp")
        session.apply(.userMessageChunk(.text("Go")))
        session.apply(.plan([
            .init(content: "Implement", priority: "medium", status: "completed"),
            .init(content: "Review", priority: "medium", status: "in_progress")
        ]))
        let taskJSON = clear ? "[]" : #"[{"content":"Review","status":"in_progress"}]"#
        let snapshot = try JSONDecoder().decode(AnyCodable.self, from: Data("""
            {"details":{"storage":"session","op":"rm","phases":[{"name":"Work","tasks":\(taskJSON)}]}}
            """.utf8))
        session.apply(.toolCall(.init(
            toolCallId: "remove", title: "Remove tasks", kind: "think", status: "completed", rawOutput: snapshot)))
        let entries: [ACPPlanEntry] = clear ? [] : [
            .init(content: "Review", priority: "medium", status: "in_progress")
        ]
        session.apply(.plan(entries))

        #expect(session.transcript.currentPlan == entries.map {
            ACPMessage.PlanItem(content: $0.content, status: $0.status)
        })
    }

    @Test("OMP does not restore completed tasks from an earlier turn")
    func earlierTodoSnapshotDoesNotOverrideNewTurn() throws {
        let session = makeSession(agentId: "omp")
        let snapshot = try JSONDecoder().decode(AnyCodable.self, from: Data(#"""
            {"details":{"storage":"session","phases":[{"tasks":[
                {"content":"Implement","status":"completed"},
                {"content":"Review","status":"in_progress"}
            ]}]}}
            """#.utf8))
        session.apply(.toolCall(.init(
            toolCallId: "old-todo", title: "todo", kind: "think", status: "completed", rawOutput: snapshot)))
        session.apply(.userMessageChunk(.text("Review")))
        session.apply(.plan([.init(content: "Review", priority: "medium", status: "in_progress")]))

        #expect(session.transcript.currentPlan == [.init(content: "Review", status: "in_progress")])
    }

    @Test("OMP does not fall back to an older todo result when the latest is unusable", arguments: [
        "{}",
        #"{"details":{"storage":"unknown","phases":[{"tasks":[{"content":"Review","status":"in_progress"}]}]}}"#,
        #"{"details":{"storage":"session","phases":[{"tasks":[{"content":"Implement","status":"unknown"},{"content":"Review","status":"in_progress"}]}]}}"#
    ])
    func unusableLatestTodoDoesNotReviveOldTasks(rawOutput: String) {
        let session = makeSession(agentId: "omp")
        session.transcript.replaceMessages(with: [
            .user(id: UUID(), text: "Go", attachments: []),
            .toolCall(.init(toolCallId: "old", title: "todo", kind: "think", status: "completed", rawOutput: #"""
                {"details":{"storage":"session","phases":[{"tasks":[
                    {"content":"Implement","status":"completed"},{"content":"Review","status":"in_progress"}
                ]}]}}
                """#)),
            .toolCall(.init(
                toolCallId: "latest", title: "todo", kind: "think", status: "completed", rawOutput: rawOutput))
        ])
        session.apply(.plan([.init(content: "Review", priority: "medium", status: "in_progress")]))

        #expect(session.transcript.currentPlan == [.init(content: "Review", status: "in_progress")])
    }

    @Test("returns nil when no plan message has arrived")
    func nilWhenNoPlan() {
        let session = makeSession()
        session.transcript.messages = [
            .agent(id: UUID(), StreamingText("hi")),
            .user(id: UUID(), text: "hello", attachments: [])
        ]
        #expect(session.transcript.currentPlan == nil)
    }

    @Test("returns the items of the current turn's latest plan message")
    func currentTurnLatestPlanItems() {
        let session = makeSession()
        let firstItems = [ACPMessage.PlanItem(content: "a", status: "completed")]
        let secondItems = [
            ACPMessage.PlanItem(content: "x", status: "completed"),
            ACPMessage.PlanItem(content: "y", status: "in_progress")
        ]
        session.transcript.messages = [
            .plan(id: UUID(), firstItems),
            .agent(id: UUID(), StreamingText("between")),
            .plan(id: UUID(), secondItems),
            .agent(id: UUID(), StreamingText("after"))
        ]
        #expect(session.transcript.currentPlan == secondItems)
    }

    @Test("returns empty array for an empty plan items array")
    func emptyPlanItems() {
        let session = makeSession()
        session.transcript.messages = [.plan(id: UUID(), [])]
        #expect(session.transcript.currentPlan == [])
    }

    @Test("returns nil after a new user prompt follows the previous plan")
    func nilAfterNewUserPromptFollowsPlan() {
        let session = makeSession()
        let previousTurnItems = [
            ACPMessage.PlanItem(content: "old step", status: "completed")
        ]
        session.transcript.messages = [
            .user(id: UUID(), text: "first prompt", attachments: []),
            .plan(id: UUID(), previousTurnItems),
            .agent(id: UUID(), StreamingText("done with turn 1")),
            .user(id: UUID(), text: "second prompt", attachments: [])
        ]
        // The previous turn's plan must not leak into the new turn.
        #expect(session.transcript.currentPlan == nil)
    }

    @Test("returns the current turn's plan when it sits after the latest user prompt")
    func returnsCurrentTurnPlan() {
        let session = makeSession()
        let previousTurnItems = [ACPMessage.PlanItem(content: "old", status: "completed")]
        let currentTurnItems = [ACPMessage.PlanItem(content: "new", status: "in_progress")]
        session.transcript.messages = [
            .user(id: UUID(), text: "first", attachments: []),
            .plan(id: UUID(), previousTurnItems),
            .user(id: UUID(), text: "second", attachments: []),
            .plan(id: UUID(), currentTurnItems)
        ]
        #expect(session.transcript.currentPlan == currentTurnItems)
    }

    @Test("apply(.plan) appends a fresh plan when the previous one belongs to an earlier turn")
    func applyAppendsAfterNewUserPrompt() {
        let session = makeSession()
        let previousTurnItems = [ACPMessage.PlanItem(content: "old", status: "completed")]
        session.transcript.messages = [
            .user(id: UUID(), text: "first", attachments: []),
            .plan(id: UUID(), previousTurnItems),
            .user(id: UUID(), text: "second", attachments: [])
        ]
        let newEntries = [ACPPlanEntry(content: "new", priority: nil, status: "in_progress")]
        session.apply(.plan(newEntries))
        // Previous turn's plan stays at index 1; the new one is appended.
        #expect(session.transcript.messages.count == 4)
        if case .plan(_, let firstItems) = session.transcript.messages[1] {
            #expect(firstItems == previousTurnItems)
        } else {
            Issue.record("expected previous turn's plan at index 1")
        }
        if case .plan(_, let latestItems) = session.transcript.messages.last {
            #expect(latestItems == [ACPMessage.PlanItem(content: "new", status: "in_progress")])
        } else {
            Issue.record("expected new plan appended at end")
        }
        #expect(session.transcript.currentPlan == [ACPMessage.PlanItem(content: "new", status: "in_progress")])
    }

    @Test("apply(.plan) overwrites in place while the current turn's plan progresses")
    func applyOverwritesWithinSameTurn() {
        let session = makeSession()
        let planId = UUID()
        session.transcript.messages = [
            .user(id: UUID(), text: "go", attachments: []),
            .plan(id: planId, [ACPMessage.PlanItem(content: "step", status: "pending")])
        ]
        let progress = [ACPPlanEntry(content: "step", priority: nil, status: "in_progress")]
        session.apply(.plan(progress))
        // No new user prompt → same plan slot updates in place, id preserved.
        #expect(session.transcript.messages.count == 2)
        if case .plan(let id, let items) = session.transcript.messages[1] {
            #expect(id == planId)
            #expect(items == [ACPMessage.PlanItem(content: "step", status: "in_progress")])
        } else {
            Issue.record("expected plan message at index 1")
        }
        #expect(session.transcript.currentPlan == [ACPMessage.PlanItem(content: "step", status: "in_progress")])
    }

    @Test("production tool-call updates do not rebuild plan caches")
    func toolCallUpdatesDoNotRebuildPlanCaches() {
        let transcript = ACPTranscript()
        let planItems = [ACPMessage.PlanItem(content: "step", status: "in_progress")]
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "tool",
            title: "Read",
            status: "in_progress",
            content: "",
            preview: "",
            locations: []
        )
        transcript.replaceMessages(with: [
            .user(id: UUID(), text: "go", attachments: []),
            .plan(id: UUID(), planItems),
            .toolCall(toolCall)
        ])
        let rebuildCount = transcript.planCacheRebuildCountForTests

        for update in 0..<100 {
            toolCall.content = "update \(update)"
            transcript.replaceMessage(at: 2, with: .toolCall(toolCall))
        }

        let updatedPlanItems = [ACPMessage.PlanItem(content: "step", status: "completed")]
        transcript.replaceMessage(at: 1, with: .plan(id: UUID(), updatedPlanItems))

        #expect(transcript.planCacheRebuildCountForTests == rebuildCount)
        #expect(transcript.currentPlan == updatedPlanItems)
    }
}
