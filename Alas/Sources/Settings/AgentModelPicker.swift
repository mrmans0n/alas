import SwiftUI

/// Agent and model menus for a `ReviewerChoice`. A nil choice inherits from a
/// wider setting and shows `inheritLabel`; `.sameAsSession` is offered only
/// when `allowsSameAsSession` is set. `readOnlyAgentsOnly` lists only agents
/// whose read-only mode holds, as an unattended reviewer needs. A saved
/// agent or model the lists no longer carry stays selectable and is named
/// as such, so the menu never claims a choice the stored value does not hold.
///
/// `body` lays the two menus out side by side; screens that label each menu
/// separately place `agentMenu` and `modelMenu` themselves.
struct AgentModelPicker: View {
    @Binding var choice: ReviewerChoice?
    let allowsSameAsSession: Bool
    let inheritLabel: String?
    let agents: [AgentDefinition]
    let modelCatalog: ACPAgentModelCatalog
    var readOnlyAgentsOnly = false

    @Environment(\.designScale) private var scale

    static let sameAsSessionLabel = "Same as the session"
    static let agentDefaultLabel = "Agent default"

    var body: some View {
        HStack(spacing: scale.space[2]) {
            agentMenu
            if selectedAgentID != nil {
                modelMenu
            }
        }
    }

    var agentMenu: some View {
        let agents = listedAgents
        let missingAgentID = selectedAgentID.flatMap { id in
            agents.contains { $0.id == id } ? nil : id
        }
        return FieldChipMenu(title: agentTitle) {
            Picker("", selection: agentSelection) {
                if let inheritLabel {
                    Text(inheritLabel).tag(AgentSelection.inherit)
                }
                if allowsSameAsSession {
                    Text(Self.sameAsSessionLabel).tag(AgentSelection.sameAsSession)
                }
                ForEach(agents) { agent in
                    Text(agent.displayName).tag(AgentSelection.agent(agent.id))
                }
                if let missingAgentID {
                    Divider()
                    Text("\(missingAgentID) · unavailable").tag(AgentSelection.agent(missingAgentID))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityLabel("Agent")
    }

    /// Models the selected agent advertised in earlier sessions.
    var modelMenu: some View {
        let models = selectedAgentID.map { modelCatalog.models(for: $0) } ?? []
        let modelID = selectedModelID
        let missingModelID = modelID.flatMap { id in
            models.contains { $0.id == id } ? nil : id
        }
        let title: String = {
            guard let modelID else { return Self.agentDefaultLabel }
            if let model = models.first(where: { $0.id == modelID }) { return model.name }
            return "\(modelID) · not listed"
        }()
        return FieldChipMenu(title: title) {
            Picker("", selection: modelSelection) {
                Text(Self.agentDefaultLabel).tag("")
                ForEach(models) { model in
                    Text(model.name).tag(model.id)
                }
                if let missingModelID {
                    Divider()
                    Text("\(missingModelID) · not listed").tag(missingModelID)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(models.isEmpty && missingModelID == nil)
        .accessibilityLabel("Model")
    }

    /// "Codex gpt-5.2", "Codex", or "Same as the session", for naming a
    /// choice in one line (the inherit label of a narrower setting).
    static func label(
        for choice: ReviewerChoice,
        agents: [AgentDefinition],
        modelCatalog: ACPAgentModelCatalog
    ) -> String {
        switch choice {
        case .sameAsSession:
            return sameAsSessionLabel
        case let .agent(id, modelID):
            let agentName = agents.first { $0.id == id }?.displayName ?? id
            guard let modelID else { return agentName }
            let modelName = modelCatalog.models(for: id).first { $0.id == modelID }?.name ?? modelID
            return "\(agentName) \(modelName)"
        }
    }

    // MARK: - Selection

    private enum AgentSelection: Hashable {
        case inherit
        case sameAsSession
        case agent(String)
    }

    private var listedAgents: [AgentDefinition] {
        guard readOnlyAgentsOnly else { return agents }
        return agents.filter { ACPSideQuestionSupportPolicy.enforcesReadOnly(agentId: $0.id) }
    }

    private var selectedAgentID: String? {
        if case let .agent(id, _) = choice { return id }
        return nil
    }

    private var selectedModelID: String? {
        if case let .agent(_, modelID) = choice { return modelID }
        return nil
    }

    private var agentTitle: String {
        switch choice {
        case nil:
            return inheritLabel ?? ""
        case .sameAsSession:
            return Self.sameAsSessionLabel
        case let .agent(id, _):
            if let agent = listedAgents.first(where: { $0.id == id }) { return agent.displayName }
            return "\(id) · unavailable"
        }
    }

    private var agentSelection: Binding<AgentSelection> {
        Binding(
            get: {
                switch choice {
                case nil: .inherit
                case .sameAsSession: .sameAsSession
                case let .agent(id, _): .agent(id)
                }
            },
            set: { selected in
                switch selected {
                case .inherit:
                    choice = nil
                case .sameAsSession:
                    choice = .sameAsSession
                case let .agent(id):
                    // A model belongs to the agent it was listed for.
                    guard id != selectedAgentID else { return }
                    choice = .agent(id: id, modelID: nil)
                }
            }
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { selectedModelID ?? "" },
            set: { selected in
                guard let agentID = selectedAgentID else { return }
                choice = .agent(id: agentID, modelID: selected.isEmpty ? nil : selected)
            }
        )
    }
}

/// A field-shaped menu: current value, chevron, and a menu of choices. The
/// same silhouette as `ProjectPicker` so a row of the two reads as one kind
/// of control.
struct FieldChipMenu<Items: View>: View {
    let title: String
    var monospaced = false
    var grows = false
    @ViewBuilder let items: () -> Items

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: scale.space[2]) {
                Text(title)
                    .font(scale.meta.font(design: monospaced ? .monospaced : .default))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if grows {
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.down")
                    .font(scale.glyphFont)
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, scale.space[2])
            .frame(height: 28)
            .frame(maxWidth: grows ? .infinity : nil)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !grows, vertical: true)
    }
}
