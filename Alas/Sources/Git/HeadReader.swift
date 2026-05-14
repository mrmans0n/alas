import Foundation

/// Result of parsing a git HEAD file.
enum HeadValue: Equatable {
    case branch(String)   // "ref: refs/heads/foo" → "foo"
    case detached         // 40-char hex SHA
}

/// Reads and parses a git HEAD file from disk without invoking `git`.
/// Used on the auto-refresh fast path so a branch flip doesn't spawn a
/// `git worktree list` and doesn't touch any file git might lock.
enum HeadReader {
    private static let refPrefix = "ref: refs/heads/"

    static func read(headFile: URL) -> HeadValue? {
        guard let raw = try? String(contentsOf: headFile, encoding: .utf8) else {
            return nil
        }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(refPrefix) {
            let branch = String(line.dropFirst(refPrefix.count))
            return branch.isEmpty ? nil : .branch(branch)
        }
        if isHexSHA(line) { return .detached }
        return nil
    }

    private static func isHexSHA(_ s: String) -> Bool {
        guard s.count == 40 else { return false }
        return s.allSatisfy { c in
            (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
        }
    }
}
