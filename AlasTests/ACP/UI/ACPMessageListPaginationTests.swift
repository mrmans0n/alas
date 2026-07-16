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

    @Test("row frame preferences are legacy-only")
    func rowFramePreferencesAreLegacyOnly() {
        #expect(ACPMessageList.shouldUseLegacyRowFramePreferences(
            isModernScrollTrackingAvailable: false
        ))
        #expect(!ACPMessageList.shouldUseLegacyRowFramePreferences(
            isModernScrollTrackingAvailable: true
        ))
    }

    @Test("modern row-frame cache ignores stable geometry reports")
    func modernRowFrameCacheIgnoresStableGeometryReports() {
        let lookup = ACPMessageList.visibleMessageLookup(rows: [
            (index: 40, stableId: "message-40")
        ])
        let cache = ACPRowFrameCache()
        let frame = CGRect(x: 0, y: 16, width: 100, height: 80)

        #expect(cache.update(id: "message-40", frame: frame, lookup: lookup))
        #expect(!cache.update(id: "message-40", frame: frame, lookup: lookup))
        #expect(cache.frames == ["message-40": frame])
    }

    @Test("modern row-frame cache removes stale rows without repeated writes")
    func modernRowFrameCachePrunesStaleRowsOnce() {
        let cache = ACPRowFrameCache()
        let frame = CGRect(x: 0, y: 16, width: 100, height: 80)
        let originalLookup = ACPMessageList.visibleMessageLookup(rows: [
            (index: 40, stableId: "message-40")
        ])
        let emptyLookup = ACPMessageList.visibleMessageLookup(rows: [])

        #expect(cache.update(id: "message-40", frame: frame, lookup: originalLookup))
        #expect(cache.update(id: "message-40", frame: frame, lookup: emptyLookup))
        #expect(!cache.update(id: "message-40", frame: frame, lookup: emptyLookup))
        #expect(cache.frames.isEmpty)
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

    @Test("tail pause anchor selection prefers sampled anchors before fallback")
    func tailPauseAnchorSelectionUsesSampledAnchorBeforeFallback() {
        let lookup = ACPMessageList.visibleMessageLookup(rows: [
            (index: 40, stableId: "message-40"),
            (index: 41, stableId: "message-41")
        ])

        #expect(ACPMessageList.rememberedAnchorWhenPausingTailFollow(
            latestTopVisibleAnchor: "message-41",
            lookup: lookup,
            allowFirstRenderedAnchorFallback: true
        ) == "message-41")
        #expect(ACPMessageList.rememberedAnchorWhenPausingTailFollow(
            latestTopVisibleAnchor: nil,
            lookup: lookup,
            allowFirstRenderedAnchorFallback: true
        ) == "message-40")
        #expect(ACPMessageList.rememberedAnchorWhenPausingTailFollow(
            latestTopVisibleAnchor: "message-41",
            lookup: lookup,
            allowFirstRenderedAnchorFallback: false
        ) == "message-41")
        #expect(ACPMessageList.rememberedAnchorWhenPausingTailFollow(
            latestTopVisibleAnchor: "stale-message",
            lookup: lookup,
            allowFirstRenderedAnchorFallback: true
        ) == "message-40")
        #expect(ACPMessageList.rememberedAnchorWhenPausingTailFollow(
            latestTopVisibleAnchor: nil,
            lookup: lookup,
            allowFirstRenderedAnchorFallback: false
        ) == nil)
    }

    @Test("first rendered anchor fallback is used only near the rendered window start")
    func firstRenderedAnchorFallbackRequiresWindowStart() {
        #expect(ACPMessageList.shouldUseFirstRenderedAnchorFallback(
            newMinY: 0,
            threshold: 1
        ))
        #expect(ACPMessageList.shouldUseFirstRenderedAnchorFallback(
            newMinY: 1,
            threshold: 1
        ))
        #expect(!ACPMessageList.shouldUseFirstRenderedAnchorFallback(
            newMinY: 120,
            threshold: 1
        ))
    }

    @Test("tail forward preservation prefers sampled anchor before first row")
    func tailForwardPreservationUsesSampledAnchorBeforeFallback() {
        let lookup = ACPMessageList.visibleMessageLookup(rows: [
            (index: 40, stableId: "message-40"),
            (index: 41, stableId: "message-41"),
            (index: 42, stableId: "message-42")
        ])

        #expect(ACPMessageList.anchorForTailForwardPreservation(
            latestTopVisibleAnchor: "message-41",
            lookup: lookup
        ) == "message-41")
        #expect(ACPMessageList.anchorForTailForwardPreservation(
            latestTopVisibleAnchor: "stale-message",
            lookup: lookup
        ) == "message-40")
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
            visibleTail: messages.count,
            stableId: { $0.stableId }
        )

        #expect(rows == [
            ACPMessageList.VisibleRow(index: 2, stableId: "acp-agent:agent-1")
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

        let rows = ACPMessageList.visibleRows(
            messages: messages,
            visibleHead: 1,
            visibleTail: 3,
            stableId: { $0.stableId }
        )

        #expect(rows.map(\.index) == [1, 2])
    }

    @Test("bottom pagination sentinel is shown only when newer rows are hidden")
    func bottomPaginationSentinelReflectsVisibleTail() {
        #expect(ACPMessageList.shouldShowBottomPaginationSentinel(
            visibleTail: 90,
            messageCount: 100
        ))
        #expect(!ACPMessageList.shouldShowBottomPaginationSentinel(
            visibleTail: 100,
            messageCount: 100
        ))
    }

    @Test("bottom geometry resumes tail follow only at the live transcript tail")
    func bottomGeometryResumesTailFollowOnlyAtLiveTail() {
        #expect(!ACPMessageList.shouldResumeTailFollowAtBottom(
            visibleTail: 90,
            messageCount: 100
        ))
        #expect(ACPMessageList.shouldResumeTailFollowAtBottom(
            visibleTail: 100,
            messageCount: 100
        ))
    }

    @Test("bottom geometry pages newer rows only for fresh downward user scrolls")
    func bottomGeometryPagesNewerRowsOnlyForFreshDownwardUserScrolls() {
        #expect(ACPMessageList.shouldStepTailForwardFromBottomGeometry(
            isUserDriven: true,
            isRestoring: false,
            previousMinY: 1_000,
            newMinY: 1_080,
            visibleTail: 90,
            messageCount: 100
        ))
        #expect(!ACPMessageList.shouldStepTailForwardFromBottomGeometry(
            isUserDriven: true,
            isRestoring: true,
            previousMinY: 1_000,
            newMinY: 1_080,
            visibleTail: 90,
            messageCount: 100
        ))
        #expect(!ACPMessageList.shouldStepTailForwardFromBottomGeometry(
            isUserDriven: true,
            isRestoring: false,
            previousMinY: 1_080,
            newMinY: 1_000,
            visibleTail: 90,
            messageCount: 100
        ))
        #expect(!ACPMessageList.shouldStepTailForwardFromBottomGeometry(
            isUserDriven: true,
            isRestoring: false,
            previousMinY: 1_000,
            newMinY: 1_080,
            visibleTail: 100,
            messageCount: 100
        ))
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
