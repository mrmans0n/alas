import Foundation
import Testing
@testable import Alas

@Suite("ACP session/update")
struct ACPSessionUpdateTests {
    @Test("decodes agent message chunk")
    func agentChunk() throws {
        let env = try decode("session-update-agent-chunk")
        if case .agentMessageChunk(let block) = env.params!.update {
            if case .text(let s) = block { #expect(s == "hello ") } else { Issue.record("expected text") }
        } else { Issue.record("expected agentMessageChunk") }
    }

    @Test("decodes tool call (initial)")
    func toolCall() throws {
        let env = try decode("session-update-tool-call")
        if case .toolCall(let tc) = env.params!.update {
            #expect(tc.toolCallId == "tc-1")
            #expect(tc.title == "read_file")
            #expect(tc.status == "in_progress")
        } else { Issue.record("expected toolCall") }
    }

    @Test("decodes plan update")
    func plan() throws {
        let env = try decode("session-update-plan")
        if case .plan(let entries) = env.params!.update {
            #expect(entries.count == 2)
            #expect(entries[1].status == "in_progress")
        } else { Issue.record("expected plan") }
    }

    @Test("decodes available_models_update")
    func availableModels() throws {
        let env = try decode("session-update-available-models")
        if case .availableModelsUpdate(let models) = env.params!.update {
            #expect(models.count == 2)
            #expect(models[0].id == "opus")
        } else { Issue.record("expected availableModelsUpdate") }
    }

    private func decode(_ name: String) throws -> JSONRPCEnvelope<ACPSessionUpdateParams> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(JSONRPCEnvelope<ACPSessionUpdateParams>.self,
                                        from: try Data(contentsOf: url))
    }
}
