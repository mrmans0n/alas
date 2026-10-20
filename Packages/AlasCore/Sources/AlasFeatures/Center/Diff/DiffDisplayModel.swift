import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum DiffLineSide: Int, Codable, Equatable, Comparable, Hashable, Sendable {
    case old
    case new
    case paired

    public static func < (lhs: DiffLineSide, rhs: DiffLineSide) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct DiffLineAnchor: Codable, Equatable, Comparable, Hashable, Sendable {
    public let filePath: String
    public let hunkIndex: Int
    public let rowIndex: Int
    public let side: DiffLineSide
    public let oldLine: Int?
    public let newLine: Int?

    public static func < (lhs: DiffLineAnchor, rhs: DiffLineAnchor) -> Bool {
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

    public init(filePath: String, hunkIndex: Int, rowIndex: Int, side: DiffLineSide, oldLine: Int?, newLine: Int?) {
        self.filePath = filePath
        self.hunkIndex = hunkIndex
        self.rowIndex = rowIndex
        self.side = side
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public struct DiffSelectionRange: Equatable, Sendable {
    public let first: DiffLineAnchor
    public let last: DiffLineAnchor

    public var normalized: ClosedRange<DiffLineAnchor> {
        first <= last ? first...last : last...first
    }

    public func contains(_ anchor: DiffLineAnchor) -> Bool {
        normalized.contains(anchor)
    }

    public init(first: DiffLineAnchor, last: DiffLineAnchor) {
        self.first = first
        self.last = last
    }
}

public struct DiffInlineSpan: Codable, Equatable, Hashable, Sendable {
    public let start: Int
    public let length: Int

    public func text(in string: String) -> String {
        let nsString = string as NSString
        let location = max(0, min(start, nsString.length))
        let end = max(location, min(start + length, nsString.length))
        return nsString.substring(with: NSRange(location: location, length: end - location))
    }

    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

public struct DiffDisplayLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let anchor: DiffLineAnchor
    public let text: String
    public let lineNumber: Int?
    public let kind: ParsedDiff.Hunk.Line.Kind
    public let inlineSpans: [DiffInlineSpan]
    public let noTrailingNewline: Bool

    public init(id: String, anchor: DiffLineAnchor, text: String, lineNumber: Int?, kind: ParsedDiff.Hunk.Line.Kind, inlineSpans: [DiffInlineSpan], noTrailingNewline: Bool) {
        self.id = id
        self.anchor = anchor
        self.text = text
        self.lineNumber = lineNumber
        self.kind = kind
        self.inlineSpans = inlineSpans
        self.noTrailingNewline = noTrailingNewline
    }
}

public enum DiffContextBoundary: String, Codable, Equatable, Hashable, Sendable {
    case above
    case below
}

public enum DiffContextExpansionEdge: String, Codable, Equatable, Hashable, Sendable {
    case top
    case bottom
}

public struct DiffContextExpansionKey: Codable, Equatable, Hashable, Sendable {
    public enum Kind: Codable, Equatable, Hashable, Sendable {
        case external(groupID: String, boundary: DiffContextBoundary)
        case shared(upperGroupID: String, lowerGroupID: String)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case groupID
        case boundary
    }

    public let kind: Kind

    public init(groupID: String, boundary: DiffContextBoundary) {
        kind = .external(groupID: groupID, boundary: boundary)
    }

    public static func shared(upperGroupID: String, lowerGroupID: String) -> DiffContextExpansionKey {
        DiffContextExpansionKey(kind: .shared(upperGroupID: upperGroupID, lowerGroupID: lowerGroupID))
    }

    private init(kind: Kind) {
        self.kind = kind
    }

    public var groupID: String {
        switch kind {
        case let .external(groupID, _):
            return groupID
        case let .shared(upperGroupID, lowerGroupID):
            return "\(upperGroupID)..\(lowerGroupID)"
        }
    }

    public var boundary: DiffContextBoundary {
        switch kind {
        case let .external(_, boundary):
            return boundary
        case .shared:
            return .below
        }
    }

    public var isShared: Bool {
        if case .shared = kind {
            return true
        }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) {
            self.kind = kind
            return
        }

        kind = .external(
            groupID: try container.decode(String.self, forKey: .groupID),
            boundary: try container.decode(DiffContextBoundary.self, forKey: .boundary)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case let .external(groupID, boundary):
            try container.encode(groupID, forKey: .groupID)
            try container.encode(boundary, forKey: .boundary)
        case .shared:
            try container.encode(kind, forKey: .kind)
        }
    }
}

public struct DiffContextExpansionRow: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case key
        case boundary
        case remainingLineCount
        case edge
    }

    public let key: DiffContextExpansionKey
    public let boundary: DiffContextBoundary
    public let remainingLineCount: Int
    public let edge: DiffContextExpansionEdge?

    public init(
        key: DiffContextExpansionKey,
        boundary: DiffContextBoundary,
        remainingLineCount: Int,
        edge: DiffContextExpansionEdge? = nil,
        defaultsEdgeFromBoundary: Bool = true
    ) {
        self.key = key
        self.boundary = boundary
        self.remainingLineCount = remainingLineCount
        self.edge = edge ?? (defaultsEdgeFromBoundary ? (boundary == .above ? .bottom : .top) : nil)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(DiffContextExpansionKey.self, forKey: .key)
        let boundary = try container.decode(DiffContextBoundary.self, forKey: .boundary)
        self.init(
            key: key,
            boundary: boundary,
            remainingLineCount: try container.decode(Int.self, forKey: .remainingLineCount),
            edge: try container.decodeIfPresent(DiffContextExpansionEdge.self, forKey: .edge)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(boundary, forKey: .boundary)
        try container.encode(remainingLineCount, forKey: .remainingLineCount)
        try container.encodeIfPresent(edge, forKey: .edge)
    }
}

public struct DiffDisplayRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case context
        case add
        case delete
        case replacement
        case collapsed
        case expandedContext
        case expandableContext
    }

    public let id: String
    public let kind: Kind
    public let old: DiffDisplayLine?
    public let new: DiffDisplayLine?
    public let collapsedLineCount: Int
    public let collapsedRows: [DiffDisplayRow]
    public let contextExpansion: DiffContextExpansionRow?
    /// Full-fidelity render revision computed once at construction time.
    /// SwiftUI compares rows frequently, so equality must not recursively walk
    /// line text, inline spans, and collapsed child rows on every transaction.
    public let contentHash: Int

    public init(
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
        self.contentHash = DiffDisplaySignatureBuilder.contentHash(
            id: id,
            kind: kind,
            old: old,
            new: new,
            collapsedLineCount: collapsedLineCount,
            collapsedRows: collapsedRows,
            contextExpansion: contextExpansion
        )
    }

    public static func == (lhs: DiffDisplayRow, rhs: DiffDisplayRow) -> Bool {
        lhs.id == rhs.id && lhs.contentHash == rhs.contentHash
    }
}

