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
    /// Per-conflict-ordinal one-line annotation populated by the agent.
    /// Cached for the lifetime of the model (cleared on `load()`).
    private(set) var annotations: [Int: String] = [:]
    /// Conflict count at the moment `load()` last succeeded. Used by the
    /// minimap to show progress (resolved vs total). Cleared (set to 0)
    /// on `load()` failure.
    private(set) var initialConflictCount: Int = 0

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

    /// Re-loads the conflicted file's three sides and re-parses the on-disk
    /// merged buffer. Safe to call repeatedly.
    func load() async {
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
            self.loadError = nil
        } catch {
            self.conflictedFile = nil
            self.regions = []
            self.resultText = ""
            self.currentConflictIndex = nil
            self.initialConflictCount = 0
            self.annotations = [:]
            self.loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            logger.error("merge-conflict load failed: \(self.loadError ?? "", privacy: .public)")
        }
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
            try resultText.write(to: absolute, atomically: true, encoding: .utf8)
        }
        try await gitService.markResolved(
            worktreePath: worktreePath,
            relativePath: relativePath
        )
    }

    /// Records a one-line agent annotation for the conflict at `ordinal`.
    /// Called by `MergeConflictTabView` after a successful `MergeAgent.explainConflict` round-trip.
    func setAnnotation(_ text: String, forConflictOrdinal ordinal: Int) {
        annotations[ordinal] = text
    }
}
