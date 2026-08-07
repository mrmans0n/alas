import AppKit

/// Reconciles a stable-id diff row plan into the native scroll view.
@MainActor
final class AppKitDiffScrollerReconciler {
    static let overscan: CGFloat = 800

    private let tiling: AppKitDiffTilingController
    private let pool: AppKitDiffRowHostingPool
    private unowned let scrollView: AppKitDiffScrollView

    private var specsByID: [String: AppKitDiffRowSpec] = [:]
    private var orderedIDs: [String] = []
    private var measuredHeights: [String: CGFloat] = [:]
    private var contentWidth: CGFloat = 0
    private var contentInsets: AppKitDiffContentInsets = .zero
    private var isReconciling = false
    private var deferredLayoutScheduled = false
    private var needsDeferredLayout = false
    private var invalidatedRowIDs: Set<String> = []

    #if DEBUG
    private(set) var fullPlanApplyCountForTests = 0
    private(set) var layoutPassCountForTests = 0
    #endif

    init(
        tiling: AppKitDiffTilingController,
        pool: AppKitDiffRowHostingPool,
        scrollView: AppKitDiffScrollView
    ) {
        self.tiling = tiling
        self.pool = pool
        self.scrollView = scrollView
        pool.onRowIntrinsicSizeInvalidated = { [weak self] id in
            self?.intrinsicSizeInvalidated(for: id)
        }
    }

    func apply(plan: AppKitDiffRowPlan, contentWidth width: CGFloat) {
        guard width > 0 else { return }
        let rowContentWidth = max(0, width - plan.contentInsets.horizontal)
        let ids = plan.rows.map(\.id)
        let widthChanged = rowContentWidth != contentWidth
        let insetsChanged = plan.contentInsets != contentInsets
        let isUnchanged = !widthChanged && !insetsChanged && ids == orderedIDs && plan.rows.allSatisfy { spec in
            guard let current = specsByID[spec.id] else { return false }
            return current.equalityToken.isEqual(to: spec.equalityToken)
                && current.ownerID == spec.ownerID
                && current.retention == spec.retention
                && current.estimatedHeight == spec.estimatedHeight
        }
        guard !isUnchanged else { return }

        #if DEBUG
        fullPlanApplyCountForTests += 1
        #endif
        isReconciling = true
        defer {
            isReconciling = false
            scheduleDeferredLayoutIfNeeded()
        }

        let anchor = tiling.anchor(viewportMinY: scrollView.scrollY)
        let previousSpecs = specsByID
        let previousMeasuredHeights = measuredHeights
        var nextSpecs: [String: AppKitDiffRowSpec] = [:]
        var nextMeasuredHeights: [String: CGFloat] = [:]
        for spec in plan.rows {
            nextSpecs[spec.id] = spec
            if !widthChanged,
               previousSpecs[spec.id]?.equalityToken.isEqual(to: spec.equalityToken) == true,
               let height = previousMeasuredHeights[spec.id] {
                nextMeasuredHeights[spec.id] = height
            }
        }

        // Detect whether the anchor row's content identity changed between
        // plans (its contentSignature differs). This happens when a group's
        // row plan restructures — e.g. a fused hunk row splitting into header +
        // segment rows when the first comment composer appears — even though
        // the row id is reused. A pure width, measurement, or hover/focus
        // presentation change keeps the same contentSignature; only a semantic
        // restructure invalidates the anchor.
        let anchorRestructured: Bool
        if let anchor {
            if let previous = previousSpecs[anchor.rowID],
               let next = nextSpecs[anchor.rowID] {
                anchorRestructured = previous.contentSignature != next.contentSignature
            } else {
                anchorRestructured = true
            }
        } else {
            anchorRestructured = false
        }

        let previousScrollY = scrollView.scrollY
        specsByID = nextSpecs
        orderedIDs = ids
        measuredHeights = nextMeasuredHeights
        contentWidth = rowContentWidth
        contentInsets = plan.contentInsets
        tiling.replaceAll(rows: plan.rows.map { spec in
            .init(
                id: spec.id,
                ownerID: spec.ownerID,
                height: nextMeasuredHeights[spec.id] ?? max(0, spec.estimatedHeight)
            )
        }, metrics: .init(topPadding: plan.contentInsets.top, bottomPadding: plan.contentInsets.bottom))
        scrollView.setDocumentHeight(tiling.documentHeight)
        if let anchoredY = tiling.viewportMinY(for: anchor),
           !anchorRestructured {
            scrollView.setScrollY(anchoredY, animated: false)
        }
        // When the anchor row was removed or its content identity changed
        // (semantic restructure, e.g. a fused hunk row splitting into header
        // + segment rows when the first comment composer appears), the
        // id-based anchor no longer refers to the same content — clamping into
        // the shrunken id-matching row would snap the viewport to its top.
        // Restore the pre-reconcile absolute Y without clamping so
        // layoutVisibleRows measures the correct band (the estimated document
        // may be temporarily shorter than the original Y). After measurement
        // updates the document height, setScrollY clamps against the real
        // document.
        if anchorRestructured {
            scrollView.setUnclampedScrollY(previousScrollY)
        }
        layoutVisibleRows()
        if anchorRestructured {
            // If previousScrollY was beyond the estimated document, the
            // unclamped band may have found no rows to measure. Iterate:
            // scroll progressively earlier so each pass measures a different
            // band of underestimated replacement rows, growing the document
            // height until the maximum scroll offset can represent
            // previousScrollY, or the scan is exhausted. The scan is bounded
            // to avoid freezing the UI on a genuine shrink — if the document
            // can't grow enough in a limited number of passes, the final
            // setScrollY correctly clamps to the real bottom.
            var previousDocumentHeight = tiling.documentHeight
            var probeY = tiling.documentHeight
            var remainingPasses = 8
            while previousScrollY > max(0, tiling.documentHeight - scrollView.viewportHeight),
                  remainingPasses > 0 {
                remainingPasses -= 1
                scrollView.setScrollY(probeY, animated: false)
                layoutVisibleRows()
                if tiling.documentHeight <= previousDocumentHeight {
                    // No growth at this band — try measuring further up.
                    let nextProbe = max(0, probeY - scrollView.viewportHeight - AppKitDiffScrollerReconciler.overscan)
                    if nextProbe == probeY { break }
                    probeY = nextProbe
                    continue
                }
                previousDocumentHeight = tiling.documentHeight
                probeY = tiling.documentHeight
            }
            // Restore the saved Y (clamped against the now-measured document)
            // and re-tile so the viewport band is mounted at the final position.
            scrollView.setScrollY(previousScrollY, animated: false)
            layoutVisibleRows()
        }
    }

