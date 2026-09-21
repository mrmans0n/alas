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

    @Test("ring body evaluates on the main actor")
    @MainActor
    func ringBodyEvaluates() {
        let view = ACPContextRing(ratio: 0.5)
        _ = view.body
    }

    @Test("context usage button renders with usage alone")
    func hasContentWithUsageOnly() {
        let button = ACPContextUsageButton(
            usage: .init(used: 100, size: 1000, cost: nil), modelName: nil)
        #expect(button.hasContent)
    }

    @Test("context usage button renders with quota alone (no usage_update yet)")
    func hasContentWithQuotaOnlyNoUsage() {
        let quota = ACPPromptQuota(
            tokenCount: .init(totalTokens: 10, inputTokens: 10, cachedInputTokens: 0,
                              cachedWriteTokens: 0, outputTokens: 0, reasoningOutputTokens: 0),
            modelUsage: [.init(model: "m", tokenCount: .init(
                totalTokens: 10, inputTokens: 10, cachedInputTokens: 0,
                cachedWriteTokens: 0, outputTokens: 0, reasoningOutputTokens: 0))])
        let button = ACPContextUsageButton(
            usage: nil, modelName: nil, lastTurnQuota: quota, sessionQuotaTotal: quota)
        #expect(button.hasContent)
    }

    @Test("context usage button renders nothing with no data at all")
    func hasContentWithNothing() {
        let button = ACPContextUsageButton(usage: nil, modelName: nil)
        #expect(!button.hasContent)
    }

    @Test("context usage button body evaluates on the main actor with quota only")
    @MainActor
    func quotaOnlyBodyEvaluates() {
        let quota = ACPPromptQuota(
            tokenCount: nil,
            modelUsage: [.init(model: "m", tokenCount: .init(
                totalTokens: 5, inputTokens: 5, cachedInputTokens: 0,
                cachedWriteTokens: 0, outputTokens: 0, reasoningOutputTokens: 0))])
        let view = ACPContextUsageButton(usage: nil, modelName: nil, lastTurnQuota: quota)
        _ = view.body
    }
}
