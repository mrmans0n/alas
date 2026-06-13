import Foundation

struct ReviewRequestDiffLoader {
    let provider: any CodeHostProvider

    init(provider: any CodeHostProvider) {
        self.provider = provider
    }

    func load(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> DiffReviewLoadedSession {
        try Task.checkCancellation()
        let diff = try await provider.reviewDiff(remote: remote, request: request, cwd: cwd)
        try Task.checkCancellation()

        var files: [DiffReviewFileSectionModel] = []
        for section in splitFileSections(diff) {
            try Task.checkCancellation()
            files.append(try await fileSection(for: section, namespace: namespace(for: remote.kind)))
        }

        return DiffReviewLoadedSession(
            files: files,
            summary: DiffReviewSessionModel(files: files.map(\.summary), groupsEnabled: false)
        )
    }

    private func fileSection(for section: ProviderDiffFileSection, namespace: String) async throws -> DiffReviewFileSectionModel {
        let parsed = DiffParser.parse(section.rawDiff)
        let isImage = ImageFileType.isSupported(relativePath: section.path)
        let canRender = !parsed.hunks.isEmpty && !isImage
        let counts = lineCounts(in: parsed)
        let summary = DiffReviewFileSummary(
            path: section.path,
            namespace: namespace,
            groupID: nil,
            groupTitle: nil,
            status: section.status,
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: canRender,
            originalPath: section.originalPath
        )

        return DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: parsed,
            displayModel: canRender
                ? try await buildDisplayModel(diff: parsed, filePath: section.path)
                : nil,
            placeholderMessage: canRender ? nil : placeholderMessage(for: section, diff: parsed),
            openFile: nil
        )
    }

    private func splitFileSections(_ rawDiff: String) -> [ProviderDiffFileSection] {
        var sections: [ProviderDiffFileSection] = []
        var currentLines: [String] = []

        func flush() {
            guard !currentLines.isEmpty else { return }
            let rawSection = currentLines.joined(separator: "\n")
            if let section = ProviderDiffFileSection(rawDiff: rawSection, lines: currentLines) {
                sections.append(section)
            }
            currentLines = []
        }

        for line in rawDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
            }
            currentLines.append(line)
        }
        flush()

        return sections
    }

    private func buildDisplayModel(diff: ParsedDiff, filePath: String) async throws -> DiffDisplayModel {
        try Task.checkCancellation()
        let model = await Task.detached(priority: .userInitiated) {
            DiffDisplayModelBuilder.build(diff: diff, filePath: filePath)
        }.value
        try Task.checkCancellation()
        return model
    }

    private func lineCounts(in diff: ParsedDiff) -> (additions: Int, deletions: Int) {
        diff.hunks.reduce(into: (additions: 0, deletions: 0)) { counts, hunk in
            for line in hunk.lines {
                switch line.kind {
                case .add:
                    counts.additions += 1
                case .delete:
                    counts.deletions += 1
                case .context:
                    break
                }
            }
        }
    }

    private func placeholderMessage(for section: ProviderDiffFileSection, diff: ParsedDiff) -> String {
        if ImageFileType.isSupported(relativePath: section.path) {
            return "Image changes are not available in this review view yet."
        }
        if diff.hunks.isEmpty {
            return "No text diff is available for this file."
        }
        return "This file cannot be rendered in the review view."
    }

    private func namespace(for kind: CodeHostKind) -> String {
        switch kind {
        case .github:
            return "github-pr"
        case .gitlab:
            return "gitlab-mr"
        }
    }
}

private struct ProviderDiffFileSection {
    let rawDiff: String
    let path: String
    let originalPath: String?
    let status: DiffReviewFileStatus

    init?(rawDiff: String, lines: [String]) {
        guard let header = lines.first(where: { $0.hasPrefix("diff --git ") }) else {
            return nil
        }

        let paths = Self.paths(fromDiffHeader: header)
        let renameFrom = Self.firstHeaderValue(in: lines, prefix: "rename from ")
        let renameTo = Self.firstHeaderValue(in: lines, prefix: "rename to ")
        let copyFrom = Self.firstHeaderValue(in: lines, prefix: "copy from ")
        let copyTo = Self.firstHeaderValue(in: lines, prefix: "copy to ")
        let oldPath = Self.pathHeader(in: lines, prefix: "--- ")
        let newPath = Self.pathHeader(in: lines, prefix: "+++ ")

        self.rawDiff = rawDiff

        if let renameTo {
            path = renameTo
            originalPath = renameFrom
            status = .renamed
        } else if let copyTo {
            path = copyTo
            originalPath = copyFrom
            status = .copied
        } else if lines.contains(where: { $0.hasPrefix("new file mode ") }) {
            path = newPath ?? paths?.new ?? paths?.old ?? ""
            originalPath = nil
            status = .added
        } else if lines.contains(where: { $0.hasPrefix("deleted file mode ") }) {
            path = oldPath ?? paths?.old ?? paths?.new ?? ""
            originalPath = nil
            status = .deleted
        } else {
            path = newPath ?? paths?.new ?? oldPath ?? paths?.old ?? ""
            originalPath = nil
            status = .modified
        }

        if path.isEmpty {
            return nil
        }
    }

