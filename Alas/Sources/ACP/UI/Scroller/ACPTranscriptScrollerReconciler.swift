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
    /// `.reset`, where `resetHeights` measures re-used ids while `specsById`
    /// still holds their OLD specs and `tiling` still holds the OLD
    /// geometry). Every measurement `apply()` needs is already performed
    /// directly by its own code paths, so ignoring the reentrant signal
    /// during this window loses nothing.
    ///
    /// Exposed read-only so `ACPTranscriptScroller.Coordinator`'s `onScroll`
    /// callback can skip its own `layoutMountedRows()` call while `apply()`
    /// is mid-mutation: `apply()`'s own programmatic scrolls
    /// (`applyPrepend`, `scrollToBottom`) report synchronously through the
    /// same callback, and running a layout pass against `specsById`/
    /// `orderedIds` before `apply()` has finished updating them would mount
    /// rows against stale state — the same hazard this flag already guards
    /// `remeasureRow` against. `apply()`'s own trailing `layoutMountedRows()`
    /// call covers the pass once it's safe to run.
    private(set) var isApplyingSpecs = false

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
        /// `count` new ids inserted at `index` in the new list; every other
        /// id is unchanged and in the same relative order. Subsumes what
        /// used to be separate prepend (`index == 0`) and append
        /// (`index == oldIds.count`) cases — a fixed row at either end (the
        /// head pagination spinner, the composer spacer) no longer forces a
        /// full reset just because it sits at position 0 or the tail.
        case inserted(index: Int, count: Int)
        /// `count` ids removed starting at `index` in the old list; every
        /// other id is unchanged and in the same relative order (e.g. the
        /// streaming caret disappearing at the end of a turn).
        case removed(index: Int, count: Int)
        case reset
    }

    /// Classifies the transition from `oldIds` to `newIds` by trimming the
    /// common prefix and common suffix. What remains between them is either
    /// nothing (`unchanged`), a pure insertion, a pure removal, or — if
    /// ids changed on both sides at once, or content was replaced in place —
    /// a `reset`. This subsumes the old prepend/append cases (insertion at
    /// index 0 or at the old list's end) without needing a fixed row at
    /// either end to defeat the classification: a common-prefix/suffix trim
    /// still finds the single insertion/removal point even when both list
    /// ends are pinned by rows whose ids never change (e.g. a head
    /// pagination spinner at index 0 and a composer spacer at the tail).
    nonisolated static func diff(oldIds: [String], newIds: [String]) -> Diff {
        if oldIds == newIds { return .unchanged }
        let minCount = min(oldIds.count, newIds.count)
        var prefix = 0
        while prefix < minCount, oldIds[prefix] == newIds[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < minCount - prefix,
              oldIds[oldIds.count - 1 - suffix] == newIds[newIds.count - 1 - suffix] {
            suffix += 1
        }
        if prefix + suffix == oldIds.count, newIds.count > oldIds.count {
            return .inserted(index: prefix, count: newIds.count - oldIds.count)
        }
        if prefix + suffix == newIds.count, oldIds.count > newIds.count {
            return .removed(index: prefix, count: oldIds.count - newIds.count)
        }
        return .reset
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
            applyDiff(idDiff, specs: specs, widthChanged: true, followsTail: followsTail)
            widthSettleTimer.poke()
        } else {
            let change: Diff = widthChanged ? .reset : idDiff
            if change == .reset, widthChanged {
                // A reset AT A NEW WIDTH re-measures everything against that
                // width, so any earlier pending width-settle reset is now
                // redundant. An id-change reset at the SAME width is not a
                // substitute: `canReuseMeasuredHeight` carries every off-band
                // height forward untouched, and those were measured at the
                // pre-resize width. Cancelling here would silently drop the
                // "off-band rows are correct once the resize settles"
                // guarantee for any reset that happens to land inside the
                // settle window.
                widthSettleTimer.cancel()
            }
            applyDiff(change, specs: specs, widthChanged: widthChanged, followsTail: followsTail)
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

    private func applyDiff(
        _ change: Diff, specs: [ACPTranscriptRowSpec], widthChanged: Bool, followsTail: Bool
    ) {
        switch change {
        case .unchanged:
            updateChangedContent(specs: specs)
        case .inserted(let index, let count):
            let insertedSpecs = Array(specs[index..<(index + count)])
            let compensation = tiling.insert(
                rows: measure(insertedSpecs), at: index,
                viewportMinY: effectiveViewportMinY(forInsertionAt: index)
            )
            if compensation != 0 {
                scroller.applyPrepend(delta: compensation, newDocumentHeight: tiling.documentHeight)
            } else {
                scroller.setDocumentHeight(tiling.documentHeight)
            }
            updateChangedContent(specs: specs)
        case .removed(let index, let count):
            let compensation = tiling.remove(at: index, count: count, viewportMinY: scroller.scrollY)
            if compensation != 0 {
                scroller.applyPrepend(delta: compensation, newDocumentHeight: tiling.documentHeight)
            } else {
                scroller.setDocumentHeight(tiling.documentHeight)
            }
            // Hosting views for the removed ids are released by the
            // trailing `layoutMountedRows()` pass in `apply()`: they're no
            // longer in `specsById`/the tiling controller, so they fall out
            // of `keep` and `pool.releaseAll(except:)` cleans them up.
            updateChangedContent(specs: specs)
        case .reset:
            performReset(specs: specs, widthChanged: widthChanged, followsTail: followsTail)
        }
    }

    /// Replaces the entire geometry from `specs`, preserving what the user
    /// is looking at.
    ///
    /// Two properties every other diff case already had, and `.reset` did
    /// not:
    ///   - the scroll offset is re-anchored to the row that was at the
    ///     viewport top, instead of keeping its old numeric value against a
    ///     completely different document (a hard content jump — most
    ///     visibly on the FINAL head step, where `__top_pagination__`
    ///     disappearing in the same update that inserts older rows changes
    ///     ids at both ends and so falls to `.reset`);
    ///   - rows whose measured height is still valid keep it instead of
    ///     being rebuilt and re-measured. The mount band bounds how many
    ///     hosting views are LIVE, but nothing bounded how many this path
    ///     CONSTRUCTED: `pool.releaseAll()` + measuring every spec meant a
    ///     reset after browsing deep into a long transcript allocated and
    ///     synchronously measured a hosting view per row in the whole render
    ///     window.
    private func performReset(specs: [ACPTranscriptRowSpec], widthChanged: Bool, followsTail: Bool) {
        // While following the tail, `apply()`'s own `scrollToBottom()` (or
        // `performWidthSettledReset`'s) is the correct final position and
        // must win — don't fight it with a restored anchor.
        let anchor = followsTail ? nil : captureScrollAnchor()
        tiling.replaceAll(rows: resetHeights(specs: specs, widthChanged: widthChanged))
        scroller.setDocumentHeight(tiling.documentHeight)
        restoreScrollAnchor(anchor)
    }

    /// The scroll offset expressed relative to a row (so it survives a
    /// wholesale geometry replacement), or — for the synthetic tail region,
    /// where no such row exists — relative to the document's bottom edge.
    private enum ScrollAnchor {
        case row(id: String, offsetWithinRow: CGFloat)
        case bottomRelative(distance: CGFloat)
    }

    /// Anchors to the first NON-synthetic row at or below the viewport top,
    /// not simply to the topmost visible row.
    ///
    /// Synthetic rows are exactly the ones a reset is most likely to delete,
    /// and the worst case is the one that matters most: the head pagination
    /// spinner occupies row 0 (`minY 24`, `maxY 38`), so any `scrollY < 38`
    /// — the top-of-history bounce, i.e. precisely the gesture that CAUSES
    /// the final head step — would otherwise capture `__top_pagination__`
    /// as the anchor. That is the very row the final head step removes, so
    /// restoration would find nothing to aim at, silently no-op, and leave
    /// the original hard jump intact at exactly the position it was fixed
    /// for.
    ///
    /// `offsetWithinRow` is deliberately allowed to be negative: the chosen
    /// row may start below the current scroll position (the spinner is on
    /// screen and the first message begins under it). Restoration
    /// reproduces the same relationship either way, so a negative offset is
    /// exact rather than approximate.
    ///
    /// The forward walk can run off the end of the document without ever
    /// finding a non-synthetic row: when the viewport top is already inside
    /// the synthetic TAIL region (a queued prompt, the context-recovery row,
    /// the composer spacer — everything after the last message row), every
    /// remaining row is synthetic too. Falling back to `nil` there (as this
    /// used to) skips restoration entirely, so a width-settled reset that
    /// reflows message heights ABOVE the viewport moves the synthetic
    /// content the user was looking at even though nothing at or below the
    /// viewport itself changed. Anchor to the distance from the document's
    /// bottom edge instead: a reset always re-measures the SAME spec list
    /// (`performReset` never adds or removes rows — only `resetHeights`
    /// dimensions change), so nothing in this window can move the document's
    /// end for reasons other than the very reflow being compensated for,
    /// which makes a bottom-relative anchor exact here — and, unlike
    /// anchoring to the nearest preceding message row, it reproduces the
    /// user's actual depth into the tail rather than snapping to the top of
    /// it. (A preceding-message anchor was considered — it reuses the `.row`
    /// case outright — but `offsetWithinRow` for a row the viewport has
    /// scrolled past is always at or beyond that row's height, so restoring
    /// through it would always land on the clamp in `restoreScrollAnchor`
    /// below, i.e. the top of the tail, not the user's actual position
    /// within it.)
    private func captureScrollAnchor() -> ScrollAnchor? {
        let viewportMinY = scroller.scrollY
        guard var index = tiling.firstRowIndex(intersectingY: viewportMinY) else { return nil }
        while index < tiling.rowCount, tiling.rowId(at: index).hasPrefix(Self.syntheticIdPrefix) {
            index += 1
        }
        guard index < tiling.rowCount else {
            return .bottomRelative(distance: scroller.distanceFromBottom)
        }
        let row = tiling.rowLayout(at: index)
        return .row(id: row.id, offsetWithinRow: viewportMinY - row.minY)
    }

    /// Puts the anchored position back where it was on screen. A nil
    /// anchor, or a `.row` anchor whose row no longer exists in the new
    /// geometry, leaves the offset alone — there is nothing better to aim
    /// at, and `setScrollY`'s clamp still keeps it inside the new document.
    ///
    /// For `.row`, the offset is capped at the anchor row's NEW height: a
    /// row that shrank across the reset (a tall tool-output row collapsing,
    /// say) would otherwise place the viewport top past its own end by
    /// `oldHeight - newHeight`. The viewport top can be at most the anchor
    /// row's bottom edge. No lower cap — see `captureScrollAnchor` on why
    /// negative offsets are legitimate.
    ///
    /// For `.bottomRelative`, `setScrollY` re-derives the offset from the
    /// NEW `documentHeight` (already installed by the caller before this
    /// runs) and the captured distance, reproducing the same visual gap
    /// from the bottom edge.
    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor else { return }
        switch anchor {
        case .row(let id, let offsetWithinRow):
            guard let row = tiling.row(withId: id) else { return }
            scroller.setScrollY(row.minY + min(offsetWithinRow, row.height))
        case .bottomRelative(let distance):
            scroller.setScrollY(tiling.documentHeight - scroller.viewportHeight - distance)
        }
    }

    /// Heights for a wholesale geometry replacement. Rows whose recorded
    /// height is still valid are carried forward WITHOUT building or
    /// measuring a hosting view; everything else is measured now.
    private func resetHeights(
        specs: [ACPTranscriptRowSpec], widthChanged: Bool
    ) -> [(id: String, height: CGFloat)] {
        let mounted = pool.mountedIds
        return specs.map { spec in
            if let known = tiling.row(withId: spec.id)?.height,
               canReuseMeasuredHeight(
                   for: spec, isMounted: mounted.contains(spec.id), widthChanged: widthChanged
               ) {
                return (spec.id, known)
            }
            let (view, _) = pool.view(for: spec)
            return (spec.id, view.measuredHeight(forWidth: contentWidth))
        }
    }

    /// Whether the height already on record for `spec`'s row can stand.
    ///
    /// The safety net this leans on is `performLayoutPass`'s mount-time
    /// fallback: any row without a live hosting view gets a fresh one when
    /// it next enters the mount band, whose `lastMeasuredWidth` is nil, so
    /// it is re-measured at that moment. That makes a carried-forward height
    /// on an UNMOUNTED row self-correcting — it can only ever be observed
    /// after the row has been re-measured. A mounted row has no such net
    /// (its view is already pinned at `contentWidth`, so the fallback won't
    /// fire), which is what the `isMounted` cases below turn on.
    private func canReuseMeasuredHeight(
        for spec: ACPTranscriptRowSpec, isMounted: Bool, widthChanged: Bool
    ) -> Bool {
        let contentChanged = specsById[spec.id]
            .map { !$0.equalityToken.isEqual(to: spec.equalityToken) } ?? true
        if contentChanged { return !isMounted }
        if !widthChanged { return true }
        // The width changed, so a height measured at the old width is stale.
        // Only rows the layout pass already re-pinned to the new width (the
        // mount band, corrected lazily while the resize drag was still
        // ticking) are current; everything else must be measured here — this
        // is the whole reason the width-settle reset exists.
        return isMounted && pool.mountedView(id: spec.id)?.lastMeasuredWidth == contentWidth
    }

    /// Synthetic rows (the head pagination spinner, the composer spacer, the
    /// streaming caret, …) all use this id prefix — see
    /// `ACPTranscriptScroller.Coordinator.rowSpecs`.
    private static let syntheticIdPrefix = "__"

    /// The viewport top to hand `ACPTranscriptTilingController.insert` when
    /// it decides whether an insertion needs offset compensation.
    ///
    /// Normally that is simply the real viewport top: content grafted in at
    /// or above it must push the offset down by the same amount to keep the
    /// reading position still. But the head pagination spinner occupies row
    /// 0, so a head step inserts at index 1 — i.e. at `topPadding +
    /// spinnerHeight + rowSpacing`, roughly 56pt down — and bouncing to the
    /// very top of history (the natural gesture that TRIGGERS a head step)
    /// leaves `scrollY` below that. The plain `insertionY <= viewportMinY`
    /// rule then declines to compensate and the whole inserted block, tens
    /// of rows and thousands of points, shoves the reading position down.
    ///
    /// When every row above the insertion point is synthetic there is no
    /// real content up there to hold still, so the insertion is logically
    /// above the viewport however small `scrollY` happens to be: report the
    /// insertion point itself as the viewport top so the rule fires. (An
    /// insertion at index 0 satisfies this vacuously, which is also exactly
    /// right — inserting above every row is what `prepend` always
    /// compensated for unconditionally.) Insertions with real message rows
    /// above them — every append, every mid-list insert — are unaffected.
    private func effectiveViewportMinY(forInsertionAt index: Int) -> CGFloat {
        let viewportMinY = scroller.scrollY
        guard index <= orderedIds.count,
              orderedIds[0..<index].allSatisfy({ $0.hasPrefix(Self.syntheticIdPrefix) })
        else { return viewportMinY }
        let insertionY = index < tiling.rowCount ? tiling.rowLayout(at: index).minY : tiling.documentHeight
        return max(viewportMinY, insertionY)
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
        performReset(specs: lastAppliedSpecs, widthChanged: true, followsTail: lastFollowsTail)
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
    ///
    /// A mounted TAIL row growing this way (an image finishing its load, an
    /// expandable row changing its own internal state) is never "entirely
    /// above the viewport", so `applyHeightToTiling`'s compensation is
    /// correctly zero — but that leaves the viewport at its old offset while
    /// the document grew underneath it, stranding it above the new bottom
    /// even though tail-follow is still active. Re-pin explicitly using
    /// `lastFollowsTail`, which is guaranteed current here: this method only
    /// runs once `isApplyingSpecs` is false, i.e. after some `apply()` call
    /// has fully finished and already assigned `lastFollowsTail` from its
    /// own `followsTail` argument. If the user scrolled away, the resulting
    /// `apply()` (driven by `session.followsTranscriptTail` flipping to
    /// false) already latched `lastFollowsTail = false` before this can run,
    /// so this never fights a user who has genuinely left the tail.
    /// `scroller.scrollToBottom()` is idempotent when already there — its
    /// `setScrollY` clamp reports no `onScroll` change (`reportScroll` skips
    /// when the offset is unchanged) — so calling it unconditionally on
    /// every tail-following remeasure, not just ones that grow the tail,
    /// costs nothing extra in the common case.
    func remeasureRow(id: String) {
        guard !isApplyingSpecs else { return }
        guard let spec = specsById[id] else { return }
        let (view, _) = pool.view(for: spec)
        applyMeasuredHeight(id: id, view: view)
        if lastFollowsTail {
            scroller.scrollToBottom()
        }
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
                // A changed height supersedes the `band`/`keep` computed at
                // the top of this pass: rows that shrank pull later rows up
                // into the band this pass will never look at, leaving a gap
                // at the bottom of the viewport until the next scroll tick.
                // Coalesce into another pass instead (`layoutMountedRows`
                // drains `pendingRelayout` before returning) — the same
                // thing `applyMeasuredHeight` does for out-of-pass callers.
                if applyHeightToTiling(id: layout.id, height: height) {
                    pendingRelayout = true
                }
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
