import Foundation
import Testing
import AlasCore

struct ACPClaudeSessionHooksPolicyTests {
    @Test("valid hooks normalize to compact sorted JSON", arguments: [
        (#"{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"./fmt.sh","timeout":30}]}]}"#,
         #"{"PostToolUse":[{"hooks":[{"command":"./fmt.sh","timeout":30,"type":"command"}],"matcher":"Edit|Write"}]}"#),
        // The settings.json form is unwrapped.
        (#"{"hooks":{"Stop":[{"hooks":[{"type":"prompt","prompt":"Done?"}]}]}}"#,
         #"{"Stop":[{"hooks":[{"prompt":"Done?","type":"prompt"}]}]}"#),
        (#"{"SessionStart":[{"hooks":[{"type":"mcp_tool","server":"s","tool":"t"},{"type":"http","url":"http://h/x"}]}]}"#,
         #"{"SessionStart":[{"hooks":[{"server":"s","tool":"t","type":"mcp_tool"},{"type":"http","url":"http://h/x"}]}]}"#),
        (" \n ", nil),
        ("{}", nil),
        (#"{"hooks":{}}"#, nil),
    ] as [(String, String?)])
    func normalizesValidHooks(input: String, expected: String?) throws {
        #expect(try ACPClaudeSessionHooksPolicy.normalized(input) == expected)
    }

    @Test("invalid hooks fail with an error that names the problem", arguments: [
        ("{", "not valid JSON"),
        (#"[{"matcher":"x"}]"#, "object keyed by event name"),
        (#"{"PostTooluse":[]}"#, #""PostTooluse" is not a Claude Code hook event"#),
        (#"{"Stop":{"hooks":[]}}"#, "Stop must be a list of matcher groups"),
        (#"{"Stop":[{"matcher":1,"hooks":[{"type":"command","command":"x"}]}]}"#, "Stop[0].matcher must be a string"),
        (#"{"Stop":[{"hooks":[]}]}"#, #"Stop[0] needs a non-empty "hooks" list"#),
        (#"{"Stop":[{"hooks":[{"type":"shell","command":"x"}]}]}"#, "Stop[0].hooks[0].type must be one of"),
        (#"{"Stop":[{"hooks":[{"type":"command","command":"x"},{"type":"command","command":" "}]}]}"#,
         "Stop[0].hooks[1].command must be a non-empty string"),
        (#"{"Stop":[{"hooks":[{"type":"mcp_tool","server":"s"}]}]}"#, "Stop[0].hooks[0].tool must be a non-empty string"),
        (#"{"Stop":[{"hooks":[{"type":"command","command":"x","timeout":true}]}]}"#, "timeout must be a positive number"),
        (#"{"Stop":[{"hooks":[{"type":"command","command":"x","args":[1]}]}]}"#, "args must be a list of strings"),
    ])
    func rejectsInvalidHooks(input: String, message: String) {
        do {
            _ = try ACPClaudeSessionHooksPolicy.normalized(input)
            Issue.record("expected \(input) to be rejected")
        } catch {
            #expect(error.errorDescription?.contains(message) == true, "\(error.errorDescription ?? "")")
        }
    }

    @Test("captured hooks go only to a verified Claude adapter, and an unverified one fails instead of dropping them", arguments: [
        ("claude", "@alas-ide/claude-agent-acp", "0.94.0-alas.1", true),
        ("claude", "@agentclientprotocol/claude-agent-acp", "0.90.0", true),
        // Before upstream #1265 the settings replaced CLAUDE_MODEL_CONFIG.
        ("claude", "@alas-ide/claude-agent-acp", "0.89.1", false),
        ("claude", "some-other-acp", "1.0.0", false),
        ("claude", nil, nil, false),
    ] as [(String, String?, String?, Bool)])
    func adapterGate(agentID: String, name: String?, version: String?, sends: Bool) throws {
        let captured = #"{"Stop":[{"hooks":[{"command":"true","type":"command"}]}]}"#
        let info = name.map { ACPImplementationInfo(name: $0, version: version ?? "") }
        do {
            let hooks = try ACPClaudeSessionHooksPolicy.sessionHooks(agentID: agentID, captured: captured, agentInfo: info)
            #expect(sends)
            #expect(hooks == (try LSPJSONValue.decode(from: Data(captured.utf8))))
        } catch {
            #expect(!sends)
        }
    }

    @Test("sessions without hooks, other agents, and malformed snapshots", arguments: [
        ("claude", nil, true),
        ("codex", #"{"Stop":[{"hooks":[{"command":"true","type":"command"}]}]}"#, true),
        // A hand-edited config captured as written fails the attach.
        ("claude", #"{"Stop":"oops"}"#, false),
    ] as [(String, String?, Bool)])
    func capturedEdgeCases(agentID: String, captured: String?, sendsNothing: Bool) {
        // An old adapter: none of these may depend on its version.
        let info = ACPImplementationInfo(name: "@alas-ide/claude-agent-acp", version: "0.80.0")
        do {
            #expect(try ACPClaudeSessionHooksPolicy.sessionHooks(agentID: agentID, captured: captured, agentInfo: info) == nil)
            #expect(sendsNothing)
        } catch {
            #expect(!sendsNothing)
            #expect(error == .invalid(#"Stop must be a list of matcher groups, like [{"matcher": "Bash", "hooks": [...]}]."#))
        }
    }
}
