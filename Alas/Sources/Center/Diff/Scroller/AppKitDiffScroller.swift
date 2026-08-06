import AppKit
import SwiftUI

/// SwiftUI bridge for the AppKit-backed, virtualized diff row scroller.
struct AppKitDiffScroller: NSViewRepresentable {
    let plan: AppKitDiffRowPlan
    let scrollRequest: AppKitDiffScrollRequest?
    let onActiveOwnerChange: (String?) -> Void
    let onScrollRequestCompletion: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AppKitDiffScrollView {
        let scrollView = AppKitDiffScrollView(frame: .zero)
        context.coordinator.attach(scrollView: scrollView, onActiveOwnerChange: onActiveOwnerChange)
        return scrollView
    }

    func updateNSView(_ scrollView: AppKitDiffScrollView, context: Context) {
        context.coordinator.update(
            plan: plan,
            scrollRequest: scrollRequest,
            onActiveOwnerChange: onActiveOwnerChange,
            onScrollRequestCompletion: onScrollRequestCompletion
        )
    }

    static func dismantleNSView(_ scrollView: AppKitDiffScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator {
        private let tiling = AppKitDiffTilingController()
        private let pool = AppKitDiffRowHostingPool()
        private var reconciler: AppKitDiffScrollerReconciler?
        private weak var scrollView: AppKitDiffScrollView?
        private var mostRecentPlan: AppKitDiffRowPlan?
        private var pendingScrollRequest: AppKitDiffScrollRequest?
        private var lastConsumedRequestGeneration: Int?
        private var latestActiveOwner: String?
        private var onActiveOwnerChange: ((String?) -> Void)?
        private var onScrollRequestCompletion: ((Int) -> Void)?

        #if DEBUG
        var fullPlanApplyCountForTests: Int { reconciler?.fullPlanApplyCountForTests ?? 0 }
        var mountedRowIDsForTests: Set<String> { pool.mountedIDs }
        #endif

        func attach(
            scrollView: AppKitDiffScrollView,
            onActiveOwnerChange: @escaping (String?) -> Void
        ) {
            guard self.scrollView == nil else { return }
            self.scrollView = scrollView
            self.onActiveOwnerChange = onActiveOwnerChange
            reconciler = AppKitDiffScrollerReconciler(
                tiling: tiling,
                pool: pool,
                scrollView: scrollView
            )
            scrollView.onContentWidthChange = { [weak self] in
                self?.applyMostRecentPlan()
                self?.processPendingScrollRequest()
            }
            scrollView.onUserViewportChange = { [weak self] in
                self?.userViewportDidChange()
            }
            scrollView.onViewportGeometryChange = { [weak self] in
                self?.reconciler?.layoutVisibleRows()
            }
        }

        func update(
            plan: AppKitDiffRowPlan,
            scrollRequest: AppKitDiffScrollRequest?,
            onActiveOwnerChange: @escaping (String?) -> Void,
            onScrollRequestCompletion: @escaping (Int) -> Void = { _ in }
        ) {
            mostRecentPlan = plan
            self.onActiveOwnerChange = onActiveOwnerChange
            self.onScrollRequestCompletion = onScrollRequestCompletion
            if let scrollRequest,
               scrollRequest.generation != lastConsumedRequestGeneration {
                pendingScrollRequest = scrollRequest
            }
            applyMostRecentPlan()
            processPendingScrollRequest()
        }

        func dismantle() {
            guard let scrollView else { return }
            scrollView.onUserViewportChange = nil
            scrollView.onViewportGeometryChange = nil
            scrollView.onContentWidthChange = nil
            pool.releaseAll()
            reconciler = nil
            self.scrollView = nil
            mostRecentPlan = nil
            pendingScrollRequest = nil
            onActiveOwnerChange = nil
            onScrollRequestCompletion = nil
            latestActiveOwner = nil
        }

        private func applyMostRecentPlan() {
            guard let mostRecentPlan, let scrollView else { return }
            reconciler?.apply(plan: mostRecentPlan, contentWidth: scrollView.contentWidth)
        }

        private var hasUsableLayout: Bool {
            (scrollView?.contentWidth ?? 0) > 0
        }

        private func processPendingScrollRequest() {
            guard let pendingScrollRequest, hasUsableLayout else { return }
            lastConsumedRequestGeneration = pendingScrollRequest.generation
            self.pendingScrollRequest = nil
            reconciler?.scroll(to: pendingScrollRequest) { [weak self] in
                self?.onScrollRequestCompletion?(pendingScrollRequest.generation)
            }
        }

        private func userViewportDidChange() {
            guard let scrollView else { return }
            reconciler?.layoutVisibleRows()
            let owner = tiling.activeOwnerID(
                viewportMinY: scrollView.scrollY,
                viewportHeight: scrollView.viewportHeight
            )
            guard owner != latestActiveOwner else { return }
            latestActiveOwner = owner
            onActiveOwnerChange?(owner)
        }
    }
}
