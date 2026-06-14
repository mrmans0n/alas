import Foundation

enum DraftReviewRequestDiffSessionBuilder {
    static let namespace = "draft-review-request"

    static func build(
        context: ReviewRequestDraftContext,
        worktreePath: URL,
        openFileForPath: @escaping (String) -> (() -> Void)?
    ) async throws -> DiffReviewLoadedSession {
        _ = worktreePath
        var sections: [DiffReviewFileSectionModel] = []

        for file in context.changedFiles {
            try Task.checkCancellation()
            let rawDiff = context.fileDiffsByPath[file.path] ?? ""
            let parsed = DiffParser.parse(rawDiff)
            try Task.checkCancellation()

            sections.append(try await fileSection(
                for: file,
                diff: parsed,
                openFile: openFileForPath(file.path)
            ))
        }

        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }

    static func selectedFileID(for path: String?) -> DiffReviewFileID? {
        guard let path else { return nil }
        return DiffReviewFileID(namespace: namespace, path: path)
    }

    static func selectedPath(for id: DiffReviewFileID?) -> String? {
        guard let id, id.namespace == namespace else { return nil }
        return id.path
    }

    static func synchronizedSelection(selectedPath: String?, session: DiffReviewLoadedSession) -> DiffReviewFileID? {
        if let id = selectedFileID(for: selectedPath),
           session.summary.files.contains(where: { $0.id == id }) {
            return id
        }
        return session.summary.files.first?.id
    }

    private static func fileSection(
        for file: CommitChangedFile,
        diff: ParsedDiff,
        openFile: (() -> Void)?
    ) async throws -> DiffReviewFileSectionModel {
        let isImage = ImageFileType.isSupported(relativePath: file.path)
        let canRender = !diff.hunks.isEmpty && !isImage
        let counts = lineCounts(for: file, diff: diff)
        let summary = DiffReviewFileSummary(
            path: file.path,
            namespace: namespace,
            groupID: nil,
            groupTitle: nil,
            status: DiffReviewFileStatus(gitStatus: file.status),
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: canRender,
            originalPath: file.originalPath
        )

        return DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: diff,
            displayModel: canRender
                ? try await buildDisplayModel(diff: diff, filePath: file.path)
                : nil,
            placeholderMessage: canRender ? nil : placeholderMessage(for: file, diff: diff),
            openFile: openFile
        )
    }

    private static func buildDisplayModel(diff: ParsedDiff, filePath: String) async throws -> DiffDisplayModel {
        try Task.checkCancellation()
        let model = await Task.detached(priority: .userInitiated) {
            DiffDisplayModelBuilder.build(diff: diff, filePath: filePath)
        }.value
        try Task.checkCancellation()
        return model
    }

    private static func lineCounts(for file: CommitChangedFile, diff: ParsedDiff) -> (additions: Int, deletions: Int) {
        guard !diff.hunks.isEmpty else {
            return (additions: file.add, deletions: file.del)
        }

        return diff.hunks.reduce(into: (additions: 0, deletions: 0)) { counts, hunk in
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

    private static func placeholderMessage(for file: CommitChangedFile, diff: ParsedDiff) -> String {
        if ImageFileType.isSupported(relativePath: file.path) {
            return "Image changes are not available in this review view yet."
        }
        if diff.hunks.isEmpty {
            return "No text diff is available for this file."
        }
        return "This file cannot be rendered in the review view."
    }
}
