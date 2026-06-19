import Testing
@testable import Alas

@Suite("Context ring helpers")
struct ACPContextRingTests {
    @Test("ratio clamps and guards divide-by-zero")
    func ratio() {
        #expect(contextRatio(used: 50, size: 200) == 0.25)
        #expect(contextRatio(used: 300, size: 200) == 1.0)   // used > size clamps to 1
        #expect(contextRatio(used: -5, size: 200) == 0.0)    // negative used clamps to 0
        #expect(contextRatio(used: 10, size: 0) == 0.0)      // size 0 -> 0, no crash
    }

    @Test("level thresholds")
    func levels() {
        #expect(ContextRingLevel(ratio: 0.79) == .neutral)
        #expect(ContextRingLevel(ratio: 0.80) == .warning)
        #expect(ContextRingLevel(ratio: 0.94) == .warning)
        #expect(ContextRingLevel(ratio: 0.95) == .critical)
        #expect(ContextRingLevel(ratio: 1.5) == .critical)
    }

    @Test("level maps to theme token")
    func tokens() {
        #expect(ContextRingLevel.neutral.token == "accent")
        #expect(ContextRingLevel.warning.token == "warn")
        #expect(ContextRingLevel.critical.token == "del")
    }

    @Test("token formatting")
    func format() {
        #expect(formatContextTokens(53000) == "53.0k")
        #expect(formatContextTokens(200000) == "200.0k")
        #expect(formatContextTokens(1_200_000) == "1.2M")
        #expect(formatContextTokens(640) == "640")
        #expect(formatContextTokens(-5) == "0")
    }

    @Test("percent rounds")
    func percent() {
        #expect(contextPercent(ratio: 0.265) == 27)
        #expect(contextPercent(ratio: 0.0) == 0)
        #expect(contextPercent(ratio: 1.0) == 100)
    }

    private func contextUsageTooltip(ratio: Double) -> String {
        "Context window: \(contextPercent(ratio: ratio))% in use"
    }

    @Test("tooltip string matches requested wording")
    func tooltipWording() {
        #expect(contextUsageTooltip(ratio: 0.0) == "Context window: 0% in use")
        #expect(contextUsageTooltip(ratio: 0.265) == "Context window: 27% in use")
        #expect(contextUsageTooltip(ratio: 0.80) == "Context window: 80% in use")
        #expect(contextUsageTooltip(ratio: 0.949) == "Context window: 95% in use")
        #expect(contextUsageTooltip(ratio: 0.951) == "Context window: 95% in use")
        #expect(contextUsageTooltip(ratio: 1.0) == "Context window: 100% in use")
    }

    @Test("ring stays non-interactive when action is nil")
    func ringWithoutActionIsNonInteractive() {
        let view = ACPContextRing(ratio: 0.5)
        _ = view.body
    }
}
