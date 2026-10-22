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

    @Test func anIdentityKeyStaysTheSameAcrossProviders() {
        // The default reading store falls through to the file store the host
        // writes, so one shared fake stands in for both.
        let shared = RemoteInMemorySecretStore()
        let first = RemoteIdentityKeyProvider(store: RemoteHostSecretStore(reading: shared, writing: shared))
        let second = RemoteIdentityKeyProvider(store: RemoteHostSecretStore(reading: shared, writing: shared))
        // A fresh provider over the same stores must find the first one's key.
        #expect(!first.publicKey.isEmpty)
        #expect(second.publicKey == first.publicKey)
    }
}
