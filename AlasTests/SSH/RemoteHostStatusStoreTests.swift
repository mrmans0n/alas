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
}
