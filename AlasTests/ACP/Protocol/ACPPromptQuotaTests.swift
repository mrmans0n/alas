import Foundation
import Testing
@testable import Alas

@Suite("ACPPromptQuota decode + accumulation")
struct ACPPromptQuotaTests {
    private func tokenCount(total: Int, input: Int = 0, cachedInput: Int = 0,
                            cachedWrite: Int = 0, output: Int = 0, reasoning: Int = 0) -> ACPTokenCount {
        ACPTokenCount(
            totalTokens: total, inputTokens: input, cachedInputTokens: cachedInput,
            cachedWriteTokens: cachedWrite, outputTokens: output, reasoningOutputTokens: reasoning)
    }

    @Test("decodes _meta.quota with per-model usage from a session/prompt result")
    func decodesFullShape() throws {
        let json = """
        {
          "stopReason": "end_turn",
          "_meta": {
            "quota": {
              "token_count": {
                "totalTokens": 120, "inputTokens": 80, "cachedInputTokens": 10,
                "cachedWriteTokens": 5, "outputTokens": 40, "reasoningOutputTokens": 0
              },
              "model_usage": [
                {
                  "model": "claude-fable-5-1",
                  "token_count": {
                    "totalTokens": 120, "inputTokens": 80, "cachedInputTokens": 10,
                    "cachedWriteTokens": 5, "outputTokens": 40, "reasoningOutputTokens": 0
                  }
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(ACPSessionPromptResult.self, from: json)
        let quota = try #require(result.quota)
        #expect(quota.tokenCount == tokenCount(total: 120, input: 80, cachedInput: 10, cachedWrite: 5, output: 40))
        #expect(quota.modelUsage.count == 1)
        #expect(quota.modelUsage[0].model == "claude-fable-5-1")
        #expect(quota.modelUsage[0].tokenCount.totalTokens == 120)
    }

    @Test("absent _meta decodes quota to nil")
    func absentMetaDecodesNil() throws {
        let json = #"{"stopReason":"end_turn"}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(ACPSessionPromptResult.self, from: json)
        #expect(result.quota == nil)
    }

    @Test("absent quota under _meta decodes to nil")
    func absentQuotaUnderMetaDecodesNil() throws {
        let json = #"{"stopReason":"end_turn","_meta":{"other":1}}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(ACPSessionPromptResult.self, from: json)
        #expect(result.quota == nil)
    }

    @Test("accumulating sums per-model and total token counts across turns")
    func accumulatingSumsAcrossTurns() {
        let turn1 = ACPPromptQuota(
            tokenCount: tokenCount(total: 100),
            modelUsage: [.init(model: "a", tokenCount: tokenCount(total: 100))])
        let turn2 = ACPPromptQuota(
            tokenCount: tokenCount(total: 50),
            modelUsage: [
                .init(model: "a", tokenCount: tokenCount(total: 30)),
                .init(model: "b", tokenCount: tokenCount(total: 20)),
            ])

        let afterFirst = ACPPromptQuota.accumulating(nil, with: turn1)
        #expect(afterFirst == turn1)

        let afterSecond = ACPPromptQuota.accumulating(afterFirst, with: turn2)
        #expect(afterSecond.tokenCount == tokenCount(total: 150))
        #expect(afterSecond.modelUsage.count == 2)
        #expect(afterSecond.modelUsage.first(where: { $0.model == "a" })?.tokenCount.totalTokens == 130)
        #expect(afterSecond.modelUsage.first(where: { $0.model == "b" })?.tokenCount.totalTokens == 20)
    }

    @Test("displayTotal falls back to summing the parts when totalTokens is missing (decodes to 0)")
    func displayTotalFallsBackWhenTotalTokensMissing() {
        // An adapter that sends per-field counters but omits totalTokens
        // decodes totalTokens as 0 (ACPTokenCount's lenient decode) even
        // though real usage occurred — displayTotal must not show that 0.
        let partial = tokenCount(total: 0, input: 30, cachedInput: 5, cachedWrite: 2, output: 10, reasoning: 1)
        #expect(partial.displayTotal == 48)
    }

    @Test("displayTotal uses totalTokens when it is present and nonzero")
    func displayTotalUsesTotalTokensWhenPresent() {
        let full = tokenCount(total: 120, input: 80, output: 40)
        #expect(full.displayTotal == 120)
    }

    @Test("displayTotal is 0 when every field is genuinely 0")
    func displayTotalIsZeroWhenAllPartsAreZero() {
        #expect(tokenCount(total: 0).displayTotal == 0)
    }

    @Test("hasDisplayableContent recognizes a model breakdown or a top-level total alone")
    func hasDisplayableContentRecognizesEitherShape() {
        #expect(ACPPromptQuota(
            tokenCount: nil,
            modelUsage: [.init(model: "a", tokenCount: tokenCount(total: 1))]
        ).hasDisplayableContent)

        #expect(ACPPromptQuota(tokenCount: tokenCount(total: 1), modelUsage: []).hasDisplayableContent)

        #expect(!ACPPromptQuota(tokenCount: nil, modelUsage: []).hasDisplayableContent)
    }
}
