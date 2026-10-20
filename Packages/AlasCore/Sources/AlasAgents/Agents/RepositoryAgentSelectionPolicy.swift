import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum RepositoryAgentSelectionPolicy: Sendable {
    public enum Selection: Equatable, Sendable {
        case agent(AgentDefinition)
        case loading
        case empty
        case selectionUnavailable
        case failed(String)

        public var agent: AgentDefinition? {
            guard case .agent(let agent) = self else { return nil }
            return agent
        }
    }

    /// Resolves Settings → Changes → AI tool for one feature. Automatic (or
    /// nil) picks the first available agent the feature can run; an explicit
    /// id must name one; `disabledAIToolID` names none.
    public static func selection(
        selectedID: String?,
        availability: AgentAvailabilityState,
        where isEligible: (AgentDefinition) -> Bool = { _ in true }
    ) -> Selection {
        switch availability {
        case .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .available(let agents):
            let eligible = agents.filter(isEligible)
            guard let first = eligible.first else { return .empty }
            let selectedID = selectedID ?? AppConfig.Changes.automaticAIToolID
            if selectedID == AppConfig.Changes.automaticAIToolID { return .agent(first) }
            guard let agent = eligible.first(where: { $0.id == selectedID }) else {
                return .selectionUnavailable
            }
            return .agent(agent)
        }
    }
}
