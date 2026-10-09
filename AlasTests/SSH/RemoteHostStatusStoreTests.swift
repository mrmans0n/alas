import Combine
import Testing
@testable import Alas

@MainActor
struct RemoteHostStatusStoreTests {
    @Test func singleFailureIsNotOffline() {
        let store = RemoteHostStatusStore()
        store.reportConnectionFailure(host: "devbox")
        #expect(!store.isOffline("devbox"))
    }

    @Test func twoConsecutiveFailuresAreOffline() {
        let store = RemoteHostStatusStore()
        store.reportConnectionFailure(host: "devbox")
        store.reportConnectionFailure(host: "devbox")
        #expect(store.isOffline("devbox"))
    }

    @Test func successResetsFailureCountAndOfflineState() {
        let store = RemoteHostStatusStore()
        store.reportConnectionFailure(host: "devbox")
        store.reportSuccess(host: "devbox")
        store.reportConnectionFailure(host: "devbox")
        #expect(!store.isOffline("devbox"))

        store.reportConnectionFailure(host: "devbox")
        #expect(store.isOffline("devbox"))
        store.reportSuccess(host: "devbox")
        #expect(!store.isOffline("devbox"))
    }

    @Test func hostsAreIndependent() {
        let store = RemoteHostStatusStore()
        store.reportConnectionFailure(host: "a")
        store.reportConnectionFailure(host: "a")
        #expect(store.isOffline("a"))
        #expect(!store.isOffline("b"))
    }

    /// Every RepoGroupView observes this store, and polls report success many
    /// times a second, so only a real offline flip may publish.
    @Test func publishesOnlyWhenOfflineStateChanges() {
        let store = RemoteHostStatusStore()
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        store.reportSuccess(host: "devbox")
        store.reportSuccess(host: "devbox")
        store.reportConnectionFailure(host: "devbox")
        #expect(changes == 0)

        store.reportConnectionFailure(host: "devbox")
        store.reportConnectionFailure(host: "devbox")
        #expect(changes == 1)

        store.reportSuccess(host: "devbox")
        store.reportSuccess(host: "devbox")
        #expect(changes == 2)
    }
}
