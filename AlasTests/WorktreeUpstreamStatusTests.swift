import Testing
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
}
