import Foundation
import Testing
@testable import Alas

struct GGInboxHelpersTests {
    @Test func resolverPrefersExactUsernameBranch() {
        let worktrees = [
            (id: "w1", branch: "nacho/auth"),
            (id: "w2", branch: "other/auth"),
        ]
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "auth", username: "nacho", worktrees: worktrees) == "w1")
    }

    @Test func resolverFallsBackToSuffixWhenUsernameUnknown() {
        let worktrees = [(id: "w1", branch: "someone/perf")]
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "perf", username: nil, worktrees: worktrees) == "w1")
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "missing", username: nil, worktrees: worktrees) == nil)
    }

    @Test func resolverReturnsNilWhenUsernameKnownButOnlyForeignMatch() {
        // Known username, no exact <username>/<stack> worktree, only a
        // different user's same-named stack checked out → no navigation.
        let worktrees = [(id: "w1", branch: "other/auth")]
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "auth", username: "nacho", worktrees: worktrees) == nil)
    }

    @Test func resolverDoesNotMatchBareOrPartialNames() {
        let worktrees = [
            (id: "w1", branch: "auth"),            // no slash — not gg convention
            (id: "w2", branch: "nacho/auth-flow"), // different stack
        ]
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "auth", username: nil, worktrees: worktrees) == nil)
    }

    @Test func ambiguousStackNamesDetectsDuplicatesAcrossBuckets() throws {
        let json = #"""
        {"version":1,"total_items":2,
         "buckets":{
           "ready_to_land":[{"stack_name":"auth","position":1,"sha":"aaa","title":"Alice's auth","pr_number":1,"pr_url":"https://example.test/1"}],
           "changes_requested":[],
           "blocked_on_ci":[],
           "awaiting_review":[{"stack_name":"auth","position":1,"sha":"bbb","title":"Bob's auth","pr_number":2,"pr_url":"https://example.test/2"}],
           "behind_base":[],
           "draft":[{"stack_name":"perf","position":1,"sha":"ccc","title":"Unique stack","pr_number":3,"pr_url":"https://example.test/3"}]},
         "stack_errors":[]}
        """#
        let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(json.utf8))
        #expect(GGInboxWorktreeResolver.ambiguousStackNames(in: snapshot.buckets) == ["auth"])
    }

    @Test func ambiguousStackNamesEmptyWhenAllUnique() throws {
        let json = #"""
        {"version":1,"total_items":1,
         "buckets":{
           "ready_to_land":[{"stack_name":"auth","position":1,"sha":"aaa","title":"t","pr_number":1,"pr_url":"https://example.test/1"}],
           "changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},
         "stack_errors":[]}
        """#
        let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(json.utf8))
        #expect(GGInboxWorktreeResolver.ambiguousStackNames(in: snapshot.buckets).isEmpty)
    }

    @Test func ambiguousStackNamesCountsStackErrorsToo() throws {
        let json = #"""
        {"version":1,"total_items":1,
         "buckets":{
           "ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],
           "awaiting_review":[{"stack_name":"auth","position":1,"sha":"bbb","title":"Bob's auth","pr_number":2,"pr_url":"https://example.test/2"}],
           "behind_base":[],"draft":[]},
         "stack_errors":[{"stack_name":"auth","error":"branch missing"}]}
        """#
        let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(json.utf8))
        #expect(GGInboxWorktreeResolver.ambiguousStackNames(
            in: snapshot.buckets, stackErrors: snapshot.stackErrors
        ) == ["auth"])
    }

    @Test func updatedLabel() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(GGInboxTabView.updatedLabel(fetchedAt: nil, now: now) == nil)
        #expect(GGInboxTabView.updatedLabel(fetchedAt: now.addingTimeInterval(-30), now: now) == "Updated just now")
        #expect(GGInboxTabView.updatedLabel(fetchedAt: now.addingTimeInterval(-150), now: now) == "Updated 2m ago")
        #expect(GGInboxTabView.updatedLabel(fetchedAt: now.addingTimeInterval(-7_200), now: now) == "Updated 2h ago")
    }

    @Test func ciIconMapping() {
        #expect(GGInboxTabView.ciIconName("success") == "checkmark.circle")
        #expect(GGInboxTabView.ciIconName("failed") == "xmark.circle")
        #expect(GGInboxTabView.ciIconName("canceled") == "xmark.circle")
        #expect(GGInboxTabView.ciIconName("running") == "clock")
        #expect(GGInboxTabView.ciIconName("pending") == "clock")
        #expect(GGInboxTabView.ciIconName("unknown") == nil)
        #expect(GGInboxTabView.ciIconName(nil) == nil)
        #expect(GGInboxTabView.ciIconName("weird") == nil)
    }

    @Test func ciIconColorMapping() {
        #expect(GGInboxTabView.ciIconColorToken("success") == "add")
        #expect(GGInboxTabView.ciIconColorToken("failed") == "del")
        #expect(GGInboxTabView.ciIconColorToken("canceled") == "del")
        #expect(GGInboxTabView.ciIconColorToken("running") == "caution")
        #expect(GGInboxTabView.ciIconColorToken("pending") == "caution")
        #expect(GGInboxTabView.ciIconColorToken("unknown") == "fg-dim")
        #expect(GGInboxTabView.ciIconColorToken(nil) == "fg-dim")
    }

    @Test func tabStateIdentityAndCodableRoundTrip() throws {
        let state = GGInboxTabState(projectId: "p1", projectName: "alas")
        #expect(state.id == "gg-inbox:p1")
        #expect(state.title == "Inbox — alas")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GGInboxTabState.self, from: data)
        #expect(decoded == state)
    }
}
