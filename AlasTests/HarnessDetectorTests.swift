import Testing
@testable import Alas

struct HarnessDetectorTests {
    /// Every built-in agent has to resolve to the harness the detector will
    /// report for it, or a scheduled prompt aimed at that agent is refused
    /// before it is ever typed. Cursor is the reason this is not a plain
    /// `AgentKind(rawValue:)`: it is registered as `cursor-agent`.
    @Test func everyBuiltinAgentResolvesToItsHarness() {
        #expect(HarnessKind.forAgentID("cursor-agent") == .cursor)
        #expect(HarnessKind.forAgentID("claude") == .claudeCode)
        #expect(HarnessKind.forAgentID("codex") == .codex)
        for builtin in AgentBuiltins.catalog {
            #expect(
                HarnessKind.forAgentID(builtin.id) != nil,
                "Built-in agent \(builtin.id) resolves to no harness, so it can never be confirmed ready"
            )
        }
        // A custom agent is not recognisable in a terminal, and saying so is
        // what keeps a prompt from being typed at whatever else is running.
        #expect(HarnessKind.forAgentID("my-custom-agent") == nil)
    }

    /// A custom agent has a UUID for an id, so only the binary it launches
    /// says what will be running. Wrapping a known CLI is the common case
    /// and has to stay identifiable, or its prompts are refused.
    @Test func aCustomAgentIsIdentifiedByItsBinary() {
        let uuid = "9C4E2A10-0000-4000-8000-000000000000"
        #expect(HarnessKind.forAgent(id: uuid, binary: "claude") == .claudeCode)
        #expect(HarnessKind.forAgent(id: uuid, binary: "/opt/homebrew/bin/codex") == .codex)
        #expect(HarnessKind.forAgent(id: uuid, binary: "~/bin/cursor-agent") == .cursor)
        // Nothing recognisable means readiness cannot be established, which
        // is the safe answer rather than trusting any harness that appears.
        #expect(HarnessKind.forAgent(id: uuid, binary: "my-own-wrapper") == nil)
        // A built-in id still wins, whatever its binary override says.
        #expect(HarnessKind.forAgent(id: "cursor-agent", binary: "/usr/bin/true") == .cursor)
    }

    @Test func matchesClaudeProcess() {
        #expect(HarnessDetector.matchKind(processName: "claude") == .claudeCode)
        #expect(HarnessDetector.matchKind(processName: "claude-code") == .claudeCode)
    }
    @Test func matchesCodex() {
        #expect(HarnessDetector.matchKind(processName: "codex-cli") == .codex)
    }
    @Test func matchesCursor() {
        #expect(HarnessDetector.matchKind(processName: "cursor-agent") == .cursor)
    }
    @Test func matchesAdditionalAgentProcesses() {
        #expect(HarnessDetector.matchKind(processName: "gemini") == .gemini)
        #expect(HarnessDetector.matchKind(processName: "opencode") == .opencode)
        #expect(HarnessDetector.matchKind(processName: "pi") == .pi)
        #expect(HarnessDetector.matchKind(processName: "omp") == .omp)
        #expect(HarnessDetector.matchKind(processName: "copilot") == .copilot)
    }
    @Test func unknownReturnsNil() {
        #expect(HarnessDetector.matchKind(processName: "zsh") == nil)
    }
    @Test func matchesCodexHomebrewBinary() {
        #expect(HarnessDetector.matchKind(processName: "codex-aarch64-apple-darwin") == .codex)
    }
    @Test func matchesAnyDashSuffix() {
        #expect(HarnessDetector.matchKind(processName: "claude-code") == .claudeCode)
        #expect(HarnessDetector.matchKind(processName: "codex-cli") == .codex)
        #expect(HarnessDetector.matchKind(processName: "cursor-agent-dev") == .cursor)
        #expect(HarnessDetector.matchKind(processName: "copilot-dev") == .copilot)
    }
    @Test func doesNotPrefixMatchShortProcessNames() {
        #expect(HarnessDetector.matchKind(processName: "pi-dev") == nil)
    }
    @Test func doesNotMatchSubstring() {
        #expect(HarnessDetector.matchKind(processName: "claudefoo") == nil)
    }
}
