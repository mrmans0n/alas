import Foundation
import Network
import Testing
@testable import Alas

@MainActor struct RemotePairingApprovalDiscoveryTests {
    @Test func capabilityNeedsMatchingDiagnosticsIdentity() async throws {
        let instance = RemoteDiscoveredInstance(id: "receiver", name: "Mac", protocolVersion: 1, model: nil,
            endpoints: [.hostPort(host: "fd00::5", port: 8765)])
        for id in [nil, "", "receiver", "other"] as [String?] {
            for version in [nil, 1] as [Int?] {
                let snapshot = RemoteDiagnosticsSnapshot(appName: "Alas", port: 8765, addresses: [],
                    usesPlainHTTP: true, pairedDeviceCount: 0, serverId: id, pairingApprovalVersion: version)
                let data = try JSONEncoder().encode(snapshot)
                let resolver = RemoteDiscoveredInstanceResolver(resolve: { _ in ("fd00::5", 8765) }, fetch: { request in
                    (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
                let result = await resolver.resolvePeer(for: instance)
                if id == "other" {
                    #expect(result == .failure(.identityMismatch))
                } else {
                    #expect(result == .success(.init(origins: ["http://[fd00::5]:8765"], serverID: id,
                        pairingApprovalVersion: id == "receiver" ? version : nil)))
                    #expect(await resolver.origins(for: instance) == .success(["http://[fd00::5]:8765"]))
                }
            }
        }
    }

    @Test func capabilityAdvertisementRequiresEnabledGatesAndPersistentKey() {
        let signer = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        var federation = true
        let server = RemoteServer(pairing: RemotePairingService(store: InMemoryDeviceStore()),
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())), provider: FakeSessionsProvider(),
            diagnostics: { _ in
                RemoteDiagnosticsSnapshot(appName: "Alas", port: nil, addresses: [], usesPlainHTTP: true,
                    pairedDeviceCount: 0, pairingApprovalVersion: 99)
            },
            identity: { () -> RemoteServerIdentity in
                RemoteServerIdentity(serverId: "receiver", name: "Mac", federationEnabled: federation)
            },
            signer: signer)
        #expect(server.diagnosticsSnapshot().pairingApprovalVersion == nil)
        server.approvalEnabled = { true }
        #expect(server.pairingApprovalVersion == nil)
        server.approvalCoordinator = RemotePairingApprovalCoordinator(localPeer: {
            ApprovalPeer(serverID: "receiver", publicKey: signer.publicKey, name: "Mac", origins: ["http://10.0.0.1:8765"])
        }, signer: signer)
        #expect(server.diagnosticsSnapshot().pairingApprovalVersion == 1)
        federation = false
        #expect(server.pairingApprovalVersion == nil)
        federation = true
        server.approvalEnabled = { false }
        #expect(server.pairingApprovalVersion == nil)
    }

    @Test func unavailableSignerNeverAdvertisesApproval() {
        let signer = RemoteIdentityKeyProvider(store: UnavailableApprovalStore())
        let server = RemoteServer(pairing: RemotePairingService(store: InMemoryDeviceStore()),
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())), provider: FakeSessionsProvider(),
            identity: { () -> RemoteServerIdentity in
                RemoteServerIdentity(serverId: "receiver", name: "Mac", federationEnabled: true)
            },
            signer: signer)
        server.approvalEnabled = { true }
        server.approvalCoordinator = RemotePairingApprovalCoordinator(localPeer: {
            ApprovalPeer(serverID: "receiver", publicKey: signer.publicKey, name: "Mac", origins: ["http://10.0.0.1:8765"])
        }, signer: signer)
        #expect(server.pairingApprovalVersion == nil)
    }
}

private final class UnavailableApprovalStore: RemoteSecretStore, @unchecked Sendable {
    func secret(for account: String) -> Data? { nil }
    func setSecret(_ data: Data?, for account: String) -> Bool { false }
}
