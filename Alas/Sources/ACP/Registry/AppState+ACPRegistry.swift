import Foundation

extension AppState {
    /// Installs (or updates) `agent` from the ACP registry and adds it to the
    /// launch catalog. An update keeps the user's enabled choice.
    func installRegistryAgent(
        _ agent: ACPRegistryAgent,
        installer: ACPRegistryInstaller = ACPRegistryInstaller()
    ) async throws {
        var record = try await installer.install(agent)
        if let index = config.agents.registry.firstIndex(where: { $0.registryID == agent.id }) {
            record.isEnabled = config.agents.registry[index].isEnabled
            config.agents.registry[index] = record
        } else {
            config.agents.registry.append(record)
        }
        saveConfig()
        rescanAgents()
    }

    func uninstallRegistryAgent(
        registryID: String,
        installer: ACPRegistryInstaller = ACPRegistryInstaller()
    ) throws {
        try installer.uninstall(registryID: registryID)
        config.agents.registry.removeAll { $0.registryID == registryID }
        saveConfig()
        rescanAgents()
    }
}
