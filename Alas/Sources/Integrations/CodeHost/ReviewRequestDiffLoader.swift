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
        let counts = isImage ? (additions: 0, deletions: 0) : lineCounts(in: parsed)
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
        let rawPaths = header
            .dropFirst("diff --git ".count)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map(String.init)
        guard rawPaths.count == 2 else { return nil }
        return (stripGitPrefix(rawPaths[0]), stripGitPrefix(rawPaths[1]))
    }

    private static func firstHeaderValue(in lines: [String], prefix: String) -> String? {
        lines
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func pathHeader(in lines: [String], prefix: String) -> String? {
        guard let rawPath = firstHeaderValue(in: lines, prefix: prefix) else { return nil }
        guard rawPath != "/dev/null" else { return nil }
        return stripGitPrefix(rawPath)
    }

    private static func stripGitPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}
