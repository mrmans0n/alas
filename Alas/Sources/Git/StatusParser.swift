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
                let status = mapXY(xy)
                let path = tokens[8]
                result.append(ChangedFile(path: path, status: status, add: 0, del: 0, renameFrom: nil))
                i += 1
            } else if line.hasPrefix("2 ") {
                // Rename: this entry's path, then a follow-up record with the original path.
                let tokens = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true).map(String.init)
                guard tokens.count >= 10, i + 1 < parts.count else { i += 1
                continue }
                let path = tokens[9]
                let from = parts[i + 1]
                result.append(ChangedFile(path: path, status: "R", add: 0, del: 0, renameFrom: from))
                i += 2
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                result.append(ChangedFile(path: path, status: "A", add: 0, del: 0, renameFrom: nil))
                i += 1
            } else if line.hasPrefix("u ") {
                // unmerged: surface as M for v1
                let tokens = line.split(separator: " ").map(String.init)
                if let path = tokens.last {
                    result.append(ChangedFile(path: path, status: "M", add: 0, del: 0, renameFrom: nil))
                }
                i += 1
            } else {
                i += 1
            }
        }
        return result
    }

    private static func mapXY(_ xy: String) -> String {
        // Two chars: index status, worktree status. Prefer worktree status.
        guard xy.count == 2 else { return "M" }
        let idx = xy.index(xy.startIndex, offsetBy: 1)
        let wt = xy[idx]
        switch wt {
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "M", ".": return xy.first == "A" ? "A"
                            : xy.first == "D" ? "D"
                            : xy.first == "R" ? "R"
                            : "M"
        default: return "M"
        }
    }
}
