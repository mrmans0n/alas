import Foundation
import Testing
@testable import Alas

struct GGInboxHostTests {
    @Test func prefersSelectedWhenInProject() {
        #expect(AppState.inboxHostWorktreeId(selectedWorktreeId: "w2", projectWorktreeIds: ["w1", "w2"]) == "w2")
    }
    @Test func fallsBackToFirstWhenSelectedIsForeign() {
        #expect(AppState.inboxHostWorktreeId(selectedWorktreeId: "wOther", projectWorktreeIds: ["w1", "w2"]) == "w1")
    }
    @Test func fallsBackToFirstWhenNoneSelected() {
        #expect(AppState.inboxHostWorktreeId(selectedWorktreeId: nil, projectWorktreeIds: ["w1", "w2"]) == "w1")
    }
    @Test func nilWhenProjectHasNoWorktrees() {
        #expect(AppState.inboxHostWorktreeId(selectedWorktreeId: "w1", projectWorktreeIds: []) == nil)
    }
}
