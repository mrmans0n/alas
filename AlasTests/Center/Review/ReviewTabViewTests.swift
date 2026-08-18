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
            hasLoadedSnapshot: false
        ))
        #expect(ReviewTabStartupRecoveryReadiness.shouldComplete(
            hasReviewRequest: false,
            hasLoadedSnapshot: true
        ))
        #expect(!ReviewTabStartupRecoveryReadiness.shouldComplete(
            hasReviewRequest: false,
            hasLoadedSnapshot: false
        ))
    }

    @Test func outdatedDrawerCapsExpandedListHeightToProtectReviewContent() {
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 1_200) == 280)
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 600) == 210)
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 200) == 80)
        #expect(OutdatedThreadsDrawerPresentation.expandedListMaxHeight(availableHeight: 0) == 280)
    }
}
