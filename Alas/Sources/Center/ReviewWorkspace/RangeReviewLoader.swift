import Foundation

protocol RangeReviewGitClient {
    func rangeDiff(worktreePath: URL, base: String, head: String, threeDot: Bool, file: String, originalPath: String?) async throws -> ParsedDiff
    func rangeContextSnapshot(worktreePath: URL, base: String, head: String, threeDot: Bool, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot
}

extension GitService: RangeReviewGitClient {
    func rangeContextSnapshot(worktreePath: URL, base: String, head: String, threeDot: Bool, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
        try await refContextSnapshot(
            worktreePath: worktreePath,
            baseRef: base,
            headRef: head,
            file: file,
            originalPath: originalPath,
            useMergeBase: threeDot
        )
    }
}

struct RangeReviewLoader {
    let git: RangeReviewGitClient

    init(git: RangeReviewGitClient = GitService()) {
        self.git = git
    }

    func load(
        worktreePath: URL,
        base: String,
        head: String,
        threeDot: Bool,
        files: [CommitChangedFile],
        openFileForPath: @escaping (String) -> (() -> Void)?
    ) async throws -> DiffReviewLoadedSession {
        var sections: [DiffReviewFileSectionModel] = []

        for file in files {
            try Task.checkCancellation()
            let diff = try await git.rangeDiff(
                worktreePath: worktreePath,
                base: base, head: head, threeDot: threeDot,
                file: file.path, originalPath: file.originalPath
            )
            try Task.checkCancellation()

            sections.append(try await fileSection(
                for: file,
                diff: diff,
                worktreePath: worktreePath,
                base: base,
                head: head,
                threeDot: threeDot,
                openFile: openFileForPath(file.path)
            ))
        }

        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }

    private func fileSection(
        for file: CommitChangedFile,
        diff: ParsedDiff,
        worktreePath: URL,
        base: String,
        head: String,
        threeDot: Bool,
        openFile: (() -> Void)?
    ) async throws -> DiffReviewFileSectionModel {
        let canRender = !diff.hunks.isEmpty && !ImageFileType.isSupported(relativePath: file.path)
        let counts = lineCounts(in: diff)
        let summary = DiffReviewFileSummary(
            path: file.path,
            namespace: "range",
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
            openFile: openFile,
            contextProvider: DiffReviewContextProvider {
                try await git.rangeContextSnapshot(
                    worktreePath: worktreePath,
                    base: base, head: head, threeDot: threeDot,
                    file: file.path, originalPath: file.originalPath
                )
            }
        )
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

    private func placeholderMessage(for file: CommitChangedFile, diff: ParsedDiff) -> String {
        if ImageFileType.isSupported(relativePath: file.path) {
            return "Image changes are not available in this review view yet."
        }
        if diff.hunks.isEmpty {
            return "No text diff is available for this file."
        }
        return "This file cannot be rendered in the review view."
    }
}
