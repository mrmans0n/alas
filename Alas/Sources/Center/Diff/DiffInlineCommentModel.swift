import Foundation

struct DiffInlineCommentThread: Identifiable, Equatable {
    let id: String
    let filePath: String
    let newLine: Int
    let isResolved: Bool
    let isOutdated: Bool
    let comments: [DiffInlineComment]
}

struct DiffInlineComment: Identifiable, Equatable {
    let id: String
    let author: String
    let body: String
    var viewerCanUpdate: Bool = false
    var viewerCanDelete: Bool = false
}

enum DiffInlineCommentLayout {
    struct RowSegment: Identifiable {
        let id: String
        let rows: [DiffDisplayRow]
    }

    enum Block: Identifiable {
        case rows(RowSegment)
        case thread(DiffInlineCommentThread)

        var id: String {
            switch self {
            case .rows(let seg): return seg.id
            case .thread(let t): return "thread-\(t.id)"
            }
        }
    }

    static func blocks(
        visibleRows: [DiffDisplayRow],
        threads: [DiffInlineCommentThread]
    ) -> [Block] {
        guard !visibleRows.isEmpty else { return [] }
        guard !threads.isEmpty else {
            return [.rows(RowSegment(id: "seg-0", rows: visibleRows))]
        }

        // Build map from row index → threads anchored after that row.
        // A thread matches the first row where row.new?.anchor.newLine == thread.newLine.
        var threadsByRowIndex: [Int: [DiffInlineCommentThread]] = [:]
        for thread in threads {
            if let rowIndex = visibleRows.firstIndex(where: { $0.new?.anchor.newLine == thread.newLine }) {
                threadsByRowIndex[rowIndex, default: []].append(thread)
            }
            // threads with no matching row are dropped
        }

        var result: [Block] = []
        var current: [DiffDisplayRow] = []
        var segmentIndex = 0

        for (rowIndex, row) in visibleRows.enumerated() {
            current.append(row)
            if let rowThreads = threadsByRowIndex[rowIndex] {
                result.append(.rows(RowSegment(id: "seg-\(segmentIndex)", rows: current)))
                segmentIndex += 1
                current = []
                for thread in rowThreads {
                    result.append(.thread(thread))
                }
            }
        }

        if !current.isEmpty {
            result.append(.rows(RowSegment(id: "seg-\(segmentIndex)", rows: current)))
        }

        return result
    }
}
