import AppKit

struct EditorDisplayHint: Equatable {
    let id: String
    let sourceOffset: Int
    let label: String
    let size: CGSize
}

enum EditorDisplayAffinity { case beforeHints, afterHints }

enum EditorDisplayMapError: Error {
    case invalidBoundary
    case invalidRange
    case duplicateHintID(String)
    case invalidHintSize(String)
    case displayLengthOverflow
}

/// An immutable UTF-16 projection. Mapping metadata grows with hint count,
/// while the captured source text supplies constant-time surrogate checks.
struct EditorDisplayMap {
    let revision: Int
    let sourceLength: Int
    let displayLength: Int
    let hintRuns: [HintRun]
    private let source: NSString
    private let groups: [HintGroup]
    private let sourceRuns: [SourceRun]

    struct HintRun {
        let hint: EditorDisplayHint
        let displayOffset: Int
    }

    private struct HintGroup {
        let sourceOffset: Int
        let displayStart: Int
        let displayEnd: Int
        let cumulativeCount: Int
    }

    private struct SourceRun {
        let source: NSRange
        let display: NSRange
    }

    init(source: String, revision: Int, hints: [EditorDisplayHint]) throws {
        let text = source as NSString
        let (length, overflow) = text.length.addingReportingOverflow(hints.count)
        guard !overflow else { throw EditorDisplayMapError.displayLengthOverflow }
        var ids = Set<String>()
        for hint in hints {
            guard ids.insert(hint.id).inserted else { throw EditorDisplayMapError.duplicateHintID(hint.id) }
            guard hint.size.width.isFinite, hint.size.height.isFinite,
                  hint.size.width > 0, hint.size.height > 0
            else { throw EditorDisplayMapError.invalidHintSize(hint.id) }
            try Self.validateBoundary(hint.sourceOffset, in: text)
        }
        let sorted = hints.enumerated().sorted {
            $0.element.sourceOffset == $1.element.sourceOffset
                ? $0.offset < $1.offset : $0.element.sourceOffset < $1.element.sourceOffset
        }.map(\.element)
        var groups: [HintGroup] = []
        var hintRuns: [HintRun] = []
        var sourceRuns: [SourceRun] = []
        var cursor = 0
        var index = 0
        while index < sorted.count {
            let offset = sorted[index].sourceOffset
            if offset > cursor {
                sourceRuns.append(SourceRun(source: NSRange(location: cursor, length: offset - cursor), display: NSRange(location: cursor + index, length: offset - cursor)))
            }
            let start = offset + index
            repeat {
                hintRuns.append(HintRun(hint: sorted[index], displayOffset: offset + index))
                index += 1
            } while index < sorted.count && sorted[index].sourceOffset == offset
            groups.append(HintGroup(sourceOffset: offset, displayStart: start, displayEnd: offset + index, cumulativeCount: index))
            cursor = offset
        }
        if cursor < text.length {
            sourceRuns.append(SourceRun(source: NSRange(location: cursor, length: text.length - cursor), display: NSRange(location: cursor + sorted.count, length: text.length - cursor)))
        }
        self.source = text
        self.revision = revision
        sourceLength = text.length
        displayLength = length
        self.groups = groups
        self.hintRuns = hintRuns
        self.sourceRuns = sourceRuns
    }

    func displayOffset(forSource offset: Int, affinity: EditorDisplayAffinity) throws -> Int {
        try Self.validateBoundary(offset, in: source)
        let index = Self.lowerBound(in: groups) { $0.sourceOffset >= offset }
        if index < groups.count, groups[index].sourceOffset == offset {
            return affinity == .beforeHints ? groups[index].displayStart : groups[index].displayEnd
        }
        return offset + (index == 0 ? 0 : groups[index - 1].cumulativeCount)
    }

    func sourceOffset(forDisplay offset: Int) throws -> Int {
        guard offset >= 0, offset <= displayLength else { throw EditorDisplayMapError.invalidBoundary }
        let index = Self.lowerBound(in: groups) { $0.displayEnd >= offset }
        if index < groups.count, offset >= groups[index].displayStart {
            return groups[index].sourceOffset
        }
        let result = offset - (index == 0 ? 0 : groups[index - 1].cumulativeCount)
        try Self.validateBoundary(result, in: source)
        return result
    }

    func sourceRange(forDisplay range: NSRange) throws -> NSRange {
        let end = try Self.validatedEnd(of: range, length: displayLength)
        let start = try sourceOffset(forDisplay: range.location)
        return try NSRange(location: start, length: sourceOffset(forDisplay: end) - start)
    }

    /// Returns only source characters. Empty ranges return no segments;
    /// use displayOffset(forSource:affinity:) to obtain a caret anchor.
    func displaySegments(forSource range: NSRange) throws -> [NSRange] {
        let end = try Self.validatedEnd(of: range, length: sourceLength)
        try Self.validateBoundary(range.location, in: source)
        try Self.validateBoundary(end, in: source)
        guard range.length > 0 else { return [] }
        var index = Self.lowerBound(in: sourceRuns) { NSMaxRange($0.source) > range.location }
        var result: [NSRange] = []
        while index < sourceRuns.count, sourceRuns[index].source.location < end {
            let run = sourceRuns[index]
            let start = max(range.location, run.source.location)
            let stop = min(end, NSMaxRange(run.source))
            result.append(NSRange(location: run.display.location + start - run.source.location, length: stop - start))
            index += 1
        }
        return result
    }

    private static func validatedEnd(of range: NSRange, length: Int) throws -> Int {
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location
        else { throw EditorDisplayMapError.invalidRange }
        return range.location + range.length
    }

    private static func validateBoundary(_ offset: Int, in text: NSString) throws {
        guard offset >= 0, offset <= text.length else { throw EditorDisplayMapError.invalidBoundary }
        if offset > 0, offset < text.length,
           (0xD800 ... 0xDBFF).contains(text.character(at: offset - 1)),
           (0xDC00 ... 0xDFFF).contains(text.character(at: offset)) {
            throw EditorDisplayMapError.invalidBoundary
        }
    }

    private static func lowerBound<T>(in values: [T], where predicate: (T) -> Bool) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(values[middle]) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }
}
