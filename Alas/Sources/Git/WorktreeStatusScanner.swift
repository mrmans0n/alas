import Foundation

/// Computes `WorktreeDirtyState` by running `git status` across worktrees.
///
/// The parsing half is a pure static function so the porcelain format — which
/// is where the bugs live — is testable without git, a filesystem, or a
/// subprocess.
enum WorktreeStatusScanner {
    /// Parses `git status --porcelain=v1 -z` output.
    ///
    /// Each record is `XY <path>` terminated by NUL. Rename and copy records
    /// carry the original path in a following NUL-terminated field, which is
    /// consumed without being counted as another changed file.
    nonisolated static func parse(porcelainZ output: String) -> WorktreeDirtyState {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // git terminates the final record too, leaving a trailing empty field.
        if fields.last?.isEmpty == true { fields.removeLast() }

        var fileCount = 0
        var conflictCount = 0
        var index = 0

        while index < fields.count {
            let record = fields[index]
            index += 1
            // "XY " plus at least one path character.
            guard record.count >= 3 else { continue }

            let code = String(record.prefix(2))
            fileCount += 1
            if isUnmerged(code) { conflictCount += 1 }

            // Renames and copies spend a second field on their source path.
            if code.hasPrefix("R") || code.hasPrefix("C") { index += 1 }
        }

        guard fileCount > 0 else { return .clean }
        return .dirty(fileCount: fileCount, conflictCount: conflictCount)
    }

    /// Unmerged (conflicted) porcelain codes: any code containing `U`, plus
    /// `AA` (both added) and `DD` (both deleted), which contain none.
    nonisolated static func isUnmerged(_ code: String) -> Bool {
        code.contains("U") || code == "AA" || code == "DD"
    }
}
