import Foundation

protocol ReviewChangesGitClient {
    func status(worktreePath: URL) async throws -> [ChangedFile]
    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff
}

extension GitService: ReviewChangesGitClient {}

struct ReviewChangesLoader {
    let git: ReviewChangesGitClient

    init(git: ReviewChangesGitClient = GitService()) {
        self.git = git
    }

    @MainActor
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
                staged: change.stage == .staged,
                originalPath: change.renameFrom
            )
            try Task.checkCancellation()

            files.append(try await fileSection(for: change, diff: diff))
        }

        return ReviewChangesLoadedSession(
            files: files,
            summary: ReviewChangesSessionModel(files: files.map(\.summary), groupsEnabled: true)
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

    private func fileSection(for change: ChangedFile, diff: ParsedDiff) async throws -> ReviewChangesFileSectionModel {
        let source = ReviewChangesSource(stage: change.stage)
        let canRender = !diff.hunks.isEmpty && !ImageFileType.isSupported(relativePath: change.path)
        let counts = lineCounts(in: diff)
        let summary = DiffReviewFileSummary(
            path: change.path,
            namespace: source.rawValue,
            groupID: source.rawValue,
            groupTitle: source.title,
            status: DiffReviewFileStatus(gitStatus: change.status, conflict: change.conflict),
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: canRender,
            originalPath: change.renameFrom
        )

        return ReviewChangesFileSectionModel(
            summary: summary,
            parsedDiff: diff,
            displayModel: canRender
                ? try await buildDisplayModel(diff: diff, filePath: change.path)
                : nil,
            placeholderMessage: canRender ? nil : placeholderMessage(for: change, diff: diff),
            openFile: nil
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
