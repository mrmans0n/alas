import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("AppKit diff scroller reconciliation")
struct AppKitDiffScrollerReconcilerTests {
    private typealias Stack = (
        window: NSWindow,
        scrollView: AppKitDiffScrollView,
        tiling: AppKitDiffTilingController,
        pool: AppKitDiffRowHostingPool,
        reconciler: AppKitDiffScrollerReconciler
    )

    private func makeStack() -> Stack {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scrollView = AppKitDiffScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let tiling = AppKitDiffTilingController()
        let pool = AppKitDiffRowHostingPool()
        let reconciler = AppKitDiffScrollerReconciler(tiling: tiling, pool: pool, scrollView: scrollView)
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        scrollView.layoutSubtreeIfNeeded()
        return (window, scrollView, tiling, pool, reconciler)
    }

    private func spec(
        _ id: String,
        token: Int = 0,
        height: CGFloat = 20,
        ownerID: String? = nil,
        retention: AppKitDiffRowRetention = .recyclable
    ) -> AppKitDiffRowSpec {
        AppKitDiffRowSpec(
            id: id,
            ownerID: ownerID,
            equalityToken: .init(token),
            contentSignature: token,
            estimatedHeight: height,
            retention: retention
        ) {
            AnyView(Color.clear.frame(height: height))
        }
    }

    private func plan(
        count: Int = 200,
        height: CGFloat = 40
    ) -> AppKitDiffRowPlan {
        .init(rows: (0..<count).map { spec("row-\($0)", height: height) })
    }

    @Test("mounts only the overscan band and follows a target row")
    func mountsBoundedBandAndScrollsToTarget() {
        let stack = makeStack()
        stack.reconciler.apply(plan: plan(), contentWidth: stack.scrollView.contentWidth)

        #expect(stack.pool.mountedIDs.count < 40)
        stack.reconciler.scroll(to: .init(
            targetID: "row-150", fallbackID: nil, alignment: .top, animated: false, generation: 1
        ))

        #expect(stack.pool.mountedIDs.contains("row-150"))
        #expect(stack.scrollView.scrollY > 2_000)
    }

    @Test("inserting above the viewport preserves the anchor screen offset")
    func prependedRowPreservesAnchorOffset() {
        let stack = makeStack()
        stack.reconciler.apply(plan: plan(), contentWidth: stack.scrollView.contentWidth)
        stack.reconciler.scroll(to: .init(
            targetID: "row-150", fallbackID: nil, alignment: .top, animated: false, generation: 1
        ))
        let before = stack.tiling.row(withID: "row-150")!.minY - stack.scrollView.scrollY
        stack.reconciler.apply(
            plan: .init(rows: [spec("before", height: 30)] + plan().rows),
            contentWidth: stack.scrollView.contentWidth
        )
        let after = stack.tiling.row(withID: "row-150")!.minY - stack.scrollView.scrollY

        #expect(abs(before - after) < 0.5)
    }

