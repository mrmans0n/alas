import Testing
@testable import Alas

struct RemoteSessionConfigProjectionTests {
    private func select(_ id: String, category: String?, current: String, _ ids: [String]) -> ACPConfigOption {
        ACPConfigOption(id: id, name: id.capitalized, type: "select", category: category,
                        currentValue: ACPConfigValue.string(current),
                        options: ids.map { ACPConfigOptionItem(id: $0, name: $0.uppercased(), description: nil) })
    }

    @Test func configBackedModelKeepsConfigSourceAndThinkingIsProjected() {
        let options = [
            select("model", category: "model", current: "gpt", ["gpt", "mini"]),
            select("reasoning_effort", category: "thought_level", current: "high", ["low", "high"]),
            ACPConfigOption(id: "web", name: "Web search", type: "boolean", category: nil,
                            currentValue: ACPConfigValue.boolean(true), options: []),
        ]
        let state = ACPChipState.normalize(agentId: "codex", availableModels: [], currentModel: nil,
                                           availableModes: [], currentMode: nil, configOptions: options)
        let chips = RemoteSessionConfigProjection.chips(state, configOptions: options)
        #expect(chips.model?.source == "config")
        #expect(chips.model?.configId == "model")
        #expect(chips.model?.currentId == "gpt")
        #expect(chips.thinking?.configId == "reasoning_effort")
        #expect(chips.thinking?.options.map(\.id) == ["low", "high"])
        #expect(chips.booleans == [RemoteBooleanOption(id: "web", name: "Web search", value: true)])
    }

    @Test func legacyModelsAndModesKeepTheirSources() {
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [ACPModelInfo(id: "opus", name: "Opus", description: nil)], currentModel: "opus",
            availableModes: [ACPModeInfo(id: "plan", name: "Plan", description: nil)], currentMode: "plan",
            configOptions: [])
        let chips = RemoteSessionConfigProjection.chips(state, configOptions: [])
        #expect(chips.model?.source == "model")
        #expect(chips.model?.configId == nil)
        #expect(chips.mode?.source == "mode")
    }
}
