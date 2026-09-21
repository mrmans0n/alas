import Foundation

struct CommitDetails: Equatable {
    let info: CommitInfo
    let body: String          // commit message minus the subject line; "" if none
    let authorEmail: String
    let parents: [String]     // full shas of parent commits, in git order
    let files: [CommitChangedFile]
}

struct ProtectedCommitTrailer: Equatable {
    let name: String
    let value: String
    fileprivate let rawLines: [String]
    fileprivate let precedingTrailerLines: Int
}

struct CommitMessage {
    let body: String
    let protectedTrailers: [ProtectedCommitTrailer]

    static func split(_ body: String) -> Self {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let trailerRange = trailingTrailerRange(in: lines) else {
            return Self(
                body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                protectedTrailers: []
            )
        }

        var protectedTrailers: [ProtectedCommitTrailer] = []
        var protectedLineIndices: Set<Int> = []
        var precedingTrailerLines = 0
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
                protectedTrailers.append(trailer)
                protectedLineIndices.formUnion(index..<trailerEnd)
            } else {
                precedingTrailerLines += trailerEnd - index
            }
            index = trailerEnd
        }

        let editableLines = lines.enumerated().compactMap { index, line in
            protectedLineIndices.contains(index) ? nil : line
        }
        return Self(
            body: editableLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            protectedTrailers: protectedTrailers
        )
    }

    static func compose(body: String, preserving protectedTrailers: [ProtectedCommitTrailer]) -> String {
        guard !protectedTrailers.isEmpty else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bodyWithoutTerminalTrailers = split(body).body
        var editableLines = removingShadowingProtectedTrailers(
            from: bodyWithoutTerminalTrailers
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
        )
        let editableBody = editableLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func isPatchDivider(_ line: String) -> Bool {
        line == "---" || line.hasPrefix("--- ")
    }

    private static func removingShadowingProtectedTrailers(from lines: [String]) -> [String] {
        var fencedCodeMarker: (marker: Character, length: Int)?
        var isRemovingShadowTrailer = false
        return lines.filter { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if let marker = codeFence(in: trimmedLine) {
                if fencedCodeMarker == nil {
                    fencedCodeMarker = marker
                } else if fencedCodeMarker?.marker == marker.marker,
                          marker.length >= fencedCodeMarker?.length ?? 0 {
                    fencedCodeMarker = nil
                }
                return true
            }
            guard fencedCodeMarker == nil else { return true }
            if isProtectedTrailerLine(line) {
                isRemovingShadowTrailer = true
                return false
            }
            if isRemovingShadowTrailer, isTrailerContinuation(line) {
                return false
            }
            isRemovingShadowTrailer = false
            return true
        }
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
}

struct CommitChangedFile: Identifiable, Equatable, Hashable {
    var id: String { path }
    let path: String              // for renames, this is the new path
    let originalPath: String?     // for renames/copies, the original path; nil otherwise
    let status: String            // single letter: A, M, D, R, C, T
    let add: Int                  // 0 for binary files
    let del: Int                  // 0 for binary files
}