    @Test("a replaced anchor row keeps the absolute viewport position")
    func replacedAnchorRowKeepsAbsoluteViewportPosition() {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: (0..<20).map { spec("giant-\($0)", height: 500) }),
            contentWidth: stack.scrollView.contentWidth
        )
        let y = CGFloat(500 * 3 + 250)
        stack.scrollView.setScrollY(y, animated: false)

        let replaced = (0..<20).flatMap { index -> [AppKitDiffRowSpec] in
            [spec("header-\(index)", height: 37)] + (0..<5).map { spec("seg-\(index)-\($0)", height: 92) }
        }
        stack.reconciler.apply(plan: .init(rows: replaced), contentWidth: stack.scrollView.contentWidth)

        #expect(abs(stack.scrollView.scrollY - min(y, max(0, stack.tiling.documentHeight - stack.scrollView.viewportHeight))) < 0.5)
    }

    @Test("a restructured anchor row keeps the previous absolute viewport position")
    func restructuredAnchorRowKeepsAbsoluteViewportPosition() {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: (0..<20).map { spec("row-\($0)", height: 500) }),
            contentWidth: stack.scrollView.contentWidth
        )
        // Viewport top exactly at a row boundary: the anchor row is `row-3`,
        // a 500pt fused hunk row that the first-comment restructure replaces
        // with a 37pt group header (different content signature) plus segment
        // and composer rows.
        let y = CGFloat(3 * 500)
        stack.scrollView.setScrollY(y, animated: false)

        var replaced: [AppKitDiffRowSpec] = (0..<3).map { spec("row-\($0)", height: 500) }
        replaced.append(spec("row-3", token: 99, height: 37))
        replaced += (0..<5).map { spec("seg-3-\($0)", height: 92) }
        replaced += (4..<20).map { spec("row-\($0)", height: 500) }
        stack.reconciler.apply(plan: .init(rows: replaced), contentWidth: stack.scrollView.contentWidth)

        #expect(abs(stack.scrollView.scrollY - y) < 0.5)
    }

    @Test("a remeasured anchor row preserves the id-based anchor under width changes")
    func remeasuredAnchorRowPreservesIdAnchor() {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: (0..<20).map { spec("row-\($0)", height: 500) }),
            contentWidth: stack.scrollView.contentWidth
        )
        let y = CGFloat(3 * 500 + 250)
        stack.scrollView.setScrollY(y, animated: false)

        // Same content (same equalityToken) but a width change drops the
        // measured height back to a shorter estimate. The anchor row's
        // identity is unchanged, so the id-based anchor should clamp into
        // the row rather than fall back to absolute-Y preservation.
        stack.reconciler.apply(
            plan: .init(rows: (0..<20).map { spec("row-\($0)", height: 37) }),
            contentWidth: 120
        )

        let clampedY = stack.tiling.row(withID: "row-3")!.minY + 37
        #expect(abs(stack.scrollView.scrollY - clampedY) < 0.5)
    }

    @Test("a restructured anchor row preserves absolute Y past short estimates")
    func restructuredAnchorRowPreservesAbsoluteYPastShortEstimates() {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: (0..<20).map { spec("row-\($0)", height: 500) }),
            contentWidth: stack.scrollView.contentWidth
        )
        let y = CGFloat(3 * 500 + 250)
        stack.scrollView.setScrollY(y, animated: false)

        // Restructure: the anchor row's contentSignature changes, and the
        // replacement rows' estimates are collectively much shorter than the
        // original — the estimated document is shorter than `y`. The absolute
        // Y must still be preserved after measurement restores the document
        // height.
        var replaced: [AppKitDiffRowSpec] = (0..<3).map { spec("row-\($0)", height: 500) }
        replaced.append(spec("row-3", token: 99, height: 37))
        replaced += (0..<2).map { spec("seg-3-\($0)", height: 92) }
        replaced += (4..<20).map { spec("row-\($0)", height: 500) }
        stack.reconciler.apply(plan: .init(rows: replaced), contentWidth: stack.scrollView.contentWidth)

        #expect(abs(stack.scrollView.scrollY - y) < 0.5)
    }

    @Test("a restructured final hunk measures tail rows past the estimated document")
    func restructuredFinalHunkMeasuresTailRows() {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: (0..<10).map { spec("row-\($0)", height: 500) }),
            contentWidth: stack.scrollView.contentWidth
        )
        // Scroll to the bottom hunk — previousScrollY is near the document end.
        let y = CGFloat(9 * 500 + 100)
        stack.scrollView.setScrollY(y, animated: false)

        // Restructure the final hunk: its replacement estimates are much
        // shorter, so the estimated document is shorter than `y`.
        var replaced: [AppKitDiffRowSpec] = (0..<9).map { spec("row-\($0)", height: 500) }
        replaced.append(spec("row-9", token: 99, height: 37))
        replaced += (0..<2).map { spec("seg-9-\($0)", height: 92) }
        stack.reconciler.apply(plan: .init(rows: replaced), contentWidth: stack.scrollView.contentWidth)

        // The content genuinely shrank — scrollY clamps to the real bottom.
        let maxScroll = max(0, stack.tiling.documentHeight - stack.scrollView.viewportHeight)
        #expect(abs(stack.scrollView.scrollY - maxScroll) < 0.5)
    }

    @Test("unchanged plans do not perform another full apply")
    func unchangedPlanIsNoOp() {
        let stack = makeStack()
        let currentPlan = plan(count: 20)
        stack.reconciler.apply(plan: currentPlan, contentWidth: stack.scrollView.contentWidth)
        let count = stack.reconciler.fullPlanApplyCountForTests
        stack.reconciler.apply(plan: currentPlan, contentWidth: stack.scrollView.contentWidth)

        #expect(stack.reconciler.fullPlanApplyCountForTests == count)
    }

    @Test("a changed equality token remeasures its row")
    func changedTokenRemeasuresRow() {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: [spec("row", token: 1, height: 20)]),
            contentWidth: stack.scrollView.contentWidth
        )
        stack.reconciler.apply(
            plan: .init(rows: [spec("row", token: 2, height: 80)]),
            contentWidth: stack.scrollView.contentWidth
        )

        #expect(stack.tiling.row(withID: "row")?.height == 80)
    }

    @Test("insertion removal and reorder replace the stable row geometry")
    func insertionRemovalAndReorderReplaceGeometry() {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: [spec("a"), spec("b"), spec("c")]),
            contentWidth: stack.scrollView.contentWidth
        )
        stack.reconciler.apply(
            plan: .init(rows: [spec("c"), spec("inserted"), spec("a")]),
            contentWidth: stack.scrollView.contentWidth
        )

        #expect(stack.tiling.rowCount == 3)
        #expect(stack.tiling.row(withID: "b") == nil)
        #expect(stack.tiling.row(withID: "c")?.minY == 0)
        #expect(stack.tiling.row(withID: "a")?.minY == 40)
    }

    @Test("a changed content width invalidates measured row heights")
    func contentWidthInvalidatesMeasurement() {
        let stack = makeStack()
        let wrapping = AppKitDiffRowSpec(
            id: "wrapping",
            ownerID: nil,
            equalityToken: .init(1),
            contentSignature: 1,
            estimatedHeight: 20
        ) {
            AnyView(
                Text(String(repeating: "a long diff line ", count: 40))
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
        stack.reconciler.apply(
            plan: .init(rows: [wrapping]), contentWidth: stack.scrollView.contentWidth
        )
        let wideHeight = stack.tiling.row(withID: "wrapping")!.height
        stack.reconciler.apply(plan: .init(rows: [wrapping]), contentWidth: 120)

        #expect(stack.tiling.row(withID: "wrapping")!.height > wideHeight)
    }

    @Test("zero width keeps live content until a positive-width recovery")
    func zeroWidthDefersAndRecovers() {
        let stack = makeStack()
        let currentPlan = plan(count: 5)
        stack.reconciler.apply(plan: currentPlan, contentWidth: 0)
        #expect(stack.tiling.rowCount == 0)

        stack.reconciler.apply(plan: currentPlan, contentWidth: stack.scrollView.contentWidth)
        #expect(stack.tiling.rowCount == 5)
    }

    @Test("pinned rows remain hosted offscreen")
    func pinnedRowsStayMountedOffscreen() {
        let stack = makeStack()
        var rows = plan().rows
        rows[0] = spec("row-0", height: 20, retention: .pinned)
        stack.reconciler.apply(plan: .init(rows: rows), contentWidth: stack.scrollView.contentWidth)
        stack.reconciler.scroll(to: .init(
            targetID: "row-150", fallbackID: nil, alignment: .top, animated: false, generation: 1
        ))

        #expect(stack.pool.mountedIDs.contains("row-0"))
    }

    @Test("retention and owner-only updates are not treated as no-ops")
    func retentionAndOwnerOnlyUpdatesApply() {
        let stack = makeStack()
        var rows = plan().rows
        stack.reconciler.apply(plan: .init(rows: rows), contentWidth: stack.scrollView.contentWidth)
        stack.reconciler.scroll(to: .init(
            targetID: "row-150", fallbackID: nil, alignment: .top, animated: false, generation: 1
        ))

        rows[0] = spec("row-0", height: 40, retention: .pinned)
        rows[150] = spec("row-150", height: 40, ownerID: "file-150")
        stack.reconciler.apply(plan: .init(rows: rows), contentWidth: stack.scrollView.contentWidth)

        #expect(stack.pool.mountedIDs.contains("row-0"))
        #expect(stack.tiling.row(withID: "row-150")?.ownerID == "file-150")
    }

    @Test("content insets are part of the native document geometry")
    func contentInsetsLayoutRowsInsideDocument() throws {
        let stack = makeStack()
        let insetPlan = plan(count: 2, height: 40)
            .withContentInsets(.init(top: 12, bottom: 18, left: 14, right: 20))
        stack.reconciler.apply(plan: insetPlan, contentWidth: stack.scrollView.contentWidth)

        let firstView = try #require(stack.pool.mountedView(id: "row-0"))

        #expect(stack.tiling.row(withID: "row-0")?.minY == 12)
        #expect(stack.tiling.documentHeight == 110)
        #expect(firstView.frame.minX == 14)
        #expect(firstView.frame.width == stack.scrollView.contentWidth - 34)

        stack.reconciler.apply(plan: plan(count: 2, height: 40), contentWidth: stack.scrollView.contentWidth)

        #expect(stack.tiling.row(withID: "row-0")?.minY == 0)
        #expect(stack.tiling.documentHeight == 80)
        #expect(firstView.frame.minX == 0)
        #expect(firstView.frame.width == stack.scrollView.contentWidth)
    }

    @Test("an intrinsic-size invalidation remeasures the mounted row")
    func intrinsicSizeInvalidationRemeasuresMountedRow() throws {
        let stack = makeStack()
        stack.reconciler.apply(
            plan: .init(rows: [spec("row", height: 20)]),
            contentWidth: stack.scrollView.contentWidth
        )
        let view = try #require(stack.pool.mountedView(id: "row"))
        view.updateRootView(AnyView(Color.clear.frame(height: 80)))
        view.invalidateIntrinsicContentSize()

        #expect(stack.tiling.row(withID: "row")?.height == 80)
    }

    @Test("height-only resize lays out a new band without a full apply")
    func heightOnlyResizeRelayoutsBand() {
        let stack = makeStack()
        stack.reconciler.apply(plan: plan(), contentWidth: stack.scrollView.contentWidth)
        let fullApplyCount = stack.reconciler.fullPlanApplyCountForTests
        let layoutCount = stack.reconciler.layoutPassCountForTests
        stack.scrollView.frame.size.height = 480
        stack.scrollView.layoutSubtreeIfNeeded()
        stack.reconciler.layoutVisibleRows()

        #expect(stack.reconciler.fullPlanApplyCountForTests == fullApplyCount)
        #expect(stack.reconciler.layoutPassCountForTests > layoutCount)
    }

    @Test("scroll requests use requested alignment and a fallback target")
    func scrollRequestAlignmentAndFallback() {
        let stack = makeStack()
        stack.reconciler.apply(plan: plan(count: 100), contentWidth: stack.scrollView.contentWidth)
        stack.reconciler.scroll(to: .init(
            targetID: "missing", fallbackID: "row-50", alignment: .center, animated: false, generation: 1
        ))

        #expect(stack.scrollView.scrollY == stack.tiling.targetOffset(
            id: "row-50", alignment: .center, viewportHeight: stack.scrollView.viewportHeight
        ))

        stack.reconciler.scroll(to: .init(
            targetID: "row-20", fallbackID: nil, alignment: .top, animated: false, generation: 2
        ))
        #expect(stack.scrollView.scrollY == stack.tiling.targetOffset(
            id: "row-20", alignment: .top, viewportHeight: stack.scrollView.viewportHeight
        ))
        let beforeMissingTarget = stack.scrollView.scrollY
        stack.reconciler.scroll(to: .init(
            targetID: "missing", fallbackID: nil, alignment: .top, animated: false, generation: 3
        ))
        #expect(stack.scrollView.scrollY == beforeMissingTarget)
    }
}
