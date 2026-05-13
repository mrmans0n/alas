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
    }
    @Test func doesNotMatchSubstring() {
        #expect(HarnessDetector.matchKind(processName: "claudefoo") == nil)
    }
}
