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
