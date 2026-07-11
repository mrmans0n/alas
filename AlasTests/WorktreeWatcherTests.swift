import Testing
import Foundation
@testable import Alas

struct WorktreeWatcherTests {
    @Test func emptyEventListSkipsRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(forEventPaths: []) == false)
    }

    @Test func gitIndexLockSkipsRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/.git/index.lock"]
        ) == false)
    }

    @Test func gitHeadLockSkipsRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/.git/HEAD.lock"]
        ) == false)
    }

    @Test func gitPackedRefsLockSkipsRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/.git/packed-refs.lock"]
        ) == false)
    }

    @Test func gitFetchHeadSkipsRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/.git/FETCH_HEAD"]
        ) == false)
    }

    @Test func linkedWorktreeIndexLockSkipsRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/.git/worktrees/feat-foo/index.lock"]
        ) == false)
    }

    @Test func gitIndexUpdateTriggersRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/.git/index"]
        ) == true)
    }

    @Test func gitHeadUpdateTriggersRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/.git/HEAD"]
        ) == true)
    }

    @Test func projectCargoLockTriggersRefresh() {
        // Project lockfiles outside .git/ are real changes.
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/Cargo.lock"]
        ) == true)
    }

    @Test func projectPackageLockTriggersRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: ["/Users/x/repo/package-lock.json"]
        ) == true)
    }

    @Test func mixedBatchWithRealEventTriggersRefresh() {
        // If at least one event is a real change, we refresh.
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: [
                "/Users/x/repo/.git/index.lock",
                "/Users/x/repo/src/foo.swift",
            ]
        ) == true)
    }

    @Test func multipleLockOnlyBatchSkipsRefresh() {
        #expect(WorktreeWatcher.shouldRefresh(
            forEventPaths: [
                "/Users/x/repo/.git/index.lock",
                "/Users/x/repo/.git/HEAD.lock",
            ]
        ) == false)
    }
}
