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

struct DiffContextExpansionKey: Codable, Equatable, Hashable, Sendable {
    let groupID: String
    let boundary: DiffContextBoundary
}

enum DiffContextBoundary: String, Codable, Equatable, Hashable, Sendable {
    case above
    case below
}

struct DiffContextExpansionRow: Codable, Equatable, Hashable, Sendable {
    let key: DiffContextExpansionKey
    let boundary: DiffContextBoundary
    let remainingLineCount: Int
}

struct DiffDisplayRow: Identifiable, Equatable {
    enum Kind: Equatable, Hashable {
        case context
        case add
        case delete
        case replacement
        case collapsed
        case expandedContext
        case expandableContext
    }

    let id: String
    let kind: Kind
    let old: DiffDisplayLine?
    let new: DiffDisplayLine?
    let collapsedLineCount: Int
    let collapsedRows: [DiffDisplayRow]
    var contextExpansion: DiffContextExpansionRow?

    init(
        id: String,
        kind: Kind,
        old: DiffDisplayLine?,
        new: DiffDisplayLine?,
        collapsedLineCount: Int,
        collapsedRows: [DiffDisplayRow] = [],
        contextExpansion: DiffContextExpansionRow? = nil
    ) {
        self.id = id
        self.kind = kind
        self.old = old
        self.new = new
        self.collapsedLineCount = collapsedLineCount
        self.collapsedRows = collapsedRows
        self.contextExpansion = contextExpansion
    }
}

struct DiffDisplayGroup: Identifiable, Equatable {
    let id: String
    let header: String
    let sourceHunk: ParsedDiff.Hunk
    let rows: [DiffDisplayRow]

    /// Full-fidelity content fingerprint (row/line identity, text, kinds,
    /// inline spans, collapse structure). Precomputed once at build time and
    /// read in O(1) so the render-context cache key never has to walk every
    /// row on each SwiftUI body pass.
    let contentHash: Int
    /// Coarse structural fingerprint (row identity + line numbers + collapse
    /// counts). Used for `.onChange` state-reset signals that only care about
    /// structural changes, not pure text edits.
    let structuralHash: Int
    /// Extent of the old/new side of the source hunk. Precomputed to avoid an
    /// O(hunk-lines) reduce every time a context-expansion signature is built.
    let oldSideExtent: DiffHunkSideExtent
    let newSideExtent: DiffHunkSideExtent

    init(id: String, header: String, sourceHunk: ParsedDiff.Hunk, rows: [DiffDisplayRow]) {
        self.id = id
        self.header = header
        self.sourceHunk = sourceHunk
        self.rows = rows

        var content = Hasher()
        content.combine(id)
        content.combine(header)
        for row in rows {
            DiffDisplaySignatureBuilder.combineContent(row, into: &content)
        }
        contentHash = content.finalize()

        var structural = Hasher()
        structural.combine(id)
        for row in rows {
            structural.combine(row.id)
            structural.combine(row.old?.lineNumber)
            structural.combine(row.new?.lineNumber)
            structural.combine(row.collapsedRows.count)
        }
        structuralHash = structural.finalize()

        oldSideExtent = DiffDisplaySignatureBuilder.sideExtent(of: sourceHunk, side: .old)
        newSideExtent = DiffDisplaySignatureBuilder.sideExtent(of: sourceHunk, side: .new)
    }
}

struct DiffDisplayModel: Equatable {
    let filePath: String
    let groups: [DiffDisplayGroup]

    /// Full-fidelity fingerprint over `filePath` + every group's `contentHash`.
    /// Keys the render-context cache without re-hashing all rows per body pass.
    let contentHash: Int
    /// Coarse structural fingerprint over every group's `structuralHash`.
    let structuralHash: Int

    init(filePath: String, groups: [DiffDisplayGroup]) {
        self.filePath = filePath
        self.groups = groups

        var content = Hasher()
        content.combine(filePath)
        for group in groups {
            content.combine(group.contentHash)
        }
        contentHash = content.finalize()

        var structural = Hasher()
        for group in groups {
            structural.combine(group.structuralHash)
        }
        structuralHash = structural.finalize()
    }
}

/// Line-count extent of one side (old or new) of a diff hunk.
struct DiffHunkSideExtent: Equatable {
    let start: Int
    let count: Int

    var lineBefore: Int {
        count > 0 ? start - 1 : start
    }

    var lineAfter: Int {
        start + max(count, 1)
    }
}

/// Builds the precomputed fingerprints and hunk extents stored on
/// `DiffDisplayGroup`/`DiffDisplayModel`. Kept in one place so the fidelity of
/// the content hash mirrors the render-context cache key exactly.
enum DiffDisplaySignatureBuilder {
    static func combineContent(_ row: DiffDisplayRow, into hasher: inout Hasher) {
        hasher.combine(row.id)
        hasher.combine(row.kind)
        combineContent(row.old, into: &hasher)
        combineContent(row.new, into: &hasher)
        hasher.combine(row.collapsedLineCount)
        hasher.combine(row.collapsedRows.count)
        for collapsed in row.collapsedRows {
            combineContent(collapsed, into: &hasher)
        }
        if let expansion = row.contextExpansion {
            hasher.combine(true)
            hasher.combine(expansion.key.groupID)
            hasher.combine(expansion.boundary)
            hasher.combine(expansion.remainingLineCount)
        } else {
            hasher.combine(false)
        }
    }

    private static func combineContent(_ line: DiffDisplayLine?, into hasher: inout Hasher) {
        guard let line else {
            hasher.combine(UInt8(0))
            return
        }
        hasher.combine(UInt8(1))
        hasher.combine(line.id)
        hasher.combine(line.anchor.side)
        hasher.combine(line.anchor.oldLine)
        hasher.combine(line.anchor.newLine)
        hasher.combine(line.text)
        hasher.combine(line.lineNumber)
        hasher.combine(line.kind)
        hasher.combine(line.inlineSpans)
        hasher.combine(line.noTrailingNewline)
    }

    static func sideExtent(of hunk: ParsedDiff.Hunk, side: DiffLineSide) -> DiffHunkSideExtent {
        let start = side == .old ? hunk.oldStart : hunk.newStart
        let count = hunk.lines.reduce(0) { partial, line in
            partial + (lineConsumes(line, side: side) ? 1 : 0)
        }
        return DiffHunkSideExtent(start: start, count: count)
    }

    private static func lineConsumes(_ line: ParsedDiff.Hunk.Line, side: DiffLineSide) -> Bool {
        switch (line.kind, side) {
        case (.context, .old), (.context, .new), (.delete, .old), (.add, .new):
            return true
        case (_, .paired), (.add, .old), (.delete, .new):
            return false
        }
    }
}
