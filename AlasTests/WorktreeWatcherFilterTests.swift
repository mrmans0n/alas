import Testing
import Foundation
@testable import Alas

struct WorktreeWatcherFilterTests {
    @Test func dropsBatchOfOnlyGitLocks() {
        let paths = [
            "/repo/.git/index.lock",
            "/repo/.git/HEAD.lock",
            "/repo/.git/worktrees/feat/HEAD.lock",
        ]
        #expect(WorktreeWatcher.shouldRefresh(forEventPaths: paths) == false)
    }

    @Test func acceptsBatchWithAnyNonLockPath() {
        let paths = [
            "/repo/.git/index.lock",
            "/repo/src/main.swift",
        ]
        #expect(WorktreeWatcher.shouldRefresh(forEventPaths: paths) == true)
    }

    @Test func acceptsProjectLockfilesOutsideGitDir() {
        // Cargo.lock / package-lock.json are real changes, not git lockfiles.
        #expect(WorktreeWatcher.shouldRefresh(forEventPaths: ["/repo/Cargo.lock"]) == true)
    }
}
