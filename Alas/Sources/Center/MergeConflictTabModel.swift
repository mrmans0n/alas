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
            self.loadError = nil
        } catch {
            self.conflictedFile = nil
            self.regions = []
            self.resultText = ""
            self.currentConflictIndex = nil
            self.loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            logger.error("merge-conflict load failed: \(self.loadError ?? "", privacy: .public)")
        }
    }

    /// Re-parses `resultText` and updates `regions` + `currentConflictIndex`.
    /// Call after any mutation of `resultText` (typed by user or via accept actions).
    func reparse() {
        regions = ConflictMarkerParser.parse(resultText)
        if let idx = currentConflictIndex, conflictRegionIndex(forConflictOrdinal: idx) == nil {
            // The current conflict was resolved; move to the next unresolved one
            // (or nil when none remain).
            currentConflictIndex = firstConflictIndex()
        } else if currentConflictIndex == nil {
            currentConflictIndex = firstConflictIndex()
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
    /// Marked `internal` (default) so Task 4's extension can call it.
    func firstConflictIndex() -> Int? {
        var ord = 0
        for r in regions where isConflict(r) {
            return ord
        }
        _ = ord
        return nil
    }
}
