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
        retention: AppKitDiffRowRetention = .recyclable
    ) -> AppKitDiffRowSpec {
        AppKitDiffRowSpec(
            id: id,
            ownerID: nil,
            equalityToken: .init(token),
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
