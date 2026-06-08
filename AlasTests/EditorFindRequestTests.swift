import Testing
@testable import Alas

struct EditorFindRequestTests {
    @Test func requestsAreEquatable() {
        #expect(EditorFindRequest.showFind == .showFind)
        #expect(EditorFindRequest.showFind != .showReplace)
        #expect(EditorFindRequest.findNext != .findPrevious)
    }

    @Test func requestsAreSendable() {
        requireSendable(EditorFindRequest.showFind)
        requireSendable(EditorFindRequest.showReplace)
        requireSendable(EditorFindRequest.findNext)
        requireSendable(EditorFindRequest.findPrevious)
    }

    private func requireSendable<T: Sendable>(_: T) {}
}
