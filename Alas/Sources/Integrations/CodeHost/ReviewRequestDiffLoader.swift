import Foundation
import os

struct ReviewRequestDiffLoader {
    private static let imageLogger = Logger(subsystem: "io.nlopez.alas", category: "review-image")

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

        let sections = splitFileSections(diff)
        let imageRevisions = await hostedImageRevisions(
            ifNeededFor: sections,
            remote: remote,
            request: request,
            cwd: cwd
        )

        var files: [DiffReviewFileSectionModel] = []
        for section in sections {
            try Task.checkCancellation()
            files.append(try await fileSection(
                for: section,
                namespace: namespace(for: remote.kind),
                remote: remote,
                request: request,
                cwd: cwd,
                imageRevisions: imageRevisions
            ))
        }

        return DiffReviewLoadedSession(
            files: files,
            summary: DiffReviewSessionModel(files: files.map(\.summary), groupsEnabled: false)
        )
    }

    private func fileSection(
        for section: ProviderDiffFileSection,
        namespace: String,
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL,
        imageRevisions: HostedImageRevisions?
    ) async throws -> DiffReviewFileSectionModel {
        let parsed = DiffParser.parse(section.rawDiff)
        let isImage = ImageFileType.isSupported(relativePath: section.path)
        let canRenderText = !parsed.hunks.isEmpty && !isImage
        let counts = lineCounts(in: parsed)
        let summary = DiffReviewFileSummary(
            path: section.path,
            namespace: namespace,
            groupID: nil,
            groupTitle: nil,
            status: section.status,
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: canRenderText || isImage,
            originalPath: section.originalPath
        )

        return DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: parsed,
            displayModel: canRenderText
                ? try await buildDisplayModel(diff: parsed, filePath: section.path)
                : nil,
            placeholderMessage: (canRenderText || isImage) ? nil : placeholderMessage(for: section, diff: parsed),
            openFile: nil,
            contextProvider: nil,
            imageProvider: isImage
                ? hostedImageProvider(
                    for: section,
                    remote: remote,
                    request: request,
                    cwd: cwd,
                    revisions: imageRevisions
                )
                : nil
        )
    }

    private func hostedImageRevisions(
        ifNeededFor sections: [ProviderDiffFileSection],
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async -> HostedImageRevisions? {
        guard sections.contains(where: { ImageFileType.isSupported(relativePath: $0.path) }) else {
            return nil
        }

        do {
            let revisions = try await provider.reviewImageRevisions(remote: remote, request: request, cwd: cwd)
            return .resolved(revisions)
        } catch {
            Self.logHostedImageFailure(
                provider: provider.kind,
                reviewNumber: request.number,
                revision: "metadata",
                path: "-",
                error: error
            )
            return .failed(message: Self.imageFailureMessage(for: error))
        }
    }

    private func hostedImageProvider(
        for section: ProviderDiffFileSection,
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL,
        revisions: HostedImageRevisions?
    ) -> DiffReviewImageProvider {
        let beforePath = section.originalPath ?? section.path
        let repository = "\(provider.kind.rawValue):\(remote.host)/\(remote.repositorySlug)#\(request.number)"
        let beforeRevision: String
        let afterRevision: String
        switch revisions {
        case .resolved(let exact):
            beforeRevision = exact.beforeSHA
            afterRevision = exact.afterSHA
        case .failed:
            beforeRevision = "unavailable-before"
            afterRevision = "unavailable-after"
        case nil:
            beforeRevision = "unavailable-before"
            afterRevision = "unavailable-after"
        }

        let id = DiffReviewImageProviderID(
            source: .hostedReview,
            repository: repository,
            beforeRevision: beforeRevision,
            afterRevision: afterRevision,
            beforePath: section.rawStatus == "A" ? nil : beforePath,
            afterPath: section.path
        )

        return DiffReviewImageProvider(id: id) { [provider, kind = provider.kind] in
            let before: ImageDiffSide
            let after: ImageDiffSide
            switch revisions {
            case .resolved(let exact):
                if section.rawStatus == "A" {
                    before = .missing
                } else {
                    before = await Self.hostedImageSide(
                        provider: provider, kind: kind, remote: remote, reviewNumber: request.number,
                        revision: exact.beforeSHA, path: beforePath, cwd: cwd, repository: repository
                    )
                }
                if section.rawStatus == "D" {
                    after = .missing
                } else {
                    after = await Self.hostedImageSide(
                        provider: provider, kind: kind, remote: remote, reviewNumber: request.number,
                        revision: exact.afterSHA, path: section.path, cwd: cwd, repository: repository
                    )
                }
            case .failed(let message):
                before = section.rawStatus == "A" ? .missing : .failed(ImageDiffLoadFailure(message: message))
                after = section.rawStatus == "D" ? .missing : .failed(ImageDiffLoadFailure(message: message))
            case nil:
                before = section.rawStatus == "A" ? .missing : .failed(ImageDiffLoadFailure(message: "Image revisions are unavailable."))
                after = section.rawStatus == "D" ? .missing : .failed(ImageDiffLoadFailure(message: "Image revisions are unavailable."))
            }

            return ImageDiffPair(
                before: before,
                after: after,
                oldPath: section.rawStatus == "R" || section.rawStatus == "C" ? section.originalPath : nil,
                kind: section.imagePairKind
            )
        }
    }

    @MainActor
    private static func hostedImageSide(
        provider: any CodeHostProvider,
        kind: CodeHostKind,
        remote: CodeHostRemote,
        reviewNumber: Int,
        revision: String,
        path: String,
        cwd: URL,
        repository: String
    ) async -> ImageDiffSide {
        let key = ImageDiffDecodedCache.Key(repository: repository, revision: revision, path: path)
        return await ImageDiffDecodedCache.shared.side(
            for: key,
            cost: ImageDiffDecodedCache.decodedImageCost,
            makeImageSide: GitService.imageSide(forDecodedImage:)
        ) {
            do {
                let data = try await provider.reviewFileData(remote: remote, revision: revision, path: path, cwd: cwd)
                let side = await GitService.imageSide(fromRawData: data, worktreePath: cwd)
                if case .failed = side {
                    Self.logHostedImageFailure(provider: kind, reviewNumber: reviewNumber, revision: revision, path: path, error: HostedImageDecodeError())
                    return .failed(ImageDiffLoadFailure(message: "Could not decode image."))
                }
                return side
            } catch {
                Self.logHostedImageFailure(provider: kind, reviewNumber: reviewNumber, revision: revision, path: path, error: error)
                return .failed(ImageDiffLoadFailure(message: imageFailureMessage(for: error)))
            }
        }
    }

    private static func imageFailureMessage(for error: Error) -> String {
        guard let error = error as? CodeHostProviderError else {
            return "Couldn't load image."
        }
        switch error {
        case .unauthenticated:
            return "Authentication required."
        case .cliMissing:
            return "Provider command unavailable."
        case .commandFailed:
            return "Couldn't load image from the provider."
        case .unsupportedProvider:
            return "Hosted image diffs are unavailable."
        case .malformedOutput:
            return "Couldn't load image revision."
        }
    }

    private static func logHostedImageFailure(
        provider: CodeHostKind,
        reviewNumber: Int,
        revision: String,
        path: String,
        error: Error
    ) {
        imageLogger.error(
            "Hosted image \(provider.rawValue, privacy: .public) review \(reviewNumber, privacy: .public) \(revision, privacy: .public):\(path, privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
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

private enum HostedImageRevisions {
    case resolved(CodeHostReviewImageRevisions)
    case failed(message: String)
}

private struct HostedImageDecodeError: LocalizedError {
    var errorDescription: String? { "Image data could not be decoded" }
}

private struct ProviderDiffFileSection {
    let rawDiff: String
    let path: String
    let originalPath: String?
    let status: DiffReviewFileStatus
    let rawStatus: Character

    var imagePairKind: ImageDiffPairKind {
        switch rawStatus {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        default: .modified
        }
    }

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
            rawStatus = "R"
        } else if let copyTo {
            path = copyTo
            originalPath = copyFrom
            status = .copied
            rawStatus = "C"
        } else if lines.contains(where: { $0.hasPrefix("new file mode ") }) {
            path = newPath ?? paths?.new ?? paths?.old ?? ""
            originalPath = nil
            status = .added
            rawStatus = "A"
        } else if lines.contains(where: { $0.hasPrefix("deleted file mode ") }) {
            path = oldPath ?? paths?.old ?? paths?.new ?? ""
            originalPath = nil
            status = .deleted
            rawStatus = "D"
        } else {
            path = newPath ?? paths?.new ?? oldPath ?? paths?.old ?? ""
            originalPath = nil
            status = .modified
            rawStatus = "M"
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
        guard let rawPath = (lines
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) })
        else { return nil }
        guard rawPath != "/dev/null" else { return nil }
        var index = rawPath.startIndex
        if let quotedPath = quotedPathToken(in: rawPath, index: &index) {
            return stripGitPrefix(quotedPath)
        }
        return stripGitPrefix(pathWithoutTabMetadata(rawPath))
    }

    private static func pathWithoutTabMetadata(_ path: String) -> String {
        guard let tabIndex = path.firstIndex(of: "\t") else { return path }
        return String(path[..<tabIndex])
    }

    private static func stripGitPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}
