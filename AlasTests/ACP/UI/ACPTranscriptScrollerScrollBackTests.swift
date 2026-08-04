import AppKit
import SwiftUI
import Testing

@testable import Alas

/// Scrolling BACK through the transcript, in a real window, with rows whose
/// SwiftUI content is measured as they mount.
///
/// This is the shape of the bug that made the AppKit scroller unusable: a
/// user scrolling up out of the tail is inside
/// `ACPScrollDirectionClassifier.pauseTolerance` for the first 160pt, so
/// tail-follow is deliberately still on. Every tick mounts the rows the
/// scroll just exposed, mount-time measurement invalidates the hosting view's
/// intrinsic size, and `remeasureRow` re-pinned to the bottom — putting the
/// user back where they started, forever.
@MainActor
@Suite("ACPTranscriptScroller scroll-back")
struct ACPTranscriptScrollerScrollBackTests {
    /// Rows with real (text-measured, varying-height) SwiftUI content, not
    /// fixed-size `Color` blocks: mount-time measurement of real content is
    /// what triggers the intrinsic-size invalidation this exercises.
    private func makeRows(_ count: Int) -> [ACPTranscriptRowSpec] {
        (0..<count).map { index in
            let body = String(repeating: "lorem ipsum dolor sit amet \(index) ", count: 6 + index % 7)
            return ACPTranscriptRowSpec(
                id: "r\(index)",
                equalityToken: ACPRowEqualityToken(index),
                build: {
                    AnyView(
                        VStack(alignment: .leading, spacing: 6) {
                            Text("message \(index)").font(.system(size: 12, weight: .semibold))
                            Text(body).font(.system(size: 13))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            )
        }
    }

    private func makeStackInWindow() -> (
        ACPTranscriptScrollerReconciler, ACPTranscriptScrollerView,
        ACPTranscriptTilingController, NSWindow
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = scroller
        let tiling = ACPTranscriptTilingController()
        let pool = ACPTranscriptRowHostingPool()
        let reconciler = ACPTranscriptScrollerReconciler(tiling: tiling, pool: pool, scroller: scroller)
        scroller.layoutSubtreeIfNeeded()
        return (reconciler, scroller, tiling, window)
    }

    /// Walks the viewport upward the way a trackpad gesture does — AppKit
    /// moves the clip view's bounds origin, then the scroll handler runs a
    /// mount pass — and reports every step the mount pass moved the offset
    /// away from where the gesture put it.
    private func scrollUpSteps(
        _ steps: Int, step: CGFloat = 60,
        reconciler: ACPTranscriptScrollerReconciler, scroller: ACPTranscriptScrollerView
    ) -> [(step: Int, requested: CGFloat, resulting: CGFloat)] {
        var perturbations: [(step: Int, requested: CGFloat, resulting: CGFloat)] = []
        for index in 0..<steps {
            let target = max(0, scroller.scrollY - step)
            scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
            scroller.reflectScrolledClipView(scroller.contentView)
            reconciler.noteUserScroll()
            reconciler.layoutMountedRows()
            if abs(scroller.scrollY - target) > 0.5 {
                perturbations.append((index, target, scroller.scrollY))
            }
        }
        return perturbations
    }

    @Test("scrolling back out of the tail is not re-pinned to the bottom", arguments: [true, false])
    func scrollingBackIsNotRePinned(followsTail: Bool) {
        let (reconciler, scroller, tiling, window) = makeStackInWindow()
        reconciler.apply(specs: makeRows(120), contentWidth: 800, followsTail: followsTail)
        if !followsTail { scroller.scrollToBottom() }
        window.layoutIfNeeded()
        #expect(scroller.distanceFromBottom < 1)

        let perturbations = scrollUpSteps(40, reconciler: reconciler, scroller: scroller)

        #expect(perturbations.isEmpty, "mount pass moved the offset: \(perturbations)")
        // 40 steps of 60pt actually travelled, rather than oscillating within
        // a row-height of the bottom.
        #expect(scroller.scrollY <= tiling.documentHeight - scroller.viewportHeight - 40 * 60 + 1)
    }

    /// Head pagination: the coordinator's scroll handler asks the transcript
    /// to step the render window back, and the NEXT apply carries the older
    /// rows. The row the user is looking at must not move on screen — on any
    /// step, including the FINAL one, where `__top_pagination__` disappears in
    /// the same update that grafts rows in above (ids change at both ends, so
    /// the diff falls to `.reset`).
    @Test("head pagination keeps the reading position, including the final step")
    func headPaginationKeepsReadingPosition() {
        let (reconciler, scroller, tiling, nsWindow) = makeStackInWindow()
        let allRows = makeRows(150)

        reconciler.apply(specs: renderWindow(head: 100, allRows: allRows),
                         contentWidth: 800, followsTail: false)
        nsWindow.layoutIfNeeded()

        // Walk the head back one chunk at a time, as the scroll handler does,
        // from a viewport parked at the top of the current window.
        for head in stride(from: 75, through: 0, by: -25) {
            scroller.setScrollY(0)
            reconciler.layoutMountedRows()
            // The row the user is reading: the first real one below the top.
            let referenceId = "r\(head + 25)"
            let onScreenBefore = tiling.row(withId: referenceId)!.minY - scroller.scrollY

            reconciler.apply(specs: renderWindow(head: head, allRows: allRows),
                             contentWidth: 800, followsTail: false)

            let onScreenAfter = tiling.row(withId: referenceId)!.minY - scroller.scrollY
            #expect(
                abs(onScreenAfter - onScreenBefore) < 1,
                "head step to \(head) moved \(referenceId) by \(onScreenAfter - onScreenBefore)pt"
            )
        }
    }

    /// The row-spec list `ACPTranscriptScroller.Coordinator.rowSpecs` builds
    /// for a render window starting at `head`: the head-pagination spinner
    /// (present only while older history remains), the window's message rows,
    /// and the composer spacer.
    private func renderWindow(head: Int, allRows: [ACPTranscriptRowSpec]) -> [ACPTranscriptRowSpec] {
        let spinner = ACPTranscriptRowSpec(
            id: "__top_pagination__",
            equalityToken: ACPRowEqualityToken(false),
            build: { AnyView(Color.clear.frame(height: 14)) }
        )
        let spacer = ACPTranscriptRowSpec(
            id: "__composer_spacer__",
            equalityToken: ACPRowEqualityToken(true),
            build: { AnyView(Color.clear.frame(height: 220)) }
        )
        return (head > 0 ? [spinner] : []) + Array(allRows[head..<allRows.count]) + [spacer]
    }

    /// A mirrored session's refresh poll (`ACPSessionManager.runMirrorRefresh`)
    /// replaces the transcript with its tail and then prepends the older
    /// messages straight back, so the reconciler sees a block removed and the
    /// SAME block re-inserted one update later — every 2.5s, forever. The
    /// round trip must net out: with only the insertion side treating an
    /// all-synthetic prefix as "above the viewport", the removal declined to
    /// compensate while the re-insertion compensated in full, teleporting the
    /// viewport a page below where the user was reading.
    @Test("removing and re-inserting the same block leaves the viewport where it was")
    func removeThenReinsertRoundTripIsNeutral() {
        let (reconciler, scroller, _, nsWindow) = makeStackInWindow()
        let allRows = makeRows(150)
        let full = renderWindow(head: 60, allRows: allRows)
        reconciler.apply(specs: full, contentWidth: 800, followsTail: false)
        nsWindow.layoutIfNeeded()

        // The user is parked at the very top of the window, under the head
        // pagination spinner — the position the round trip used to destroy.
        scroller.setScrollY(0)
        reconciler.layoutMountedRows()
        let scrollYBefore = scroller.scrollY

        // Poll tick: transcript replaced with its tail (the 60 window rows
        // between the spinner and the composer spacer drop out) …
        var tailOnly = full
        tailOnly.removeSubrange(1..<61)
        reconciler.apply(specs: tailOnly, contentWidth: 800, followsTail: false)
        // … then the backfill puts them straight back.
        reconciler.apply(specs: full, contentWidth: 800, followsTail: false)

        #expect(
            abs(scroller.scrollY - scrollYBefore) < 1,
            "round trip moved the viewport \(scroller.scrollY - scrollYBefore)pt"
        )
    }

    /// The mirror of the `remeasureRow` trap, one level up: inside
    /// `ACPScrollDirectionClassifier.pauseTolerance` the coordinator has not
    /// paused tail-follow yet, so any SwiftUI update landing mid-gesture
    /// reaches `apply(followsTail: true)` and used to slam the viewport back
    /// to the bottom — the user scrolls up, and the transcript jumps to the
    /// newest message "for no reason".
    @Test("an update landing mid-gesture does not slam the viewport back to the bottom")
    func updateDuringUnpausedScrollUpDoesNotRePin() {
        let (reconciler, scroller, _, nsWindow) = makeStackInWindow()
        let specs = makeRows(120)
        reconciler.apply(specs: specs, contentWidth: 800, followsTail: true)
        nsWindow.layoutIfNeeded()
        #expect(scroller.distanceFromBottom < 1)

        // The user scrolls up less than `pauseTolerance`, so tail-follow is
        // deliberately still on — exactly as the coordinator leaves it.
        let target = scroller.scrollY - 90
        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
        scroller.reflectScrolledClipView(scroller.contentView)
        reconciler.noteUserScroll()
        reconciler.layoutMountedRows()
        #expect(abs(scroller.scrollY - target) < 0.5)

        // A model update lands mid-gesture: a streaming row grows, so this is
        // a genuine content change, not a no-op apply.
        let grown = ACPTranscriptRowSpec(
            id: "r119",
            equalityToken: ACPRowEqualityToken(119_000),
            build: { AnyView(Color.clear.frame(height: 400)) }
        )
        reconciler.apply(
            specs: specs.dropLast() + [grown], contentWidth: 800, followsTail: true
        )

        #expect(abs(scroller.scrollY - target) < 0.5, "viewport was re-pinned to \(scroller.scrollY)")
    }

    /// The suppression must not outlive the gesture. Between
    /// `bottomTolerance` and `pauseTolerance` the session still reports that
    /// it follows the tail, so a viewport left permanently unpinned there
    /// would get neither behavior: streaming content piling up below the
    /// fold while the "go to newest" affordance stays hidden, because it keys
    /// off `session.followsTranscriptTail` and nothing paused it.
    @Test("once the gesture ends, an update re-pins to the tail again")
    func rePinResumesAfterTheGestureEnds() async throws {
        let (reconciler, scroller, _, nsWindow) = makeStackInWindow()
        let specs = makeRows(120)
        reconciler.apply(specs: specs, contentWidth: 800, followsTail: true)
        nsWindow.layoutIfNeeded()

        // Parked in the band where tail-follow is deliberately still on:
        // past `bottomTolerance`, short of `pauseTolerance`.
        let target = scroller.scrollY - 90
        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
        scroller.reflectScrolledClipView(scroller.contentView)
        reconciler.noteUserScroll()
        reconciler.layoutMountedRows()
        #expect(abs(scroller.scrollY - target) < 0.5)

        // The gesture ends. Generous grace over the window, matching this
        // codebase's margin for time-based tests under CI scheduling load.
        let grace = ACPTranscriptScrollerReconciler.userScrollSuppressionWindow + 0.4
        try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))

        reconciler.apply(specs: specs, contentWidth: 800, followsTail: true)

        #expect(scroller.distanceFromBottom < 1)
    }

    /// The behavior `remeasureRow`'s re-pin exists for must survive the fix:
    /// while the viewport IS at the tail, a row growing under it keeps the
    /// tail glued.
    @Test("a row growing while the viewport sits at the tail still re-pins")
    func growthAtTailStillRePins() {
        let (reconciler, scroller, _, window) = makeStackInWindow()
        let specs = makeRows(30)
        reconciler.apply(specs: specs, contentWidth: 800, followsTail: true)
        window.layoutIfNeeded()
        #expect(scroller.distanceFromBottom < 1)

        let grown = ACPTranscriptRowSpec(
            id: "r29",
            equalityToken: ACPRowEqualityToken(29_000),
            build: { AnyView(Color.clear.frame(height: 900)) }
        )
        reconciler.apply(
            specs: specs.dropLast() + [grown], contentWidth: 800, followsTail: true
        )
        reconciler.remeasureRow(id: "r29")

        #expect(scroller.distanceFromBottom < 1)
    }
}
