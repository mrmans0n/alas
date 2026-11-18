import Foundation
import AlasFoundation
import AlasModel

public struct CommitDetails: Equatable, Codable, Sendable {
    public let info: CommitInfo
    public let body: String          // commit message minus the subject line; "" if none
    public let authorEmail: String
    public let parents: [String]     // full shas of parent commits, in git order
    public let files: [CommitChangedFile]

    public init(info: CommitInfo, body: String, authorEmail: String, parents: [String], files: [CommitChangedFile]) {
        self.info = info
        self.body = body
        self.authorEmail = authorEmail
        self.parents = parents
        self.files = files
    }
}

public struct ProtectedCommitTrailer: Equatable, Sendable {
    public let name: String
    public let value: String
    fileprivate let rawLines: [String]
    fileprivate let precedingTrailerLines: Int

    public init(name: String, value: String, rawLines: [String], precedingTrailerLines: Int) {
        self.name = name
        self.value = value
        self.rawLines = rawLines
        self.precedingTrailerLines = precedingTrailerLines
    }
}

public struct CommitMessage: Sendable {
    public let body: String
    public let protectedTrailers: [ProtectedCommitTrailer]

    public static func split(_ body: String) -> Self {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trailerRange = trailingTrailerRange(in: lines)

        var blockTrailers: [ProtectedCommitTrailer] = []
        var protectedLineIndices: Set<Int> = []
        var precedingTrailerLines = 0
        if let trailerRange {
            var index = trailerRange.lowerBound
            while index < trailerRange.upperBound {
                var trailerEnd = index + 1
                while trailerEnd < trailerRange.upperBound,
                      isTrailerContinuation(lines[trailerEnd]),
                      !isProtectedTrailerLine(lines[trailerEnd]) {
                    trailerEnd += 1
                }

                if let trailer = protectedTrailer(
                    in: lines[index],
                    rawLines: Array(lines[index..<trailerEnd]),
                    precedingTrailerLines: precedingTrailerLines
                ) {
                    blockTrailers.append(trailer)
                    protectedLineIndices.formUnion(index..<trailerEnd)
                } else {
                    precedingTrailerLines += trailerEnd - index
                }
                index = trailerEnd
            }
        }

        // gg appends each trailer as its own paragraph, so a GG-ID often sits
        // outside the terminal trailer block. Protect every GG trailer that
        // `compose` would strip from the body, keeping message order.
        var leadingTrailers: [ProtectedCommitTrailer] = []
        var followingTrailers: [ProtectedCommitTrailer] = []
        for range in protectedTrailerLineRanges(in: lines) where !protectedLineIndices.contains(range.lowerBound) {
            let isLeading = range.lowerBound < (trailerRange?.lowerBound ?? lines.count)
            guard let trailer = protectedTrailer(
                in: lines[range.lowerBound],
                rawLines: Array(lines[range]),
                precedingTrailerLines: isLeading ? 0 : precedingTrailerLines
            ) else { continue }
            if isLeading {
                leadingTrailers.append(trailer)
            } else {
                followingTrailers.append(trailer)
            }
            protectedLineIndices.formUnion(range)
        }

        // Drop the blank line a removed trailer paragraph would leave doubled.
        var editableLines: [String] = []
        var removedSinceLastKept = false
        for (index, line) in lines.enumerated() {
            if protectedLineIndices.contains(index) {
                removedSinceLastKept = true
                continue
            }
            if removedSinceLastKept, isBlank(line), editableLines.last.map(isBlank) ?? true {
                continue
            }
            removedSinceLastKept = false
            editableLines.append(line)
        }
        return Self(
            body: editableLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            protectedTrailers: leadingTrailers + blockTrailers + followingTrailers
        )
    }

