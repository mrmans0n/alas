import Foundation

/// What a child session reported about its own configuration, reduced to the
/// labels a subagent row shows. Built from the child's own config snapshot
/// only — never from the parent's settings or the spawn arguments.
public struct ACPSubagentConfigSummary: Equatable, Sendable {
    public let model: String?
    public let effort: String?
    /// Every other select option the child advertised, as "Label: Value".
    public let parameters: [String]
    /// Observed live on the current connection, rather than restored or
    /// replayed history.
    public let isConfirmed: Bool

    public init(model: String?, effort: String?, parameters: [String], isConfirmed: Bool) {
        self.model = model
        self.effort = effort
        self.parameters = parameters
        self.isConfirmed = isConfirmed
    }

    /// nil when the child advertised nothing displayable.
    public static func make(
        agentId: String, configOptions: [ACPConfigOption], isConfirmed: Bool
    ) -> ACPSubagentConfigSummary? {
        let chips = ACPChipState.normalize(
            agentId: agentId,
            availableModels: [],
            currentModel: nil,
            availableModes: [],
            currentMode: nil,
            configOptions: configOptions)
        let model = chips.models?.currentName
        let effort = chips.thinking?.currentName
        let parameters = chips.parameters.compactMap { chip in
            chip.spec.currentName.map { "\(chip.label): \($0)" }
        }
        guard model != nil || effort != nil || !parameters.isEmpty else { return nil }
        return .init(model: model, effort: effort, parameters: parameters, isConfirmed: isConfirmed)
    }
}
