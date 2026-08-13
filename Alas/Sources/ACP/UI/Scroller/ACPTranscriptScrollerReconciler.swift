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

    /// Ids of specs whose `keepsMountedOffscreen` flag is set — recomputed
    /// alongside `specsById` on every `apply()`. Kept as its own small set
    /// (rather than filtering `specsById.values` on every layout pass, which
    /// runs on every scroll tick) so the per-pass cost of the exemption stays
    /// O(kept rows), not O(window). See `ACPTranscriptRowSpec.keepsMountedOffscreen`.
    private var keepMountedOffscreenIds: Set<String> = []

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

    /// A scroll anchor whose row was removed by an update, kept so the
    /// position can be recovered if the row comes back.
    ///
    /// This exists because a transcript can drop rows and put the same rows
    /// straight back: `ACPSessionManager.runMirrorRefresh` replaces a mirrored
    /// session's transcript with its tail on every 2.5s poll, and the backfill
    /// it schedules prepends the older messages again one update later. Across
    /// that pair the row the user is reading does not exist, so neither offset
    /// compensation (which clamps to 0 at the top of the document and silently
    /// loses the correction) nor `performReset`'s anchor (which finds nothing
    /// to aim at and declines to move) can hold the position — the user ends
    /// up a page or more below where they were. Remembering the vanished
    /// anchor and restoring it when the row reappears is what the legacy path
    /// gets for free from `restoreRememberedAnchorIfNeeded`, which re-scrolls
    /// to a remembered MESSAGE id after any rebuild.
    ///
    /// `applyBudget` bounds how long a vanished anchor stays interesting: a
    /// row that returns many updates later is no longer what the user is
    /// looking at, and restoring to it then would be its own teleport. The
    /// coordinator additionally drops it outright on any user-driven scroll
    /// (`invalidatePendingAnchorRestore`), so a live gesture is never fought.
    private struct PendingAnchorRestore {
        let id: String
        let offsetWithinRow: CGFloat
        var applyBudget: Int
    }
    private var pendingAnchorRestore: PendingAnchorRestore?

    /// Number of subsequent `apply()` calls a vanished anchor stays eligible
    /// for restoration. The mirror-refresh pair lands on consecutive updates;
    /// a small budget covers an interleaved unrelated update without letting
    /// a long-gone anchor resurface.
    private static let pendingAnchorApplyBudget = 3

    /// How long after a user-driven scroll tick the tail re-pin stays
    /// suppressed — see `repinsToTail(followsTail:wasFollowingTail:)`.
    static let userScrollSuppressionWindow: TimeInterval = 0.25

    /// `ProcessInfo.systemUptime` of the last user-driven scroll tick, or nil
    /// if the user has never moved this viewport.
    private var lastUserScrollUptime: TimeInterval?

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

        // Whether this update should end by re-pinning to the tail. Read
        // BEFORE any mutation below moves the document or the offset, and
        // gated on the viewport actually SITTING at the tail rather than on
        // `followsTail` alone — see `repinsToTail(followsTail:wasFollowingTail:)`.
        let repins = repinsToTail(followsTail: followsTail, wasFollowingTail: lastFollowsTail)

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

        // Read before the mutations below, so a row that this update removes
        // can still be identified afterwards.
        let anchorBeforeUpdate = repins ? nil : captureScrollAnchor()

        contentWidth = width
        if isPureWidthChange {
            // Apply the ordinary incremental diff at the new width (so
            // genuinely new rows are measured correctly right away), let
            // `layoutMountedRows` lazily re-pin already-mounted rows to the
            // new width as they're placed (bounded by the mount band, so the
            // visible content is never wrong), and debounce the full
            // re-measure-every-row reset until the resize settles — so a
            // live drag doesn't rebuild thousands of hosting views per tick.
            applyDiff(idDiff, specs: specs, widthChanged: true, repinsToTail: repins)
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
            applyDiff(change, specs: specs, widthChanged: widthChanged, repinsToTail: repins)
        }

        trackAnchorAcrossUpdate(anchorBeforeUpdate, repinsToTail: repins)

        orderedIds = newIds
        specsById = newSpecs
        keepMountedOffscreenIds = Set(specs.lazy.filter(\.keepsMountedOffscreen).map(\.id))
        lastAppliedSpecs = specs
        lastFollowsTail = followsTail
        if repins {
            scroller.scrollToBottom()
        }
        layoutMountedRows()
    }

    /// Drops any remembered vanished anchor. Called by the coordinator on
    /// user-driven scrolling: once the user has moved the viewport themselves,
    /// a row reappearing is no longer a reason to move it back.
    func invalidatePendingAnchorRestore() {
        pendingAnchorRestore = nil
    }

    /// Carries the reading position across an update that removes the row it
    /// was anchored to — see `PendingAnchorRestore`.
    ///
    /// Three outcomes, in priority order: the anchor row went away (remember
    /// it), a previously remembered row came back (restore and forget), or
    /// neither (age out anything remembered). Restoration deliberately runs
    /// after the diff's own compensation, overwriting it: compensation
    /// computed against a document that was missing the block is exactly what
    /// produced the wrong offset.
    private func trackAnchorAcrossUpdate(_ before: ScrollAnchor?, repinsToTail: Bool) {
        guard !repinsToTail else {
            pendingAnchorRestore = nil
            return
        }
        if case .row(let id, let offsetWithinRow) = before, tiling.row(withId: id) == nil {
            pendingAnchorRestore = PendingAnchorRestore(
                id: id, offsetWithinRow: offsetWithinRow,
                applyBudget: Self.pendingAnchorApplyBudget
            )
            return
        }
        guard var pending = pendingAnchorRestore else { return }
        if let row = tiling.row(withId: pending.id) {
            pendingAnchorRestore = nil
            scroller.setScrollY(row.minY + min(pending.offsetWithinRow, row.height))
            return
        }
        pending.applyBudget -= 1
        pendingAnchorRestore = pending.applyBudget > 0 ? pending : nil
    }

    /// Whether an update should end by re-pinning the viewport to the tail:
    /// tail-follow is on AND the viewport is currently sitting at the tail.
    ///
    /// Those two are not the same thing, and treating `followsTail` alone as
    /// the answer is what made the transcript jump to the newest message
    /// while the user was scrolling back. Before the coordinator classifies
    /// the first upward scroll tick, it can still report `followsTail: true`
    /// while the user is already moving away. Any update landing in that
    /// window — a streamed chunk, a queue change, any SwiftUI invalidation at
    /// all, since `updateNSView` runs `apply()` unconditionally — must not slam
    /// the viewport back to the bottom mid-gesture.
    ///
    /// Position alone is NOT enough to decide this, and gating on it alone
    /// was wrong: while the viewport remains within `bottomTolerance` the
    /// session still reports that it follows the tail. Suppressing the pin
    /// there indefinitely leaves a state with neither behavior — streaming
    /// content accumulates below the viewport while the "go to newest"
    /// affordance stays hidden. The suppression is therefore scoped to an
    /// ACTIVE GESTURE. This includes
    /// elastic overrun at the bottom: `distanceFromBottom` is clamped to zero
    /// there, but re-pinning would fight AppKit's rebound. Once the gesture
    /// ends, an update re-pins exactly as it always did.
    ///
    /// "The user moved it" is `noteUserScroll()`, driven by the scroller's own
    /// programmatic/non-programmatic split, not by `NSApp.currentEvent` —
    /// under responsive scrolling that event is absent for ~97% of scroll
    /// ticks (see `ACPTranscriptScroller.shouldStepHeadBack`), so a gesture
    /// detector built on it would suppress almost nothing.
    ///
    /// The state machine still converges from here: scrolling back within
    /// `bottomTolerance` re-arms the glue through the coordinator's
    /// `.userAtBottom` → `resumeTailFollow`, and travelling past that tolerance
    /// pauses the follow outright. What it no longer does is fight a gesture
    /// that is still in progress.
    ///
    /// The "at the tail" test is skipped on the RISING EDGE of tail-follow —
    /// `followsTail` true where `wasFollowingTail` is false. That transition
    /// is somebody deliberately (re-)arming the follow from wherever the
    /// viewport happens to be: `ACPMessageList`'s "go to newest" button
    /// (which sets `session.followsTranscriptTail` and resets the render
    /// window WITHOUT scrolling, leaving this re-pin as the only thing that
    /// makes it jump), `Coordinator.resumeTailFollow`, and the
    /// initial load. Requiring the viewport to already be at the tail there
    /// would defeat the whole point of the gesture.
    ///
    /// Must be read before an update mutates row geometry: afterwards, a tail
    /// insertion has already grown the document and `distanceFromBottom`
    /// answers a different question.
    private func repinsToTail(followsTail: Bool, wasFollowingTail: Bool) -> Bool {
        guard followsTail else { return false }
        if !wasFollowingTail { return true }
        return !isUserScrollInFlight()
    }

    /// Whether the user has moved the viewport recently enough that an
    /// update landing now would be interrupting a gesture still in progress.
    ///
    /// Scroll ticks arrive every ~8–25ms within a gesture (including the
    /// momentum tail and the elastic bounce at either end), so the window
    /// only has to outlast the gaps between them, not the gesture itself.
    /// It deliberately does not outlast the gesture by much: everything the
    /// window suppresses is behavior the user gets back the moment they stop.
    private func isUserScrollInFlight() -> Bool {
        guard let lastUserScrollUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - lastUserScrollUptime
            <= Self.userScrollSuppressionWindow
    }

    /// Records that the viewport was just moved by the user rather than by
    /// this reconciler. Called by the coordinator's scroll handler for every
    /// non-programmatic tick — the scroller's own
    /// `programmaticAdjustmentDepth` is what tells the two apart, which is
    /// reliable where the event stream is not.
    func noteUserScroll() {
        lastUserScrollUptime = ProcessInfo.processInfo.systemUptime
    }

    /// `repinsToTail` is the caller's already-made decision about whether this
    /// update ends by re-pinning to the tail (see
    /// `repinsToTail(followsTail:wasFollowingTail:)`),
    /// not the raw tail-follow flag: `performReset` must not capture and
    /// restore a scroll anchor it is only going to overwrite.
    private func applyDiff(
        _ change: Diff, specs: [ACPTranscriptRowSpec], widthChanged: Bool, repinsToTail: Bool
    ) {
        switch change {
        case .unchanged:
            updateChangedContent(specs: specs)
        case .inserted(let index, let count):
            let insertedSpecs = Array(specs[index..<(index + count)])
            let compensation = tiling.insert(
                rows: measure(insertedSpecs), at: index,
                viewportMinY: effectiveViewportMinY(forMutationAt: index)
            )
            if compensation != 0 {
                scroller.applyPrepend(delta: compensation, newDocumentHeight: tiling.documentHeight)
            } else {
                scroller.setDocumentHeight(tiling.documentHeight)
            }
            updateChangedContent(specs: specs)
        case .removed(let index, let count):
            let compensation = tiling.remove(
                at: index, count: count,
                viewportMinY: effectiveViewportMinY(forMutationAt: index)
            )
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
            performReset(specs: specs, widthChanged: widthChanged, repinsToTail: repinsToTail)
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
    private func performReset(specs: [ACPTranscriptRowSpec], widthChanged: Bool, repinsToTail: Bool) {
        // When the update ends by re-pinning, `apply()`'s own
        // `scrollToBottom()` (or `performWidthSettledReset`'s) is the correct
        // final position and must win — don't fight it with a restored
        // anchor. When it does NOT re-pin — including a tail-following
        // viewport the user has scrolled off the tail, which no longer
        // re-pins — the anchor is what keeps the reset from moving the
        // content under them.
        let anchor = repinsToTail ? nil : captureScrollAnchor()
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
    /// Prefix marking rows that are not messages: the head pagination
    /// spinner, queued prompts, the context-recovery row, the composer
    /// spacer. Internal so the coordinator's anchor logic shares this one
    /// definition rather than re-spelling the literal.
    static let syntheticIdPrefix = "__"

    /// The viewport top to hand `ACPTranscriptTilingController.insert` /
    /// `.remove` when they decide whether a mutation needs offset
    /// compensation.
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
    /// When every row above the mutation point is synthetic there is no
    /// real content up there to hold still, so the mutation is logically
    /// above the viewport however small `scrollY` happens to be: report the
    /// mutation point itself as the viewport top so the rule fires. (A
    /// mutation at index 0 satisfies this vacuously, which is also exactly
    /// right — inserting above every row is what `prepend` always
    /// compensated for unconditionally.) Mutations with real message rows
    /// above them — every append, every mid-list insert — are unaffected.
    ///
    /// REMOVALS go through the same rule as insertions, and must: a model
    /// that removes a block and then re-inserts the same block is not
    /// hypothetical, it is the steady state for a mirrored session
    /// (`ACPSessionManager.runMirrorRefresh` replaces the transcript with its
    /// tail every poll, then `scheduleBackfillIfNeeded` prepends the older
    /// messages straight back). With only the insertion side overridden, the
    /// removal declined to compensate while the matching re-insertion
    /// compensated in full, so each round trip teleported the viewport DOWN
    /// by the block's entire height — thousands of points, landing the user
    /// a page or more below where they had been reading. The two sides have
    /// to answer "is this above me?" identically or the round trip cannot
    /// net out.
    private func effectiveViewportMinY(forMutationAt index: Int) -> CGFloat {
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
        let repins = repinsToTail(followsTail: lastFollowsTail, wasFollowingTail: lastFollowsTail)
        performReset(specs: lastAppliedSpecs, widthChanged: true, repinsToTail: repins)
        if repins {
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
    /// `lastFollowsTail`.
    ///
    /// `apply()` alone does not keep `lastFollowsTail` current. A user
    /// scrolling away flips `session.followsTranscriptTail` to false, but
    /// the `apply()` that latches it only arrives on the NEXT SwiftUI
    /// update — and the scroll handler mounts newly exposed rows in the
    /// meantime. If mounting one of those synchronously invalidates its
    /// intrinsic size, this method runs inside that window and would re-pin
    /// a user who has just scrolled up, stranding them at the bottom with
    /// tail-follow off. The scroll handler therefore calls
    /// `setFollowsTail(false)` as it pauses, before mounting anything, so
    /// the state read here is current and this never fights a user who has
    /// genuinely left the tail.
    /// The re-pin additionally requires the viewport to have BEEN at the tail
    /// when the invalidation arrived, not merely `lastFollowsTail`. Those two
    /// are not the same thing, and conflating them made scrolling back
    /// impossible: before the coordinator pauses tail-follow for a verified
    /// upward gesture, a scroll tick can still report `lastFollowsTail ==
    /// true`. That tick mounts the rows the scroll exposed, and
    /// `performLayoutPass`'s mount-time `measuredHeight(forWidth:)` reassigns
    /// `rootView`, which SwiftUI answers by invalidating the hosting view's
    /// intrinsic size — landing right here. Re-pinning then yanked the user
    /// straight back to the bottom, so they could never travel the 160pt that
    /// would have paused the follow in the first place: the transcript
    /// oscillated within one row-height of the bottom and never escaped.
    /// (Note that this fires on a bare scroll gesture with no model update
    /// and no content change at all — the invalidation is a side effect of
    /// measuring, not evidence that anything grew.)
    ///
    /// Gating on `repinsToTail(followsTail:wasFollowingTail:)` — which
    /// additionally requires
    /// the viewport to BE at the tail — keeps the behavior this method exists for —
    /// content growing under a viewport that IS sitting at the tail keeps the
    /// tail glued — while leaving a viewport the user has already moved off
    /// the tail alone. `bottomTolerance` is the right threshold: the question
    /// here is "is the viewport at the tail right now", which is exactly what
    /// that constant answers for the classifier.
    /// While genuinely pinned, `scrollToBottom()` remains idempotent — its
    /// `setScrollY` clamp reports no `onScroll` change (`reportScroll` skips
    /// when the offset is unchanged) — so calling it on every tail-following
    /// remeasure, not just ones that grow the tail, costs nothing extra.
    /// Updates the tail-follow state that `remeasureRow` re-pins against,
    /// without waiting for the `apply()` that will carry the same value.
    ///
    /// This exists so the scroll handler can close the window described on
    /// `remeasureRow`: it pauses or resumes tail-follow synchronously, one
    /// SwiftUI update ahead of the `apply()` that latches the session's new
    /// `followsTranscriptTail`. Only the re-pin decision is affected —
    /// nothing here mounts, measures, or moves the viewport, and the next
    /// `apply()` overwrites it with the authoritative value either way.
    func setFollowsTail(_ followsTail: Bool) {
        lastFollowsTail = followsTail
    }

    /// The tail-follow state this reconciler is currently acting on. Read by
    /// the coordinator's height-change path, which has to make the same
    /// re-pin decision `remeasureRow` makes and must read it from the same
    /// place rather than from the session (which the scroll handler has not
    /// necessarily mirrored yet).
    var followsTail: Bool { lastFollowsTail }

    func remeasureRow(id: String) {
        guard !isApplyingSpecs else { return }
        guard let spec = specsById[id] else { return }
        // Read BEFORE measuring: `applyMeasuredHeight` can change both the
        // document height and the offset, after which "was the viewport at
        // the tail when this arrived?" is no longer answerable.
        let repins = repinsToTail(followsTail: lastFollowsTail, wasFollowingTail: lastFollowsTail)
        let (view, _) = pool.view(for: spec)
        applyMeasuredHeight(id: id, view: view)
        if repins {
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
        // Rows in the band, PLUS any row exempted from unmounting regardless
        // of distance from the viewport (an in-progress form prompt, say).
        // The exemption only widens which rows get mounted/kept — `band`
        // itself, which governs ordinary rows and the memory bound, is
        // untouched. Kept rows are placed at their real tiled coordinates
        // like any other mounted row (they just happen to sit outside the
        // visible rect), not at some arbitrary position.
        var indices = Array(band)
        for id in keepMountedOffscreenIds {
            guard let index = tiling.index(ofId: id), !band.contains(index) else { continue }
            indices.append(index)
        }
        var keep = Set<String>()
        keep.reserveCapacity(indices.count)
        for index in indices {
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
