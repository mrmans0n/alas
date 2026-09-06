import Testing
@testable import Alas

struct ReviewTabViewTests {
    @Test func loadingPresentationKeepsLoadedSessionVisibleDuringRefresh() {
        #expect(ReviewTabLoadingPresentation.showsBlockingLoader(isLoading: true, hasSession: false))
        #expect(!ReviewTabLoadingPresentation.showsBlockingLoader(isLoading: true, hasSession: true))
        #expect(!ReviewTabLoadingPresentation.showsBlockingLoader(isLoading: false, hasSession: true))
    }

    @Test func loadErrorPresentationReplacesStaleLoadedSessionAfterRefreshFailure() {
        #expect(ReviewTabLoadingPresentation.showsLoadError(
            loadError: "failed",
            isLoading: false,
            hasSession: true
        ))
        #expect(!ReviewTabLoadingPresentation.showsLoadError(
            loadError: "failed",
            isLoading: true,
            hasSession: false
        ))
        #expect(!ReviewTabLoadingPresentation.showsLoadError(
            loadError: nil,
            isLoading: false,
            hasSession: true
        ))
    }

    @Test func pendingReviewRailOnlyShowsForStagedComments() {
        #expect(!ReviewTabPendingReviewPresentation.showsRail(stagedCount: 0, loadedFileCount: 0))
        #expect(ReviewTabPendingReviewPresentation.showsRail(stagedCount: 1, loadedFileCount: 0))
        #expect(ReviewTabPendingReviewPresentation.showsRail(stagedCount: 1, loadedFileCount: 3))
        #expect(!ReviewTabPendingReviewPresentation.showsRail(stagedCount: 1, loadedFileCount: nil))
    }

    @Test func finishReviewToolbarButtonRequiresSubmitCapabilityAndPendingReviewScope() {
        #expect(ReviewTabPendingReviewPresentation.showsToolbarFinishButton(
            canSubmitReview: true,
            hasPendingReviewScope: true
        ))
        #expect(!ReviewTabPendingReviewPresentation.showsToolbarFinishButton(
            canSubmitReview: false,
            hasPendingReviewScope: true
        ))
        #expect(!ReviewTabPendingReviewPresentation.showsToolbarFinishButton(
            canSubmitReview: true,
            hasPendingReviewScope: false
        ))
    }

    @Test func startupRecoveryCompletesAfterMatchedOrSettledReviewLoad() {
        #expect(ReviewTabStartupRecoveryReadiness.shouldComplete(
            hasReviewRequest: true,
            reviewRefreshSettled: false
        ))
        #expect(ReviewTabStartupRecoveryReadiness.shouldComplete(
            hasReviewRequest: false,
            reviewRefreshSettled: true
        ))
        #expect(!ReviewTabStartupRecoveryReadiness.shouldComplete(
            hasReviewRequest: false,
            reviewRefreshSettled: false
        ))
        #expect(ReviewTabStartupRecoveryReadiness.reviewRefreshSettled(
            hasSnapshot: false,
            isRefreshing: false,
            hasError: true
        ))
        #expect(!ReviewTabStartupRecoveryReadiness.reviewRefreshSettled(
            hasSnapshot: true,
            isRefreshing: true,
            hasError: false
        ))
    }

    @Test func reviewTabLoadKeyChangesWhenReviewRequestArrives() {
        #expect(ReviewTabLoadKey.build(
            baseLoadKey: "base",
            reviewRequestNumber: nil,
            reviewRefreshSettled: false
        ) != ReviewTabLoadKey.build(
            baseLoadKey: "base",
            reviewRequestNumber: 1042,
            reviewRefreshSettled: false
        ))
    }

    @Test func outdatedDrawerCapsExpandedListHeightToProtectReviewContent() {
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 1_200) == 280)
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 600) == 210)
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 200) == 80)
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 0) == 280)
    }

    @Test func outdatedDrawerCappedListHeightShrinksToContentButNeverExceedsCap() {
        // Short content: shrink-wrap to its measured height.
        #expect(
            OutdatedThreadsDrawerPresentation.cappedListHeight(
                measuredContentHeight: 60,
                maxHeight: 280
            ) == 60
        )
        // Long content (e.g. many threads): clamp to the cap instead of overflowing
        // past the drawer, which is what let the expanded section swallow the whole
        // review pane and made it impossible to scroll.
        #expect(
            OutdatedThreadsDrawerPresentation.cappedListHeight(
                measuredContentHeight: 1_892,
                maxHeight: 280
            ) == 280
        )
        // Not-yet-measured content (0, before the first layout pass reports a size)
        // must not collapse the list to zero height.
        #expect(
            OutdatedThreadsDrawerPresentation.cappedListHeight(
                measuredContentHeight: 0,
                maxHeight: 280
            ) == 1
        )
    }
}
