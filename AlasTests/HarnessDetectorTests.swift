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
    @Test func unknownReturnsNil() {
        #expect(HarnessDetector.matchKind(processName: "zsh") == nil)
    }

    @Test func matchesCodexHomebrewBinary() {
        #expect(HarnessDetector.matchKind(processName: "codex-aarch64-apple-darwin") == .codex)
        #expect(HarnessDetector.matchKind(processName: "codex-x86_64-apple-darwin") == .codex)
    }

    @Test func matchesAnyDashSuffix() {
        #expect(HarnessDetector.matchKind(processName: "claude-code") == .claudeCode)
        #expect(HarnessDetector.matchKind(processName: "codex-cli") == .codex)
    }

    @Test func doesNotMatchSubstring() {
        // "claudefoo" must NOT match — only the exact name or name-DASH prefix.
        #expect(HarnessDetector.matchKind(processName: "claudefoo") == nil)
        #expect(HarnessDetector.matchKind(processName: "aiderbot") == nil)
    }
}
