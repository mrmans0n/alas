import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct AppKitDiffScrollerTests {
    private typealias Stack = (
        window: NSWindow,
        scrollView: AppKitDiffScrollView,
        coordinator: AppKitDiffScroller.Coordinator
    )

    private func makeStack(
        onActiveOwnerChange: @escaping (String?) -> Void = { _ in },
        animatedScrollExecutorForTests: AppKitDiffScrollView.AnimatedScrollExecutorForTests? = nil
    ) -> Stack {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scrollView = AppKitDiffScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        scrollView.animatedScrollExecutorForTests = animatedScrollExecutorForTests
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

    @Test("a request automatically retries when the native view gains width")
    func zeroWidthRequestRetriesAfterLayout() {
        let scrollView = AppKitDiffScrollView(frame: .zero)
        let coordinator = AppKitDiffScroller.Coordinator()
        coordinator.attach(scrollView: scrollView, onActiveOwnerChange: { _ in })
        let request = AppKitDiffScrollRequest(
            targetID: "missing", fallbackID: "row-50", alignment: .top, animated: false, generation: 1
        )

        coordinator.update(plan: plan(), scrollRequest: request, onActiveOwnerChange: { _ in })
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        scrollView.layoutSubtreeIfNeeded()

        #expect(scrollView.scrollY > 0)
    }

    @Test("an unresolved request is consumed after a positive-width reconcile")
    func unresolvedRequestGenerationDoesNotReplay() {
        let stack = makeStack()
        let request = AppKitDiffScrollRequest(
            targetID: "later", fallbackID: nil, alignment: .top, animated: false, generation: 1
        )
        stack.coordinator.update(plan: plan(), scrollRequest: request, onActiveOwnerChange: { _ in })
        var laterPlan = plan().rows
        laterPlan.append(
            AppKitDiffRowSpec(
                id: "later", ownerID: nil, equalityToken: .init(101), estimatedHeight: 40
            ) {
                AnyView(Color.clear.frame(height: 40))
            }
        )

        stack.coordinator.update(
            plan: .init(rows: laterPlan), scrollRequest: request, onActiveOwnerChange: { _ in }
        )

        #expect(stack.scrollView.scrollY == 0)
    }

    @Test("an empty positive-width plan consumes a request generation")
    func emptyPlanRequestGenerationDoesNotReplay() {
        let stack = makeStack()
        let request = AppKitDiffScrollRequest(
            targetID: "later", fallbackID: nil, alignment: .top, animated: false, generation: 1
        )
        stack.coordinator.update(plan: .init(rows: []), scrollRequest: request, onActiveOwnerChange: { _ in })
        var laterPlan = plan().rows
        laterPlan.append(
            AppKitDiffRowSpec(
                id: "later", ownerID: nil, equalityToken: .init(101), estimatedHeight: 40
            ) {
                AnyView(Color.clear.frame(height: 40))
            }
        )

        stack.coordinator.update(
            plan: .init(rows: laterPlan), scrollRequest: request, onActiveOwnerChange: { _ in }
        )

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

    @Test("animated programmatic scrolling does not publish active-owner changes")
    func animatedScrollingDoesNotReportActiveOwner() async throws {
        var owners: [String?] = []
        let stack = makeStack(
            onActiveOwnerChange: { owners.append($0) },
            animatedScrollExecutorForTests: { scrollView, point, completion in
                scrollView.contentView.setBoundsOrigin(point)
                completion()
            }
        )
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { owners.append($0) })

        stack.coordinator.update(
            plan: plan(),
            scrollRequest: .init(
                targetID: "row-50", fallbackID: nil, alignment: .top, animated: true, generation: 1
            ),
            onActiveOwnerChange: { owners.append($0) }
        )

        #expect(owners.isEmpty)
    }

    @Test("animated requests report completion only after the native scroll finishes")
    func animatedRequestReportsCompletion() async throws {
        var completedGenerations: [Int] = []
        var finishAnimation: (() -> Void)?
        let stack = makeStack(
            animatedScrollExecutorForTests: { scrollView, point, completion in
                scrollView.contentView.setBoundsOrigin(point)
                finishAnimation = completion
            }
        )
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { _ in })

        stack.coordinator.update(
            plan: plan(),
            scrollRequest: .init(
                targetID: "row-50", fallbackID: nil, alignment: .top, animated: true, generation: 73
            ),
            onActiveOwnerChange: { _ in },
            onScrollRequestCompletion: { completedGenerations.append($0) }
        )

        #expect(completedGenerations.isEmpty)
        finishAnimation?()
        #expect(completedGenerations == [73])
    }

    @Test("superseded animated request completion cannot restore the previous target")
    func supersededAnimatedRequestCompletionIsIgnored() async throws {
        var completedGenerations: [Int] = []
        var finishAnimations: [() -> Void] = []
        let stack = makeStack(
            animatedScrollExecutorForTests: { scrollView, point, completion in
                scrollView.contentView.setBoundsOrigin(point)
                finishAnimations.append(completion)
            }
        )
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { _ in })

        stack.coordinator.update(
            plan: plan(),
            scrollRequest: .init(
                targetID: "row-20", fallbackID: nil, alignment: .top, animated: true, generation: 1
            ),
            onActiveOwnerChange: { _ in },
            onScrollRequestCompletion: { completedGenerations.append($0) }
        )
        stack.coordinator.update(
            plan: plan(),
            scrollRequest: .init(
                targetID: "row-60", fallbackID: nil, alignment: .top, animated: true, generation: 2
            ),
            onActiveOwnerChange: { _ in },
            onScrollRequestCompletion: { completedGenerations.append($0) }
        )

        let secondTargetY = stack.scrollView.scrollY
        finishAnimations.first?()
        #expect(stack.scrollView.scrollY == secondTargetY)
        #expect(completedGenerations.isEmpty)

        finishAnimations.last?()
        #expect(completedGenerations == [2])
    }

    @Test("long animated navigation mounts the destination before completion")
    func animatedNavigationMountsDestination() async throws {
        var mountedAtCompletion = false
        let stack = makeStack(
            animatedScrollExecutorForTests: { scrollView, point, completion in
                scrollView.contentView.setBoundsOrigin(point)
                completion()
            }
        )
        stack.coordinator.update(plan: plan(count: 2_000), scrollRequest: nil, onActiveOwnerChange: { _ in })

        stack.coordinator.update(
            plan: plan(count: 2_000),
            scrollRequest: .init(
                targetID: "row-1900", fallbackID: nil, alignment: .top, animated: true, generation: 91
            ),
            onActiveOwnerChange: { _ in },
            onScrollRequestCompletion: { _ in
                mountedAtCompletion = stack.coordinator.mountedRowIDsForTests.contains("row-1900")
            }
        )

        #expect(mountedAtCompletion)
        #expect(stack.coordinator.mountedRowIDsForTests.contains("row-1900"))
        #expect(stack.scrollView.scrollY > 70_000)
    }

    @Test("height-only viewport changes relayout without publishing active owner")
    func heightChangesDoNotReportActiveOwner() {
        var owners: [String?] = []
        let stack = makeStack { owners.append($0) }
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { owners.append($0) })
        stack.scrollView.frame.size.height = 480
        stack.scrollView.layoutSubtreeIfNeeded()

        #expect(owners.isEmpty)
    }

    @Test("dismantling releases mounted rows and callbacks")
    func dismantleReleasesResources() {
        let stack = makeStack()
        stack.coordinator.update(plan: plan(), scrollRequest: nil, onActiveOwnerChange: { _ in })
        #expect(!stack.coordinator.mountedRowIDsForTests.isEmpty)

        stack.coordinator.dismantle()

        #expect(stack.coordinator.mountedRowIDsForTests.isEmpty)
        #expect(stack.scrollView.onUserViewportChange == nil)
        #expect(stack.scrollView.onViewportGeometryChange == nil)
        #expect(stack.scrollView.onContentWidthChange == nil)
    }
}
