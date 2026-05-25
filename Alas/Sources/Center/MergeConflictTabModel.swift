import Foundation
import Observation
import os

/// Runtime view-model for a merge-conflict tab. Loads the three sides
/// via `GitService.conflictedFile`, parses the on-disk merged buffer
/// into regions, and exposes navigation / accept-side / resolve methods.
@Observable
@MainActor
final class MergeConflictTabModel {
    private(set) var conflictedFile: ConflictedFile?
    private(set) var regions: [ConflictRegion] = []
    /// 0-based index into the conflict subset of `regions`. nil when no
    /// unresolved conflicts remain.
    private(set) var currentConflictIndex: Int?
    /// Mutable text of the on-disk merged buffer. Drives the RESULT column.
    /// Updated by accept-side actions and by direct user edits.
    var resultText: String = ""
    /// Set when `load()` fails. Cleared on successful (re)load.
    private(set) var loadError: String?
    /// `true` when the most recent load failed specifically because the
    /// file is no longer in a conflicted state (resolved or staged from
    /// elsewhere while this tab stayed open). Drives the empty-state
    /// pane rendering — distinct from a generic load failure.
    private(set) var notInConflictedState: Bool = false
    /// Per-conflict-block one-line annotation populated by the agent.
    /// Keyed by a stable identity derived from the conflict's three sides
    /// (NOT by ordinal — ordinals shift when prior conflicts are resolved).
    /// Cleared on `load()`.
    private(set) var annotations: [String: String] = [:]
    /// Conflict count at the moment `load()` last succeeded. Used by the
    /// minimap to show progress (resolved vs total). Cleared (set to 0)
    /// on `load()` failure.
    private(set) var initialConflictCount: Int = 0

    /// Increments at the *start* of every `load()` attempt. Used by
    /// stale-async guards (binary image cache, `requestAgentResolveFile`)
    /// to detect that a load has begun mid-await and drop their results.
    /// Bumping at start (rather than completion) means an in-flight request
    /// is invalidated as soon as a new load kicks off — even if it never
    /// finishes (e.g. file no longer conflicted).
    private(set) var loadGeneration: Int = 0

    /// Increments after `load()` has committed its new state to the model
    /// (success OR failure). Used by view-side reload triggers that need
    /// to read the post-load `regions` / `currentConflictIndex` to dispatch
    /// further work (e.g. auto-explain). Distinct from `loadGeneration`
    /// because firing on the start-of-load value would read stale state.
    private(set) var loadCompletionGeneration: Int = 0

    /// Block keys for which an `explainCurrentConflict` request is currently
    /// in flight. Prevents duplicate agent dispatches when both an
    /// `onChange(currentConflictIndex)` and an `onChange(loadGeneration)`
    /// view-hook fire for the same conflict in the same render cycle.
    @ObservationIgnored
    private var explainInFlight: Set<String> = []

    /// Set while a `MergeAgent` request is in flight. Drives toolbar disabled-state.
    private(set) var agentBusy: Bool = false

    /// Agent's proposed full-file resolution, awaiting user Apply/Cancel.
    /// Nil when no proposal is pending. Cleared by `applyAgentProposal` /
    /// `discardAgentProposal`.
    private(set) var agentProposal: String?

    /// Per-tab session preference for word-level diff inside conflict
    /// hunks. Drives the highlight inside `MergeResultPane`. Not
    /// persisted — same lifetime semantics as `showBase`.
    var wordDiffMode: MergeWordDiff.Mode = .characters

