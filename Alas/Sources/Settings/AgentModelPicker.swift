import SwiftUI

/// Agent and model chips for a `ReviewerChoice`, in the same agent-logo
/// `ACPSelectChip` pair as the new-worktree dialog and the schedule editor.
/// A nil choice inherits from a wider setting and shows `inheritLabel`;
/// `.sameAsSession` is offered only when `allowsSameAsSession` is set. With
/// `picksReviewer`, agents whose read-only mode Alas can't enforce say they
/// review in a separate checkout. A saved agent or model the lists no longer
/// carry stays selectable and is named as such, so the chip never claims a
/// choice the stored value does not hold.
struct AgentModelPicker: View {
    @Binding var choice: ReviewerChoice?
    let allowsSameAsSession: Bool
    let inheritLabel: String?
    let agents: [AgentDefinition]
    let modelCatalog: ACPAgentModelCatalog
    var picksReviewer = false

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    static let sameAsSessionLabel = "Same as the session"
    static let agentDefaultLabel = "Agent default"

    var body: some View {
        HStack(spacing: scale.space[2]) {
            agentChip
            if let selectedAgentID {
                modelChip(agentID: selectedAgentID)
            }
        }
    }

    private var agentChip: some View {
        let items = agentItems
        let selectedID = Self.itemID(for: agentSelection)
        return ACPSelectChip(
            label: items.first { $0.id == selectedID }?.name ?? "",
            placeholder: "Agent",
            accent: theme.color("fg-muted"),
            items: items,
            selectedId: selectedID,
            searchDescriptions: false,
            searchIdentifiers: false,
            fillsWidth: false,
            onSelect: { item in
                guard let selection = Self.selection(forItemID: item.id) else { return }
                select(selection)
            }
        )
        .accessibilityLabel("Agent")
    }

    private var agentItems: [ACPSelectChip.Item] {
        var items: [ACPSelectChip.Item] = []
        if let inheritLabel {
            items.append(ACPSelectChip.Item(
                id: Self.itemID(for: .inherit),
                name: inheritLabel,
                description: nil,
                icon: .system("gearshape")
            ))
        }
        if allowsSameAsSession {
            items.append(ACPSelectChip.Item(
                id: Self.itemID(for: .sameAsSession),
                name: Self.sameAsSessionLabel,
                description: nil,
                icon: .system("bubble.left")
            ))
        }
        items += agents.map { agent in
            ACPSelectChip.Item(
                id: Self.itemID(for: .agent(agent.id)),
                name: agent.displayName,
                description: reviewerNote(agentID: agent.id),
                icon: .image(AgentLogoView.menuImage(for: agent, size: 14))
            )
        }
        if let selectedAgentID, !agents.contains(where: { $0.id == selectedAgentID }) {
            items.append(ACPSelectChip.Item(
                id: Self.itemID(for: .agent(selectedAgentID)),
                name: "\(selectedAgentID) · unavailable",
                description: nil,
                icon: .system("sparkles")
            ))
        }
        return items
    }

    /// Models the selected agent advertised in earlier sessions.
    private func modelChip(agentID: String) -> some View {
        let models = modelCatalog.models(for: agentID)
        var items = [ACPSelectChip.Item(id: Self.agentDefaultItemID, name: Self.agentDefaultLabel, description: nil)]
        items += models.map { ACPSelectChip.Item(id: $0.id, name: $0.name, description: nil) }
        if let selectedModelID, !models.contains(where: { $0.id == selectedModelID }) {
            items.append(ACPSelectChip.Item(id: selectedModelID, name: "\(selectedModelID) · not listed", description: nil))
        }
        let selectedID = selectedModelID ?? Self.agentDefaultItemID
        return ACPSelectChip(
            label: items.first { $0.id == selectedID }?.name ?? "",
            placeholder: "Model",
            accent: theme.color("syntax-keyword"),
            items: items,
            selectedId: selectedID,
            searchDescriptions: false,
            searchIdentifiers: false,
            fillsWidth: false,
            onSelect: { item in
                choice = .agent(id: agentID, modelID: item.id == Self.agentDefaultItemID ? nil : item.id)
            }
        )
        .disabled(items.count == 1)
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

    /// Model ids are never empty, so this "use the default" row cannot
    /// collide with a real one.
    private static let agentDefaultItemID = ""
    private static let agentItemPrefix = "agent:"

    /// Agent rows are prefixed so no agent id can collide with the inherit
    /// or same-as-session rows.
    private static func itemID(for selection: AgentSelection) -> String {
        switch selection {
        case .inherit: "inherit"
        case .sameAsSession: "same-as-session"
        case let .agent(id): agentItemPrefix + id
        }
    }

    private static func selection(forItemID id: String) -> AgentSelection? {
        if id.hasPrefix(agentItemPrefix) { return .agent(String(id.dropFirst(agentItemPrefix.count))) }
        if id == itemID(for: .inherit) { return .inherit }
        if id == itemID(for: .sameAsSession) { return .sameAsSession }
        return nil
    }

    /// Where a reviewer that can't be held read-only works instead.
    private func reviewerNote(agentID: String) -> String? {
        guard picksReviewer, !ACPSideQuestionSupportPolicy.enforcesReadOnly(agentId: agentID) else { return nil }
        return "reviews in a separate checkout"
    }

    private var selectedAgentID: String? {
        if case let .agent(id, _) = choice { return id }
        return nil
    }

    private var selectedModelID: String? {
        if case let .agent(_, modelID) = choice { return modelID }
        return nil
    }

    private var agentSelection: AgentSelection {
        switch choice {
        case nil: .inherit
        case .sameAsSession: .sameAsSession
        case let .agent(id, _): .agent(id)
        }
    }

    private func select(_ selection: AgentSelection) {
        switch selection {
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
        .fixedSize(horizontal: false, vertical: true)
    }
}
