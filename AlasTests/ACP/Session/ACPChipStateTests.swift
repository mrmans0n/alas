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

    private func booleanOption(_ id: String,
                               current: Bool,
                               category: String? = nil) -> ACPConfigOption {
        ACPConfigOption(id: id, name: id.capitalized, type: "boolean",
                        category: category, currentValue: .boolean(current))
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

    @Test("Models chip sources from category=model configOption when present")
    func modelFromConfigOption() {
        let modelOpt = configOption("preset",
                                    current: "sonnet",
                                    options: [("opus","Opus"),("sonnet","Sonnet")],
                                    category: "model")
        let state = ACPChipState.normalize(
            agentId: "future-agent",
            availableModels: [],
            currentModel: nil,
            availableModes: [],
            currentMode: nil,
            configOptions: [modelOpt])
        #expect(state.models?.currentId == "sonnet")
        #expect(state.models?.options.count == 2)
        if case .configOption(let id)? = state.models?.source {
            #expect(id == "preset")
        } else { Issue.record("expected configOption source for model chip") }
    }

    @Test("canonical category lookup skips boolean options")
    func canonicalCategorySkipsBooleanOptions() {
        let state = ACPChipState.normalize(
            agentId: "future-agent",
            availableModels: [],
            currentModel: nil,
            availableModes: [],
            currentMode: nil,
            configOptions: [
                booleanOption("fast_model", current: false, category: "model"),
                configOption("preset",
                             current: "sonnet",
                             options: [("opus","Opus"),("sonnet","Sonnet")],
                             category: "model"),
            ])
        #expect(state.models?.currentId == "sonnet")
        if case .configOption(let id)? = state.models?.source {
            #expect(id == "preset")
        } else { Issue.record("expected select configOption source for model chip") }
    }

    @Test("Mode chip sources from category=mode configOption when present")
    func modeFromConfigOption() {
        let modeOpt = configOption("posture",
                                   current: "plan",
                                   options: [("build","Build"),("plan","Plan")],
                                   category: "mode")
        let state = ACPChipState.normalize(
            agentId: "future-agent",
            availableModels: [model("m","M")],
            currentModel: "m",
            availableModes: [],
            currentMode: nil,
            configOptions: [modeOpt])
        #expect(state.mode?.currentId == "plan")
        if case .configOption(let id)? = state.mode?.source {
            #expect(id == "posture")
        } else { Issue.record("expected configOption source for mode chip") }
    }

    @Test("configOption mode selector wins over legacy availableModes")
    func modeConfigOptionWinsOverLegacy() {
        let modeOpt = configOption("posture",
                                   current: "plan",
                                   options: [("build","Build"),("plan","Plan")],
                                   category: "mode")
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [model("opus","Opus")],
            currentModel: "opus",
            availableModes: [mode("legacy","Legacy")],
            currentMode: "legacy",
            configOptions: [modeOpt])
        if case .configOption(let id)? = state.mode?.source {
            #expect(id == "posture")
        } else { Issue.record("configOption mode chip should win") }
        #expect(state.mode?.currentId == "plan")
    }

    @Test("configOption model selector wins over legacy availableModels")
    func modelConfigOptionWinsOverLegacy() {
        let modelOpt = configOption("preset",
                                    current: "sonnet",
                                    options: [("opus","Opus"),("sonnet","Sonnet")],
                                    category: "model")
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [model("legacy","Legacy")],
            currentModel: "legacy",
            availableModes: [],
            currentMode: nil,
            configOptions: [modelOpt])
        #expect(state.models?.currentId == "sonnet")
        if case .configOption(let id)? = state.models?.source {
            #expect(id == "preset")
        } else { Issue.record("configOption model chip should win") }
    }
}

