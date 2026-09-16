import Testing
import Foundation
@testable import Alas

struct WorktreeUpstreamStatusTests {
    @Test func nonzeroSyncCountsDescribeBothDirections() {
        let status = WorktreeUpstreamStatus(
            ahead: 3,
            behind: 2,
            upstreamRef: "origin/main"
        )

        #expect(status.subtitleItems == [
            .init(text: "↑3", accessibilityLabel: "3 commits ahead of origin/main"),
            .init(text: "↓2", accessibilityLabel: "2 commits behind origin/main")
        ])
    }

    @Test func synchronizedWorktreeHasNoSyncSubtitleItems() {
        let status = WorktreeUpstreamStatus(
            ahead: 0,
            behind: 0,
            upstreamRef: "origin/main"
        )

        #expect(status.subtitleItems.isEmpty)
    }

    @Test func linkedWorktreeDoesNotUseMainWorktreeSyncSubtitle() {
        let status = WorktreeUpstreamStatus(ahead: 1, behind: 1, upstreamRef: "origin/feature")

        #expect(WorktreeRowView.upstreamStatusItems(status, isMain: false).isEmpty)
    }

    @Test func fetchPolicyHonorsAutoFetchSetting() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: false,
            lastFetchAt: nil,
            now: now,
            minFetchInterval: 60
        ) == false)

        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: true,
            lastFetchAt: nil,
            now: now,
            minFetchInterval: 60
        ))
    }

    @Test func fetchPolicyUsesConfiguredInterval() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(WorktreeUpstreamStatusStore.fetchInterval(fetchIntervalMinutes: 7) == 420)
        #expect(WorktreeUpstreamStatusStore.fetchInterval(fetchIntervalMinutes: 0) == 60)
        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: true,
            lastFetchAt: now.addingTimeInterval(-59),
            now: now,
            minFetchInterval: 60
        ) == false)
        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: true,
            lastFetchAt: now.addingTimeInterval(-60),
            now: now,
            minFetchInterval: 60
        ))
    }
}
