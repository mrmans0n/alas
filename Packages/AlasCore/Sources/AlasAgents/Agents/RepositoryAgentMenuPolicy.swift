import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum RepositoryAgentMenuPolicy: Sendable {
    public static func directAgents(from availableAgents: [AgentDefinition]) -> [AgentDefinition] {
        availableAgents.filter(\.supportsTerminal)
    }

    public static func acpAgents(from availableAgents: [AgentDefinition]) -> [AgentDefinition] {
        let acpAgentIDs = Set(ACPLaunchCatalog.specs.map(\.agentID))
        return availableAgents.filter { acpAgentIDs.contains($0.id) }
    }
}
