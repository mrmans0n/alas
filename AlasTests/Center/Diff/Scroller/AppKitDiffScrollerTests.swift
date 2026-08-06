import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("AppKit diff scroller SwiftUI bridge")
struct AppKitDiffScrollerTests {
    private typealias Stack = (
        window: NSWindow,
        scrollView: AppKitDiffScrollView,
        coordinator: AppKitDiffScroller.Coordinator
    )

    private func makeStack(onActiveOwnerChange: @escaping (String?) -> Void = { _ in }) -> Stack {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scrollView = AppKitDiffScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let coordinator = AppKitDiffScroller.Coordinator()
        coordinator.attach(scrollView: scrollView, onActiveOwnerChange: onActiveOwnerChange)
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        scrollView.layoutSubtreeIfNeeded()
        return (window, scrollView, coordinator)
    }

    private func plan(count: Int = 100) -> AppKitDiffRowPlan {
        .init(rows: (0..<count).map { index in
            AppKitDiffRowSpec(
                id: "row-\(index)",
                ownerID: "owner-\(index / 10)",
                equalityToken: .init(index),
                estimatedHeight: 40
            ) {
                AnyView(Color.clear.frame(height: 40))
            }
        })
    }

    @Test("a changed plan reaches the reconciler")
    func changedPlanApplies() {
        let stack = makeStack()
        stack.coordinator.update(plan: plan(count: 1), scrollRequest: nil, onActiveOwnerChange: { _ in })
        let initialApplyCount = stack.coordinator.fullPlanApplyCountForTests

        stack.coordinator.update(plan: plan(count: 2), scrollRequest: nil, onActiveOwnerChange: { _ in })

        #expect(stack.coordinator.fullPlanApplyCountForTests > initialApplyCount)
    }

    @Test("each scroll request generation is consumed once and falls back")
    func requestsAreDeduplicatedAndFallBack() {
        let stack = makeStack()
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { _ in })
        let request = AppKitDiffScrollRequest(
            targetID: "missing", fallbackID: "row-50", alignment: .top, animated: false, generation: 1
        )

        stack.coordinator.update(plan: plan(), scrollRequest: request, onActiveOwnerChange: { _ in })
        let afterFirstRequest = stack.scrollView.scrollY
        stack.scrollView.setScrollY(0, animated: false)
        stack.coordinator.update(plan: plan(), scrollRequest: request, onActiveOwnerChange: { _ in })

        #expect(afterFirstRequest > 0)
        #expect(stack.scrollView.scrollY == 0)
    }

    @Test("only user scrolling reports a changed active owner")
    func userScrollingReportsActiveOwner() {
        var owners: [String?] = []
        let stack = makeStack { owners.append($0) }
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { owners.append($0) })
        let request = AppKitDiffScrollRequest(
            targetID: "row-50", fallbackID: nil, alignment: .top, animated: false, generation: 1
        )

        stack.coordinator.update(plan: plan(), scrollRequest: request, onActiveOwnerChange: { owners.append($0) })
        #expect(owners.isEmpty)

        stack.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 800))
        stack.scrollView.reflectScrolledClipView(stack.scrollView.contentView)

        #expect(owners == ["owner-2"])
    }

    @Test("dismantling releases mounted rows and callbacks")
    func dismantleReleasesResources() {
        let stack = makeStack()
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { _ in })
        #expect(!stack.coordinator.mountedRowIDsForTests.isEmpty)

        stack.coordinator.dismantle()

        #expect(stack.coordinator.mountedRowIDsForTests.isEmpty)
        #expect(stack.scrollView.onViewportChange == nil)
        #expect(stack.scrollView.onContentWidthChange == nil)
    }
}
