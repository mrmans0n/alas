import Foundation

enum RepositoryAgentSelectionPolicy {
    enum Selection: Equatable {
        case agent(AgentDefinition)
        case loading
        case empty
        case selectionUnavailable
        case failed(String)

        var agent: AgentDefinition? {
            guard case .agent(let agent) = self else { return nil }
            return agent
        }
    }

    static func selection(
        selectedID: String?,
        availability: AgentAvailabilityState
    ) -> Selection {
        switch availability {
        case .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .available(let agents):
            guard !agents.isEmpty else { return .empty }
            guard let selectedID,
                  selectedID != "none",
                  let agent = agents.first(where: { $0.id == selectedID }) else {
                return .selectionUnavailable
            }
            return .agent(agent)
        }
    }
}
