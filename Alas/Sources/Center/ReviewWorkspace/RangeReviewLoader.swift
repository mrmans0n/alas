import Foundation

protocol RangeReviewGitClient: Sendable {
    func resolvedRangeTrees(worktreePath: URL, base: String, head: String, threeDot: Bool) async throws -> (before: String, after: String)
    func rangeDiff(worktreePath: URL, revisions: (before: String, after: String), file: String, originalPath: String?) async throws -> ParsedDiff
    func rangeContextSnapshot(worktreePath: URL, base: String, head: String, threeDot: Bool, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot
    func rangeImageProvider(worktreePath: URL, revisions: (before: String, after: String), file: CommitChangedFile) -> DiffReviewImageProvider
    func treeDiffsByFile(worktreePath: URL, revisions: (before: String, after: String), paths: [String]) async throws -> [String: ParsedDiff]
}

extension RangeReviewGitClient {
    /// No batch: every file takes the per-file `rangeDiff` path.
    func treeDiffsByFile(worktreePath: URL, revisions: (before: String, after: String), paths: [String]) async throws -> [String: ParsedDiff] { [:] }
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

    /// `onFileList` receives the files as pending sections before any diff loads.
    @MainActor
    func load(
        worktreePath: URL,
        base: String,
        head: String,
        threeDot: Bool,
        files: [CommitChangedFile],
        openFileForPath: @escaping @MainActor (String) -> (() -> Void)?,
        onFileList: (@MainActor (DiffReviewLoadedSession) -> Void)? = nil
    ) async throws -> DiffReviewLoadedSession {
        onFileList?(DiffReviewBatchLoading.pendingSession(files: files, namespace: "range"))
        let revisions = try await git.resolvedRangeTrees(
            worktreePath: worktreePath,
            base: base,
            head: head,
            threeDot: threeDot
        )
        try Task.checkCancellation()

        let git = git
        let diffs = try await DiffReviewBatchLoading.diffs(
            for: files,
            batched: {
                let byPath = try await git.treeDiffsByFile(worktreePath: worktreePath, revisions: revisions, paths: files.map(\.path))
                return Dictionary(files.compactMap { file in byPath[file.path].map { (file, $0) } }, uniquingKeysWith: { first, _ in first })
            },
            single: { file in
                try await git.rangeDiff(worktreePath: worktreePath, revisions: revisions, file: file.path, originalPath: file.originalPath)
            }
        )
        let displayModels = try await DiffReviewBatchLoading.displayModels(
            for: files.compactMap { file in
                diffs[file].flatMap { Self.canRenderText(file, diff: $0) ? (key: file, diff: $0, filePath: file.path) : nil }
            }
        )

        let sections = files.map { file in
            fileSection(
                for: file,
                diff: diffs[file] ?? ParsedDiff(hunks: []),
                displayModel: displayModels[file],
                worktreePath: worktreePath,
                revisions: revisions,
                base: base,
                head: head,
                threeDot: threeDot,
                openFile: openFileForPath(file.path)
            )
        }

        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }

    private static func isImage(_ file: CommitChangedFile) -> Bool {
        ImageFileType.isSupported(relativePath: file.path)
            || file.originalPath.map(ImageFileType.isSupported(relativePath:)) == true
    }

    private static func canRenderText(_ file: CommitChangedFile, diff: ParsedDiff) -> Bool {
        !diff.hunks.isEmpty && !isImage(file)
    }

    private func fileSection(
        for file: CommitChangedFile,
        diff: ParsedDiff,
        displayModel: DiffDisplayModel?,
        worktreePath: URL,
        revisions: (before: String, after: String),
        base: String,
        head: String,
        threeDot: Bool,
        openFile: (() -> Void)?
    ) -> DiffReviewFileSectionModel {
        let imageProvider = Self.isImage(file)
            ? git.rangeImageProvider(worktreePath: worktreePath, revisions: revisions, file: file)
            : nil
        let canRenderText = Self.canRenderText(file, diff: diff)
        let canRender = canRenderText || imageProvider != nil
        let counts = DiffReviewBatchLoading.lineCounts(in: diff)
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
            displayModel: displayModel,
            placeholderMessage: canRender ? nil : placeholderMessage(for: file, diff: diff),
            openFile: openFile,
            contextProvider: DiffReviewContextProvider {
                try await git.rangeContextSnapshot(
                    worktreePath: worktreePath,
                    base: base, head: head, threeDot: threeDot,
                    file: file.path, originalPath: file.originalPath
                )
            },
            imageProvider: imageProvider
        )
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
