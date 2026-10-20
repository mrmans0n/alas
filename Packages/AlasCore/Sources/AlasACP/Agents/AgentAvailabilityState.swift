import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum AgentAvailabilityState: Equatable, Sendable {
    case loading
    case available([AgentDefinition])
    case failed(String)

    public var agents: [AgentDefinition] {
        guard case .available(let agents) = self else { return [] }
        return agents
    }
}
