import Testing
@testable import Alas

struct HarnessBadgeSurfaceTests {
    /// One opaque fill per state at a fixed lightness, so a logo drawn in its
    /// own colors reads the same on every state, and the hue still tells
    /// running from waiting.
    @Test func surfaceKeepsTheTokensHueAndChromaAtOneLightness() throws {
        // cool-slate's `add` and `caution`.
        let running = try #require(HarnessSessionBadgeChrome.surfaceColor(from: "oklch(0.78 0.14 155)"))
        let awaiting = try #require(HarnessSessionBadgeChrome.surfaceColor(from: "oklch(0.80 0.13 95 / 0.5)"))
        #expect(running == OKLCH(l: HarnessSessionBadgeChrome.surfaceLightness, c: 0.14, h: 155, a: 1))
        #expect(awaiting == OKLCH(l: HarnessSessionBadgeChrome.surfaceLightness, c: 0.13, h: 95, a: 1))
    }

    @Test func overflowSurfaceReflectsOnlyHiddenSessionStates() {
        let running = HarnessService.WorktreeHarnessSession(id: "running", state: .running, agent: .claude)
        let awaiting = HarnessService.WorktreeHarnessSession(id: "awaiting", state: .awaiting, agent: .pi)
        let limited = HarnessService.WorktreeHarnessSession(id: "limited", state: .limited, agent: .codex)
        let failed = HarnessService.WorktreeHarnessSession(id: "failed", state: .failed, agent: .claude)

        #expect(HarnessSessionBadgeSurface(sessions: [running]) == .running)
        #expect(HarnessSessionBadgeSurface(sessions: [awaiting]) == .awaiting)
        #expect(HarnessSessionBadgeSurface(sessions: [running, awaiting]) == .mixed)
        #expect(HarnessSessionBadgeSurface(sessions: [limited]) == .limited)
        #expect(HarnessSessionBadgeSurface(sessions: [failed]) == .failed)
        #expect(HarnessSessionBadgeSurface(sessions: [limited, failed]) == .failed)
        #expect(HarnessSessionBadgeSurface(sessions: [running, failed]) == .running)
        // A mix shows the session that is waiting on someone.
        #expect(HarnessSessionBadgeSurface.mixed.colorToken == HarnessSessionBadgeSurface.awaiting.colorToken)
    }

    @Test func missingOrUnparseableTokenYieldsNoSurface() {
        // Theme.fallback ships no tokens; callers fall back to the token's color.
        #expect(HarnessSessionBadgeChrome.surfaceColor(from: nil) == nil)
        #expect(HarnessSessionBadgeChrome.surfaceColor(from: "#ff00ff") == nil)
        #expect(HarnessSessionBadgeChrome.surfaceColor(from: "") == nil)
    }
}