    private static func paths(fromDiffHeader header: String) -> (old: String, new: String)? {
        let payload = String(header.dropFirst("diff --git ".count))
        if let quotedPaths = quotedPaths(from: payload) {
            return quotedPaths
        }
        if let prefixedPaths = prefixedPaths(from: payload) {
            return prefixedPaths
        }

        let rawPaths = payload
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)
        guard rawPaths.count == 2 else { return nil }
        return (stripGitPrefix(rawPaths[0]), stripGitPrefix(rawPaths[1]))
    }

    private static func prefixedPaths(from payload: String) -> (old: String, new: String)? {
        guard payload.hasPrefix("a/") else { return nil }

        var candidates: [(old: String, new: String)] = []
        var searchStart = payload.startIndex
        while let delimiter = payload.range(of: " b/", range: searchStart..<payload.endIndex) {
            let oldPath = String(payload[..<delimiter.lowerBound])
            let newPath = String(payload[payload.index(after: delimiter.lowerBound)...])
            candidates.append((stripGitPrefix(oldPath), stripGitPrefix(newPath)))
            searchStart = payload.index(after: delimiter.lowerBound)
        }

        if let matchingCandidate = candidates.first(where: { $0.old == $0.new }) {
            return matchingCandidate
        }
        return candidates.last
    }

    private static func quotedPaths(from payload: String) -> (old: String, new: String)? {
        var index = payload.startIndex
        guard let oldPath = quotedPathToken(in: payload, index: &index) else {
            return nil
        }
        skipSpaces(in: payload, index: &index)
        guard let newPath = quotedPathToken(in: payload, index: &index) else {
            return nil
        }
        return (stripGitPrefix(oldPath), stripGitPrefix(newPath))
    }

    private static func quotedPathToken(in text: String, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else {
            return nil
        }

        index = text.index(after: index)
        var value = ""

        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                index = text.index(after: index)
                return value
            }
            if character == "\\" {
                if let decodedOctalBytes = decodeOctalByteSequence(in: text, index: &index) {
                    value.append(decodedOctalBytes)
                    continue
                }
                guard let escaped = decodeEscapedCharacter(in: text, index: &index) else {
                    return nil
                }
                value.append(escaped)
            } else {
                value.append(character)
                index = text.index(after: index)
            }
        }

        return nil
    }

    private static func decodeOctalByteSequence(in text: String, index: inout String.Index) -> String? {
        var cursor = index
        var bytes: [UInt8] = []

        while cursor < text.endIndex, text[cursor] == "\\" {
            let escapedIndex = text.index(after: cursor)
            guard escapedIndex < text.endIndex, isOctalDigit(text[escapedIndex]) else {
                break
            }

            var digitCursor = escapedIndex
            var digits = ""
            while digitCursor < text.endIndex, digits.count < 3, isOctalDigit(text[digitCursor]) {
                digits.append(text[digitCursor])
                digitCursor = text.index(after: digitCursor)
            }

            guard let value = UInt8(digits, radix: 8) else {
                return nil
            }

            bytes.append(value)
            cursor = digitCursor
        }

        guard !bytes.isEmpty else { return nil }
        index = cursor
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeEscapedCharacter(in text: String, index: inout String.Index) -> Character? {
        let escapeStart = index
        let escapedIndex = text.index(after: escapeStart)
        guard escapedIndex < text.endIndex else { return nil }

        let escaped = text[escapedIndex]
        switch escaped {
        case "n":
            index = text.index(after: escapedIndex)
            return "\n"
        case "r":
            index = text.index(after: escapedIndex)
            return "\r"
        case "t":
            index = text.index(after: escapedIndex)
            return "\t"
        case "\"", "\\":
            index = text.index(after: escapedIndex)
            return escaped
        default:
            if let octal = decodeOctalEscape(in: text, index: escapedIndex) {
                index = octal.nextIndex
                return octal.character
            }
            index = text.index(after: escapedIndex)
            return escaped
        }
    }

    private static func decodeOctalEscape(in text: String, index: String.Index) -> (character: Character, nextIndex: String.Index)? {
        var cursor = index
        var digits = ""

        while cursor < text.endIndex, digits.count < 3, isOctalDigit(text[cursor]) {
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }

        guard !digits.isEmpty,
              let value = UInt32(digits, radix: 8),
              let scalar = UnicodeScalar(value)
        else { return nil }

        return (Character(scalar), cursor)
    }

    private static func isOctalDigit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 48 && scalar.value <= 55
    }

    private static func skipSpaces(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index] == " " {
            index = text.index(after: index)
        }
    }

    private static func firstHeaderValue(in lines: [String], prefix: String) -> String? {
        guard let value = (lines
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) })
        else { return nil }

        var index = value.startIndex
        return quotedPathToken(in: value, index: &index) ?? value
    }

    private static func pathHeader(in lines: [String], prefix: String) -> String? {
        guard let rawPath = firstHeaderValue(in: lines, prefix: prefix) else { return nil }
        guard rawPath != "/dev/null" else { return nil }
        var index = rawPath.startIndex
        if let quotedPath = quotedPathToken(in: rawPath, index: &index) {
            return stripGitPrefix(quotedPath)
        }
        return stripGitPrefix(rawPath)
    }

    private static func stripGitPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}
