import Foundation
import Testing
@testable import AlasCore

@MainActor
struct ReviewStatusFollowTests {
    /// A worktree's review status is refreshed while any subscription
    /// follows it, and no longer once the last follower is gone.
    @Test func refreshLastsAsLongAsAFollower() {
        let host = AlasHost(core: AlasCoreContext(projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil))
        let first = host.subscribe()
        let second = host.subscribe()

        first.followWorktree("w")
        second.followWorktree("w")
        first.followWorktree("w")
        first.unfollowWorktree("w")
        #expect(host.core.reviewRefreshes["w"] != nil)

        second.cancel()
        #expect(host.core.reviewRefreshes["w"] == nil)
        #expect(host.core.reviewFollowers["w"] == nil)
    }
}
