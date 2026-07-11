import Testing
@testable import Alas

struct RemoteStatusFingerprintTests {
    @Test func firstObservationDoesNotRefresh() {
        let value = RemoteStatusFingerprint.make(status: "s", head: "h")
        #expect(!RemoteStatusFingerprint.shouldRefresh(previous: nil, current: value))
    }
    @Test func changesRefresh() {
        let first = RemoteStatusFingerprint.make(status: "s", head: "h")
        #expect(!RemoteStatusFingerprint.shouldRefresh(previous: first, current: first))
        #expect(RemoteStatusFingerprint.shouldRefresh(previous: first, current: RemoteStatusFingerprint.make(status: "s2", head: "h")))
    }
}
