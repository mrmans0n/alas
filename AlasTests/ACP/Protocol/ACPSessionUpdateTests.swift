import Foundation
import Testing
@testable import Alas

@Suite("ACP session/update")
struct ACPSessionUpdateTests {
    @Test("decodes agent message chunk")
    func agentChunk() throws {
        let env = try decode("session-update-agent-chunk")
        if case .agentMessageChunk(let chunk) = env.params!.update {
            if case .text(let s) = chunk.content { #expect(s == "hello ") } else { Issue.record("expected text") }
        } else { Issue.record("expected agentMessageChunk") }
    }

    @Test("decodes messageId on text chunks")
    func textChunkMessageId() throws {
        let json = """
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "s1",
            "update": {
              "sessionUpdate": "agent_message_chunk",
              "messageId": "msg-agent-1",
              "content": { "type": "text", "text": "hello" }
            }
          }
        }
        """
        let env = try JSONDecoder().decode(
            JSONRPCEnvelope<ACPSessionUpdateParams>.self,
            from: Data(json.utf8))
        if case .agentMessageChunk(let chunk) = env.params!.update {
            #expect(chunk.messageId == "msg-agent-1")
            #expect(chunk.content == .text("hello"))
        } else {
            Issue.record("expected agentMessageChunk")
        }
    }

    @Test("preserves chunk metadata and recognizes Codex phases")
    func chunkMetadataAndPhase() throws {
        let json = """
        {
          "sessionUpdate": "agent_message_chunk",
          "messageId": "commentary-1",
          "content": { "type": "text", "text": "Working" },
          "_meta": {
            "codex": { "phase": "commentary", "future": true },
            "adapter": { "trace": "kept" }
          }
        }
        """
        let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
        guard case .agentMessageChunk(let chunk) = update else {
            Issue.record("expected agentMessageChunk")
            return
        }

        #expect(chunk.phase == .commentary)
        let metadata = try #require(chunk.metadata?.value as? [String: AnyCodable])
        #expect((metadata["adapter"]?.value as? [String: AnyCodable])?["trace"]?.value as? String == "kept")
        let encoded = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(ACPSessionUpdate.self, from: encoded)
        #expect(decoded == update)

        let chunks: [ACPSessionUpdate] = [
            .userMessageChunk(.init(messageId: "user-1", content: .text("prompt"), metadata: chunk.metadata)),
            .agentMessageChunk(chunk),
            .agentThoughtChunk(.init(messageId: "thought-1", content: .text("thinking"), metadata: chunk.metadata))
        ]
        for chunkUpdate in chunks {
            let roundTripped = try JSONDecoder().decode(
                ACPSessionUpdate.self,
                from: JSONEncoder().encode(chunkUpdate))
            #expect(roundTripped == chunkUpdate)
        }
    }

    @Test("unknown and missing chunk phases use the compatibility fallback")
    func unknownChunkPhase() throws {
        let unknown = ACPTextChunk(
            messageId: "agent-1",
            content: .text("answer"),
            metadata: AnyCodable(["codex": AnyCodable(["phase": AnyCodable("future_phase")])]))
        #expect(unknown.phase == nil)
        #expect(ACPTextChunk(content: .text("answer")).phase == nil)
    }

    @Test("decodes tool call (initial)")
    func toolCall() throws {
        let env = try decode("session-update-tool-call")
        if case .toolCall(let tc) = env.params!.update {
            #expect(tc.toolCallId == "tc-1")
            #expect(tc.title == "read_file")
            #expect(tc.status == "in_progress")
            #expect(tc.metadata == nil)
            #expect(tc.content?.count == 1)
            if case .content(.text(let s)) = tc.content?.first {
                #expect(s == "reading…")
            } else { Issue.record("expected wrapped text content") }
        } else { Issue.record("expected toolCall") }
    }

    @Test("decodes session_info_update with metadata")
    func sessionInfoUpdate() throws {
        let env = try decode("session-update-session-info-goal")
        guard case .sessionInfoUpdate(let info) = env.params!.update else {
            Issue.record("expected sessionInfoUpdate")
            return
        }
        #expect(info.title == .value("Investigate ACP events"))
        let meta = try #require(info.metadata?.value as? [String: AnyCodable])
        let codex = try #require(meta["codex"]?.value as? [String: AnyCodable])
        let goal = try #require(codex["goal"]?.value as? [String: AnyCodable])
        #expect(goal["objective"]?.value as? String == "Surface richer ACP events")
        #expect(goal["status"]?.value as? String == "in_progress")
        #expect(goal["tokenBudget"]?.value as? Int == 12000)
    }

    @Test("decodes session_info_update without metadata")
    func sessionInfoUpdateWithoutMetadata() throws {
        let env = try decode("session-update-session-info-no-meta")
        guard case .sessionInfoUpdate(let info) = env.params!.update else {
            Issue.record("expected sessionInfoUpdate")
            return
        }
        #expect(info.title == .value("Title only"))
        #expect(info.metadata == nil)
    }

    @Test("decodes tool call metadata")
    func toolCallMetadata() throws {
        let env = try decode("session-update-tool-call-meta")
        guard case .toolCall(let tc) = env.params!.update else {
            Issue.record("expected toolCall")
            return
        }
        #expect(tc.toolCallId == "cmd-1")
        #expect(tc.metadata != nil)
        let meta = try #require(tc.metadata?.value as? [String: AnyCodable])
        let terminalInfo = try #require(meta["terminal_info"]?.value as? [String: AnyCodable])
        #expect(terminalInfo["terminal_id"]?.value as? String == "cmd-1")
        #expect(terminalInfo["cwd"]?.value as? String == "/repo")
    }

    @Test("decodes tool call update metadata and mutable fields")
    func toolCallUpdateMetadata() throws {
        let env = try decode("session-update-tool-call-update-meta")
        guard case .toolCallUpdate(let update) = env.params!.update else {
            Issue.record("expected toolCallUpdate")
            return
        }
        #expect(update.toolCallId == "cmd-1")
        #expect(update.title == "swift test --filter ACP")
        #expect(update.locations?.first?.path == "AlasTests/ACP/Session/ACPSessionTests.swift")
        #expect(update.locations?.first?.line == 12)
        let rawInput = try #require(update.rawInput?.value as? [String: AnyCodable])
        #expect(rawInput["command"]?.value as? String == "swift test --filter ACP")
        let rawOutput = try #require(update.rawOutput?.value as? [String: AnyCodable])
        #expect(rawOutput["exit_code"]?.value as? Int == 0)
        let meta = try #require(update.metadata?.value as? [String: AnyCodable])
        let outputDelta = try #require(meta["terminal_output_delta"]?.value as? [String: AnyCodable])
        #expect(outputDelta["terminal_id"]?.value as? String == "cmd-1")
        #expect(outputDelta["data"]?.value as? String == "ok\n")
        let terminalExit = try #require(meta["terminal_exit"]?.value as? [String: AnyCodable])
        #expect(terminalExit["terminal_id"]?.value as? String == "cmd-1")
        #expect(terminalExit["exit_code"]?.value as? Int == 0)
        let signal = terminalExit["signal"]?.value
        #expect(signal == nil || signal is NSNull)
    }

    @Test("decodes legacy tool call update without metadata")
    func toolCallUpdateNoMetadata() throws {
        let env = try decode("session-update-tool-call-update-no-meta")
        guard case .toolCallUpdate(let update) = env.params!.update else {
            Issue.record("expected toolCallUpdate")
            return
        }
        #expect(update.toolCallId == "cmd-legacy")
        #expect(update.title == "read_file")
        #expect(update.status == "completed")
        #expect(update.locations?.first?.path == "AlasTests/ACP/Protocol/ACPSessionUpdateTests.swift")
        #expect(update.locations?.first?.line == 7)
        #expect(update.content?.count == 1)
        #expect(update.rawInput != nil)
        #expect(update.rawOutput != nil)
        #expect(update.metadata == nil)
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

    @Test("decodes current_model_update")
    func currentModel() throws {
        let env = try decode("session-update-current-model")
        if case .currentModelUpdate(let modelId) = env.params!.update {
            #expect(modelId == "opus")
        } else { Issue.record("expected currentModelUpdate") }
    }

    @Test("decodes session_config_options_update")
    func configOptions() throws {
        let env = try decode("session-update-config-options")
        if case .sessionConfigOptionsUpdate(let opts) = env.params!.update {
            #expect(opts.count == 1)
            #expect(opts[0].id == "effort")
            #expect(opts[0].currentValue == .string("high"))
        } else { Issue.record("expected sessionConfigOptionsUpdate") }
    }

    @Test("decodes config_option_update (canonical spec discriminator)")
    func configOptionCanonical() throws {
        let env = try decode("session-update-config-option")
        if case .sessionConfigOptionsUpdate(let opts) = env.params!.update {
            #expect(opts.count == 1)
            #expect(opts[0].id == "effort")
            #expect(opts[0].options.first?.id == "low")
        } else { Issue.record("expected sessionConfigOptionsUpdate") }
    }

    @Test("decodes available_commands_update with argument hint")
    func availableCommandsHint() throws {
        let json = """
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "s1",
            "update": {
              "sessionUpdate": "available_commands_update",
              "availableCommands": [
                { "name": "review", "description": "Review a PR",
                  "input": { "hint": "<pr-number>" } },
                { "name": "init", "description": "Initialize" }
              ]
            }
          }
        }
        """
        let env = try JSONDecoder().decode(
            JSONRPCEnvelope<ACPSessionUpdateParams>.self, from: Data(json.utf8))
        guard case .availableCommandsUpdate(let cmds) = env.params!.update else {
            Issue.record("expected availableCommandsUpdate")
            return
        }
        #expect(cmds.count == 2)
        #expect(cmds[0].command == "/review")
        #expect(cmds[0].hint == "<pr-number>")
        #expect(cmds[1].command == "/init")
        #expect(cmds[1].hint == nil)
    }

    @Test("tolerates malformed command input without dropping the update")
    func availableCommandsMalformedInput() throws {
        let json = """
        {
          "jsonrpc": "2.0",
          "method": "session/update",
          "params": {
            "sessionId": "s1",
            "update": {
              "sessionUpdate": "available_commands_update",
              "availableCommands": [
                { "name": "a", "description": "A", "input": {} },
                { "name": "b", "description": "B", "input": "nope" },
                { "name": "c", "description": "C" }
              ]
            }
          }
        }
        """
        let env = try JSONDecoder().decode(
            JSONRPCEnvelope<ACPSessionUpdateParams>.self, from: Data(json.utf8))
        guard case .availableCommandsUpdate(let cmds) = env.params!.update else {
            Issue.record("expected availableCommandsUpdate")
            return
        }
        #expect(cmds.count == 3)
        #expect(cmds.allSatisfy { $0.hint == nil })
    }

    @Test("decodes Codex version 1 context compaction metadata")
    func codexContextCompactionMetadata() throws {
        let env = try decode("session-update-context-compaction-running")
        guard case .toolCall(let toolCall) = env.params?.update,
              let compaction = ACPContextCompaction(toolCall: .init(
                toolCallId: toolCall.toolCallId,
                title: toolCall.title,
                kind: toolCall.kind,
                status: toolCall.status,
                metadata: toolCall.metadata
              )) else {
            Issue.record("expected a normalized context compaction")
            return
        }

        #expect(compaction.id == "codex-compact-1")
        #expect(compaction.status == .inProgress)
        #expect(compaction.trigger == "automatic")
        #expect(compaction.tokensBefore == nil)
        #expect(compaction.tokensAfter == nil)
        #expect(compaction.durationMs == nil)
    }

    @Test("decodes completed and failed Codex compaction metadata without fabricated values")
    func codexCompactionCompletionStates() throws {
        let completed = try toolCallCompaction(
            id: "compact-completed",
            status: "completed",
            facts: "\"trigger\": \"manual\", \"preTokens\": 120000, \"postTokens\": 18000, \"durationMs\": 840")
        let failed = try toolCallCompaction(
            id: "compact-failed",
            status: "failed",
            facts: "\"error\": \"compaction timed out\"")

        #expect(completed.status == .completed)
        #expect(completed.trigger == "manual")
        #expect(completed.tokensBefore == 120_000)
        #expect(completed.tokensAfter == 18_000)
        #expect(completed.durationMs == 840)
        #expect(failed.status == .failed)
        #expect(failed.error == "compaction timed out")
        #expect(failed.tokensBefore == nil)
        #expect(failed.tokensAfter == nil)
        #expect(failed.durationMs == nil)
    }

    @Test("decodes documented context compaction metadata variants")
    func codexContextCompactionMetadataVariants() throws {
        let expectations: [(String, ACPContextCompaction.Status, Int?, Int?, Int?, String?)] = [
            ("session-update-context-compaction-completed", .completed, 128_000, 16_000, 950, nil),
            ("session-update-context-compaction-failed", .failed, nil, nil, nil, "Context limit exceeded"),
            ("session-update-context-compaction-partial", .completed, 128_000, nil, nil, nil),
            ("session-update-context-compaction-unknown", .completed, nil, nil, nil, nil)
        ]

        for (fixture, status, before, after, duration, error) in expectations {
            let env = try decode(fixture)
            guard case .toolCall(let toolCall) = env.params?.update,
                  let compaction = ACPContextCompaction(toolCall: .init(
                    toolCallId: toolCall.toolCallId,
                    title: toolCall.title,
                    kind: toolCall.kind,
                    status: toolCall.status,
                    metadata: toolCall.metadata
                  )) else {
                Issue.record("expected a normalized context compaction from \(fixture)")
                continue
            }
            #expect(compaction.status == status)
            #expect(compaction.tokensBefore == before)
            #expect(compaction.tokensAfter == after)
            #expect(compaction.durationMs == duration)
            #expect(compaction.error == error)
        }
    }

    @Test("decodes experimental compaction updates")
    func compactionUpdates() throws {
        let running = try decode("session-update-compaction-update")
        guard case .compactionUpdate(let update) = running.params?.update else {
            Issue.record("expected compactionUpdate")
            return
        }
        #expect(update.compactionId == "standard-compact-1")
        #expect(update.status == "in_progress")
        #expect(update.summary == nil)

        let patch = try JSONDecoder().decode(ACPSessionUpdateParams.self, from: Data("""
        { "sessionId": "s", "update": { "sessionUpdate": "compaction_update", "compactionId": "standard-compact-1", "status": "failed", "summary": null, "error": null, "future": true } }
        """.utf8))
        guard case .compactionUpdate(let nullPatch) = patch.update else {
            Issue.record("expected compactionUpdate")
            return
        }
        #expect(nullPatch.summaryWasProvided)
        #expect(nullPatch.summaryWasNull)
        #expect(nullPatch.errorWasProvided)
        #expect(nullPatch.errorWasNull)

        let chunk = try decode("session-update-compaction-summary-chunk")
        guard case .compactionSummaryChunk(let summaryChunk) = chunk.params?.update else {
            Issue.record("expected compactionSummaryChunk")
            return
        }
        #expect(summaryChunk.compactionId == "standard-compact-1")
        #expect(summaryChunk.content == .text("Kept decisions."))
    }

    @Test("initialize advertises compaction support")
    func compactionCapability() throws {
        let data = try JSONEncoder().encode(ACPInitializeParams(
            protocolVersion: 1,
            clientCapabilities: .init(
                fs: .init(readTextFile: true, writeTextFile: true), terminal: true)))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let capabilities = try #require(json["clientCapabilities"] as? [String: Any])
        let session = try #require(capabilities["session"] as? [String: Any])
        #expect(session["compaction"] as? [String: Any] != nil)
    }

    private func decode(_ name: String) throws -> JSONRPCEnvelope<ACPSessionUpdateParams> {
        let bundle = Bundle(for: ACPSessionUpdateFixtureMarker.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONRPCEnvelope<ACPSessionUpdateParams>.self,
                                        from: try Data(contentsOf: url))
    }

    private func toolCallCompaction(
        id: String,
        status: String,
        facts: String
    ) throws -> ACPContextCompaction {
        let json = """
        { "sessionId": "s", "update": { "sessionUpdate": "tool_call", "toolCallId": "\(id)", "title": "Compact conversation", "status": "\(status)", "_meta": { "contextCompaction": { "version": 1, \(facts) } } } }
        """
        let params = try JSONDecoder().decode(ACPSessionUpdateParams.self, from: Data(json.utf8))
        guard case .toolCall(let payload) = params.update,
              let compaction = ACPContextCompaction(toolCall: .init(
                toolCallId: payload.toolCallId, title: payload.title, kind: payload.kind,
                status: payload.status, metadata: payload.metadata)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "missing compaction"))
        }
        return compaction
    }
}

private final class ACPSessionUpdateFixtureMarker {}
