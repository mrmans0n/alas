import Testing
import Foundation
import CoreGraphics
@testable import Alas

@Suite("ACPMessageList pagination")
struct ACPMessageListPaginationTests {
    @Test("top indicator is hidden when the full transcript is visible")
    func hiddenWhenFullyVisible() {
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 0,
            isBackfillingOlderMessages: false
        ) == .hidden)
    }

    @Test("top indicator keeps an invisible sentinel after backfill completes")
    func sentinelWhenOlderRowsAreAvailable() {
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 30,
            isBackfillingOlderMessages: false
        ) == .sentinel)
    }

    @Test("top indicator shows spinner only while older rows are backfilling")
    func spinnerWhileBackfilling() {
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 0,
            isBackfillingOlderMessages: true
        ) == .spinner)
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 30,
            isBackfillingOlderMessages: true
        ) == .spinner)
    }

    @Test("queue bubbles render pending items only")
    func queueBubblesRenderPendingItemsOnly() {
        #expect(ACPMessageList.shouldRenderQueueBubble(status: .pending))
        #expect(!ACPMessageList.shouldRenderQueueBubble(status: .sending))
    }

    @Test("queue drops only accept pending items onto pending targets")
    func queueDropsOnlyAcceptPendingItemsOntoPendingTargets() {
        #expect(ACPMessageList.canDropQueuedItem(sourceStatus: .pending, targetStatus: .pending))
        #expect(!ACPMessageList.canDropQueuedItem(sourceStatus: .sending, targetStatus: .pending))
        #expect(!ACPMessageList.canDropQueuedItem(sourceStatus: .pending, targetStatus: .sending))
        #expect(!ACPMessageList.canDropQueuedItem(sourceStatus: nil, targetStatus: .pending))
    }

    @Test("queue header count matches rendered queue bubbles")
    func queueHeaderCountMatchesRenderedQueueBubbles() {
        #expect(ACPMessageList.queueHeaderCount(statuses: []) == 0)
        #expect(ACPMessageList.queueHeaderCount(statuses: [.pending]) == 1)
        #expect(ACPMessageList.queueHeaderCount(statuses: [.sending]) == 0)
        #expect(ACPMessageList.queueHeaderCount(statuses: [.sending, .pending]) == 1)
    }

    @Test("content growth restores the tail when tail-follow is still enabled")
    func contentGrowthRestoresTailWhenFollowing() {
        let viewportHeight: CGFloat = 600
        let previousContentHeight: CGFloat = 5_000
        let newContentHeight: CGFloat = 5_220
        let oldTailOffset = previousContentHeight - viewportHeight

        #expect(ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: previousContentHeight,
            newContentHeight: newContentHeight,
            viewportHeight: viewportHeight,
            newMinY: oldTailOffset,
            followsTranscriptTail: true
        ))
    }

    @Test("content growth does not restore the tail after the user paused tail-follow")
    func contentGrowthDoesNotRestoreWhenTailFollowPaused() {
        #expect(!ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: 5_000,
            newContentHeight: 5_220,
            viewportHeight: 600,
            newMinY: 4_400,
            followsTranscriptTail: false
        ))
    }

    @Test("content growth does not issue an extra restore when already at the new tail")
    func contentGrowthDoesNotRestoreWhenAlreadyAtTail() {
        let viewportHeight: CGFloat = 600
        let newContentHeight: CGFloat = 5_220
        let newTailOffset = newContentHeight - viewportHeight

        #expect(!ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: 5_000,
            newContentHeight: newContentHeight,
            viewportHeight: viewportHeight,
            newMinY: newTailOffset,
            followsTranscriptTail: true
        ))
    }

    @Test("streaming tail scrolls do not animate")
    func streamingTailScrollsDoNotAnimate() {
        #expect(!ACPMessageList.shouldAnimateTailScroll(
            trigger: .contentSignature,
            streamingState: .streaming
        ))
        #expect(!ACPMessageList.shouldAnimateTailScroll(
            trigger: .streamingState,
            streamingState: .sending
        ))
    }

    @Test("non-streaming content tail scrolls keep animation")
    func nonStreamingContentTailScrollsKeepAnimation() {
        #expect(ACPMessageList.shouldAnimateTailScroll(
            trigger: .contentSignature,
            streamingState: .idle
        ))
        #expect(!ACPMessageList.shouldAnimateTailScroll(
            trigger: .contentGrowth,
            streamingState: .idle
        ))
    }

    @Test("deferred tail scrolls require active tail-follow")
    func deferredTailScrollsRequireActiveTailFollow() {
        #expect(ACPMessageList.shouldRunScheduledTailScroll(followsTranscriptTail: true))
        #expect(!ACPMessageList.shouldRunScheduledTailScroll(followsTranscriptTail: false))
    }

    @Test("tail scroll scheduling coalesces pending work")
    func tailScrollSchedulingCoalescesPendingWork() {
        #expect(ACPMessageList.shouldScheduleTailScroll(hasPendingTailScroll: false))
        #expect(!ACPMessageList.shouldScheduleTailScroll(hasPendingTailScroll: true))
    }

    @Test("viewport width changes restore the tail only while following")
    func viewportWidthChangesRestoreTailOnlyWhileFollowing() {
        #expect(ACPMessageList.shouldRestoreTailAfterViewportWidthChange(
            previousWidth: 720,
            newWidth: 560,
            followsTranscriptTail: true
        ))
        #expect(!ACPMessageList.shouldRestoreTailAfterViewportWidthChange(
            previousWidth: 720,
            newWidth: 560,
            followsTranscriptTail: false
        ))
        #expect(!ACPMessageList.shouldRestoreTailAfterViewportWidthChange(
            previousWidth: 720,
            newWidth: 720,
            followsTranscriptTail: true
        ))
    }

    @Test("top visible anchor prefers the row crossing the viewport top")
    func topVisibleAnchorPrefersRowCrossingTop() {
        let frames: [String: CGRect] = [
            "above": CGRect(x: 0, y: -90, width: 100, height: 50),
            "crossing": CGRect(x: 0, y: -40, width: 100, height: 80),
            "below": CGRect(x: 0, y: 48, width: 100, height: 80)
        ]

        #expect(ACPMessageList.topVisibleAnchorID(in: frames) == "crossing")
    }

    @Test("top visible anchor uses first row below top when no row crosses")
    func topVisibleAnchorUsesFirstRowBelowTop() {
        let frames: [String: CGRect] = [
            "above": CGRect(x: 0, y: -90, width: 100, height: 50),
            "first": CGRect(x: 0, y: 16, width: 100, height: 80),
            "second": CGRect(x: 0, y: 120, width: 100, height: 80)
        ]

        #expect(ACPMessageList.topVisibleAnchorID(in: frames) == "first")
    }

    @Test("top visible scroll target ignores non-message targets")
    func topVisibleScrollTargetIgnoresNonMessageTargets() {
        #expect(ACPMessageList.topVisibleScrollTargetID(
            in: ["__pending_perm__", "message-2", "message-3"],
            visibleMessageIds: ["message-1", "message-2", "message-3"]
        ) == "message-2")
    }

    @Test("top visible scroll target returns nil without visible messages")
    func topVisibleScrollTargetReturnsNilWithoutMessages() {
        #expect(ACPMessageList.topVisibleScrollTargetID(
            in: ["__pending_question__", "__composer_spacer__"],
            visibleMessageIds: ["message-1"]
        ) == nil)
    }

    @Test("row frame preferences are legacy-only")
    func rowFramePreferencesAreLegacyOnly() {
        #expect(ACPMessageList.shouldUseLegacyRowFramePreferences(
            isModernScrollTrackingAvailable: false
        ))
        #expect(!ACPMessageList.shouldUseLegacyRowFramePreferences(
            isModernScrollTrackingAvailable: true
        ))
    }

    @Test("visible message lookup records ids and transcript indices")
    func visibleMessageLookupRecordsIdsAndTranscriptIndices() {
        let lookup = ACPMessageList.visibleMessageLookup(rows: [
            (index: 40, stableId: "message-40"),
            (index: 41, stableId: "message-41")
        ])

        #expect(lookup.contains("message-40"))
        #expect(!lookup.contains("message-39"))
        #expect(lookup.transcriptIndex(for: "message-41") == 41)
        #expect(lookup.firstStableId == "message-40")
    }

    @Test("visible rows contain only transcript indices and stable ids")
    @MainActor
    func visibleRowsContainOnlyIndicesAndStableIds() {
        let messages: [ACPMessage] = [
            .user(id: UUID(), messageId: "user-1", text: "old", attachments: []),
            .plan(id: UUID(), [ACPMessage.PlanItem(content: "skip", status: "pending")]),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("new"))
        ]

        let rows = ACPMessageList.visibleRows(
            messages: messages,
            visibleHead: 1,
            stableId: { $0.stableId }
        )

        #expect(rows == [
            ACPMessageList.VisibleRow(index: 2, stableId: "acp-agent:agent-1")
        ])
    }

    @Test("visible anchor memory accepts live anchors when the remembered id is stale")
    func visibleAnchorMemoryAcceptsStaleRememberedIDReplacement() {
        #expect(ACPMessageList.shouldRememberVisibleAnchor(
            "regenerated-2",
            rememberedAnchor: "old-2",
            restoredRememberedAnchor: nil,
            visibleMessageIds: ["regenerated-1", "regenerated-2", "regenerated-3"],
            isBackfillingOlderMessages: false
        ))
    }

    @Test("visible anchor memory waits while the remembered id is still rendered")
    func visibleAnchorMemoryWaitsForRenderedRememberedID() {
        #expect(!ACPMessageList.shouldRememberVisibleAnchor(
            "message-1",
            rememberedAnchor: "message-2",
            restoredRememberedAnchor: nil,
            visibleMessageIds: ["message-1", "message-2", "message-3"],
            isBackfillingOlderMessages: false
        ))
    }

    @Test("visible anchor memory accepts refreshed anchors after restoration")
    func visibleAnchorMemoryAcceptsAfterRestoration() {
        #expect(ACPMessageList.shouldRememberVisibleAnchor(
            "message-3",
            rememberedAnchor: "message-2",
            restoredRememberedAnchor: "message-2",
            visibleMessageIds: ["message-1", "message-2", "message-3"],
            isBackfillingOlderMessages: false
        ))
    }

    @Test("visible anchor memory waits while older messages are backfilling")
    func visibleAnchorMemoryWaitsDuringBackfill() {
        #expect(!ACPMessageList.shouldRememberVisibleAnchor(
            "tail-2",
            rememberedAnchor: "old-2",
            restoredRememberedAnchor: nil,
            visibleMessageIds: ["tail-1", "tail-2", "tail-3"],
            isBackfillingOlderMessages: true
        ))
    }
}
