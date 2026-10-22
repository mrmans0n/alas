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
}
