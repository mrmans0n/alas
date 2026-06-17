import Foundation

struct DiffInlineAnnotation: Identifiable, Equatable {
    let id: String
    let checkName: String
    let newLine: Int
    let level: CheckAnnotation.AnnotationLevel
    let message: String
    let rawDetails: String?
}

extension DiffInlineAnnotation {
    static func from(_ annotation: CheckAnnotation) -> DiffInlineAnnotation {
        DiffInlineAnnotation(
            id: annotation.id,
            checkName: annotation.checkName,
            newLine: annotation.startLine,
            level: annotation.level,
            message: annotation.message,
            rawDetails: annotation.rawDetails
        )
    }
}

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
        case annotation(DiffInlineAnnotation)

        var id: String {
            switch self {
            case .rows(let seg): return seg.id
            case .thread(let t): return "thread-\(t.id)"
            case .annotation(let a): return "annotation-\(a.id)"
            }
        }
    }

    static func blocks(
        visibleRows: [DiffDisplayRow],
        threads: [DiffInlineCommentThread],
        annotations: [DiffInlineAnnotation] = []
    ) -> [Block] {
        guard !visibleRows.isEmpty else { return [] }
        guard !threads.isEmpty, !annotations.isEmpty else {
            if threads.isEmpty && annotations.isEmpty {
                return [.rows(RowSegment(id: "seg-0", rows: visibleRows))]
            }
            // Fall through to general logic with only threads or only annotations
            return blocksInternal(visibleRows: visibleRows, threads: threads, annotations: annotations)
        }
        return blocksInternal(visibleRows: visibleRows, threads: threads, annotations: annotations)
    }

    private static func blocksInternal(
        visibleRows: [DiffDisplayRow],
        threads: [DiffInlineCommentThread],
        annotations: [DiffInlineAnnotation]
    ) -> [Block] {
        // Build map from row index → threads anchored after that row.
        // A thread matches the first row where row.new?.anchor.newLine == thread.newLine.
        var threadsByRowIndex: [Int: [DiffInlineCommentThread]] = [:]
        for thread in threads {
            if let rowIndex = visibleRows.firstIndex(where: { $0.new?.anchor.newLine == thread.newLine }) {
                threadsByRowIndex[rowIndex, default: []].append(thread)
            }
            // threads with no matching row are dropped
        }

        var annotationsByRowIndex: [Int: [DiffInlineAnnotation]] = [:]
        for annotation in annotations {
            if let rowIndex = visibleRows.firstIndex(where: { $0.new?.anchor.newLine == annotation.newLine }) {
                annotationsByRowIndex[rowIndex, default: []].append(annotation)
            }
            // annotations with no matching row are dropped
        }

        var result: [Block] = []
        var current: [DiffDisplayRow] = []
        var segmentIndex = 0

        for (rowIndex, row) in visibleRows.enumerated() {
            current.append(row)
            let rowThreads = threadsByRowIndex[rowIndex]
            let rowAnnotations = annotationsByRowIndex[rowIndex]
            if rowThreads != nil || rowAnnotations != nil {
                result.append(.rows(RowSegment(id: "seg-\(segmentIndex)", rows: current)))
                segmentIndex += 1
                current = []
                for thread in rowThreads ?? [] {
                    result.append(.thread(thread))
                }
                for annotation in rowAnnotations ?? [] {
                    result.append(.annotation(annotation))
                }
            }
        }

        if !current.isEmpty {
            result.append(.rows(RowSegment(id: "seg-\(segmentIndex)", rows: current)))
        }

        return result
    }
}
