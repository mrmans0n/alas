import Testing
@testable import Alas

struct HarnessDetectorTests {
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
