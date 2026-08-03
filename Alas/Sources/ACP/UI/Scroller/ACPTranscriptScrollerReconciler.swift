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

    /// Trailing-edge delay before a width-only change triggers the
    /// expensive "re-measure every row" reset. A live resize/split-view
    /// drag delivers a new width on essentially every frame (tens of
    /// milliseconds apart); 150ms comfortably absorbs that whole burst
    /// (so the drag never rebuilds thousands of hosting views per tick)
    /// while staying well under the ~200-300ms threshold where a settle
    /// delay starts reading as sluggish once the user stops dragging.
    static let widthChangeSettleInterval: TimeInterval = 0.15

    private let tiling: ACPTranscriptTilingController
    private let pool: ACPTranscriptRowHostingPool
    private unowned let scroller: ACPTranscriptScrollerView
    private var specsById: [String: ACPTranscriptRowSpec] = [:]
    private var orderedIds: [String] = []
    private var contentWidth: CGFloat = 0

    /// The full spec list and tail-follow flag from the most recent
    /// `apply()` call, kept so the deferred width-settle reset (which can
    /// fire well after the `apply()` call that scheduled it returned) always
    /// measures against current state rather than a stale captured snapshot.
    private var lastAppliedSpecs: [ACPTranscriptRowSpec] = []
    private var lastFollowsTail = false
    private let widthSettleTimer: DebounceTimer

    /// True for the entire duration of `apply()` (and the deferred
    /// width-settle reset). Suppresses `remeasureRow`'s reentrant path:
    /// AppKit/SwiftUI can synchronously invalidate a hosting view's
    /// intrinsic size as a side effect of the measurement calls `apply()`
    /// itself makes (e.g. via `addSubview` or re-pinning `rootView`), which
    /// would otherwise route back into `remeasureRow` while `specsById` and
    /// the tiling controller are mid-mutation (most sharply during a
    /// `.reset`, between `pool.releaseAll()` and `tiling.replaceAll`, where
    /// `specsById` still holds the OLD specs for ids being reused). Every
    /// measurement `apply()` needs is already performed directly by its own
    /// code paths, so ignoring the reentrant signal during this window loses
    /// nothing.
    private var isApplyingSpecs = false

    /// Reentrancy guard for `layoutMountedRows()`. A layout pass can itself
    /// trigger a nested re-measure (mounting/measuring a row can invalidate
    /// its intrinsic size synchronously), which must coalesce into another
    /// full pass afterward rather than recurse mid-pass — recursing would
    /// let the outer pass's stale `band`/`keep` release views the inner
    /// pass just mounted.
    private var isLayingOutRows = false
    private var pendingRelayout = false

    init(
        tiling: ACPTranscriptTilingController,
        pool: ACPTranscriptRowHostingPool,
        scroller: ACPTranscriptScrollerView
    ) {
        self.tiling = tiling
        self.pool = pool
        self.scroller = scroller
        widthSettleTimer = DebounceTimer(interval: Self.widthChangeSettleInterval)
        pool.onRowIntrinsicSizeInvalidated = { [weak self] id in
            self?.remeasureRow(id: id)
        }
        widthSettleTimer.onFire = { [weak self] in
            MainActor.assumeIsolated {
                self?.performWidthSettledReset()
            }
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
        // A non-positive width is transient (e.g. a host view not yet laid
        // out). Nothing can be usefully measured against it — every row
        // would collapse to zero height and `lastMeasuredWidth` would stay
        // unset, permanently failing the placement invariant below. Defer
        // entirely: state is left exactly as it was, so the next call with a
        // real width is diffed as a normal (likely initial) update.
        guard width > 0 else { return }

        let newIds = specs.map(\.id)
        var newSpecs: [String: ACPTranscriptRowSpec] = [:]
        newSpecs.reserveCapacity(specs.count)
        for spec in specs { newSpecs[spec.id] = spec }

        let idDiff = Self.diff(oldIds: orderedIds, newIds: newIds)
        let widthChanged = width != contentWidth
        // A width change whose row identity is otherwise unchanged (or only
        // incrementally so) does not need the eager "measure every row"
        // reset applied immediately: see `performWidthSettledReset`.
        let isPureWidthChange = widthChanged && idDiff != .reset

        isApplyingSpecs = true
        defer { isApplyingSpecs = false }

        contentWidth = width
        if isPureWidthChange {
            // Apply the ordinary incremental diff at the new width (so
            // genuinely new rows are measured correctly right away), let
            // `layoutMountedRows` lazily re-pin already-mounted rows to the
            // new width as they're placed (bounded by the mount band, so the
            // visible content is never wrong), and debounce the full
            // re-measure-every-row reset until the resize settles — so a
            // live drag doesn't rebuild thousands of hosting views per tick.
            applyDiff(idDiff, specs: specs)
            widthSettleTimer.poke()
        } else {
            let change: Diff = widthChanged ? .reset : idDiff
            if change == .reset {
                // We're about to do the full remeasure ourselves; any
                // earlier pending width-settle reset is now redundant.
                widthSettleTimer.cancel()
            }
            applyDiff(change, specs: specs)
        }

        orderedIds = newIds
        specsById = newSpecs
        lastAppliedSpecs = specs
        lastFollowsTail = followsTail
        if followsTail {
            scroller.scrollToBottom()
        }
        layoutMountedRows()
    }

    private func applyDiff(_ change: Diff, specs: [ACPTranscriptRowSpec]) {
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
    }

    /// Fires once a width-only change has stopped ticking for
    /// `widthChangeSettleInterval`. Performs the full eager-build reset the
    /// coalesced `apply()` path deferred, so off-screen rows (never touched
    /// by the lazy per-row fallback in `layoutMountedRows`) end up with
    /// correct, non-stale heights too. Always reads current state
    /// (`lastAppliedSpecs`/`contentWidth`/`lastFollowsTail`) rather than a
    /// captured snapshot, since this can fire well after the `apply()` call
    /// that scheduled it returned.
    private func performWidthSettledReset() {
        isApplyingSpecs = true
        defer { isApplyingSpecs = false }
        pool.releaseAll()
        tiling.replaceAll(rows: measure(lastAppliedSpecs[...]))
        scroller.setDocumentHeight(tiling.documentHeight)
        if lastFollowsTail {
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

    /// Wired to `pool.onRowIntrinsicSizeInvalidated`. Re-measures a row
    /// whose SwiftUI content invalidated its own intrinsic size (e.g. a
    /// streaming row growing in place). No-ops while `apply()` (or the
    /// deferred width-settle reset) is itself mutating row state — see
    /// `isApplyingSpecs`'s doc comment.
    func remeasureRow(id: String) {
        guard !isApplyingSpecs else { return }
        guard let spec = specsById[id] else { return }
        let (view, _) = pool.view(for: spec)
        applyMeasuredHeight(id: id, view: view)
    }

    /// Measures `view` at the current content width and pushes the result
    /// into the tiling controller; triggers a relayout pass only if the
    /// height actually changed. Safe to call from within a layout pass:
    /// `layoutMountedRows()` coalesces re-entrant calls rather than
    /// recursing, so this never interleaves with an in-progress pass.
    private func applyMeasuredHeight(id: String, view: ACPTranscriptRowHostingView) {
        let height = view.measuredHeight(forWidth: contentWidth)
        if applyHeightToTiling(id: id, height: height) {
            layoutMountedRows()
        }
    }

    /// Pushes a freshly measured height into the tiling controller, only if
    /// it actually differs from what's on record — an unchanged height is a
    /// no-op that must not cost a relayout pass. Returns whether geometry
    /// changed.
    @discardableResult
    private func applyHeightToTiling(id: String, height: CGFloat) -> Bool {
        guard let oldHeight = tiling.row(withId: id)?.height, oldHeight != height else { return false }
        let compensation = tiling.updateHeight(id: id, to: height, viewportMinY: scroller.scrollY)
        scroller.setDocumentHeight(tiling.documentHeight)
        if compensation != 0 {
            scroller.setScrollY(scroller.scrollY + compensation)
        }
        return true
    }

    private func measure<S: Sequence>(_ specs: S) -> [(id: String, height: CGFloat)]
    where S.Element == ACPTranscriptRowSpec {
        specs.map { spec in
            let (view, _) = pool.view(for: spec)
            return (spec.id, view.measuredHeight(forWidth: contentWidth))
        }
    }

    /// Mount hosting views for rows in the band, position them, unmount the
    /// rest. Called after every apply and on every scroll tick. Re-entrant
    /// calls (triggered by AppKit/SwiftUI invalidating a row's intrinsic
    /// size as a side effect of a mount/measure happening inside a pass)
    /// coalesce into an extra pass afterward instead of recursing.
    func layoutMountedRows() {
        guard !isLayingOutRows else {
            pendingRelayout = true
            return
        }
        isLayingOutRows = true
        defer { isLayingOutRows = false }

        performLayoutPass()
        var safetyCount = 0
        while pendingRelayout {
            pendingRelayout = false
            performLayoutPass()
            safetyCount += 1
            if safetyCount > 8 {
                assertionFailure("layoutMountedRows did not converge after \(safetyCount) extra passes")
                break
            }
        }
    }

    private func performLayoutPass() {
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
            // A freshly mounted (or previously-released-and-now-remounted)
            // view has never been measured at the current width, or was
            // last measured at a since-superseded one. Make the invariant
            // below true by construction rather than relying on AppKit
            // happening to invalidate the view's intrinsic size as a side
            // effect of `addSubview` — that isn't contractual behavior.
            if view.lastMeasuredWidth != contentWidth {
                let height = view.measuredHeight(forWidth: contentWidth)
                applyHeightToTiling(id: layout.id, height: height)
            }
            assert(
                view.lastMeasuredWidth == contentWidth,
                "row \(layout.id) placed at width \(contentWidth) but last measured at \(String(describing: view.lastMeasuredWidth))"
            )
            let placedLayout = tiling.rowLayout(at: index)
            view.frame = NSRect(
                x: 0, y: placedLayout.minY,
                width: contentWidth, height: placedLayout.height
            )
        }
        pool.releaseAll(except: keep)
    }

    #if DEBUG
    var mountedRowIdsForTesting: Set<String> { pool.mountedIds }
    #endif
}
