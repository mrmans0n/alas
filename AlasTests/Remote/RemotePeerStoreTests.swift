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

    /// Never the real Keychain: these tests run in the app's own test host,
    /// and a suite has no business writing this Mac's actual credentials.
    private func secrets(writable: Bool = true) -> RemoteInMemorySecretStore {
        RemoteInMemorySecretStore(writable: writable)
    }

    @Test func missingFileLoadsEmpty() {
        #expect(FilePeerStore(url: tempFile(), secrets: secrets()).load().isEmpty)
    }

    @Test func peersRoundTripThroughDisk() {
        let url = tempFile()
        let vault = secrets()
        let peer = RemotePeer(id: "p1", serverId: "srv-b", name: "Studio",
                              origins: ["http://100.64.1.5:8765", "http://192.168.1.20:8765"],
                              lastOrigin: "http://100.64.1.5:8765", token: "tok",
                              publicKey: "pk", protocolVersion: 1,
                              localDeviceId: "d9", addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        FilePeerStore(url: url, secrets: vault).save([peer])
        #expect(FilePeerStore(url: url, secrets: vault).load() == [peer])
    }

    // A peer's token is an outbound credential: what this Mac presents to
    // reach another one. Leaving it in the same plain JSON as the addresses
    // that reference it made a copied file enough to impersonate this Mac.
    @Test func tokensLiveInTheSecretStoreNotTheFile() throws {
        let url = tempFile()
        let vault = secrets()
        let peer = RemotePeer(id: "p1", serverId: "srv-b", name: "Studio", origins: ["http://a:1"],
                              lastOrigin: nil, token: "s3cret", addedAt: Date())
        FilePeerStore(url: url, secrets: vault).save([peer])
        let onDisk = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
        #expect(!onDisk.contains("s3cret"))
        #expect(vault.secret(for: FilePeerStore.tokensAccount) != nil)
        #expect(FilePeerStore(url: url, secrets: vault).load().first?.token == "s3cret")
    }

    // Records written by an older build still carry their token inline; they
    // must keep working, and the next save must move the secret out.
    @Test func aTokenWrittenInlineByAnOlderBuildIsLoadedAndThenMigrated() throws {
        let url = tempFile()
        let vault = secrets()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"id":"p1","serverId":"srv-b","name":"Studio","origins":["http://a:1"],"token":"legacy","addedAt":"2026-01-02T03:04:05Z"}]"#.utf8)
            .write(to: url)
        let store = FilePeerStore(url: url, secrets: vault)
        let loaded = store.load()
        #expect(loaded.first?.token == "legacy")
        store.save(loaded)
        let onDisk = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
        #expect(!onDisk.contains("legacy"))
        #expect(FilePeerStore(url: url, secrets: vault).load().first?.token == "legacy")
    }

    // With nowhere secret to put them, the tokens stay in the record rather
    // than being dropped: silently logging this Mac out of every peer it has
    // would be far worse than writing the file the previous build wrote.
    @Test func tokensStayInTheRecordWhenNoSecretStoreAcceptsThem() throws {
        let url = tempFile()
        let vault = secrets(writable: false)
        let peer = RemotePeer(id: "p1", serverId: "srv-b", name: "Studio", origins: ["http://a:1"],
                              lastOrigin: nil, token: "s3cret", addedAt: Date())
        FilePeerStore(url: url, secrets: vault).save([peer])
        #expect(FilePeerStore(url: url, secrets: vault).load().first?.token == "s3cret")
    }

    // A record paired before verification shipped has no key, and must be
    // reported as unverified rather than silently treated like a bound one.
    @Test func aRecordWithoutAKeyIsNotVerified() {
        let unpinned = RemotePeer(id: "p1", serverId: "srv-b", name: "Studio", origins: ["http://a:1"],
                                  lastOrigin: nil, token: "t", addedAt: Date())
        #expect(!unpinned.isVerified)
        var pinned = unpinned
        pinned.publicKey = "a-key"
        #expect(pinned.isVerified)
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
        let peers = FilePeerStore(url: url, secrets: secrets()).load()
        #expect(peers.count == 1)
        #expect(peers.first?.lastOrigin == nil)
        #expect(peers.first?.protocolVersion == nil)
        #expect(peers.first?.localDeviceId == nil)
        #expect(peers.first?.publicKey == nil)
    }
}
