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
            followsTranscriptTail: true,
            isRestoring: false
        ))
    }

    @Test("content growth does not restore the tail after the user paused tail-follow")
    func contentGrowthDoesNotRestoreWhenTailFollowPaused() {
        #expect(!ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: 5_000,
            newContentHeight: 5_220,
            viewportHeight: 600,
            newMinY: 4_400,
            followsTranscriptTail: false,
            isRestoring: false
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
            followsTranscriptTail: true,
            isRestoring: false
        ))
    }

    @Test("content height oscillation schedules one tail restore")
    func contentHeightOscillationSchedulesOneTailRestore() {
        let viewportHeight: CGFloat = 600
        let lowEstimatedHeight: CGFloat = 5_000
        let highEstimatedHeight: CGFloat = 5_220
        let oldTailOffset = lowEstimatedHeight - viewportHeight

        #expect(ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: lowEstimatedHeight,
            newContentHeight: highEstimatedHeight,
            viewportHeight: viewportHeight,
            newMinY: oldTailOffset,
            followsTranscriptTail: true,
            isRestoring: false
        ))

        #expect(!ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: lowEstimatedHeight,
            newContentHeight: highEstimatedHeight,
            viewportHeight: viewportHeight,
            newMinY: oldTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            lastRestoreSourceContentHeight: lowEstimatedHeight,
            lastRestoredContentHeight: highEstimatedHeight
        ))

        #expect(ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: highEstimatedHeight,
            newContentHeight: highEstimatedHeight + ACPScrollDirectionClassifier.bottomTolerance + 1,
            viewportHeight: viewportHeight,
            newMinY: oldTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            lastRestoreSourceContentHeight: lowEstimatedHeight,
            lastRestoredContentHeight: highEstimatedHeight
        ))
    }

    @Test("content growth can restore after a real content shrink")
    func contentGrowthCanRestoreAfterRealContentShrink() {
        let viewportHeight: CGFloat = 600
        let previousRestoredHeight: CGFloat = 5_220
        let previousRestoreSourceHeight: CGFloat = 5_000
        let shrunkenHeight: CGFloat = 4_800
        let regrownHeight: CGFloat = 5_000
        let shrunkenTailOffset = shrunkenHeight - viewportHeight

        #expect(ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: shrunkenHeight,
            newContentHeight: regrownHeight,
            viewportHeight: viewportHeight,
            newMinY: shrunkenTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            lastRestoreSourceContentHeight: previousRestoreSourceHeight,
            lastRestoredContentHeight: previousRestoredHeight
        ))
    }

    @Test("settled content shrink resets the content growth restore bookmark")
    func settledContentShrinkResetsContentGrowthRestoreBookmark() {
        let viewportHeight: CGFloat = 600
        let previousRestoredHeight: CGFloat = 5_220
        let shrunkenHeight: CGFloat = 5_000
        let shrunkenTailOffset = shrunkenHeight - viewportHeight

        #expect(ACPMessageList.shouldResetContentGrowthTailRestoreAfterShrink(
            previousContentHeight: previousRestoredHeight,
            newContentHeight: shrunkenHeight,
            viewportHeight: viewportHeight,
            newMinY: shrunkenTailOffset,
            followsTranscriptTail: true,
            isRestoring: true,
            hasPendingTailScroll: false,
            lastRestoredContentHeight: previousRestoredHeight
        ))

        #expect(ACPMessageList.shouldApplyDeferredContentShrinkBookmarkReset(
            expectedContentHeight: shrunkenHeight,
            latestContentHeight: shrunkenHeight,
            latestViewportHeight: viewportHeight,
            latestMinY: shrunkenTailOffset,
            followsTranscriptTail: true,
            isRestoring: true,
            hasPendingTailScroll: false
        ))

        #expect(ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: shrunkenHeight,
            newContentHeight: previousRestoredHeight,
            viewportHeight: viewportHeight,
            newMinY: shrunkenTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            lastRestoreSourceContentHeight: nil,
            lastRestoredContentHeight: nil
        ))
    }

    @Test("estimate oscillation does not apply deferred shrink reset")
    func estimateOscillationDoesNotApplyDeferredShrinkReset() {
        let viewportHeight: CGFloat = 600
        let highEstimatedHeight: CGFloat = 5_220
        let lowEstimatedHeight: CGFloat = 5_000
        let highTailOffset = highEstimatedHeight - viewportHeight

        #expect(!ACPMessageList.shouldApplyDeferredContentShrinkBookmarkReset(
            expectedContentHeight: lowEstimatedHeight,
            latestContentHeight: highEstimatedHeight,
            latestViewportHeight: viewportHeight,
            latestMinY: highTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            hasPendingTailScroll: false
        ))
    }

    @Test("pending shrink reset keeps same oscillation bookmark active")
    func pendingShrinkResetKeepsSameOscillationBookmarkActive() {
        let viewportHeight: CGFloat = 600
        let lowHeight: CGFloat = 5_000
        let highHeight: CGFloat = 5_220
        let lowTailOffset = lowHeight - viewportHeight

        #expect(!ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: lowHeight,
            newContentHeight: highHeight,
            viewportHeight: viewportHeight,
            newMinY: lowTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            contentShrinkBookmarkResetState: .pending,
            lastRestoreSourceContentHeight: lowHeight,
            lastRestoredContentHeight: highHeight
        ))
    }

    @Test("verified shrink reset allows same source regrowth restore")
    func verifiedShrinkResetAllowsSameSourceRegrowthRestore() {
        let viewportHeight: CGFloat = 600
        let lowHeight: CGFloat = 5_000
        let highHeight: CGFloat = 5_220
        let lowTailOffset = lowHeight - viewportHeight

        #expect(ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: lowHeight,
            newContentHeight: highHeight,
            viewportHeight: viewportHeight,
            newMinY: lowTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            contentShrinkBookmarkResetState: .verified,
            lastRestoreSourceContentHeight: lowHeight,
            lastRestoredContentHeight: highHeight
        ))
    }

    @Test("content growth restore is stored before coalescing a pending tail scroll")
    func contentGrowthRestoreIsStoredBeforeCoalescingPendingTailScroll() {
        #expect(ACPMessageList.shouldStoreContentGrowthRestoreBeforeCoalescing(
            hasPendingTailScroll: true,
            hasContentGrowthRestore: true
        ))
        #expect(!ACPMessageList.shouldStoreContentGrowthRestoreBeforeCoalescing(
            hasPendingTailScroll: false,
            hasContentGrowthRestore: true
        ))
        #expect(!ACPMessageList.shouldStoreContentGrowthRestoreBeforeCoalescing(
            hasPendingTailScroll: true,
            hasContentGrowthRestore: false
        ))
    }

    @Test("coalesced content growth restore preserves lowest source height")
    func coalescedContentGrowthRestorePreservesLowestSourceHeight() {
        let existing = ACPContentGrowthTailRestore(sourceHeight: 5_000, targetHeight: 5_100)
        let next = ACPContentGrowthTailRestore(sourceHeight: 5_100, targetHeight: 5_220)
        let lowerNext = ACPContentGrowthTailRestore(sourceHeight: 5_000, targetHeight: 5_050)

        #expect(ACPMessageList.mergedContentGrowthTailRestore(existing: existing, new: next) == ACPContentGrowthTailRestore(
            sourceHeight: 5_000,
            targetHeight: 5_220
        ))
        #expect(ACPMessageList.mergedContentGrowthTailRestore(existing: next, new: lowerNext) == ACPContentGrowthTailRestore(
            sourceHeight: 5_000,
            targetHeight: 5_220
        ))
        #expect(ACPMessageList.mergedContentGrowthTailRestore(existing: nil, new: next) == next)
        #expect(ACPMessageList.mergedContentGrowthTailRestore(existing: existing, new: nil) == nil)
    }

    @Test("scheduled tail task clears bookkeeping only for its own generation")
    func scheduledTailTaskClearsBookkeepingOnlyForOwnGeneration() {
        #expect(ACPMessageList.shouldClearScheduledTailScrollBookkeeping(
            scheduledGeneration: 4,
            currentGeneration: 4
        ))
        #expect(!ACPMessageList.shouldClearScheduledTailScrollBookkeeping(
            scheduledGeneration: 4,
            currentGeneration: 5
        ))
    }

    @Test("shrink reset task clears bookkeeping only for its own generation")
    func shrinkResetTaskClearsBookkeepingOnlyForOwnGeneration() {
        #expect(ACPMessageList.shouldClearContentShrinkResetBookkeeping(
            scheduledGeneration: 8,
            currentGeneration: 8
        ))
        #expect(!ACPMessageList.shouldClearContentShrinkResetBookkeeping(
            scheduledGeneration: 8,
            currentGeneration: 9
        ))
    }

    @Test("verified shrink reset is consumed only after growth restore scrolls")
    func verifiedShrinkResetIsConsumedOnlyAfterGrowthRestoreScrolls() {
        #expect(ACPMessageList.contentShrinkBookmarkResetStateAfterScheduledTailScroll(
            didScroll: false,
            hasContentGrowthRestore: true,
            currentState: .verified
        ) == .verified)
        #expect(ACPMessageList.contentShrinkBookmarkResetStateAfterScheduledTailScroll(
            didScroll: true,
            hasContentGrowthRestore: true,
            currentState: .verified
        ) == .none)
        #expect(ACPMessageList.contentShrinkBookmarkResetStateAfterScheduledTailScroll(
            didScroll: true,
            hasContentGrowthRestore: false,
            currentState: .verified
        ) == .verified)
    }

    @Test("deferred shrink reset accepts small settled height drift at bottom")
    func deferredShrinkResetAcceptsSmallSettledHeightDriftAtBottom() {
        let viewportHeight: CGFloat = 600
        let expectedContentHeight: CGFloat = 5_000
        let latestContentHeight: CGFloat = 5_001
        let latestTailOffset = latestContentHeight - viewportHeight

        #expect(ACPMessageList.shouldApplyDeferredContentShrinkBookmarkReset(
            expectedContentHeight: expectedContentHeight,
            latestContentHeight: latestContentHeight,
            latestViewportHeight: viewportHeight,
            latestMinY: latestTailOffset,
            followsTranscriptTail: true,
            isRestoring: false,
            hasPendingTailScroll: false
        ))
    }

    @Test("deferred shrink reset requires a later geometry probe or debounce")
    func deferredShrinkResetRequiresLaterGeometryProbeOrDebounce() {
        #expect(!ACPMessageList.shouldUseScrollProbeForDeferredShrinkReset(
            latestProbeGeneration: 12,
            scheduledProbeGeneration: 12,
            didDebounce: false
        ))
        #expect(ACPMessageList.shouldUseScrollProbeForDeferredShrinkReset(
            latestProbeGeneration: 12,
            scheduledProbeGeneration: 12,
            didDebounce: true
        ))
        #expect(ACPMessageList.shouldUseScrollProbeForDeferredShrinkReset(
            latestProbeGeneration: 13,
            scheduledProbeGeneration: 12,
            didDebounce: false
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

    @Test("go-to-newest affordance shows only when tail-follow is paused")
    func goToNewestAffordanceShowsOnlyWhenTailFollowPaused() {
        #expect(!ACPMessageList.shouldShowGoToNewestAffordance(followsTranscriptTail: true))
        #expect(ACPMessageList.shouldShowGoToNewestAffordance(followsTranscriptTail: false))
    }

    @Test("go-to-newest affordance resumes tail-follow with scheduled animated scroll")
    func goToNewestAffordanceResumesTailFollowWithScheduledAnimatedScroll() {
        #expect(ACPMessageList.goToNewestAffordanceAction() == ACPMessageList.GoToNewestAffordanceAction(
            resumesTailFollow: true,
            schedulesTailScroll: true,
            animatedTailScroll: true
        ))
    }

    @Test("go-to-newest affordance is positioned above composer-safe space")
    func goToNewestAffordanceIsPositionedAboveComposerSafeSpace() {
        #expect(ACPMessageList.goToNewestAffordanceBottomPadding(
            composerSpacerHeight: 220,
            gap: 12
        ) == 232)
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
        let windowKey = ACPRowFrameCache.WindowKey(generation: 1, head: 0, tail: 90)

        #expect(cache.update(id: "message-40", frame: frame, lookup: lookup, windowKey: windowKey))
        #expect(!cache.update(id: "message-40", frame: frame, lookup: lookup, windowKey: windowKey))
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
        let originalWindow = ACPRowFrameCache.WindowKey(generation: 1, head: 0, tail: 90)
        let movedWindow = ACPRowFrameCache.WindowKey(generation: 1, head: 0, tail: 0)

        #expect(cache.update(id: "message-40", frame: frame, lookup: originalLookup, windowKey: originalWindow))
        // Window moved (tail bound changed): the stale scan should run once
        // here and evict "message-40", which the new lookup no longer contains.
        #expect(cache.update(id: "message-40", frame: frame, lookup: emptyLookup, windowKey: movedWindow))
        #expect(!cache.update(id: "message-40", frame: frame, lookup: emptyLookup, windowKey: movedWindow))
        #expect(cache.frames.isEmpty)
    }

    @Test("modern row-frame cache skips the stale-entry scan while the window key is unchanged")
    func modernRowFrameCacheSkipsStaleScanForUnchangedWindow() {
        let cache = ACPRowFrameCache()
        let frame = CGRect(x: 0, y: 16, width: 100, height: 80)
        let windowKey = ACPRowFrameCache.WindowKey(generation: 1, head: 0, tail: 90)
        // The lookup no longer contains "message-40", but the window key is
        // identical to the one already recorded by the cache's first update
        // below, so the stale scan must not run again and evict it.
        let lookup = ACPMessageList.visibleMessageLookup(rows: [
            (index: 41, stableId: "message-41")
        ])

        #expect(cache.update(id: "message-40", frame: frame, lookup: ACPMessageList.visibleMessageLookup(rows: [
            (index: 40, stableId: "message-40")
        ]), windowKey: windowKey))
        // Same window key as above: even though "message-40" is stale
        // relative to `lookup`, the cleanup scan already ran for this window
        // and must not run again, so "message-40" survives this call.
        #expect(cache.update(id: "message-41", frame: frame, lookup: lookup, windowKey: windowKey))
        #expect(cache.frames["message-40"] == frame)
        #expect(cache.frames["message-41"] == frame)
    }

    @Test("modern row-frame cache runs the stale-entry scan again once the window key changes")
    func modernRowFrameCacheRerunsStaleScanWhenWindowChanges() {
        let cache = ACPRowFrameCache()
        let frame = CGRect(x: 0, y: 16, width: 100, height: 80)
        let firstWindow = ACPRowFrameCache.WindowKey(generation: 1, head: 0, tail: 90)
        let secondWindow = ACPRowFrameCache.WindowKey(generation: 1, head: 1, tail: 91)
        let lookup = ACPMessageList.visibleMessageLookup(rows: [
            (index: 41, stableId: "message-41")
        ])

        #expect(cache.update(id: "message-40", frame: frame, lookup: ACPMessageList.visibleMessageLookup(rows: [
            (index: 40, stableId: "message-40")
        ]), windowKey: firstWindow))
        // Different window key: the scan must run and evict "message-40",
        // which `lookup` no longer contains.
        #expect(cache.update(id: "message-41", frame: frame, lookup: lookup, windowKey: secondWindow))
        #expect(cache.frames == ["message-41": frame])
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

    @Test("tracked anchor is cleared when tail-follow resumes so a later pause can't reuse a stale value")
    func trackedAnchorResetsWhenTailFollowResumes() {
        // Resuming clears whatever anchor a previous pause left behind, so
        // the next pause is forced to recompute from the live frame cache
        // instead of reusing a value that predates the resume.
        #expect(ACPMessageList.trackedAnchorAfterFollowsChange(
            follows: true,
            previousTrackedAnchor: "message-40"
        ) == nil)
        #expect(ACPMessageList.trackedAnchorAfterFollowsChange(
            follows: true,
            previousTrackedAnchor: nil
        ) == nil)
        // Pausing doesn't touch the tracked anchor; the pause path computes
        // its own anchor separately.
        #expect(ACPMessageList.trackedAnchorAfterFollowsChange(
            follows: false,
            previousTrackedAnchor: "message-40"
        ) == "message-40")
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

    @Test func rowFrameAnchorTrackingSkippedWhileFollowingTailOrRestoring() {
        #expect(!ACPMessageList.shouldTrackAnchorFromRowFrames(
            followsTranscriptTail: true, isRestoringTail: false, isBackfillingOlderMessages: false))
        #expect(!ACPMessageList.shouldTrackAnchorFromRowFrames(
            followsTranscriptTail: false, isRestoringTail: true, isBackfillingOlderMessages: false))
        #expect(!ACPMessageList.shouldTrackAnchorFromRowFrames(
            followsTranscriptTail: false, isRestoringTail: false, isBackfillingOlderMessages: true))
        #expect(ACPMessageList.shouldTrackAnchorFromRowFrames(
            followsTranscriptTail: false, isRestoringTail: false, isBackfillingOlderMessages: false))
    }

    @Test func tailScrollSkippedWhenAlreadyAtBottom() {
        #expect(!ACPMessageList.shouldPerformTailScroll(distanceFromBottom: 0))
        #expect(!ACPMessageList.shouldPerformTailScroll(
            distanceFromBottom: ACPScrollDirectionClassifier.bottomTolerance))
        #expect(ACPMessageList.shouldPerformTailScroll(
            distanceFromBottom: ACPScrollDirectionClassifier.bottomTolerance + 1))
        // Unknown geometry (no probe yet) must scroll.
        #expect(ACPMessageList.shouldPerformTailScroll(distanceFromBottom: nil))
    }

    @Test func contentGrowthRestoreSuppressedWhileRestoring() {
        #expect(!ACPMessageList.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: 100, newContentHeight: 200, viewportHeight: 50,
            newMinY: 0, followsTranscriptTail: true, isRestoring: true))
    }
}