/// Compact revision for an ordered row collection. It is built when a model
/// or rendered segment is created, then copied and compared in O(1).
public struct DiffDisplayRowsSignature: Equatable, Hashable, Sendable {
    public let count: Int
    public let contentHash: Int

    public init(_ rows: [DiffDisplayRow]) {
        count = rows.count
        var content = Hasher()
        content.combine(count)
        for row in rows {
            content.combine(row.contentHash)
        }
        contentHash = content.finalize()
    }
}

public final class DiffDisplayRowsSnapshot {
    public let rows: [DiffDisplayRow]
    public let signature: DiffDisplayRowsSignature

    public init(rows: [DiffDisplayRow], signature: DiffDisplayRowsSignature? = nil) {
        self.rows = rows
        self.signature = signature ?? DiffDisplayRowsSignature(rows)
    }
}

public struct DiffDisplayGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let header: String
    public let sourceHunk: ParsedDiff.Hunk
    public let rows: [DiffDisplayRow]
    public let sharedContextBefore: DiffContextExpansionKey?
    public let sharedContextAfter: DiffContextExpansionKey?
    public let rowsSignature: DiffDisplayRowsSignature

    /// Full-fidelity content fingerprint (row/line identity, text, kinds,
    /// inline spans, collapse structure). Precomputed once at build time and
    /// read in O(1) so the render-context cache key never has to walk every
    /// row on each SwiftUI body pass.
    public let contentHash: Int
    /// Coarse structural fingerprint (row identity + line numbers + collapse
    /// counts). Used for `.onChange` state-reset signals that only care about
    /// structural changes, not pure text edits.
    public let structuralHash: Int
    /// Extent of the old/new side of the source hunk. Precomputed to avoid an
    /// O(hunk-lines) reduce every time a context-expansion signature is built.
    public let oldSideExtent: DiffHunkSideExtent
    public let newSideExtent: DiffHunkSideExtent

    public init(
        id: String,
        header: String,
        sourceHunk: ParsedDiff.Hunk,
        rows: [DiffDisplayRow],
        sharedContextBefore: DiffContextExpansionKey? = nil,
        sharedContextAfter: DiffContextExpansionKey? = nil,
        rowsSignature: DiffDisplayRowsSignature? = nil
    ) {
        self.id = id
        self.header = header
        self.sourceHunk = sourceHunk
        self.rows = rows
        self.sharedContextBefore = sharedContextBefore
        self.sharedContextAfter = sharedContextAfter
        self.rowsSignature = rowsSignature ?? DiffDisplayRowsSignature(rows)

        var content = Hasher()
        content.combine(id)
        content.combine(header)
        content.combine(sourceHunk.oldStart)
        content.combine(sourceHunk.newStart)
        content.combine(sharedContextBefore)
        content.combine(sharedContextAfter)
        content.combine(self.rowsSignature)
        contentHash = content.finalize()

        var structural = Hasher()
        structural.combine(id)
        structural.combine(sharedContextBefore)
        structural.combine(sharedContextAfter)
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

    public static func == (lhs: DiffDisplayGroup, rhs: DiffDisplayGroup) -> Bool {
        lhs.id == rhs.id && lhs.contentHash == rhs.contentHash
    }
}

