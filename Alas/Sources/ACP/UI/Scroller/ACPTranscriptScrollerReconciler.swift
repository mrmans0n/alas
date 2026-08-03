import AppKit
import SwiftUI

/// Applies each SwiftUI update (a fresh ordered list of row specs) onto the
/// tiling controller + scroller + hosting pool:
///   - classifies the change (prepend / append / reset / in-place),
///   - measures new or content-changed rows at the current width,
///   - applies prepend offset compensation synchronously,
///   - mounts/unmounts hosting views around the viewport's mount band,
///   - pins the viewport to the bottom while tail-following.
@MainActor
final class ACPTranscriptScrollerReconciler {
    /// How far beyond the viewport rows stay mounted, in points. Roughly
    /// 1.5 viewport-heights on a typical window; tuned by feel in QA.
    static let overscan: CGFloat = 1200

    private let tiling: ACPTranscriptTilingController
    private let pool: ACPTranscriptRowHostingPool
    private unowned let scroller: ACPTranscriptScrollerView
    private var specsById: [String: ACPTranscriptRowSpec] = [:]
    private var orderedIds: [String] = []
    private var contentWidth: CGFloat = 0

    init(
        tiling: ACPTranscriptTilingController,
        pool: ACPTranscriptRowHostingPool,
        scroller: ACPTranscriptScrollerView
    ) {
        self.tiling = tiling
        self.pool = pool
        self.scroller = scroller
        pool.onRowIntrinsicSizeInvalidated = { [weak self] id in
            self?.remeasureRow(id: id)
        }
    }

    enum Diff: Equatable {
        case unchanged
        case prepended(count: Int)
        case appended(count: Int)
        case prependedAndAppended(prepended: Int, appended: Int)
        case reset
    }

    /// Old ids must appear as a contiguous run inside new ids for an
    /// incremental classification; anything else is a reset.
    nonisolated static func diff(oldIds: [String], newIds: [String]) -> Diff {
        if oldIds == newIds { return .unchanged }
        guard let oldFirst = oldIds.first else { return newIds.isEmpty ? .unchanged : .reset }
        guard let start = newIds.firstIndex(of: oldFirst) else { return .reset }
        let end = start + oldIds.count
        guard end <= newIds.count, Array(newIds[start..<end]) == oldIds else { return .reset }
        let prepended = start
        let appended = newIds.count - end
        switch (prepended > 0, appended > 0) {
        case (true, true): return .prependedAndAppended(prepended: prepended, appended: appended)
        case (true, false): return .prepended(count: prepended)
        case (false, true): return .appended(count: appended)
        case (false, false): return .unchanged
        }
    }

    func apply(specs: [ACPTranscriptRowSpec], contentWidth width: CGFloat, followsTail: Bool) {
        let widthChanged = width != contentWidth
        contentWidth = width
        let newIds = specs.map(\.id)
        var newSpecs: [String: ACPTranscriptRowSpec] = [:]
        newSpecs.reserveCapacity(specs.count)
        for spec in specs { newSpecs[spec.id] = spec }

        let change: Diff = widthChanged ? .reset : Self.diff(oldIds: orderedIds, newIds: newIds)
        switch change {
        case .unchanged:
            updateChangedContent(specs: specs)
        case .prepended(let count):
            let delta = tiling.prepend(rows: measure(specs[0..<count]))
            scroller.applyPrepend(delta: delta, newDocumentHeight: tiling.documentHeight)
            updateChangedContent(specs: specs)
        case .appended(let count):
            tiling.append(rows: measure(specs[(specs.count - count)...]))
            scroller.setDocumentHeight(tiling.documentHeight)
            updateChangedContent(specs: specs)
        case .prependedAndAppended(let prepended, let appended):
            let delta = tiling.prepend(rows: measure(specs[0..<prepended]))
            tiling.append(rows: measure(specs[(specs.count - appended)...]))
            scroller.applyPrepend(delta: delta, newDocumentHeight: tiling.documentHeight)
            updateChangedContent(specs: specs)
        case .reset:
            pool.releaseAll()
            tiling.replaceAll(rows: measure(specs[...]))
            scroller.setDocumentHeight(tiling.documentHeight)
        }

        orderedIds = newIds
        specsById = newSpecs
        if followsTail {
            scroller.scrollToBottom()
        }
        layoutMountedRows()
    }

    /// Re-apply specs whose equality token changed; re-measure those rows and
    /// compensate the viewport when the change happened above it.
    private func updateChangedContent(specs: [ACPTranscriptRowSpec]) {
        for spec in specs {
            guard let old = specsById[spec.id],
                  !old.equalityToken.isEqual(to: spec.equalityToken)
            else { continue }
            specsById[spec.id] = spec
            guard pool.mountedIds.contains(spec.id) else { continue }
            let (view, contentChanged) = pool.view(for: spec)
            if contentChanged {
                applyMeasuredHeight(id: spec.id, view: view)
            }
        }
    }

    func remeasureRow(id: String) {
        guard let spec = specsById[id] else { return }
        let (view, _) = pool.view(for: spec)
        applyMeasuredHeight(id: id, view: view)
    }

    private func applyMeasuredHeight(id: String, view: ACPTranscriptRowHostingView) {
        let height = view.measuredHeight(forWidth: contentWidth)
        let compensation = tiling.updateHeight(
            id: id, to: height, viewportMinY: scroller.scrollY
        )
        scroller.setDocumentHeight(tiling.documentHeight)
        if compensation != 0 {
            scroller.setScrollY(scroller.scrollY + compensation)
        }
        layoutMountedRows()
    }

    private func measure<S: Sequence>(_ specs: S) -> [(id: String, height: CGFloat)]
    where S.Element == ACPTranscriptRowSpec {
        specs.map { spec in
            let (view, _) = pool.view(for: spec)
            return (spec.id, view.measuredHeight(forWidth: contentWidth))
        }
    }

    /// Mount hosting views for rows in the band, position them, unmount the
    /// rest. Called after every apply and on every scroll tick.
    func layoutMountedRows() {
        guard tiling.rowCount > 0 else {
            pool.releaseAll()
            return
        }
        let band = tiling.mountBand(
            viewportMinY: scroller.scrollY,
            viewportHeight: scroller.viewportHeight,
            overscan: Self.overscan
        )
        var keep = Set<String>()
        keep.reserveCapacity(band.count)
        for index in band {
            let layout = tiling.rowLayout(at: index)
            guard let spec = specsById[layout.id] else { continue }
            keep.insert(layout.id)
            let (view, _) = pool.view(for: spec)
            if view.superview !== scroller.flippedDocumentView {
                scroller.flippedDocumentView.addSubview(view)
            }
            assert(
                view.lastMeasuredWidth == contentWidth,
                "row \(layout.id) placed at width \(contentWidth) but last measured at \(String(describing: view.lastMeasuredWidth))"
            )
            view.frame = NSRect(
                x: 0, y: layout.minY,
                width: contentWidth, height: layout.height
            )
        }
        pool.releaseAll(except: keep)
    }

    #if DEBUG
    var mountedRowIdsForTesting: Set<String> { pool.mountedIds }
    #endif
}
