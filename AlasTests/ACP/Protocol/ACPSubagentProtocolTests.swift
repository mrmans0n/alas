import Foundation
import Testing
@testable import Alas

@Suite("ACP subagent protocol")
struct ACPSubagentProtocolTests {
    @Test("initialize advertises the subagent opt-in in both spellings")
    func initializeAdvertisesSubagentCapability() throws {
        let params = ACPInitializeParams(
            protocolVersion: ACPProtocolVersion.current,
            clientCapabilities: .init(
                fs: .init(readTextFile: true, writeTextFile: true),
                terminal: true))
        let encoded = try JSONEncoder().encode(params)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let capabilities = try #require(json["clientCapabilities"] as? [String: Any])

        let subagents = try #require(capabilities["subagents"] as? [String: Any])
        #expect(subagents.isEmpty)
        let meta = try #require(capabilities["_meta"] as? [String: Any])
        #expect(meta["opencode/child-session-updates"] as? Bool == true)
    }

    @Test("agent subagent support is read from sessionCapabilities")
    func agentSubagentCapability() throws {
        let json = """
        {
          "protocolVersion": 1,
          "agentCapabilities": {
            "loadSession": true,
            "sessionCapabilities": { "resume": {}, "subagents": {} }
          }
        }
        """
        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: Data(json.utf8))
        #expect(result.agentCapabilities?.sessionCapabilities.supportsSubagents == true)
        #expect(result.agentCapabilities?.meta.openCodeChildSessionUpdates == false)
    }

    @Test("OpenCode advertises subagents through agent _meta")
    func openCodeAgentCapability() throws {
        let json = """
        {
          "protocolVersion": 1,
          "agentCapabilities": {
            "_meta": { "opencode/child-session-updates": true }
          }
        }
        """
        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: Data(json.utf8))
        #expect(result.agentCapabilities?.sessionCapabilities.supportsSubagents == false)
        #expect(result.agentCapabilities?.meta.openCodeChildSessionUpdates == true)
    }

    @Test("an agent that ignores the capability reports no subagent support")
    func agentWithoutSubagentCapability() throws {
        let json = """
        { "protocolVersion": 1, "agentCapabilities": { "loadSession": true } }
        """
        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: Data(json.utf8))
        #expect(result.agentCapabilities?.sessionCapabilities.supportsSubagents == false)
        #expect(result.agentCapabilities?.meta.openCodeChildSessionUpdates == false)
    }

    @Test("decodes subagent_spawned with its capabilities")
    func decodesSpawn() throws {
        let json = """
        {
          "sessionId": "parent",
          "update": {
            "sessionUpdate": "subagent_spawned",
            "subagentSessionId": "child-1",
            "name": "Explore",
            "task": "Find the router",
            "capabilities": { "cancel": {}, "close": {} }
          }
        }
        """
        let params = try JSONDecoder().decode(ACPSessionUpdateParams.self, from: Data(json.utf8))
        #expect(params.sessionId == "parent")
        guard case .subagentSpawned(let spawn) = params.update else {
            Issue.record("expected subagentSpawned")
            return
        }
        #expect(spawn.subagentSessionId == "child-1")
        #expect(spawn.name == "Explore")
        #expect(spawn.task == "Find the router")
        #expect(spawn.capabilities.supportsCancel)
        #expect(spawn.capabilities.supportsClose)
    }

    @Test("a spawn without capabilities offers no cancel")
    func decodesSpawnWithoutCapabilities() throws {
        let json = """
        { "sessionUpdate": "subagent_spawned", "subagentSessionId": "child-1" }
        """
        let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
        guard case .subagentSpawned(let spawn) = update else {
            Issue.record("expected subagentSpawned")
            return
        }
        #expect(spawn.name == nil)
        #expect(spawn.capabilities.supportsCancel == false)
    }

    @Test("decodes every terminal subagent_state_update")
    func decodesStateUpdates() throws {
        for (raw, expected) in [
            ("completed", ACPSubagentState.completed),
            ("failed", .failed),
            ("cancelled", .cancelled),
            ("disconnected", .disconnected)
        ] {
            let json = """
            {
              "sessionUpdate": "subagent_state_update",
              "subagentSessionId": "child-1",
              "state": "\(raw)"
            }
            """
            let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
            guard case .subagentStateUpdate(let state) = update else {
                Issue.record("expected subagentStateUpdate for \(raw)")
                return
            }
            #expect(state.state == expected)
            #expect(state.state.isTerminal)
        }
    }

    @Test("an unknown state keeps the child running rather than claiming it finished")
    func unknownStateIsNotTerminal() throws {
        let json = """
        {
          "sessionUpdate": "subagent_state_update",
          "subagentSessionId": "child-1",
          "state": "awaiting_permission"
        }
        """
        let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
        guard case .subagentStateUpdate(let state) = update else {
            Issue.record("expected subagentStateUpdate")
            return
        }
        #expect(state.state == .other("awaiting_permission"))
        #expect(state.state.isTerminal == false)
    }

    // Frames below are claude-agent-acp 0.91.0's own scenario snapshots
    // (`subagent-native-sessions.jsonl`), the revised RFD form it sends to a
    // non-AIR client that declares `clientCapabilities.subagents`.

    @Test("the revised subagent_update announces the child and its state on the parent")
    func revisedAnnouncementNormalizes() throws {
        let updates = try Self.frame("""
        {"sessionId":"root","update":{"capabilities":{"cancel":{}},"description":"Fix the build",\
        "sessionId":"agent_n","sessionUpdate":"subagent_update","state":{"state":"running"},"title":"general-purpose"}}
        """)

        #expect(updates.map(\.sessionId) == ["root", "root"])
        guard case .subagentSpawned(let spawn) = updates[0].update,
              case .subagentStateUpdate(let state) = updates[1].update else {
            Issue.record("expected a spawn followed by a state update, got \(updates.map(\.update))")
            return
        }
        #expect(spawn.subagentSessionId == "agent_n")
        #expect(spawn.name == "general-purpose")
        #expect(spawn.task == "Fix the build")
        #expect(spawn.capabilities.supportsCancel)
        #expect(state.subagentSessionId == "agent_n")
        #expect(state.state == .running)
    }

    @Test("a revised session_message is the child's prompt, keyed by its message id")
    func revisedSessionMessageNormalizes() throws {
        let updates = try Self.frame("""
        {"sessionId":"agent_n","update":{"content":[{"text":"Make the build pass","type":"text"},\
        {"type":"text"}],"messageId":"toolu_native","recipientSessionId":"agent_n",\
        "senderMessageId":"toolu_native","senderSessionId":"root","sessionUpdate":"session_message"}}
        """)
        let chunk = try Self.frame("""
        {"sessionId":"agent_n","update":{"content":{"text":"and run tests","type":"text"},\
        "messageId":"toolu_native","sessionUpdate":"session_message_chunk"}}
        """)

        // The malformed block is skipped rather than failing the whole message.
        // The whole message replaces the row's content; the chunk extends it.
        #expect(updates + chunk == [
            .init(sessionId: "agent_n", update: .userMessageChunk(.init(
                messageId: "toolu_native", content: .text("Make the build pass"),
                directed: .init(senderSessionId: "root", recipientSessionId: "agent_n", replacesContent: true,
                                senderMessageId: "toolu_native", isOutgoing: false)))),
            .init(sessionId: "agent_n", update: .userMessageChunk(.init(
                messageId: "toolu_native", content: .text("and run tests"),
                directed: .init(senderSessionId: nil, recipientSessionId: nil, replacesContent: false))))
        ])
    }

    @Test("subagent_update directory members are patches: absent keeps, null inherits, a value replaces", arguments: [
        (#""cwd":"/w/pkg","additionalDirectories":["/w/a"]"#, "/w/pkg" as String?, false, ["/w/a"], true),
        (#""cwd":null,"additionalDirectories":null"#, nil, true, [], true),
        (#""title":"t""#, nil, false, [], false),
    ])
    func revisedDirectoryPatches(members: String, cwd: String?, clearsCwd: Bool, dirs: [String], replacesDirs: Bool) throws {
        let updates = try Self.frame(#"{"sessionId":"root","update":{"sessionUpdate":"subagent_update","sessionId":"agent_n",\#(members)}}"#)
        guard case .subagentSpawned(let spawn) = updates.first?.update else { Issue.record("expected a spawn")
        return }
        #expect(spawn.cwd == cwd)
        #expect(spawn.clearsCwd == clearsCwd)
        #expect(spawn.additionalDirectories == dirs)
        #expect(spawn.replacesAdditionalDirectories == replacesDirs)
    }

    @Test("the sender's view of a linked session_message is kept as an outgoing chunk, not a prompt")
    func revisedMessageOutgoingView() throws {
        let updates = try Self.frame(#"{"sessionId":"agent_n","update":{"sessionUpdate":"session_message","messageId":"toolu_h","senderSessionId":"agent_n","recipientSessionId":"root","recipientMessageId":"toolu_h","content":[{"type":"text","text":"done"}]}}"#)
        #expect(updates == [.init(sessionId: "agent_n", update: .userMessageChunk(.init(messageId: "toolu_h", content: .text("done"),
            directed: .init(senderSessionId: "agent_n", recipientSessionId: "root", replacesContent: true,
                            recipientMessageId: "toolu_h", isOutgoing: true))))])
    }

    @Test("revised work states map onto the subagent lifecycle", arguments: [
        (#"{"state":"requires_action"}"#, ACPSubagentState.requiresAction, nil as String?),
        (#"{"state":"idle","stopReason":"end_turn"}"#, .completed, nil),
        (#"{"state":"idle"}"#, .completed, nil),
        (#"{"state":"idle","stopReason":"cancelled"}"#, .cancelled, nil),
        (#"{"state":"idle","stopReason":"error","error":{"code":-32603,"message":"boom"}}"#, .failed, "boom"),
        // Not terminal: the work may still be live, and a later snapshot replaces it.
        (#"{"state":"unknown"}"#, .other("unknown"), nil),
        // `null` clears the snapshot: no activity is asserted any more.
        ("null", .unconfirmed, nil)
    ])
    func revisedStatesNormalize(state json: String, expected: ACPSubagentState, error: String?) throws {
        let updates = try Self.frame("""
        {"sessionId":"root","update":{"sessionId":"agent_n","sessionUpdate":"subagent_update","state":\(json)}}
        """)
        guard updates.count == 2, case .subagentStateUpdate(let state) = updates[1].update else {
            Issue.record("expected a state update, got \(updates.map(\.update))")
            return
        }
        #expect(state.state == expected)
        #expect(state.error == error)
    }

    @Test("a revised metadata-only update asserts no state")
    func revisedUpdateWithoutState() throws {
        let updates = try Self.frame("""
        {"sessionId":"root","update":{"sessionId":"agent_n","sessionUpdate":"subagent_update","title":"Explore"}}
        """)
        #expect(updates.count == 1)
        guard case .subagentSpawned(let spawn) = updates.first?.update else {
            Issue.record("expected a spawn")
            return
        }
        #expect(spawn.name == "Explore")
        // A child first announced this way is not claimed to be running.
        #expect(spawn.initialState == .unconfirmed)
    }

    private static func frame(_ json: String) throws -> [ACPSessionUpdateParams] {
        try JSONDecoder().decode(ACPSessionUpdateFrame.self, from: Data(json.utf8)).updates
    }
}

@Suite("OpenCode child updates")
struct ACPOpenCodeChildUpdateTests {
    @Test("a child update normalizes to a spawn plus a child-scoped update")
    func normalizesUpdate() throws {
        let json = """
        {
          "rootSessionId": "root",
          "childSessionId": "child-1",
          "parentSessionId": "root",
          "depth": 1,
          "title": "Reviewer",
          "type": "update",
          "update": {
            "sessionUpdate": "agent_message_chunk",
            "content": { "type": "text", "text": "looking" }
          }
        }
        """
        let normalized = ACPOpenCodeChildUpdate.normalize(params: Data(json.utf8))
        #expect(normalized.count == 2)

        #expect(normalized[0].sessionId == "root")
        guard case .subagentSpawned(let spawn) = normalized[0].update else {
            Issue.record("expected a synthesized spawn first")
            return
        }
        #expect(spawn.subagentSessionId == "child-1")
        #expect(spawn.name == "Reviewer")
        // OpenCode never advertises per-child cancel, so the row must not
        // offer an action the agent would reject.
        #expect(spawn.capabilities.supportsCancel == false)

        #expect(normalized[1].sessionId == "child-1")
        guard case .agentMessageChunk(let chunk) = normalized[1].update else {
            Issue.record("expected the inner update, addressed to the child")
            return
        }
        #expect(chunk.content == .text("looking"))
    }

    @Test("a status notification normalizes to a state update on the root")
    func normalizesStatus() throws {
        let json = """
        {
          "rootSessionId": "root",
          "childSessionId": "child-1",
          "type": "status",
          "status": "completed"
        }
        """
        let normalized = ACPOpenCodeChildUpdate.normalize(params: Data(json.utf8))
        #expect(normalized.count == 2)
        #expect(normalized[1].sessionId == "root")
        guard case .subagentStateUpdate(let state) = normalized[1].update else {
            Issue.record("expected subagentStateUpdate")
            return
        }
        #expect(state.subagentSessionId == "child-1")
        #expect(state.state == .completed)
    }

    @Test("a failed status carries its diagnostic text into the normalized update")
    func normalizesStatusErrorText() throws {
        let json = """
        {
          "rootSessionId": "root",
          "childSessionId": "child-1",
          "type": "status",
          "status": "failed",
          "error": "rate limited by upstream provider"
        }
        """
        let normalized = ACPOpenCodeChildUpdate.normalize(params: Data(json.utf8))
        guard case .subagentStateUpdate(let state) = normalized.last?.update else {
            Issue.record("expected subagentStateUpdate")
            return
        }
        #expect(state.state == .failed)
        #expect(state.error == "rate limited by upstream provider")
    }

    @Test("OpenCode's interrupted status maps onto cancelled")
    func mapsInterruptedStatus() throws {
        let json = """
        { "rootSessionId": "r", "childSessionId": "c", "type": "status", "status": "interrupted" }
        """
        let normalized = ACPOpenCodeChildUpdate.normalize(params: Data(json.utf8))
        guard case .subagentStateUpdate(let state) = normalized.last?.update else {
            Issue.record("expected subagentStateUpdate")
            return
        }
        #expect(state.state == .cancelled)
    }

    @Test("a created status registers the child without ending it")
    func createdStatusKeepsChildRunning() throws {
        let json = """
        { "rootSessionId": "r", "childSessionId": "c", "type": "status", "status": "created" }
        """
        let normalized = ACPOpenCodeChildUpdate.normalize(params: Data(json.utf8))
        guard case .subagentStateUpdate(let state) = normalized.last?.update else {
            Issue.record("expected subagentStateUpdate")
            return
        }
        #expect(state.state == .running)
        #expect(state.state.isTerminal == false)
    }

    @Test("an unparseable payload yields nothing rather than a bogus child")
    func ignoresGarbage() {
        #expect(ACPOpenCodeChildUpdate.normalize(params: Data("{}".utf8)).isEmpty)
        #expect(ACPOpenCodeChildUpdate.normalize(params: Data("not json".utf8)).isEmpty)
    }
}
