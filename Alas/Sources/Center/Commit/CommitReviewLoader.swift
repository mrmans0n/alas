import Foundation

protocol CommitReviewGitClient: Sendable {
    func diff(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> ParsedDiff
    func commitContextSnapshot(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot
    func commitImageProvider(worktreePath: URL, sha: String, file: CommitChangedFile) -> DiffReviewImageProvider
    func commitDiffsByFile(worktreePath: URL, sha: String, paths: [String]) async throws -> [String: ParsedDiff]
}

extension CommitReviewGitClient {
    /// No batch: every file takes the per-file `diff` path.
    func commitDiffsByFile(worktreePath: URL, sha: String, paths: [String]) async throws -> [String: ParsedDiff] { [:] }
}

extension GitService: CommitReviewGitClient {}

struct CommitReviewLoader {
    let git: CommitReviewGitClient

    init(git: CommitReviewGitClient = GitService()) {
        self.git = git
    }

    /// Loads commit review sections. `openFileForPath` is evaluated during
    /// loading and must be a lightweight, pure factory; put UI work in the
    /// returned closure instead of the factory itself. `onFileList` receives
    /// the files as pending sections before any diff loads.
    @MainActor
    func load(
        worktreePath: URL,
        sha: String,
        files: [CommitChangedFile],
        openFileForPath: @escaping @MainActor (String) -> (() -> Void)?,
        onFileList: (@MainActor (DiffReviewLoadedSession) -> Void)? = nil
    ) async throws -> DiffReviewLoadedSession {
        onFileList?(DiffReviewBatchLoading.pendingSession(files: files, namespace: "commit"))
        try Task.checkCancellation()

        let git = git
        let diffs = try await DiffReviewBatchLoading.diffs(
            for: files,
            batched: {
                let byPath = try await git.commitDiffsByFile(worktreePath: worktreePath, sha: sha, paths: files.map(\.path))
                return Dictionary(files.compactMap { file in byPath[file.path].map { (file, $0) } }, uniquingKeysWith: { first, _ in first })
            },
            single: { file in
                try await git.diff(worktreePath: worktreePath, sha: sha, file: file.path, originalPath: file.originalPath)
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
                sha: sha,
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
        sha: String,
        openFile: (() -> Void)?
    ) -> DiffReviewFileSectionModel {
        let isImage = Self.isImage(file)
        let canRenderText = Self.canRenderText(file, diff: diff)
        let counts = DiffReviewBatchLoading.lineCounts(in: diff)
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
            displayModel: displayModel,
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
