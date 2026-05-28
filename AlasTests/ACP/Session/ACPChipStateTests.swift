import Foundation
import Testing
@testable import Alas

@Suite("ACPChipState")
struct ACPChipStateTests {
    private func mode(_ id: String, _ name: String) -> ACPModeInfo {
        ACPModeInfo(id: id, name: name)
    }
    private func model(_ id: String, _ name: String) -> ACPModelInfo {
        ACPModelInfo(id: id, name: name)
    }
    private func configOption(_ id: String,
                              current: String,
                              options: [(String, String)],
                              category: String? = nil) -> ACPConfigOption {
        ACPConfigOption(
            id: id, name: id.capitalized, type: "select",
            category: category, currentValue: current,
            options: options.map { ACPConfigOptionItem(id: $0.0, name: $0.1) })
    }

    @Test("claude: modes -> Mode chip, effort configOption -> Thinking chip")
    func claudeFullHouse() {
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [model("opus", "Opus")],
            currentModel: "opus",
            availableModes: [mode("plan", "Plan"), mode("default", "Default")],
            currentMode: "default",
            configOptions: [configOption("effort",
                                         current: "high",
                                         options: [("low","Low"),("high","High")])])
        #expect(state.models?.options.count == 1)
        #expect(state.mode?.options.count == 2)
        #expect(state.mode?.currentId == "default")
        #expect(state.mode?.source == .mode)
        #expect(state.thinking?.currentId == "high")
        if case .configOption(let id)? = state.thinking?.source { #expect(id == "effort") }
        else { Issue.record("expected configOption source") }
        #expect(state.autoRun == .supported)
    }

    @Test("pi: modes route to Thinking, Mode chip is nil")
    func piRoutesModesToThinking() {
        let state = ACPChipState.normalize(
            agentId: "pi",
            availableModels: [model("pi-1", "Pi")],
            currentModel: "pi-1",
            availableModes: [mode("low","Low"), mode("medium","Medium"), mode("high","High")],
            currentMode: "medium",
            configOptions: [])
        #expect(state.mode == nil)
        #expect(state.thinking?.options.count == 3)
        #expect(state.thinking?.currentId == "medium")
        #expect(state.thinking?.source == .mode)
        #expect(state.autoRun == .ignored)
    }

    @Test("claude without effort configOption: Thinking chip is nil")
    func claudeNoEffort() {
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [model("opus", "Opus")],
            currentModel: "opus",
            availableModes: [mode("plan", "Plan")],
            currentMode: "plan",
            configOptions: [])
        #expect(state.thinking == nil)
        #expect(state.mode?.options.count == 1)
    }

    @Test("unknown agent: heuristic picks ThoughtLevel-category option")
    func unknownAgentByCategory() {
        let state = ACPChipState.normalize(
            agentId: "future-agent",
            availableModels: [model("m", "M")],
            currentModel: "m",
            availableModes: [],
            currentMode: nil,
            configOptions: [configOption("speed",
                                         current: "fast",
                                         options: [("fast","Fast")]),
                            configOption("brainpower",
                                         current: "high",
                                         options: [("low","Low"),("high","High")],
                                         category: "ThoughtLevel")])
        if case .configOption(let id)? = state.thinking?.source {
            #expect(id == "brainpower")
        } else { Issue.record("expected ThoughtLevel option to be picked") }
    }

    @Test("non-select configOption is dropped (empty options)")
    func nonSelectDropped() {
        let textOpt = ACPConfigOption(id: "effort", name: "Effort",
                                      type: "text", category: nil,
                                      currentValue: "", options: [])
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [model("opus","Opus")],
            currentModel: "opus",
            availableModes: [mode("plan","Plan")],
            currentMode: "plan",
            configOptions: [textOpt])
        #expect(state.thinking == nil)
    }

    @Test("Models chip is nil when availableModels is empty (still loading)")
    func modelsNilDuringLoad() {
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [],
            currentModel: nil,
            availableModes: [],
            currentMode: nil,
            configOptions: [])
        #expect(state.models == nil)
    }
}
