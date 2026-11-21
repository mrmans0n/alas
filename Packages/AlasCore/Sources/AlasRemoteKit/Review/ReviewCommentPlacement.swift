import Foundation

public struct ReviewPlaceable: Equatable, Sendable {
    public let id: String
    public let side: String?
    public let line: Int?
    public let endLine: Int?

    public init(id: String, side: String?, line: Int?, endLine: Int?) {
        self.id = id
        self.side = side
        self.line = line
        self.endLine = endLine
    }
}

public enum ReviewCommentPlacement {
    /// Row index (into `ReviewLayout.rows(for:folded:false)`) after which each comment goes;
    /// nil = top of file, shown as Outdated.
    public static func place(_ items: [ReviewPlaceable], in hunks: [RemoteDiffHunk]) -> [String: Int?] {
        var result: [String: Int?] = [:]
        for item in items {
            result[item.id] = .some(row(for: item, in: hunks))
        }
        return result
    }

    private static func row(for item: ReviewPlaceable, in hunks: [RemoteDiffHunk]) -> Int? {
        guard let side = item.side, let target = item.endLine ?? item.line else { return nil }
        var index = 0
        for hunk in hunks {
            index += 1
            for line in hunk.lines {
                if (side == "new" ? line.newNumber : line.oldNumber) == target { return index }
                index += 1
            }
        }
        return nil
    }
}