    func layoutVisibleRows() {
        guard contentWidth > 0 else { return }
        guard !isReconciling || !isLayingOutRows else {
            needsDeferredLayout = true
            return
        }
        layoutMountedRows()
    }

    func scroll(
        to request: AppKitDiffScrollRequest,
        isCurrent: @escaping () -> Bool = { true },
        completion: (() -> Void)? = nil
    ) {
        let targetID: String?
        if tiling.row(withID: request.targetID) != nil {
            targetID = request.targetID
        } else {
            targetID = request.fallbackID
        }
        guard let targetID,
              let offset = tiling.targetOffset(
                id: targetID,
                alignment: request.alignment,
                viewportHeight: scrollView.viewportHeight
              ) else {
            completion?()
            return
        }
        // For requests that opt in (file-click navigation), snap for long
        // jumps and only animate when the destination is already close
        // enough (within one screen) that motion reads as a nudge rather
        // than a multi-second slide.
        let animated = request.animated
            && (!request.snapsWhenFar || abs(offset - scrollView.scrollY) <= scrollView.viewportHeight)
        scrollView.setScrollY(offset, animated: animated) { [weak self] in
            // Bounds notifications remain suppressed for programmatic animation
            // so active-owner feedback cannot fight navigation. Re-tile at the
            // final native offset before announcing completion, however, or a
            // long jump can leave only the source viewport mounted.
            guard let self else {
                completion?()
                return
            }
            guard isCurrent() else { return }
            self.layoutVisibleRows()
            guard let measuredOffset = self.tiling.targetOffset(
                id: targetID,
                alignment: request.alignment,
                viewportHeight: self.scrollView.viewportHeight
            ) else {
                completion?()
                return
            }
            self.scrollView.setScrollY(measuredOffset, animated: false, completion: completion)
        }
        if isCurrent() {
            layoutVisibleRows()
        }
    }

    private var isLayingOutRows = false

    private func layoutMountedRows() {
        guard !isLayingOutRows else {
            needsDeferredLayout = true
            return
        }
        isLayingOutRows = true
        defer { isLayingOutRows = false }

        #if DEBUG
        layoutPassCountForTests += 1
        #endif
        for _ in 0..<3 {
            let band = tiling.mountBand(
                viewportMinY: scrollView.scrollY,
                viewportHeight: scrollView.viewportHeight,
                overscan: Self.overscan
            )
            let bandIDs = Set(band.compactMap { index in
                orderedIDs.indices.contains(index) ? orderedIDs[index] : nil
            })
            let pinnedIDs = Set(specsByID.values.lazy.filter { $0.retention == .pinned }.map(\.id))
            let keep = bandIDs.union(pinnedIDs)
            pool.releaseAll(except: keep)

            var geometryChanged = false
            for id in keep {
                guard let spec = specsByID[id], let row = tiling.row(withID: id) else { continue }
                let result = pool.view(for: spec)
                let view = result.view
                if view.superview !== scrollView.flippedDocumentView {
                    scrollView.flippedDocumentView.addSubview(view)
                }
                let shouldMeasure = result.contentChanged
                    || view.lastMeasuredWidth != contentWidth
                    || invalidatedRowIDs.remove(id) != nil
                if shouldMeasure {
                    let height = max(0, view.measuredHeight(forWidth: contentWidth))
                    measuredHeights[id] = height
                    let compensation = tiling.updateHeight(
                        id: id,
                        to: height,
                        viewportMinY: scrollView.scrollY
                    )
                    if compensation != 0 {
                        scrollView.setDocumentHeight(tiling.documentHeight)
                        scrollView.setScrollY(scrollView.scrollY + compensation, animated: false)
                    }
                    geometryChanged = geometryChanged || abs(row.height - height) > 0.01
                }
                if let updatedRow = tiling.row(withID: id) {
                    view.frame = NSRect(
                        x: contentInsets.left,
                        y: updatedRow.minY,
                        width: contentWidth,
                        height: updatedRow.height
                    )
                }
            }
            scrollView.setDocumentHeight(tiling.documentHeight)
            guard geometryChanged else { break }
        }
    }

    private func intrinsicSizeInvalidated(for id: String) {
        guard specsByID[id] != nil else { return }
        invalidatedRowIDs.insert(id)
        if isReconciling || isLayingOutRows {
            needsDeferredLayout = true
            scheduleDeferredLayoutIfNeeded()
            return
        }
        measuredHeights.removeValue(forKey: id)
        layoutVisibleRows()
    }

    private func scheduleDeferredLayoutIfNeeded() {
        guard needsDeferredLayout, !deferredLayoutScheduled else { return }
        needsDeferredLayout = false
        deferredLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredLayoutScheduled = false
            self.layoutVisibleRows()
        }
    }
}