    let worktreePath: URL
    let relativePath: String
    private let gitService: GitService
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "merge-conflict-tab")

    init(worktreePath: URL, relativePath: String, gitService: GitService) {
        self.worktreePath = worktreePath
        self.relativePath = relativePath
        self.gitService = gitService
    }

    /// Number of unresolved conflict regions currently in `resultText`.
    var conflictCount: Int {
        regions.reduce(0) { $0 + (isConflict($1) ? 1 : 0) }
    }

    /// True when any conflict region carries a BASE side. Used by the
    /// toolbar to disable the Show BASE toggle for merges driven without
    /// `merge.conflictStyle=zdiff3`, where toggling would be a no-op.
    var hasBase: Bool {
        for region in regions {
            if case .conflict(let block) = region, block.base != nil {
                return true
            }
        }
        return false
    }

    /// Re-loads the conflicted file's three sides and re-parses the on-disk
    /// merged buffer. Safe to call repeatedly.
    ///
    /// `loadGeneration` is incremented on EVERY attempt (success or failure)
    /// so stale-async guards (`requestAgentResolveFile`, binary image cache)
    /// invalidate even when a reload fails — otherwise an in-flight agent
    /// resolve from before a failed reload could still write its proposal
    /// into the model after we've cleared everything.
    func load() async {
        loadGeneration += 1
        explainInFlight.removeAll()
        do {
            let file = try await gitService.conflictedFile(
                worktreePath: worktreePath,
                relativePath: relativePath
            )
            self.conflictedFile = file
            self.resultText = file.merged
            self.regions = ConflictMarkerParser.parse(file.merged)
            self.currentConflictIndex = firstConflictIndex()
            self.initialConflictCount = self.conflictCount
            self.annotations = [:]
            self.agentProposal = nil
            self.agentBusy = false
            self.loadError = nil
            self.notInConflictedState = false
        } catch {
            self.conflictedFile = nil
            self.regions = []
            self.resultText = ""
            self.currentConflictIndex = nil
            self.initialConflictCount = 0
            self.annotations = [:]
            self.agentProposal = nil
            self.agentBusy = false
            self.loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            if case ConflictedFileError.notConflicted = error {
                self.notInConflictedState = true
            } else {
                self.notInConflictedState = false
            }
            logger.error("merge-conflict load failed: \(self.loadError ?? "", privacy: .public)")
        }
        // Bump AFTER state is committed so view-side reload triggers read
        // post-load `regions` / `currentConflictIndex` (not stale values).
        loadCompletionGeneration += 1
    }

    /// Re-parses `resultText` and updates `regions` + `currentConflictIndex`.
    /// Call after any mutation of `resultText` (typed by user or via accept actions).
    func reparse() {
        regions = ConflictMarkerParser.parse(resultText)
        let total = conflictCount
        guard total > 0 else {
            currentConflictIndex = nil
            return
        }
        if let idx = currentConflictIndex {
            // Clamp: if the resolved conflict was the last in the list (or beyond),
            // step the cursor back to the new last instead of snapping to 0.
            // Otherwise the ordinal still points to a valid conflict because
            // every later conflict shifts down by one when one is removed.
            currentConflictIndex = min(idx, total - 1)
        } else {
            currentConflictIndex = 0
        }
    }

    // MARK: - Helpers

    /// Marked `internal` (default) so Task 4's extension can call it.
    func isConflict(_ region: ConflictRegion) -> Bool {
        if case .conflict = region { return true }
        return false
    }

    /// Returns the 0-based index into `regions` of the Nth conflict, or nil.
    /// Marked `internal` (default) so Task 4's extension can call it.
    func conflictRegionIndex(forConflictOrdinal ordinal: Int) -> Int? {
        var seen = 0
        for (i, r) in regions.enumerated() {
            if isConflict(r) {
                if seen == ordinal { return i }
                seen += 1
            }
        }
        return nil
    }

    /// Returns the ordinal (0-based) of the first unresolved conflict, or nil.
    /// Marked `internal` (default) so callers in the same target can use it.
    func firstConflictIndex() -> Int? {
        regions.contains(where: isConflict) ? 0 : nil
    }

    private func ordinal(of block: ConflictBlock) -> Int? {
        var seen = 0
        for region in regions {
            if case .conflict(let candidate) = region {
                if candidate == block { return seen }
                seen += 1
            }
        }
        return nil
    }

    // MARK: - Accept actions

    /// Replaces the current conflict's marker block with LOCAL content.
    func acceptLocal() {
        guard let ordinal = currentConflictIndex,
              let regionIdx = conflictRegionIndex(forConflictOrdinal: ordinal),
              case .conflict(let block) = regions[regionIdx]
        else { return }
        replaceCurrentConflictBlock(with: block.local)
    }

    /// Replaces the current conflict's marker block with REMOTE content.
    func acceptRemote() {
        guard let ordinal = currentConflictIndex,
              let regionIdx = conflictRegionIndex(forConflictOrdinal: ordinal),
              case .conflict(let block) = regions[regionIdx]
        else { return }
        replaceCurrentConflictBlock(with: block.remote)
    }

    /// Returns the parsed `ConflictBlock`s in document order. Used by
    /// the new editor's action gutters to wire per-block accepts.
    func allConflictBlocks() -> [ConflictBlock] {
        regions.compactMap { region in
            if case .conflict(let block) = region { return block }
            return nil
        }
    }

    /// Accepts LOCAL for a specific conflict block (by identity).
    /// Equivalent to placing the cursor on that block and calling
    /// `acceptLocal()` — implemented directly to skip the
    /// currentConflictIndex round-trip.
    func acceptLocal(for block: ConflictBlock) {
        guard let ordinal = ordinal(of: block) else { return }
        let saved = currentConflictIndex
        currentConflictIndex = ordinal
        acceptLocal()
        restoreCursor(saved: saved, after: ordinal)
    }

    /// Accepts REMOTE for a specific conflict block (by identity).
    func acceptRemote(for block: ConflictBlock) {
        guard let ordinal = ordinal(of: block) else { return }
        let saved = currentConflictIndex
        currentConflictIndex = ordinal
        acceptRemote()
        restoreCursor(saved: saved, after: ordinal)
    }

    /// Restores `currentConflictIndex` after a per-block accept took
    /// place at `acceptedOrdinal`. Compensates for the fact that
    /// resolving a conflict shifts the ordinal of every later conflict
    /// down by one.
    private func restoreCursor(saved: Int?, after acceptedOrdinal: Int) {
        guard let saved else { return }
        if saved < acceptedOrdinal {
            currentConflictIndex = saved
        } else if saved > acceptedOrdinal {
            currentConflictIndex = saved - 1
        }
        // If saved == acceptedOrdinal, leave reparse()'s post-state alone.
    }

    /// Appends a new conflict block at the end of the buffer. Called by
    /// the gutter context-menu "reset this conflict" action when the user
    /// wants to undo an accept without manually rewriting markers. The
    /// originals are passed in because the model no longer holds them once
    /// the conflict has been resolved. Note: this always appends to the end
    /// of the buffer regardless of the original position of the conflict —
    /// for use cases where positional fidelity is not required.
    func appendConflictBlock(
        originalLocal: String,
        originalRemote: String,
        originalBase: String?,
        originalLocalLabel: String,
        originalRemoteLabel: String
    ) {
        var marker = "<<<<<<< \(originalLocalLabel)\n"
        marker += originalLocal
        if !originalLocal.hasSuffix("\n") { marker += "\n" }
        if let base = originalBase, !base.isEmpty {
            marker += "||||||| ancestor\n"
            marker += base
            if !base.hasSuffix("\n") { marker += "\n" }
        }
        marker += "=======\n"
        marker += originalRemote
        if !originalRemote.hasSuffix("\n") { marker += "\n" }
        marker += ">>>>>>> \(originalRemoteLabel)\n"
        resultText.append(marker)
        reparse()
    }

    /// Pushes an edit on visual row `row` to the underlying region.
    /// Maps row -> (region index, sub-position) via the same layout
    /// algorithm the view uses, then rewrites that region's stored
    /// content. No-op for rows that are out of bounds or padding.
    /// Triggers `rebuildResultText()` so `resultText` stays in sync
    /// with the rewritten `regions`.
    func setRowContent(at row: Int, to content: String) {
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        guard row < layout.result.count else { return }
        var cursor = 0
        for (regionIndex, region) in regions.enumerated() {
            switch region {
            case .text(let text):
                let lineCount = Self.lineCount(of: text)
                if row < cursor + lineCount {
                    var lines = text.components(separatedBy: "\n")
                    let inside = row - cursor
                    if inside < lines.count {
                        lines[inside] = content
                    }
                    regions[regionIndex] = .text(lines.joined(separator: "\n"))
                    rebuildResultText()
                    return
                }
                cursor += lineCount
            case .conflict(let block):
                let localLineCount = Self.lineCount(of: block.local)
                let remoteLineCount = Self.lineCount(of: block.remote)
                if row < cursor + localLineCount {
                    var lines = block.local.components(separatedBy: "\n")
                    let inside = row - cursor
                    if inside < lines.count { lines[inside] = content }
                    let updated = ConflictBlock(
                        local: lines.joined(separator: "\n"),
                        base: block.base,
                        remote: block.remote,
                        localLabel: block.localLabel,
                        remoteLabel: block.remoteLabel,
                        lineRangeInMerged: block.lineRangeInMerged
                    )
                    regions[regionIndex] = .conflict(updated)
                    rebuildResultText()
                    return
                }
                if row < cursor + localLineCount + remoteLineCount {
                    var lines = block.remote.components(separatedBy: "\n")
                    let inside = row - cursor - localLineCount
                    if inside < lines.count { lines[inside] = content }
                    let updated = ConflictBlock(
                        local: block.local,
                        base: block.base,
                        remote: lines.joined(separator: "\n"),
                        localLabel: block.localLabel,
                        remoteLabel: block.remoteLabel,
                        lineRangeInMerged: block.lineRangeInMerged
                    )
                    regions[regionIndex] = .conflict(updated)
                    rebuildResultText()
                    return
                }
                cursor += localLineCount + remoteLineCount
            }
        }
    }

    /// Reconciles user edits in the RESULT pane back to the model's
    /// regions. Two strategies:
    ///
    /// 1. **Single-region edit (fast path):** find the longest common
    ///    prefix/suffix between the old buffer (rendered markerless,
    ///    same view the user sees) and the new buffer. The changed
    ///    range, when it falls entirely within a single region, is
    ///    attributed to that region — so typing a context line ABOVE
    ///    a conflict stays in the text region, doesn't leak into the
    ///    conflict's LOCAL hunk.
    ///
    /// 2. **Cross-region or ambiguous edit (slow path):** fall back to
    ///    the cursor-walking reconcile that distributes lines to
    ///    regions in order, with conflicts capped at their original
    ///    total. Last meaningful region absorbs extras.
    ///
    /// After mutation, `resultText` is rebuilt in MARKER form via
    /// `serializeRegionsWithMarkers` and `reparse()` is called so each
    /// block's `lineRangeInMerged` reflects the new line counts.
    func applyEditedFullText(_ newText: String, showBase: Bool = false) {
        let oldBuffer = renderMarkerlessBuffer(showBase: showBase)
        // Try the single-region fast path first.
        if applyEditedFullTextSingleRegion(newText: newText, oldBuffer: oldBuffer, showBase: showBase) {
            rebuildResultText()
            reparse()
            return
        }
        // Fall back to cursor-walking reconcile.
        applyEditedFullTextCursorWalk(newText, showBase: showBase)
        rebuildResultText()
        reparse()
    }

    /// Renders the same markerless stacked-hunk buffer the user sees
    /// in the RESULT pane. Used to compute prefix/suffix against the
    /// edited buffer.
    private func renderMarkerlessBuffer(showBase: Bool) -> String {
        var out = ""
        for region in regions {
            switch region {
            case .text(let t):
                out.append(t)
            case .conflict(let block):
                if !block.local.isEmpty {
                    out.append(block.local)
                    if !block.local.hasSuffix("\n") { out.append("\n") }
                }
                if showBase, let base = block.base, !base.isEmpty {
                    out.append(base)
                    if !base.hasSuffix("\n") { out.append("\n") }
                }
                if !block.remote.isEmpty {
                    out.append(block.remote)
                    if !block.remote.hasSuffix("\n") { out.append("\n") }
                }
            }
        }
        return out
    }

    /// Fast path: detects a single contiguous change between
    /// `oldBuffer` and `newText`, attributes it to one region, and
    /// returns `true` if it could handle the edit. Returns `false`
    /// when the change spans multiple regions (caller falls back).
    private func applyEditedFullTextSingleRegion(
        newText: String,
        oldBuffer: String,
        showBase: Bool
    ) -> Bool {
        let oldUTF16 = Array(oldBuffer.utf16)
        let newUTF16 = Array(newText.utf16)
        // Longest common prefix.
        var pre = 0
        while pre < oldUTF16.count, pre < newUTF16.count, oldUTF16[pre] == newUTF16[pre] {
            pre += 1
        }
        // Longest common suffix (bounded so prefix and suffix don't overlap).
        var suf = 0
        let oldRemaining = oldUTF16.count - pre
        let newRemaining = newUTF16.count - pre
        while suf < oldRemaining, suf < newRemaining,
              oldUTF16[oldUTF16.count - 1 - suf] == newUTF16[newUTF16.count - 1 - suf] {
            suf += 1
        }
        let oldChangedStart = pre
        let oldChangedEnd = oldUTF16.count - suf
        // Map UTF-16 offsets to region indices in the old buffer.
        guard let regionIdx = regionContainingUTF16Range(
            start: oldChangedStart,
            end: oldChangedEnd,
            in: oldBuffer,
            showBase: showBase
        ) else {
            return false // change spans multiple regions
        }
        // Slice the new lines for this region: take everything from
        // the region's start in the old buffer up to (region end +
        // (newText.length - oldText.length)).
        let oldRegionStart = regionUTF16Start(at: regionIdx, in: oldBuffer, showBase: showBase)
        let oldRegionEnd = regionUTF16End(at: regionIdx, in: oldBuffer, showBase: showBase)
        let delta = newUTF16.count - oldUTF16.count
        let newRegionStart = oldRegionStart
        let newRegionEnd = oldRegionEnd + delta
        guard newRegionStart >= 0, newRegionEnd <= newUTF16.count, newRegionStart <= newRegionEnd else {
            return false
        }
        let newRegionUTF16 = Array(newUTF16[newRegionStart ..< newRegionEnd])
        let newRegionString = String(decoding: newRegionUTF16, as: UTF16.self)
        // NEW: pass the within-region UTF-16 offset of the change so
        // rewriteRegion can route extras to the correct conflict half.
        let withinRegionOffset = oldChangedStart - oldRegionStart
        rewriteRegion(at: regionIdx, fromMarkerlessContent: newRegionString, showBase: showBase, editOffsetInOldRegion: withinRegionOffset)
        return true
    }

    /// Returns the region index whose UTF-16 range in the markerless
    /// rendering of the old buffer fully contains `[start, end)`.
    /// Nil if the range spans multiple regions or is out of bounds.
    private func regionContainingUTF16Range(
        start: Int,
        end: Int,
        in buffer: String,
        showBase: Bool
    ) -> Int? {
        guard end >= start else { return nil }
        var cursor = 0
        for (i, region) in regions.enumerated() {
            let length = regionRenderedUTF16Length(region, showBase: showBase)
            let regionEnd = cursor + length
            if start >= cursor, end <= regionEnd {
                return i
            }
            if start < regionEnd, end > regionEnd {
                return nil // straddles a boundary
            }
            cursor = regionEnd
        }
        // Edge: change at the very end of the buffer.
        if start == cursor, end == cursor, !regions.isEmpty {
            return regions.count - 1
        }
        return nil
    }

    private func regionUTF16Start(at index: Int, in buffer: String, showBase: Bool) -> Int {
        var cursor = 0
        for i in 0 ..< index {
            cursor += regionRenderedUTF16Length(regions[i], showBase: showBase)
        }
        return cursor
    }

    private func regionUTF16End(at index: Int, in buffer: String, showBase: Bool) -> Int {
        regionUTF16Start(at: index, in: buffer, showBase: showBase)
            + regionRenderedUTF16Length(regions[index], showBase: showBase)
    }

    private func regionRenderedUTF16Length(_ region: ConflictRegion, showBase: Bool) -> Int {
        switch region {
        case .text(let t):
            return (t as NSString).length
        case .conflict(let block):
            var len = 0
            if !block.local.isEmpty {
                len += (block.local as NSString).length
                if !block.local.hasSuffix("\n") { len += 1 }
            }
            if showBase, let base = block.base, !base.isEmpty {
                len += (base as NSString).length
                if !base.hasSuffix("\n") { len += 1 }
            }
            if !block.remote.isEmpty {
                len += (block.remote as NSString).length
                if !block.remote.hasSuffix("\n") { len += 1 }
            }
            return len
        }
    }

    /// Rewrites region at `index` using the new markerless content for
    /// that region. For `.text` regions, the content becomes the new
    /// text. For `.conflict` regions, splits the new content back into
    /// LOCAL / (BASE) / REMOTE — uses `editOffsetInOldRegion` (if
    /// provided) to determine which side absorbs any added lines.
    /// Without a hint, extras default to LOCAL (matches the slow
    /// path's behavior).
    private func rewriteRegion(at index: Int, fromMarkerlessContent content: String, showBase: Bool, editOffsetInOldRegion: Int? = nil) {
        let lines = Self.splitPreservingTrailingEmpty(content)
        let trailingNewline = content.hasSuffix("\n")
        switch regions[index] {
        case .text:
            regions[index] = .text(content)
        case .conflict(let block):
            let localCount = Self.lineCount(of: block.local)
            let baseCount = (showBase && block.base != nil) ? Self.lineCount(of: block.base ?? "") : 0
            let remoteCount = Self.lineCount(of: block.remote)
            let totalOriginal = localCount + baseCount + remoteCount
            let extras = max(0, lines.count - totalOriginal)
            // Decide which side absorbs extras based on edit offset.
            // The rendered region's UTF-16 layout is: LOCAL bytes ||
            // BASE bytes (if showBase) || REMOTE bytes.
            let localBytes = block.local.isEmpty ? 0
                : (block.local as NSString).length + (block.local.hasSuffix("\n") ? 0 : 1)
            let baseBytes: Int = {
                guard showBase, let b = block.base, !b.isEmpty else { return 0 }
                return (b as NSString).length + (b.hasSuffix("\n") ? 0 : 1)
            }()
            // Default: LOCAL absorbs extras. Override if the edit
            // offset points into BASE (treat as LOCAL — BASE is
            // immutable) or REMOTE.
            enum ExtrasTarget { case local, remote }
            let extrasTarget: ExtrasTarget = {
                guard let offset = editOffsetInOldRegion else { return .local }
                if offset <= localBytes { return .local }
                if offset <= localBytes + baseBytes { return .local } // BASE immutable
                return .remote
            }()
            let localTake: Int
            let remoteTake: Int
            let baseTake = min(baseCount, lines.count - localCount - remoteCount)
            switch extrasTarget {
            case .local:
                localTake = min(localCount + extras, max(0, lines.count - baseCount - remoteCount))
                remoteTake = max(0, lines.count - localTake - baseTake)
            case .remote:
                let remoteWithExtras = remoteCount + extras
                remoteTake = max(0, min(remoteWithExtras, lines.count - localCount - baseCount))
                localTake = max(0, lines.count - remoteTake - baseTake)
            }
            let localSlice = Array(lines[0 ..< min(localTake, lines.count)])
            let baseSliceStart = min(localTake, lines.count)
            let baseSliceEnd = min(baseSliceStart + baseTake, lines.count)
            let _ = Array(lines[baseSliceStart ..< baseSliceEnd]) // BASE unchanged
            let remoteSliceStart = baseSliceEnd
            let remoteSliceEnd = min(remoteSliceStart + remoteTake, lines.count)
            let remoteSlice = Array(lines[remoteSliceStart ..< remoteSliceEnd])
            let localText = localSlice.isEmpty ? "" : localSlice.joined(separator: "\n")
                + (block.local.hasSuffix("\n") || localTake < localCount || trailingNewline ? "\n" : "")
            let remoteText = remoteSlice.isEmpty ? "" : remoteSlice.joined(separator: "\n")
                + (block.remote.hasSuffix("\n") || remoteTake < remoteCount || trailingNewline ? "\n" : "")
            regions[index] = .conflict(ConflictBlock(
                local: localText,
                base: block.base,
                remote: remoteText,
                localLabel: block.localLabel,
                remoteLabel: block.remoteLabel,
                lineRangeInMerged: block.lineRangeInMerged
            ))
        }
    }

    /// Slow-path reconcile: the previous cursor-walking algorithm,
    /// used when the prefix/suffix detection couldn't isolate the
    /// change to a single region. See the original applyEditedFullText
    /// for the full rationale.
    private func applyEditedFullTextCursorWalk(_ newText: String, showBase: Bool) {
        let newLines = Self.splitPreservingTrailingEmpty(newText)
        var cursor = 0
        // Treat trailing zero-linecount text regions (e.g. the empty string
        // the parser emits for a file whose last char is "\n") as padding:
        // the last MEANINGFUL region absorbs any extra lines the user typed.
        let lastMeaningfulIndex: Int = {
            var idx = regions.count - 1
            while idx > 0 {
                let r = regions[idx]
                if case .text(let t) = r, Self.lineCount(of: t) == 0 { idx -= 1 }
                else { break }
            }
            return idx
        }()
        for (regionIndex, region) in regions.enumerated() {
            let isLast = regionIndex == lastMeaningfulIndex
            switch region {
            case .text(let text):
                let originalCount = Self.lineCount(of: text)
                let take = isLast
                    ? max(0, newLines.count - cursor)
                    : min(originalCount, max(0, newLines.count - cursor))
                let safeCursor = min(cursor, newLines.count)
                let safeEnd = min(safeCursor + take, newLines.count)
                let slice = Array(newLines[safeCursor ..< safeEnd])
                let trailingNewline = text.hasSuffix("\n")
                    || take < originalCount
                    || (isLast && newText.hasSuffix("\n"))
                let rebuilt = slice.joined(separator: "\n") + (trailingNewline ? "\n" : "")
                regions[regionIndex] = .text(rebuilt)
                cursor += take
            case .conflict(let block):
                let localCount = Self.lineCount(of: block.local)
                let baseCount = (showBase && block.base != nil)
                    ? Self.lineCount(of: block.base ?? "") : 0
                let remoteCount = Self.lineCount(of: block.remote)
                let totalOriginal = localCount + baseCount + remoteCount
                // For non-last regions: take exactly the original total.
                // For the last region: take everything remaining.
                let totalTake = isLast
                    ? max(0, newLines.count - cursor)
                    : min(totalOriginal, max(0, newLines.count - cursor))
                // Distribute the take across LOCAL / BASE / REMOTE.
                // Any extras (totalTake > totalOriginal) go to LOCAL.
                let extras = max(0, totalTake - totalOriginal)
                let localTake = min(localCount + extras, totalTake)
                let baseTake = min(baseCount, totalTake - localTake)
                let remoteTake = max(0, totalTake - localTake - baseTake)
                let safeCursor = min(cursor, newLines.count)
                // LOCAL slice
                let localEnd = min(safeCursor + localTake, newLines.count)
                let localSlice = Array(newLines[safeCursor ..< localEnd])
                let localJoined = localSlice.joined(separator: "\n")
                let localText = localJoined.isEmpty ? "" : localJoined
                    + (block.local.hasSuffix("\n") || localTake < localCount ? "\n" : "")
                // BASE slice (skipped — block.base is preserved as-is;
                // editing the BASE hunk isn't supported in v1 because
                // BASE is the common ancestor, not a side to merge).
                let baseEnd = min(localEnd + baseTake, newLines.count)
                _ = Array(newLines[localEnd ..< baseEnd])
                // REMOTE slice
                let remoteEnd = min(baseEnd + remoteTake, newLines.count)
                let remoteSlice = Array(newLines[baseEnd ..< remoteEnd])
                let remoteJoined = remoteSlice.joined(separator: "\n")
                let remoteText = remoteJoined.isEmpty ? "" : remoteJoined
                    + (block.remote.hasSuffix("\n") || remoteTake < remoteCount ? "\n" : "")
                regions[regionIndex] = .conflict(ConflictBlock(
                    local: localText,
                    base: block.base, // unchanged — BASE is immutable in the UI
                    remote: remoteText,
                    localLabel: block.localLabel,
                    remoteLabel: block.remoteLabel,
                    lineRangeInMerged: block.lineRangeInMerged
                ))
                cursor += totalTake
            }
        }
    }

    /// Same semantics as `MergeRegionVisualLayout.splitPreservingTrailingEmpty`,
    /// duplicated here to avoid making the layout's helper public.
    private static func splitPreservingTrailingEmpty(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Re-emits `regions` back into marker form for in-memory storage
    /// in `resultText`. Used by `setRowContent` so user edits don't
    /// destroy the marker structure the accept methods rely on for
    /// line-range lookup. Distinct from `flatTextForWriting()`, which
    /// strips markers for the on-disk write at `markFileResolved`.
    private func serializeRegionsWithMarkers() -> String {
        var out = ""
        for region in regions {
            switch region {
            case .text(let t):
                out.append(t)
            case .conflict(let block):
                out.append("<<<<<<< \(block.localLabel)\n")
                out.append(block.local)
                if !block.local.isEmpty, !block.local.hasSuffix("\n") { out.append("\n") }
                if let base = block.base, !base.isEmpty {
                    out.append("||||||| ancestor\n")
                    out.append(base)
                    if !base.hasSuffix("\n") { out.append("\n") }
                }
                out.append("=======\n")
                out.append(block.remote)
                if !block.remote.isEmpty, !block.remote.hasSuffix("\n") { out.append("\n") }
                out.append(">>>>>>> \(block.remoteLabel)\n")
            }
        }
        return out
    }

    /// Re-derives `resultText` from the current `regions` preserving
    /// marker structure so subsequent `acceptLocal()` / `acceptRemote()`
    /// calls can still find conflict blocks via line-range parsing.
    /// `reparse()` must NOT be called here — it would clobber `regions`
    /// with a fresh parse and lose any mid-edit state.
    private func rebuildResultText() {
        resultText = serializeRegionsWithMarkers()
    }

    /// Derives the final on-disk file content from the current regions
    /// without conflict markers. Called by the new view layer to
    /// serialize edits back to disk on `markFileResolved`. Conflicts
    /// that haven't been explicitly resolved (still in stacked state)
    /// are serialized as LOCAL hunk followed by REMOTE hunk — same as
    /// today's "Use BOTH".
    func flatTextForWriting() -> String {
        var out = ""
        for region in regions {
            switch region {
            case .text(let t): out.append(t)
            case .conflict(let block):
                if !block.local.isEmpty {
                    out.append(block.local)
                    if !block.local.hasSuffix("\n") { out.append("\n") }
                }
                if !block.remote.isEmpty {
                    out.append(block.remote)
                    if !block.remote.hasSuffix("\n") { out.append("\n") }
                }
            }
        }
        return out
    }

    /// Replaces the current conflict's marker block with LOCAL followed by REMOTE.
    func acceptBoth() {
        guard let ordinal = currentConflictIndex,
              let regionIdx = conflictRegionIndex(forConflictOrdinal: ordinal),
              case .conflict(let block) = regions[regionIdx]
        else { return }
        replaceCurrentConflictBlock(with: block.local + block.remote)
    }

    /// Replaces the current conflict region in `resultText` with `replacement`
    /// (which should already include any trailing newlines required). Updates
    /// regions + currentConflictIndex.
    private func replaceCurrentConflictBlock(with replacement: String) {
        guard let ordinal = currentConflictIndex,
              let regionIdx = conflictRegionIndex(forConflictOrdinal: ordinal),
              case .conflict(let block) = regions[regionIdx]
        else { return }

        // Find the substring range of the marker block in resultText.
        // We use the 0-indexed line range stored on the ConflictBlock:
        //   lineRangeInMerged covers the `<<<<<<<` line through `>>>>>>>` line inclusive.
        let lines = resultText.split(separator: "\n", omittingEmptySubsequences: false)
        let lower = block.lineRangeInMerged.lowerBound
        let upper = block.lineRangeInMerged.upperBound
        guard upper < lines.count else { return }

        // Rebuild resultText with the marker-block lines replaced by `replacement`.
        var head = lines[0..<lower].map(String.init).joined(separator: "\n")
        if !head.isEmpty { head += "\n" }
        let tail = lines[(upper + 1)..<lines.count].map(String.init).joined(separator: "\n")
        let trimmedReplacement = replacement.hasSuffix("\n") ? replacement : replacement + "\n"
        resultText = head + trimmedReplacement + tail

        reparse()
    }

    // MARK: - Navigation

    /// Jumps to the next unresolved conflict, clamping at the last one.
    func nextConflict() {
        let total = conflictCount
        guard total > 0 else {
            currentConflictIndex = nil
            return
        }
        let current = currentConflictIndex ?? -1
        currentConflictIndex = min(current + 1, total - 1)
    }

    /// Jumps to the previous unresolved conflict, clamping at the first one.
    func previousConflict() {
        let total = conflictCount
        guard total > 0 else {
            currentConflictIndex = nil
            return
        }
        let current = currentConflictIndex ?? total
        currentConflictIndex = max(current - 1, 0)
    }

    // MARK: - Resolve

    /// Writes `resultText` to disk and stages the file via `GitService.markResolved`.
    /// Throws if either step fails.
    ///
    /// The write step is skipped in two cases where `resultText` is
    /// intentionally empty and writing would corrupt the resolution:
    ///   - Binary conflicts: the editor does not show binary bytes. The
    ///     on-disk file is whatever the user chose via the right-pane
    ///     Use ours / Use theirs context menu.
    ///   - Missing files: delete-side conflicts (e.g., `bothDeleted` from
    ///     a rename/rename, or any path the user removed via Keep deleted)
    ///     have no working-tree entry. Writing would recreate the file as
    ///     a zero-byte addition and `git add` would stage it as an
    ///     addition, undoing the deletion.
    /// In both cases we simply stage whatever is currently in the index
    /// (or the missing-file state) via `git add`.
    func markFileResolved() async throws {
        let absolute = worktreePath.appendingPathComponent(relativePath)
        let exists = FileManager.default.fileExists(atPath: absolute.path)
        if conflictedFile?.isBinary != true, exists {
            try flatTextForWriting().write(to: absolute, atomically: true, encoding: .utf8)
        }
        try await gitService.markResolved(
            worktreePath: worktreePath,
            relativePath: relativePath
        )
    }

    /// Mirrors `MergeRegionVisualLayout.splitPreservingTrailingEmpty`:
    /// 0 rows for an empty string, otherwise the number of physical
    /// lines (treating a trailing newline as terminator, not separator).
    private static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let parts = text.components(separatedBy: "\n")
        return text.hasSuffix("\n") ? parts.count - 1 : parts.count
    }

    /// Deterministic stable identity for a `ConflictBlock`. Used as the key
    /// for `annotations` so cached explanations follow the block when other
    /// conflicts get resolved and the ordinal numbering shifts.
    static func annotationKey(for block: ConflictBlock) -> String {
        "\(block.local)\n<<<<<<<<\n\(block.base ?? "")\n========\n\(block.remote)"
    }

    /// Records a one-line agent annotation for `block`. Called by
    /// `MergeConflictTabView` after a successful `MergeAgent.explainConflict`
    /// round-trip.
    func setAnnotation(_ text: String, for block: ConflictBlock) {
        annotations[Self.annotationKey(for: block)] = text
    }

    /// Returns the cached annotation for `block`, or nil if not cached.
    func annotation(for block: ConflictBlock) -> String? {
        annotations[Self.annotationKey(for: block)]
    }

    // MARK: - Agent assist

    /// Asks the agent to summarize the current conflict in one sentence and
    /// caches the result in `annotations`, keyed by block content. No-op if
    /// there's no current conflict, no agent, the annotation is already
    /// cached, or a request for the same block is already in flight.
    /// Errors are silent (no UI).
    func explainCurrentConflict(using agent: AgentDefinition, language: String?) async {
        guard let ordinal = currentConflictIndex,
              let regionIdx = conflictRegionIndex(forConflictOrdinal: ordinal),
              case .conflict(let block) = regions[regionIdx]
        else { return }
        let key = Self.annotationKey(for: block)
        // De-dupe: cache hit or already-in-flight for the same block → bail.
        guard annotations[key] == nil, !explainInFlight.contains(key) else { return }
        explainInFlight.insert(key)
        defer { explainInFlight.remove(key) }
        do {
            let sentence = try await MergeAgent.explainConflict(
                agent: agent,
                block: block,
                language: language
            )
            if !sentence.isEmpty {
                setAnnotation(sentence, for: block)
            }
        } catch {
            logger.error("explain failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks the agent to propose a full-file resolution. On success, stashes
    /// the proposal in `agentProposal` for the view to render as a diff
    /// overlay. Errors leave `agentProposal` nil.
    ///
    /// If `load()` runs while this request is in flight (e.g. tab re-focused
    /// for a fresh conflict on the same path), the late response is dropped:
    /// applying it would clobber the freshly loaded buffer with stale content.
    /// We detect that via the `loadGeneration` token captured at request start.
    func requestAgentResolveFile(
        using agent: AgentDefinition,
        template: String,
        language: String?
    ) async {
        guard let file = conflictedFile else { return }
        let startGeneration = loadGeneration
        agentBusy = true
        defer {
            if loadGeneration == startGeneration {
                agentBusy = false
            }
        }
        do {
            let proposal = try await MergeAgent.resolveFile(
                agent: agent,
                template: template,
                filePath: relativePath,
                local: file.local ?? "",
                base: file.base,
                remote: file.remote ?? "",
                mergedWithMarkers: resultText,
                language: language
            )
            guard loadGeneration == startGeneration else { return }
            agentProposal = proposal
        } catch {
            guard loadGeneration == startGeneration else { return }
            agentProposal = nil
            logger.error("resolveFile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Replaces `resultText` with the pending `agentProposal` and clears it.
    /// No-op when there's no proposal.
    func applyAgentProposal() {
        guard let proposal = agentProposal else { return }
        resultText = proposal
        agentProposal = nil
        reparse()
    }

    /// Discards the pending agent proposal without changing `resultText`.
    func discardAgentProposal() {
        agentProposal = nil
    }

    /// Test-only setter so unit tests can stage a proposal without invoking
    /// a real agent. Marked `internal` (default) and named to make its
    /// test-only intent obvious.
    func setAgentProposalForTesting(_ proposal: String) {
        agentProposal = proposal
    }
}
