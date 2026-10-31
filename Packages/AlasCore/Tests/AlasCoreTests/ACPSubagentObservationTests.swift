import Foundation
import Testing
import AlasCore

struct ACPSubagentObservationTests {
    @Test("a child's config snapshot projects to model and effort labels", arguments: [true, false])
    func configSummary(confirmed: Bool) throws {
        let options = [
            ACPConfigOption(id: "model", name: "Model", category: "model", currentValue: .string("gpt-5"),
                            options: [.init(id: "gpt-5", name: "GPT-5")]),
            ACPConfigOption(id: "reasoning_effort", name: "Effort", category: "thought_level",
                            currentValue: .string("high"),
                            options: [.init(id: "high", name: "High")])]
        let summary = try #require(ACPSubagentConfigSummary.make(
            agentId: "codex", configOptions: options, isConfirmed: confirmed))
        #expect(summary.model == "GPT-5")
        #expect(summary.effort == "High")
        #expect(summary.isConfirmed == confirmed)
        #expect(ACPSubagentConfigSummary.make(agentId: "codex", configOptions: [], isConfirmed: true) == nil)
    }
}