extension ACPChipStateTests {
    @Test("cursor-agent: variant suffixes synthesize Model + Thinking chips")
    func cursorVariantsSynthesizeChips() {
        let state = ACPChipState.normalize(
            agentId: "cursor-agent",
            availableModels: [
                model("claude-opus-4-6[effort=low,context=200k]",    "Opus 4.6"),
                model("claude-opus-4-6[effort=medium,context=200k]", "Opus 4.6"),
                model("claude-opus-4-6[effort=high,context=200k]",   "Opus 4.6"),
                model("gpt-5.3-codex[effort=medium]",                "GPT 5.3 Codex"),
            ],
            currentModel: "claude-opus-4-6[effort=medium,context=200k]",
            availableModes: [mode("agent", "Agent")],
            currentMode: "agent",
            configOptions: [])
        // Derived chips preserve first-appearance order from `availableModels`.
        #expect(state.models?.options.map { $0.name } == ["Opus 4.6", "GPT 5.3 Codex"])
        #expect(state.thinking?.options.map { $0.name } == ["low", "medium", "high"])
        #expect(state.thinking?.source == .model)
        #expect(state.mode?.options.first?.name == "Agent")
    }

    @Test("cursor-agent: real thought_level configOption wins over variant overlay")
    func cursorConfigOptionWinsOverVariants() {
        let state = ACPChipState.normalize(
            agentId: "cursor-agent",
            availableModels: [
                model("claude-opus-4-6[effort=high]", "Opus 4.6"),
                model("claude-opus-4-6[effort=low]",  "Opus 4.6"),
            ],
            currentModel: "claude-opus-4-6[effort=high]",
            availableModes: [],
            currentMode: nil,
            configOptions: [configOption("effort",
                                         current: "high",
                                         options: [("low","Low"),("high","High")],
                                         category: "thought_level")])
        // The heuristic finds the configOption first; overlay is bypassed.
        if case .configOption(let id)? = state.thinking?.source { #expect(id == "effort") }
        else { Issue.record("expected configOption source") }
        #expect(state.thinking?.options.map { $0.name } == ["Low", "High"])
    }

    @Test("cursor-agent: parameterized config options expose Thinking chip")
    func cursorParameterizedConfigOptionsExposeThinking() {
        let state = ACPChipState.normalize(
            agentId: "cursor-agent",
            availableModels: [model("gpt-5.5", "GPT-5.5")],
            currentModel: "gpt-5.5",
            availableModes: [mode("agent", "Agent")],
            currentMode: "agent",
            configOptions: [
                configOption("model",
                             current: "gpt-5.5",
                             options: [("default", "Auto"), ("gpt-5.5", "GPT-5.5")],
                             category: "model"),
                configOption("reasoning",
                             current: "medium",
                             options: [("none", "None"), ("low", "Low"), ("medium", "Medium"),
                                       ("high", "High"), ("extra-high", "Extra High")],
                             category: "thought_level"),
                configOption("context",
                             current: "272k",
                             options: [("272k", "272k"), ("1m", "1m")]),
                configOption("fast",
                             current: "false",
                             options: [("false", "Off"), ("true", "On")]),
            ])

        #expect(state.models?.currentId == "gpt-5.5")
        if case .configOption(let id)? = state.thinking?.source {
            #expect(id == "reasoning")
        } else { Issue.record("expected configOption source") }
        #expect(state.thinking?.currentId == "medium")
        #expect(state.thinking?.options.map { $0.name } == ["None", "Low", "Medium", "High", "Extra High"])
        #expect(state.parameters.map { $0.label } == ["Context", "Fast"])
        #expect(state.parameters.map { $0.spec.currentId } == ["272k", "false"])
        #expect(state.parameters.map { $0.presentation } == [.cursorContextWindow, .fastMode])
    }

    @Test("agents with fast select options expose a fast mode parameter")
    func agentsWithFastSelectOptionsExposeFastModeParameter() {
        let state = ACPChipState.normalize(
            agentId: "future-agent",
            availableModels: [],
            currentModel: nil,
            availableModes: [],
            currentMode: nil,
            configOptions: [
                configOption("context",
                             current: "272k",
                             options: [("272k", "272k"), ("1m", "1m")]),
                configOption("fast",
                             current: "false",
                             options: [("false", "Off"), ("true", "On")]),
            ])

        #expect(state.parameters.map { $0.presentation } == [.standard, .fastMode])
    }

    @Test("fast mode detection accepts common config option spellings")
    func fastModeDetectionAcceptsCommonSpellings() {
        let state = ACPChipState.normalize(
            agentId: "claude",
            availableModels: [],
            currentModel: nil,
            availableModes: [],
            currentMode: nil,
            configOptions: [
                ACPConfigOption(
                    id: "fast-mode",
                    name: "Fast mode",
                    type: "select",
                    currentValue: "off",
                    options: [
                        ACPConfigOptionItem(id: "off", name: "Off"),
                        ACPConfigOptionItem(id: "on", name: "On"),
                    ]),
            ])

        #expect(state.parameters.first?.presentation == .fastMode)
    }

    @Test("fast mode detection ignores unrelated fast model selectors")
    func fastModeDetectionIgnoresUnrelatedFastModelSelectors() {
        let state = ACPChipState.normalize(
            agentId: "codex",
            availableModels: [],
            currentModel: nil,
            availableModes: [],
            currentMode: nil,
            configOptions: [
                configOption("fast_model",
                             current: "enabled",
                             options: [("disabled", "Disabled"), ("enabled", "Enabled")]),
            ])

        #expect(state.parameters.first?.presentation == .standard)
    }

    @Test("fast mode detection recognizes boolean options")
    func fastModeDetectionRecognizesBooleanOptions() {
        let fastMode = ACPConfigOption(
            id: "fast-mode",
            name: "Fast mode",
            type: "boolean",
            currentValue: .boolean(false))
        let fastModel = ACPConfigOption(
            id: "fast_model",
            name: "Fast model",
            type: "boolean",
            currentValue: .boolean(false))

        #expect(ACPChipState.isFastModeConfigOption(fastMode))
        #expect(!ACPChipState.isFastModeConfigOption(fastModel))
    }

    @Test("composer fast and auto-run controls use distinct icon semantics")
    func composerControlIconSemantics() {
        #expect(ACPComposerControlPresentation.fastModeIconName(isEnabled: false) == "bolt")
        #expect(ACPComposerControlPresentation.fastModeIconName(isEnabled: true) == "bolt.fill")
        #expect(ACPComposerControlPresentation.autoRunIconName(isEnabled: false) == "play")
        #expect(ACPComposerControlPresentation.autoRunIconName(isEnabled: true) == "play.fill")
    }

    @Test("composer fast mode help explains the hover action")
    func composerFastModeHelpExplainsHoverAction() {
        #expect(ACPComposerControlPresentation.fastModeHelp(isEnabled: false, canToggle: true) == "Click to enable fast mode")
        #expect(ACPComposerControlPresentation.fastModeHelp(isEnabled: true, canToggle: true) == "Fast mode is ON — click to disable")
        #expect(ACPComposerControlPresentation.fastModeHelp(isEnabled: false, canToggle: false) == "Fast mode cannot be changed")
    }

    @Test("cursor-agent: no brackets -> no synthesized chips")
    func cursorNoBracketsNoOverlay() {
        let state = ACPChipState.normalize(
            agentId: "cursor-agent",
            availableModels: [model("a", "A"), model("b", "B")],
            currentModel: "a",
            availableModes: [],
            currentMode: nil,
            configOptions: [])
        #expect(state.thinking == nil)
        // Legacy availableModels path still produces a Model chip.
        #expect(state.models?.options.map { $0.name } == ["A", "B"])
    }

    @Test("non-cursor agent with bracketed model id: overlay does NOT fire")
    func nonCursorIgnoresVariants() {
        let state = ACPChipState.normalize(
            agentId: "future-agent",
            availableModels: [model("m[effort=high]", "M"), model("m[effort=low]", "M")],
            currentModel: "m[effort=high]",
            availableModes: [],
            currentMode: nil,
            configOptions: [])
        #expect(state.thinking == nil)
    }
}
