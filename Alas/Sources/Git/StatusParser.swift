import Foundation

enum StatusParser {
    /// Parses `git status --porcelain=v2 -z` into [ChangedFile]. Counts default to 0;
    /// callers fill them in via NumstatParser.
    static func parse(_ raw: String) throws -> [ChangedFile] {
        var result: [ChangedFile] = []
        // Split on NUL but be careful: rename entries consume two records.
        let parts = raw.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < parts.count {
            let line = parts[i]
            if line.isEmpty { i += 1
            continue }
            if line.hasPrefix("1 ") {
                let tokens = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
                guard tokens.count >= 9 else { i += 1
                continue }
                let xy = tokens[1]
                let path = tokens[8]
                result.append(contentsOf: entriesForXY(xy, path: path, renameFrom: nil))
                i += 1
            } else if line.hasPrefix("2 ") {
                // Rename: this entry's path, then a follow-up record with the original path.
                let tokens = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true).map(String.init)
                guard tokens.count >= 10, i + 1 < parts.count else { i += 1
                continue }
                let xy = tokens[1]
                let path = tokens[9]
                let from = parts[i + 1]
                result.append(contentsOf: entriesForXY(xy, path: path, renameFrom: from))
                i += 2
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                result.append(ChangedFile(path: path, status: "A", stage: .unstaged, add: 0, del: 0, renameFrom: nil))
                i += 1
            } else if line.hasPrefix("u ") {
                // unmerged: surface as M for v1
                let tokens = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true).map(String.init)
                if tokens.count >= 11 {
                    let path = tokens[10]
                    result.append(ChangedFile(path: path, status: "M", stage: .unstaged, add: 0, del: 0, renameFrom: nil))
                }
                i += 1
            } else {
                i += 1
            }
        }
        return result
    }

    private static func entriesForXY(_ xy: String, path: String, renameFrom: String?) -> [ChangedFile] {
        guard xy.count == 2 else {
            return [ChangedFile(path: path, status: "M", stage: .unstaged, add: 0, del: 0, renameFrom: renameFrom)]
        }

        let indexStatus = xy[xy.startIndex]
        let worktreeStatus = xy[xy.index(after: xy.startIndex)]
        var entries: [ChangedFile] = []

        if indexStatus != "." {
            entries.append(ChangedFile(
                path: path,
                status: mapStatus(indexStatus, fallback: "M"),
                stage: .staged,
                add: 0,
                del: 0,
                renameFrom: indexStatus == "R" ? renameFrom : nil
            ))
        }

        if worktreeStatus != "." {
            entries.append(ChangedFile(
                path: path,
                status: mapStatus(worktreeStatus, fallback: "M"),
                stage: .unstaged,
                add: 0,
                del: 0,
                renameFrom: nil
            ))
        }

        if entries.isEmpty {
            entries.append(ChangedFile(path: path, status: "M", stage: .unstaged, add: 0, del: 0, renameFrom: renameFrom))
        }
        return entries
    }

    private static func mapStatus(_ status: Character, fallback: String) -> String {
        switch status {
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "M": return "M"
        default: return fallback
        }
    }
}
