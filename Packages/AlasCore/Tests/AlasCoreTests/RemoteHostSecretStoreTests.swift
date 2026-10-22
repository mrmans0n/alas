import Foundation
import Testing
@testable import AlasHostCore
@testable import AlasModel

@MainActor
struct RemoteHostSecretStoreTests {
    @Test func readsThroughButWritesOnlyTheWritingStore() {
        let reading = RemoteInMemorySecretStore()
        let writing = RemoteInMemorySecretStore()
        reading.setSecret(Data("A".utf8), for: "k")

        RemoteHostSecretStore(reading: reading, writing: writing).setSecret(Data("B".utf8), for: "k")

        #expect(reading.secret(for: "k") == Data("A".utf8))
        #expect(writing.secret(for: "k") == Data("B".utf8))
    }

    /// The app's stale Keychain copy must not shadow what the host wrote
    /// since, nor come back after the host removed it.
    @Test func whatTheHostWroteOrRemovedWinsOverTheReadingStore() {
        let reading = RemoteInMemorySecretStore()
        reading.setSecret(Data("old".utf8), for: "k")
        let store = RemoteHostSecretStore(reading: reading, writing: RemoteInMemorySecretStore())
        #expect(store.secret(for: "k") == Data("old".utf8))

        store.setSecret(Data("new".utf8), for: "k")
        #expect(store.secret(for: "k") == Data("new".utf8))

        store.setSecret(nil, for: "k")
        #expect(store.secret(for: "k") == nil)
    }
}
