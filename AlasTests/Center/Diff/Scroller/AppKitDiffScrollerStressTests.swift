import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("AppKit diff scroller stress and accessibility")
struct AppKitDiffScrollerStressTests {
    @Test("twenty thousand rows keep a bounded mount band and preserve anchors")
    func twentyThousandRows() throws {
        let stack = makeStack()
        let baseRows = (0..<20_000).map { row(index: $0) }
        let initialPlan = AppKitDiffRowPlan(rows: baseRows)
        let middleRequest = AppKitDiffScrollRequest(
            targetID: "row-10000", fallbackID: nil, alignment: .top, animated: false, generation: 1
        )
        stack.reconciler.apply(plan: initialPlan, contentWidth: stack.scrollView.contentWidth)
        stack.reconciler.scroll(to: middleRequest)

        let mountedAfterMiddleScroll = stack.pool.mountedIDs.count
        #expect(mountedAfterMiddleScroll < 120)
        let middleRowBefore = try #require(stack.tiling.row(withID: "row-10000"))
        let anchorBefore = middleRowBefore.minY - stack.scrollView.scrollY

        var updatedRows = baseRows
        updatedRows.insert(row(id: "inserted-above", height: 60), at: 100)
        updatedRows[15_001] = row(id: "row-15000", token: 1, height: 80)
        stack.reconciler.apply(plan: AppKitDiffRowPlan(rows: updatedRows), contentWidth: stack.scrollView.contentWidth)
        let middleRowAfter = try #require(stack.tiling.row(withID: "row-10000"))
        let anchorAfter = middleRowAfter.minY - stack.scrollView.scrollY
        let anchorDelta = abs(anchorBefore - anchorAfter)
        #expect(anchorDelta < 0.5)

        let endRequest = AppKitDiffScrollRequest(
            targetID: "row-19999", fallbackID: nil, alignment: .top, animated: false, generation: 2
        )
        stack.reconciler.scroll(to: endRequest)
        let mountedAfterEndScroll = stack.pool.mountedIDs.count
        let containsEndRow = stack.pool.mountedIDs.contains("row-19999")
        let applyCount = stack.reconciler.fullPlanApplyCountForTests
        #expect(mountedAfterEndScroll < 120)
        #expect(containsEndRow)
        #expect(applyCount == 2)
    }

    @Test("hosted accessibility survives recycling and focus retention can be released")
    func accessibilityAndFocusRetention() throws {
        let stack = makeStack()
        var rows = (0..<200).map { row(index: $0) }
        rows[0] = accessibleRow(retention: .pinned)
        stack.reconciler.apply(plan: AppKitDiffRowPlan(rows: rows), contentWidth: stack.scrollView.contentWidth)
        let hosted = try #require(stack.pool.mountedView(id: "focus-row"))
        hosted.layoutSubtreeIfNeeded()
        let hostedDraftField = descendant(withAccessibilityIdentifier: "focusable-draft", in: hosted)
        #expect(hostedDraftField != nil)

        let distantRequest = AppKitDiffScrollRequest(
            targetID: "row-150", fallbackID: nil, alignment: .top, animated: false, generation: 1
        )
        stack.reconciler.scroll(to: distantRequest)
        let retainedWhilePinned = stack.pool.mountedIDs.contains("focus-row")
        #expect(retainedWhilePinned)

        rows[0] = accessibleRow(retention: .recyclable)
        stack.reconciler.apply(plan: AppKitDiffRowPlan(rows: rows), contentWidth: stack.scrollView.contentWidth)
        let recycledAfterRelease = !stack.pool.mountedIDs.contains("focus-row")
        #expect(recycledAfterRelease)
    }

    private final class Stack {
        let window: NSWindow
        let scrollView: AppKitDiffScrollView
        let tiling: AppKitDiffTilingController
        let pool: AppKitDiffRowHostingPool
        let reconciler: AppKitDiffScrollerReconciler

        init(
            window: NSWindow,
            scrollView: AppKitDiffScrollView,
            tiling: AppKitDiffTilingController,
            pool: AppKitDiffRowHostingPool,
            reconciler: AppKitDiffScrollerReconciler
        ) {
            self.window = window
            self.scrollView = scrollView
            self.tiling = tiling
            self.pool = pool
            self.reconciler = reconciler
        }
    }

    private func makeStack() -> Stack {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scrollView = AppKitDiffScrollView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        let tiling = AppKitDiffTilingController()
        let pool = AppKitDiffRowHostingPool()
        let reconciler = AppKitDiffScrollerReconciler(tiling: tiling, pool: pool, scrollView: scrollView)
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        scrollView.layoutSubtreeIfNeeded()
        return Stack(window: window, scrollView: scrollView, tiling: tiling, pool: pool, reconciler: reconciler)
    }

    private func row(index: Int) -> AppKitDiffRowSpec {
        row(id: "row-\(index)", ownerID: "owner-\(index / 80)")
    }

    private func row(
        id: String,
        ownerID: String? = nil,
        token: Int = 0,
        height: CGFloat = 40
    ) -> AppKitDiffRowSpec {
        .init(
            id: id, ownerID: ownerID, equalityToken: .init(token), estimatedHeight: height
        ) {
            AnyView(Color.clear.frame(height: height))
        }
    }

    private func accessibleRow(retention: AppKitDiffRowRetention) -> AppKitDiffRowSpec {
        .init(
            id: "focus-row", ownerID: "owner-0", equalityToken: .init(retention),
            estimatedHeight: 40, retention: retention
        ) {
            AnyView(AccessibleMarker(identifier: "focusable-draft").frame(height: 40))
        }
    }

    private func descendant(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let match = descendant(withAccessibilityIdentifier: identifier, in: child) { return match }
        }
        return nil
    }
}

private struct AccessibleMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier(identifier)
    }
}
