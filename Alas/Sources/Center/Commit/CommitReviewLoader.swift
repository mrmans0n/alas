import Foundation

protocol CommitReviewGitClient {
    func diff(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> ParsedDiff
    func commitContextSnapshot(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot
    func commitImageProvider(worktreePath: URL, sha: String, file: CommitChangedFile) -> DiffReviewImageProvider
}

extension GitService: CommitReviewGitClient {}

struct CommitReviewLoader {
    let git: CommitReviewGitClient

    init(git: CommitReviewGitClient = GitService()) {
        self.git = git
    }

    /// Loads commit review sections. `openFileForPath` is evaluated during
    /// loading and must be a lightweight, pure factory; put UI work in the
    /// returned closure instead of the factory itself.
    func load(
        worktreePath: URL,
        sha: String,
        files: [CommitChangedFile],
        openFileForPath: @escaping (String) -> (() -> Void)?
    ) async throws -> DiffReviewLoadedSession {
        var sections: [DiffReviewFileSectionModel] = []

        for file in files {
            try Task.checkCancellation()
            let diff = try await git.diff(
                worktreePath: worktreePath,
                sha: sha,
                file: file.path,
                originalPath: file.originalPath
            )
            try Task.checkCancellation()

            sections.append(try await fileSection(
                for: file,
                diff: diff,
                worktreePath: worktreePath,
                sha: sha,
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
        sha: String,
        openFile: (() -> Void)?
    ) async throws -> DiffReviewFileSectionModel {
        let isImage = ImageFileType.isSupported(relativePath: file.path)
            || file.originalPath.map(ImageFileType.isSupported(relativePath:)) == true
        let canRenderText = !diff.hunks.isEmpty && !isImage
        let counts = lineCounts(in: diff)
        let summary = DiffReviewFileSummary(
            path: file.path,
            namespace: "commit",
            groupID: nil,
            groupTitle: nil,
            status: DiffReviewFileStatus(gitStatus: file.status),
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: isImage || canRenderText,
            originalPath: file.originalPath
        )

        return DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: diff,
            displayModel: canRenderText
                ? try await buildDisplayModel(diff: diff, filePath: file.path)
                : nil,
            placeholderMessage: (isImage || canRenderText) ? nil : placeholderMessage(for: file, diff: diff),
            openFile: openFile,
            contextProvider: DiffReviewContextProvider {
                try await git.commitContextSnapshot(
                    worktreePath: worktreePath,
                    sha: sha,
                    file: file.path,
                    originalPath: file.originalPath
                )
            },
            imageProvider: isImage
                ? git.commitImageProvider(worktreePath: worktreePath, sha: sha, file: file)
                : nil
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
