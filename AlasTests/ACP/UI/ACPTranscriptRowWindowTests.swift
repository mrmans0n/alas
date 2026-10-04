import Testing
import Foundation
@testable import Alas

@Suite("ACP transcript row window")
struct ACPTranscriptRowWindowTests {
    @Test("queue bubbles render pending items only")
    func queueBubblesRenderPendingItemsOnly() {
        #expect(ACPTranscriptQueuePolicy.shouldRenderQueueBubble(status: .pending))
        #expect(!ACPTranscriptQueuePolicy.shouldRenderQueueBubble(status: .sending))
    }

    @Test("queue drops only accept pending items onto pending targets")
    func queueDropsOnlyAcceptPendingItemsOntoPendingTargets() {
        #expect(ACPTranscriptQueuePolicy.canDropQueuedItem(sourceStatus: .pending, targetStatus: .pending))
        #expect(!ACPTranscriptQueuePolicy.canDropQueuedItem(sourceStatus: .sending, targetStatus: .pending))
        #expect(!ACPTranscriptQueuePolicy.canDropQueuedItem(sourceStatus: .pending, targetStatus: .sending))
        #expect(!ACPTranscriptQueuePolicy.canDropQueuedItem(sourceStatus: nil, targetStatus: .pending))
    }

    @Test("queue mutations are allowed only while the session is not a mirror")
    func queueMutationsGatedOnOwnership() {
        #expect(ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: false))
        #expect(!ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: true))
    }

    @Test("go-to-newest affordance shows only when tail-follow is paused")
    func goToNewestAffordanceShowsOnlyWhenTailFollowPaused() {
        #expect(!ACPMessageList.shouldShowGoToNewestAffordance(followsTranscriptTail: true))
        #expect(ACPMessageList.shouldShowGoToNewestAffordance(followsTranscriptTail: false))
    }

    @Test("go-to-newest affordance is positioned above composer-safe space")
    func goToNewestAffordanceIsPositionedAboveComposerSafeSpace() {
        #expect(ACPMessageList.goToNewestAffordanceBottomPadding(
            composerSpacerHeight: 220,
            gap: 12
        ) == 232)
    }

    @Test("visible rows contain only transcript indices and stable ids")
    @MainActor
    func visibleRowsContainOnlyIndicesAndStableIds() {
        let messages: [ACPMessage] = [
            .user(id: UUID(), messageId: "user-1", text: "old", attachments: []),
            .plan(id: UUID(), [ACPMessage.PlanItem(content: "skip", status: "pending")]),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("new"))
        ]

        let rows = ACPTranscriptVisibleRow.rows(
            messages: messages,
            visibleHead: 1,
            visibleTail: messages.count,
            stableId: { $0.stableId }
        )

        #expect(rows == [
            ACPTranscriptVisibleRow(index: 2, stableId: "acp-agent:agent-1")
        ])
    }

    @Test("visible rows stop at the visible tail")
    @MainActor
    func visibleRowsStopAtVisibleTail() {
        let messages: [ACPMessage] = [
            .user(id: UUID(), messageId: "user-1", text: "one", attachments: []),
            .user(id: UUID(), messageId: "user-2", text: "two", attachments: []),
            .user(id: UUID(), messageId: "user-3", text: "three", attachments: []),
            .user(id: UUID(), messageId: "user-4", text: "four", attachments: [])
        ]

        let rows = ACPTranscriptVisibleRow.rows(
            messages: messages,
            visibleHead: 1,
            visibleTail: 3,
            stableId: { $0.stableId }
        )

        #expect(rows.map(\.index) == [1, 2])
    }

    @Test("the latest background-task snapshot controls rendered rows and anchors", arguments: [true, false])
    @MainActor
    func backgroundTaskVisibilityUsesLatestSnapshot(showInTranscript: Bool) {
        var task = ACPBackgroundTask(ownerSessionId: "root", asyncTaskId: "job", name: "Tests")
        task.showInTranscript = !showInTranscript
        let previous = ACPMessage.toolCall(task.transcriptRow)
        task.showInTranscript = showInTranscript
        let latest = ACPMessage.toolCall(task.transcriptRow)
        let messages: [ACPMessage] = [
            .user(id: UUID(), messageId: "before", text: "Before", attachments: []),
            previous, latest,
            .user(id: UUID(), messageId: "after", text: "After", attachments: [])
        ]
        let rows = ACPTranscriptVisibleRow.rows(
            messages: messages, visibleHead: 0, visibleTail: messages.count, stableId: { $0.stableId })
        #expect(rows.map(\.index) == (showInTranscript ? [0, 2, 3] : [0, 3]))
        let lookup = ACPTranscriptVisibleRowLookup(rows: rows.map { .message($0) })
        #expect(lookup.transcriptIndex(for: latest.stableId) == (showInTranscript ? 2 : nil))
    }
}