public struct DiffDisplayModel: Equatable, Sendable {
    public let filePath: String
    public let groups: [DiffDisplayGroup]

    /// Full-fidelity fingerprint over `filePath` + every group's `contentHash`.
    /// Keys the render-context cache without re-hashing all rows per body pass.
    public let contentHash: Int
    /// Coarse structural fingerprint over every group's `structuralHash`.
    public let structuralHash: Int

    public init(filePath: String, groups: [DiffDisplayGroup]) {
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

    public static func == (lhs: DiffDisplayModel, rhs: DiffDisplayModel) -> Bool {
        lhs.filePath == rhs.filePath
            && lhs.groups.count == rhs.groups.count
            && lhs.contentHash == rhs.contentHash
    }
}

/// Line-count extent of one side (old or new) of a diff hunk.
public struct DiffHunkSideExtent: Equatable, Sendable {
    public let start: Int
    public let count: Int

    public var lineBefore: Int {
        count > 0 ? start - 1 : start
    }

    public var lineAfter: Int {
        start + max(count, 1)
    }

    public init(start: Int, count: Int) {
        self.start = start
        self.count = count
    }
}

/// Builds the precomputed fingerprints and hunk extents stored on
/// `DiffDisplayGroup`/`DiffDisplayModel`. Kept in one place so the fidelity of
/// the content hash mirrors the render-context cache key exactly.
public enum DiffDisplaySignatureBuilder: Sendable {
    public static func contentHash(
        id: String,
        kind: DiffDisplayRow.Kind,
        old: DiffDisplayLine?,
        new: DiffDisplayLine?,
        collapsedLineCount: Int,
        collapsedRows: [DiffDisplayRow],
        contextExpansion: DiffContextExpansionRow?
    ) -> Int {
        var content = Hasher()
        content.combine(id)
        content.combine(kind)
        combineContent(old, into: &content)
        combineContent(new, into: &content)
        content.combine(collapsedLineCount)
        content.combine(collapsedRows.count)
        for collapsed in collapsedRows {
            content.combine(collapsed.contentHash)
        }
        if let contextExpansion {
            content.combine(true)
            content.combine(contextExpansion.key.kind)
            content.combine(contextExpansion.boundary)
            content.combine(contextExpansion.remainingLineCount)
            content.combine(contextExpansion.edge)
        } else {
            content.combine(false)
        }
        return content.finalize()
    }

    private static func combineContent(_ line: DiffDisplayLine?, into hasher: inout Hasher) {
        guard let line else {
            hasher.combine(UInt8(0))
            return
        }
        hasher.combine(UInt8(1))
        hasher.combine(line.id)
        hasher.combine(line.anchor.filePath)
        hasher.combine(line.anchor.hunkIndex)
        hasher.combine(line.anchor.rowIndex)
        hasher.combine(line.anchor.side)
        hasher.combine(line.anchor.oldLine)
        hasher.combine(line.anchor.newLine)
        hasher.combine(line.text)
        hasher.combine(line.lineNumber)
        hasher.combine(line.kind)
        hasher.combine(line.inlineSpans)
        hasher.combine(line.noTrailingNewline)
    }

    public static func sideExtent(of hunk: ParsedDiff.Hunk, side: DiffLineSide) -> DiffHunkSideExtent {
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
