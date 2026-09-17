import Foundation

enum RepositoryAgentMenuPolicy {
    static func directAgents(from availableAgents: [AgentDefinition]) -> [AgentDefinition] {
        availableAgents
    }

    static func acpAgents(from availableAgents: [AgentDefinition]) -> [AgentDefinition] {
        let acpAgentIDs = Set(ACPLaunchCatalog.specs.map(\.agentID))
        return availableAgents.filter { acpAgentIDs.contains($0.id) }
    }
}
