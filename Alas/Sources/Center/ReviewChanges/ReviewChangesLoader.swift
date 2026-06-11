import Foundation

protocol ReviewChangesGitClient {
    func status(worktreePath: URL) async throws -> [ChangedFile]
    func diff(worktreePath: URL, file: String, staged: Bool) async throws -> ParsedDiff
}

extension GitService: ReviewChangesGitClient {}

struct ReviewChangesLoader {
    let git: ReviewChangesGitClient

    init(git: ReviewChangesGitClient = GitService()) {
        self.git = git
    }

    func load(worktreePath: URL) async throws -> ReviewChangesLoadedSession {
        try Task.checkCancellation()
        let status = try await git.status(worktreePath: worktreePath)
        try Task.checkCancellation()

        var files: [ReviewChangesFileSectionModel] = []
        for change in orderedReviewableChanges(status) {
            try Task.checkCancellation()
            let diff = try await git.diff(
                worktreePath: worktreePath,
                file: change.path,
                staged: change.stage == .staged
            )
            try Task.checkCancellation()

            files.append(fileSection(for: change, diff: diff))
        }

        return ReviewChangesLoadedSession(
            files: files,
            summary: ReviewChangesSessionModel(files: files.map(\.summary))
        )
    }

    private func orderedReviewableChanges(_ changes: [ChangedFile]) -> [ChangedFile] {
        changes
            .filter { $0.conflict == nil }
            .sorted { lhs, rhs in
                let lhsSource = ReviewChangesSource(stage: lhs.stage)
                let rhsSource = ReviewChangesSource(stage: rhs.stage)
                if lhsSource != rhsSource {
                    return lhsSource < rhsSource
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    private func fileSection(for change: ChangedFile, diff: ParsedDiff) -> ReviewChangesFileSectionModel {
        let source = ReviewChangesSource(stage: change.stage)
        let canRender = !diff.hunks.isEmpty && !ImageFileType.isSupported(relativePath: change.path)
        let summary = ReviewChangesFileSummary(
            path: change.path,
            source: source,
            status: ReviewChangesFileStatus(gitStatus: change.status, conflict: change.conflict),
            additions: change.add,
            deletions: change.del,
            isRenderable: canRender,
            originalPath: change.renameFrom
        )

        return ReviewChangesFileSectionModel(
            summary: summary,
            parsedDiff: diff,
            displayModel: canRender
                ? DiffDisplayModelBuilder.build(diff: diff, filePath: change.path)
                : nil,
            placeholderMessage: canRender ? nil : placeholderMessage(for: change, diff: diff)
        )
    }

    private func placeholderMessage(for change: ChangedFile, diff: ParsedDiff) -> String {
        if ImageFileType.isSupported(relativePath: change.path) {
            return "Image changes are not available in this review view yet."
        }
        if diff.hunks.isEmpty {
            return "No text diff is available for this file."
        }
        return "This file cannot be rendered in the review view."
    }
}

private extension ReviewChangesSource {
    init(stage: ChangeStage) {
        switch stage {
        case .unstaged:
            self = .unstaged
        case .staged:
            self = .staged
        }
    }
}
