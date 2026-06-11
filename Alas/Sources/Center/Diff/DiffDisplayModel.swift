import Foundation

enum DiffLineSide: Int, Codable, Equatable, Comparable, Hashable {
    case old
    case new
    case paired

    static func < (lhs: DiffLineSide, rhs: DiffLineSide) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DiffLineAnchor: Codable, Equatable, Comparable, Hashable {
    let filePath: String
    let hunkIndex: Int
    let rowIndex: Int
    let side: DiffLineSide
    let oldLine: Int?
    let newLine: Int?

    static func < (lhs: DiffLineAnchor, rhs: DiffLineAnchor) -> Bool {
        if lhs.filePath != rhs.filePath {
            return lhs.filePath < rhs.filePath
        }

        if lhs.hunkIndex != rhs.hunkIndex {
            return lhs.hunkIndex < rhs.hunkIndex
        }

        if lhs.rowIndex != rhs.rowIndex {
            return lhs.rowIndex < rhs.rowIndex
        }

        if lhs.side != rhs.side {
            return lhs.side < rhs.side
        }

        let lhsOldLine = lhs.oldLine ?? 0
        let rhsOldLine = rhs.oldLine ?? 0
        if lhsOldLine != rhsOldLine {
            return lhsOldLine < rhsOldLine
        }

        return (lhs.newLine ?? 0) < (rhs.newLine ?? 0)
    }
}

struct DiffSelectionRange: Equatable {
    let first: DiffLineAnchor
    let last: DiffLineAnchor

    var normalized: ClosedRange<DiffLineAnchor> {
        first <= last ? first...last : last...first
    }

    func contains(_ anchor: DiffLineAnchor) -> Bool {
        normalized.contains(anchor)
    }
}

struct DiffInlineSpan: Codable, Equatable, Hashable {
    let start: Int
    let length: Int

    func text(in string: String) -> String {
        let nsString = string as NSString
        let location = max(0, min(start, nsString.length))
        let end = max(location, min(start + length, nsString.length))
        return nsString.substring(with: NSRange(location: location, length: end - location))
    }
}

struct DiffDisplayLine: Identifiable, Equatable {
    let id: String
    let anchor: DiffLineAnchor
    let text: String
    let lineNumber: Int?
    let kind: ParsedDiff.Hunk.Line.Kind
    let inlineSpans: [DiffInlineSpan]
    let noTrailingNewline: Bool
}

struct DiffDisplayRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case context
        case add
        case delete
        case replacement
        case collapsed
    }

    let id: String
    let kind: Kind
    let old: DiffDisplayLine?
    let new: DiffDisplayLine?
    let collapsedLineCount: Int
}

struct DiffDisplayGroup: Identifiable, Equatable {
    let id: String
    let header: String
    let sourceHunk: ParsedDiff.Hunk
    let rows: [DiffDisplayRow]
}

struct DiffDisplayModel: Equatable {
    let filePath: String
    let groups: [DiffDisplayGroup]
}
