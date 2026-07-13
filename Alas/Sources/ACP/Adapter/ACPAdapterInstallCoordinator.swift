import Foundation

actor ACPAdapterInstallCoordinator {
    typealias LocalInstall = @Sendable (_ agentID: String) async throws -> Void
    typealias RemoteInstall = @Sendable (
        _ host: String,
        _ descriptor: ACPManagedAdapterDescriptor
    ) async throws -> Void

    private let localInstall: LocalInstall
    private let remoteInstall: RemoteInstall
    private var inFlight: [ACPAdapterUpdateKey: Task<Void, Error>] = [:]

    init(
        localInstall: @escaping LocalInstall = { agentID in
            try await ACPInstallerRegistry.install(agentID: agentID)
        },
        remoteInstall: @escaping RemoteInstall = { host, descriptor in
            try await ACPRemoteAdapterManagement().install(host: host, descriptor: descriptor)
        }
    ) {
        self.localInstall = localInstall
        self.remoteInstall = remoteInstall
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

    func isInstalling(target: ACPAdapterTarget, agentID: String) -> Bool {
        inFlight[ACPAdapterUpdateKey(target: target, agentID: agentID)] != nil
    }
}
