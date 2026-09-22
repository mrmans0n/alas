import Testing
import Foundation
import Network
@testable import Alas

/// Real Bonjour on this host: a `RemoteServer` advertises, a real `NWBrowser`
/// finds it, and the resolver lands on the listener's port. Exercises the
/// `NWListener.service` assignment, the TXT record on the wire, the browse
/// result mapping, and TCP resolution together, which no fake can.
@MainActor
struct RemoteDiscoveryIntegrationTests {
    private func startServer() async throws -> RemoteServer {
        let server = RemoteServer(
            pairing: RemotePairingService(store: InMemoryDeviceStore()),
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: FakeSessionsProvider())
        try server.start(port: 0)
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(server.port != nil)
        return server
    }

    private func waitForInstance(id: String, in browser: RemotePeerBrowser, seconds: Double) async -> RemoteDiscoveredInstance? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = browser.instances.first(where: { $0.id == id }) { return found }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    @Test func advertisedServerIsBrowsedAndResolvesToItsPort() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let serverId = "test-\(UUID().uuidString)"
        let name = "Alas Test \(UUID().uuidString.prefix(8))"
        server.advertise(RemoteBonjourAdvertisement(
            displayName: name,
            txt: RemoteBonjourTXT(serverId: serverId, model: "TestMac1,1")))

        let browser = RemotePeerBrowser(localServerId: { "someone-else" })
        browser.start()
        defer { browser.stop() }

        let instance = try #require(await waitForInstance(id: serverId, in: browser, seconds: 10),
                                    "the advertised server never showed up in a real Bonjour browse")
        #expect(instance.name == name)
        #expect(instance.model == "TestMac1,1")
        #expect(instance.protocolVersion == RemoteProtocolVersion.current)

        let resolved = try await RemoteDiscoveredInstanceResolver.resolveOverTCP(instance.endpoint, timeout: 10)
        #expect(resolved.port == server.port)
        #expect(!resolved.host.isEmpty)
    }

    @Test func ownAdvertisementIsHiddenAndWithdrawnWhenAdvertiseIsNil() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let serverId = "test-\(UUID().uuidString)"
        server.advertise(RemoteBonjourAdvertisement(
            displayName: "Alas Self \(UUID().uuidString.prefix(8))",
            txt: RemoteBonjourTXT(serverId: serverId, model: nil)))

        // Browsing as the same identity: the row must never appear.
        let selfBrowser = RemotePeerBrowser(localServerId: { serverId })
        selfBrowser.start()
        defer { selfBrowser.stop() }
        // Another identity sees it, which proves the advertisement is live
        // and the self-filter, not a slow mDNS, is why `selfBrowser` is empty.
        let otherBrowser = RemotePeerBrowser(localServerId: { "someone-else" })
        otherBrowser.start()
        defer { otherBrowser.stop() }
        _ = try #require(await waitForInstance(id: serverId, in: otherBrowser, seconds: 10))
        #expect(selfBrowser.instances.contains(where: { $0.id == serverId }) == false)

        server.advertise(nil)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, otherBrowser.instances.contains(where: { $0.id == serverId }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(otherBrowser.instances.contains(where: { $0.id == serverId }) == false,
                "withdrawing the advertisement should remove the row")
    }
}
