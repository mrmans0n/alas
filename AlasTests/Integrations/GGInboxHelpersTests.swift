import Foundation
import Testing
@testable import Alas

struct GGInboxHelpersTests {
    @Test func resolverPrefersExactUsernameBranch() {
        // A same-named-stack branch from a different user ("other/auth")
        // is now a genuine ambiguity case (see worktreeIdReturnsNil... below)
        // and must not be mixed into this fixture, so the distractor here
        // is a different stack entirely — this test isolates "picks the
        // exact <username>/<stackName> match among several worktrees."
        let worktrees = [
            (id: "w1", branch: "nacho/auth"),
            (id: "w2", branch: "nacho/perf"),
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

    @Test func hasAmbiguousLocalOwnersTrueWithTwoMatchingBranches() {
        let worktrees = [(id: "w1", branch: "alice/auth"), (id: "w2", branch: "bob/auth")]
        #expect(GGInboxWorktreeResolver.hasAmbiguousLocalOwners(stackName: "auth", worktrees: worktrees))
    }

    @Test func hasAmbiguousLocalOwnersFalseWithOneMatch() {
        let worktrees = [(id: "w1", branch: "bob/auth"), (id: "w2", branch: "bob/perf")]
        #expect(!GGInboxWorktreeResolver.hasAmbiguousLocalOwners(stackName: "auth", worktrees: worktrees))
    }

    @Test func worktreeIdReturnsNilWhenMultipleLocalBranchesShareStackName() {
        // Even though "bob/auth" is an exact match for username "bob", a
        // second local branch for the same stack name ("alice/auth") means
        // this specific row can't be safely attributed — must dim, not guess.
        let worktrees = [(id: "w1", branch: "alice/auth"), (id: "w2", branch: "bob/auth")]
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "auth", username: "bob", worktrees: worktrees) == nil)
    }

    @Test func worktreeIdResolvesNormallyWhenOnlyOneLocalBranchMatches() {
        // A stack's multiple positions/PRs never affect this — the check is
        // purely about distinct local branches, not row count.
        let worktrees = [(id: "w1", branch: "bob/auth")]
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "auth", username: "bob", worktrees: worktrees) == "w1")
    }

    @Test func doesNotConflateNestedStackNameWithSuffixMatch() {
        // "alice/feature/auth" is a DIFFERENT stack ("feature/auth"), not
        // related to stack "auth" — despite ending in the raw substring
        // "/auth". Must not be treated as a same-name collision.
        let worktrees = [(id: "w1", branch: "bob/auth"), (id: "w2", branch: "alice/feature/auth")]
        #expect(!GGInboxWorktreeResolver.hasAmbiguousLocalOwners(stackName: "auth", worktrees: worktrees))
        #expect(GGInboxWorktreeResolver.worktreeId(stackName: "auth", username: "bob", worktrees: worktrees) == "w1")
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

    @Test(arguments: ["0.9.12", "0.9.13", "0.10.0", "1.0.0"])
    func supportedInboxVersions(_ version: String) {
        #expect(GGInboxSupport.isSupported(version: version))
    }

    @Test(arguments: [nil, "", "abc", "0.9.11", "0.8.99"] as [String?])
    func unsupportedInboxVersions(_ version: String?) {
        #expect(!GGInboxSupport.isSupported(version: version))
    }

    @Test func refreshProgressLabel() {
        #expect(GGInboxTabView.refreshLabel(nil) == nil)
        #expect(GGInboxTabView.refreshLabel(.init(completed: 2, total: 5)) == "Refreshing 2/5")
    }

    @Test func clearInboxRequiresCompletedNonErrorState() {
        let empty = GGInboxSnapshot(totalItems: 0, buckets: GGInboxBuckets(), stackErrors: [])
        #expect(GGInboxTabView.shouldShowClearInbox(snapshot: empty, isRefreshing: false, lastError: nil))
        #expect(!GGInboxTabView.shouldShowClearInbox(snapshot: nil, isRefreshing: false, lastError: nil))
        #expect(!GGInboxTabView.shouldShowClearInbox(snapshot: empty, isRefreshing: true, lastError: nil))
        #expect(!GGInboxTabView.shouldShowClearInbox(snapshot: empty, isRefreshing: false, lastError: "failed"))
    }

    @Test func becomingSupportedRefreshesMissingOrStaleSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = GGInboxSnapshot(totalItems: 1, buckets: GGInboxBuckets(), stackErrors: [])

        #expect(GGInboxTabView.shouldRefreshAfterSupportTransition(
            wasSupported: false,
            isSupported: true,
            snapshot: nil,
            fetchedAt: nil,
            now: now
        ))
        #expect(GGInboxTabView.shouldRefreshAfterSupportTransition(
            wasSupported: false,
            isSupported: true,
            snapshot: snapshot,
            fetchedAt: now.addingTimeInterval(-120),
            now: now
        ))
        #expect(!GGInboxTabView.shouldRefreshAfterSupportTransition(
            wasSupported: false,
            isSupported: true,
            snapshot: snapshot,
            fetchedAt: now,
            now: now
        ))
        #expect(!GGInboxTabView.shouldRefreshAfterSupportTransition(
            wasSupported: true,
            isSupported: true,
            snapshot: nil,
            fetchedAt: nil,
            now: now
        ))
    }

    @Test func upgradeGateWaitsForAvailabilityProbe() {
        #expect(!GGInboxTabView.shouldShowUpgradeRequired(
            hasProbed: false,
            supportsStreamingInbox: false
        ))
        #expect(GGInboxTabView.shouldShowUpgradeRequired(
            hasProbed: true,
            supportsStreamingInbox: false
        ))
        #expect(!GGInboxTabView.shouldShowUpgradeRequired(
            hasProbed: true,
            supportsStreamingInbox: true
        ))
    }

    @Test func validPRURLRequiresHTTPOrHTTPS() {
        #expect(GGInboxTabView.validPRURL("https://example.test/42") != nil)
        #expect(GGInboxTabView.validPRURL("") == nil)
        #expect(GGInboxTabView.validPRURL(nil) == nil)
        #expect(GGInboxTabView.validPRURL("file:///tmp/secret") == nil)
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
