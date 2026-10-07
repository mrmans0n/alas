import Foundation

actor ACPAdapterInstallCoordinator {
    typealias LocalInstall = @Sendable (_ agentID: String) async throws -> Void
    typealias RemoteInstall = @Sendable (
        _ host: String,
        _ descriptor: ACPManagedAdapterDescriptor
    ) async throws -> Void

    private let localInstall: LocalInstall
    private let remoteInstall: RemoteInstall
    private let detectedUpdate: DetectedUpdate
    private var inFlight: [ACPAdapterUpdateKey: Task<Void, Error>] = [:]

    typealias DetectedUpdate = @Sendable (_ owner: ACPDetectedAgentOwner) async throws -> Void

    init(
        localInstall: @escaping LocalInstall = { agentID in
            try await ACPInstallerRegistry.install(agentID: agentID)
        },
        remoteInstall: @escaping RemoteInstall = { host, descriptor in
            try await ACPRemoteAdapterManagement().install(host: host, descriptor: descriptor)
        },
        detectedUpdate: @escaping DetectedUpdate = { owner in
            try await ACPDetectedAgentUpdater().upgrade(owner: owner)
        }
    ) {
        self.localInstall = localInstall
        self.remoteInstall = remoteInstall
        self.detectedUpdate = detectedUpdate
    }

    func install(target: ACPAdapterTarget, agentID: String) async throws {
        let key = ACPAdapterUpdateKey(target: target, agentID: agentID)
        if let task = inFlight[key] {
            return try await task.value
        }

        let task: Task<Void, Error>
        switch target {
        case .local:
            task = Task { try await localInstall(agentID) }
        case .ssh(let host):
            guard let descriptor = ACPManagedAdapterDescriptor.descriptor(for: agentID) else {
                throw ACPRemoteAdapterInstallError.unsupportedAgent(agentID)
            }
            task = Task { try await remoteInstall(host, descriptor) }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }

    /// Upgrades a detected agent CLI through the package manager that owns it,
    /// sharing one run across tabs showing the same agent.
    func updateDetectedAgent(agentID: String, owner: ACPDetectedAgentOwner) async throws {
        let key = ACPAdapterUpdateKey.detectedCLI(agentID: agentID, owner: owner)
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await detectedUpdate(owner) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }

    func isInstalling(target: ACPAdapterTarget, agentID: String) -> Bool {
        inFlight[ACPAdapterUpdateKey(target: target, agentID: agentID)] != nil
    }
}
