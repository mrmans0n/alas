import AlasRemoteKit
import Testing

struct RemoteSessionRecapTests {
    @Test func keepsTheNewestMessagesThatFitOldestFirst() throws {
        let rows: [RemoteTranscriptRow] = [
            .user(String(repeating: "a", count: 400), checkpointID: nil),
            .toolCall(ACPToolCall(toolCallId: "t", title: "ls", status: "completed")),
            .agent("second"),
            .plan([ACPPlanItem(content: "ship", status: "in_progress")]),
            .user("third", checkpointID: nil),
        ]
        let prompt = try #require(RemoteSessionRecap.prompt(rows: rows, goal: "Land it", byteLimit: 120))
        #expect(prompt == "Goal: Land it\n\nPlan:\n- [in_progress] ship\n\n(Earlier messages omitted.)\n\nAgent: second\n\nUser: third")
        #expect(RemoteSessionRecap.prompt(rows: [.thought("hmm")], goal: "g") == nil)
    }
}
