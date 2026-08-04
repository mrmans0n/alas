import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptScrollBookkeeping reset")
struct ACPTranscriptScrollBookkeepingResetTests {
    /// Switching the transcript between the legacy and AppKit scrollers
    /// rebuilds the subtree via `.id(scrollerFlagState)`, but this object is
    /// `@State` on `ACPMessageList` itself and survives that identity
    /// change. `restoredRememberedAnchor` is the field that matters: if it
    /// carries over, `restoreRememberedAnchorIfNeeded` sees the current
    /// anchor as already restored and returns early, leaving a paused chat
    /// at the rebuilt scroll view's default position instead of where the
    /// user was reading.
    @Test("reset clears the restored-anchor latch so the rebuilt scroll view restores again")
    func resetClearsRestoredAnchorLatch() {
        let book = ACPTranscriptScrollBookkeeping()
        book.restoredRememberedAnchor = "msg-42"

        book.reset()

        #expect(book.restoredRememberedAnchor == nil)
    }

    @Test("reset returns every field to its initial value")
    func resetClearsEveryField() {
        let book = ACPTranscriptScrollBookkeeping()
        book.isRestoringTail = true
        book.restoredRememberedAnchor = "msg-42"
        book.latestRememberedScrollAnchorIndex = 7
        book.lastHeadStepAt = Date(timeIntervalSince1970: 1)
        book.lastTailStepAt = Date(timeIntervalSince1970: 2)
        book.pendingTailScrollGeneration = 3
        book.pendingContentShrinkResetGeneration = 4
        book.scrollGeometryGeneration = 5
        book.lastContentGrowthTailRestoreSourceHeight = 100
        book.lastContentGrowthTailRestoreHeight = 200

        book.reset()

        #expect(book.isRestoringTail == false)
        #expect(book.restoredRememberedAnchor == nil)
        #expect(book.latestRememberedScrollAnchorIndex == nil)
        #expect(book.lastHeadStepAt == .distantPast)
        #expect(book.lastTailStepAt == .distantPast)
        #expect(book.pendingTailScrollGeneration == 0)
        #expect(book.pendingContentShrinkResetGeneration == 0)
        #expect(book.scrollGeometryGeneration == 0)
        #expect(book.lastScrollProbe == nil)
        #expect(book.pendingContentGrowthTailRestore == nil)
        #expect(book.lastContentGrowthTailRestoreSourceHeight == nil)
        #expect(book.lastContentGrowthTailRestoreHeight == nil)
    }

    /// A tail scroll scheduled against the outgoing scroll view must not
    /// land on the incoming one after the switch.
    @Test("reset cancels scheduled scroll work")
    func resetCancelsPendingTasks() async {
        let book = ACPTranscriptScrollBookkeeping()
        let started = AsyncChannel()
        book.pendingTailScrollTask = Task {
            await started.signal()
            try? await Task.sleep(for: .seconds(60))
        }
        book.pendingContentShrinkResetTask = Task {
            try? await Task.sleep(for: .seconds(60))
        }
        let tailTask = book.pendingTailScrollTask
        let shrinkTask = book.pendingContentShrinkResetTask
        await started.wait()

        book.reset()

        _ = await tailTask?.value
        _ = await shrinkTask?.value
        #expect(tailTask?.isCancelled == true)
        #expect(shrinkTask?.isCancelled == true)
        #expect(book.pendingTailScrollTask == nil)
        #expect(book.pendingContentShrinkResetTask == nil)
    }
}

/// Minimal one-shot signal so the cancellation test can wait for the task to
/// actually start before cancelling it, rather than sleeping.
private actor AsyncChannel {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isSignalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
