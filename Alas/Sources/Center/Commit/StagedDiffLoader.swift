import Foundation

protocol StagedDiffGitClient {
    func stagedChangedFiles(at worktreePath: URL) async throws -> [CommitChangedFile]
    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff
    func stagedImageProvider(worktreePath: URL, file: CommitChangedFile) async -> DiffReviewImageProvider
}

extension GitService: StagedDiffGitClient {}

struct StagedDiffLoader {
    let git: StagedDiffGitClient

    init(git: StagedDiffGitClient = GitService()) {
        self.git = git
    }

    @MainActor
    func load(worktreePath: URL) async throws -> DiffReviewLoadedSession {
        try Task.checkCancellation()
        let stagedFiles = try await git.stagedChangedFiles(at: worktreePath)
        try Task.checkCancellation()

        var sections: [DiffReviewFileSectionModel] = []
        for file in stagedFiles {
            try Task.checkCancellation()
            let diff = try await git.diff(
                worktreePath: worktreePath,
                file: file.path,
                staged: true,
                originalPath: file.originalPath
            )
            try Task.checkCancellation()

            sections.append(try await fileSection(for: file, diff: diff, worktreePath: worktreePath))
        }

        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }

    private func fileSection(
        for file: CommitChangedFile,
        diff: ParsedDiff,
        worktreePath: URL
    ) async throws -> DiffReviewFileSectionModel {
        let isImage = ImageFileType.isSupported(relativePath: file.path)
            || file.originalPath.map(ImageFileType.isSupported(relativePath:)) == true
        let canRenderText = !diff.hunks.isEmpty && !isImage
        let counts = lineCounts(in: diff)
        let summary = DiffReviewFileSummary(
            path: file.path,
            namespace: "staged",
            groupID: nil,
            groupTitle: nil,
            status: DiffReviewFileStatus(gitStatus: file.status),
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: isImage || canRenderText,
            originalPath: file.originalPath,
            gitStatus: file.status
        )

        return DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: diff,
            displayModel: canRenderText
                ? try await buildDisplayModel(diff: diff, filePath: file.path)
                : nil,
            placeholderMessage: (isImage || canRenderText) ? nil : placeholderMessage(for: file, diff: diff),
            openFile: nil,
            contextProvider: nil,
            imageProvider: isImage
                ? await git.stagedImageProvider(worktreePath: worktreePath, file: file)
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
