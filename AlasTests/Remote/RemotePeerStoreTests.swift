import Testing
import Foundation
@testable import Alas

/// In-memory `RemotePeerStore` shared by the Remote suite.
final class InMemoryPeerStore: RemotePeerStore {
    private(set) var saved: [RemotePeer] = []
    func load() -> [RemotePeer] { saved }
    func save(_ peers: [RemotePeer]) { saved = peers }
}

struct RemotePeerStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-peers-\(UUID().uuidString)")
            .appendingPathComponent("remote-peers.json")
    }

    @Test func missingFileLoadsEmpty() {
        #expect(FilePeerStore(url: tempFile()).load().isEmpty)
    }

    @Test func peersRoundTripThroughDisk() {
        let url = tempFile()
        let peer = RemotePeer(id: "p1", serverId: "srv-b", name: "Studio",
                              origins: ["http://100.64.1.5:8765", "http://192.168.1.20:8765"],
                              lastOrigin: "http://100.64.1.5:8765", token: "tok", protocolVersion: 1,
                              localDeviceId: "d9", addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        FilePeerStore(url: url).save([peer])
        #expect(FilePeerStore(url: url).load() == [peer])
    }

    // Seeded through FilePeerStore, not a throwaway JSONDecoder: the behaviour
    // under test is that the PRODUCTION load path tolerates a record written
    // without the optional keys. FilePeerStore.load() decodes the whole file as
    // one array and returns [] on any error, so a wrongly-strict field loses
    // every peer, not one.
    @Test func recordWithoutOptionalKeysDecodes() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = Data(#"[{"id":"p1","serverId":"srv-b","name":"Studio","origins":["http://a:1"],"token":"t","addedAt":"2026-01-02T03:04:05Z"}]"#.utf8)
        try json.write(to: url)
        let peers = FilePeerStore(url: url).load()
        #expect(peers.count == 1)
        #expect(peers.first?.lastOrigin == nil)
        #expect(peers.first?.protocolVersion == nil)
        #expect(peers.first?.localDeviceId == nil)
    }
}