    public static func compose(body: String, preserving protectedTrailers: [ProtectedCommitTrailer]) -> String {
        guard !protectedTrailers.isEmpty else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let editableBody = split(body).body
        var editableLines = editableBody
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let trailerRange = trailingTrailerRange(in: editableLines) else {
            let trailers = protectedTrailers
                .flatMap(\.rawLines)
                .joined(separator: "\n")
            guard !editableBody.isEmpty else { return trailers }
            return "\(editableBody)\n\n\(trailers)"
        }

        var insertedLines = 0
        for trailer in protectedTrailers {
            var insertionIndex = trailerRange.lowerBound
                + min(trailer.precedingTrailerLines, trailerRange.count)
                + insertedLines
            let trailerEnd = trailerRange.upperBound + insertedLines
            while insertionIndex < trailerEnd, isTrailerContinuation(editableLines[insertionIndex]) {
                insertionIndex += 1
            }
            editableLines.insert(contentsOf: trailer.rawLines, at: insertionIndex)
            insertedLines += trailer.rawLines.count
        }
        return editableLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trailingTrailerRange(in lines: [String]) -> Range<Int>? {
        if let dividerIndex = lines.firstIndex(where: isPatchDivider) {
            var trailerEnd = dividerIndex
            while trailerEnd > 0,
                  lines[trailerEnd - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trailerEnd -= 1
            }

            var start = trailerEnd - 1
            while start >= 0, isTrailerBlockLine(lines[start]) {
                start -= 1
            }
            let trailerStart = start + 1
            guard trailerStart < trailerEnd,
                  trailerStart == 0 || lines[start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return dividerIndex ..< dividerIndex
            }
            return trailerStart ..< trailerEnd
        }

        guard let last = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return nil
        }

        var start = last
        while start >= 0, isTrailerBlockLine(lines[start]) {
            start -= 1
        }
        let trailerStart = start + 1
        guard trailerStart <= last,
              trailerStart == 0 || lines[start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return trailerStart ..< last + 1
    }

    private static func isTrailerBlockLine(_ line: String) -> Bool {
        isTrailerLine(line) || isCherryPickAnnotation(line) || isTrailerContinuation(line)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isPatchDivider(_ line: String) -> Bool {
        line == "---" || line.hasPrefix("--- ")
    }

    /// `GG-ID`/`GG-Parent` lines outside fenced code, each with its continuation lines.
    private static func protectedTrailerLineRanges(in lines: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var fencedCodeMarker: (marker: Character, length: Int)?
        var index = 0
        while index < lines.count {
            if let marker = codeFence(in: lines[index].trimmingCharacters(in: .whitespaces)) {
                if fencedCodeMarker == nil {
                    fencedCodeMarker = marker
                } else if fencedCodeMarker?.marker == marker.marker,
                          marker.length >= fencedCodeMarker?.length ?? 0 {
                    fencedCodeMarker = nil
                }
                index += 1
                continue
            }
            guard fencedCodeMarker == nil, isProtectedTrailerLine(lines[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count,
                  isTrailerContinuation(lines[end]),
                  !isProtectedTrailerLine(lines[end]),
                  codeFence(in: lines[end].trimmingCharacters(in: .whitespaces)) == nil {
                end += 1
            }
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }

    private static func codeFence(in line: String) -> (marker: Character, length: Int)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let length = line.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    private static func isCherryPickAnnotation(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        return trimmedLine.hasPrefix("(cherry picked from commit ") && trimmedLine.hasSuffix(")")
    }

    private static func isTrailerContinuation(_ line: String) -> Bool {
        guard line.first == " " || line.first == "\t" else { return false }
        return !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isTrailerLine(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmedLine.firstIndex(of: ":"), separator != trimmedLine.startIndex else {
            return false
        }
        return trimmedLine[..<separator].allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }

    private static func isProtectedTrailerLine(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmedLine.firstIndex(of: ":") else { return false }
        let name = String(trimmedLine[..<separator])
        return name == "GG-ID" || name == "GG-Parent"
    }

    private static func protectedTrailer(
        in line: String,
        rawLines: [String],
        precedingTrailerLines: Int
    ) -> ProtectedCommitTrailer? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmedLine.firstIndex(of: ":") else { return nil }

        let name = String(trimmedLine[..<separator])
        guard name == "GG-ID" || name == "GG-Parent" else { return nil }

        let value = ([
            String(trimmedLine[trimmedLine.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        ] + rawLines.dropFirst().map {
            $0.trimmingCharacters(in: .whitespaces)
        }).joined(separator: "\n")
        return ProtectedCommitTrailer(
            name: name,
            value: value,
            rawLines: rawLines,
            precedingTrailerLines: precedingTrailerLines
        )
    }

    public init(body: String, protectedTrailers: [ProtectedCommitTrailer]) {
        self.body = body
        self.protectedTrailers = protectedTrailers
    }
}

public struct CommitChangedFile: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String              // for renames, this is the new path
    public let originalPath: String?     // for renames/copies, the original path; nil otherwise
    public let status: String            // single letter: A, M, D, R, C, T
    public let add: Int                  // 0 for binary files
    public let del: Int                  // 0 for binary files

    public init(path: String, originalPath: String?, status: String, add: Int, del: Int) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.add = add
        self.del = del
    }
}
