import Foundation

protocol ReviewChangesGitClient: Sendable {
    func status(worktreePath: URL) async throws -> [ChangedFile]
    func imageStatus(worktreePath: URL) async throws -> [ChangedFile]
    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff
    func contextSnapshot(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> DiffReviewFileContextSnapshot
    func workingCopyImageProvider(worktreePath: URL, change: ChangedFile) async -> DiffReviewImageProvider
    func workingCopyDiffsByFile(worktreePath: URL, staged: Bool, paths: [String]) async throws -> [String: ParsedDiff]
}

extension ReviewChangesGitClient {
    /// No batch: every file takes the per-file `diff` path.
    func workingCopyDiffsByFile(worktreePath: URL, staged: Bool, paths: [String]) async throws -> [String: ParsedDiff] { [:] }
}

extension GitService: ReviewChangesGitClient {}

struct ReviewChangesLoader {
    let git: ReviewChangesGitClient

    init(git: ReviewChangesGitClient = GitService()) {
        self.git = git
    }

    /// `onFileList` receives the changes as pending sections, with counts from
    /// `git status`, before any diff loads.
    @MainActor
    func load(
        worktreePath: URL,
        onFileList: (@MainActor (ReviewChangesLoadedSession) -> Void)? = nil
    ) async throws -> ReviewChangesLoadedSession {
        try Task.checkCancellation()
        async let normalStatus = git.status(worktreePath: worktreePath)
        async let imageStatus = git.imageStatus(worktreePath: worktreePath)
        let status = try await normalStatus
        let imageChanges = try await imageStatus
        try Task.checkCancellation()

        let changes = orderedReviewableChanges(reconciling: status, with: imageChanges)
        onFileList?(Self.pendingSession(changes: changes))

        let git = git
        let keys = changes.map(ReviewChangesDiffKey.init)
        // The batch detects renames only, so a copy (`status.renames=copies`)
        // would come back as a whole-file add; copies diff singly with `-C`.
        let batchedKeys = keys.filter { !$0.isCopy }
        let diffs = try await DiffReviewBatchLoading.diffs(
            for: keys,
            batched: {
                async let unstaged = git.workingCopyDiffsByFile(
                    worktreePath: worktreePath, staged: false,
                    paths: batchedKeys.filter { $0.stage == .unstaged }.map(\.path)
                )
                async let staged = git.workingCopyDiffsByFile(
                    worktreePath: worktreePath, staged: true,
                    paths: batchedKeys.filter { $0.stage == .staged }.map(\.path)
                )
                let byStage = try await (unstaged: unstaged, staged: staged)
                return Dictionary(batchedKeys.compactMap { key in
                    (key.stage == .staged ? byStage.staged : byStage.unstaged)[key.path].map { (key, $0) }
                }, uniquingKeysWith: { first, _ in first })
            },
            single: { key in
                try await git.diff(
                    worktreePath: worktreePath,
                    file: key.path,
                    staged: key.stage == .staged,
                    originalPath: key.renameFrom
                )
            }
        )
        let displayModels = try await DiffReviewBatchLoading.displayModels(
            for: zip(changes, keys).compactMap { change, key in
                diffs[key].flatMap { Self.canRenderText(change, diff: $0) ? (key: key, diff: $0, filePath: change.path) : nil }
            }
        )

        var files: [ReviewChangesFileSectionModel] = []
        for (change, key) in zip(changes, keys) {
            files.append(await fileSection(
                for: change,
                diff: diffs[key] ?? ParsedDiff(hunks: []),
                displayModel: displayModels[key],
                worktreePath: worktreePath
            ))
        }

        return ReviewChangesLoadedSession(
            files: files,
            summary: ReviewChangesSessionModel(files: files.map(\.summary), groupsEnabled: true)
        )
    }

    private static func pendingSession(changes: [ChangedFile]) -> ReviewChangesLoadedSession {
        let files = changes.map { change in
            let source = ReviewChangesSource(stage: change.stage)
            return ReviewChangesFileSectionModel.pending(summary: DiffReviewFileSummary(
                path: change.path,
                namespace: source.rawValue,
                groupID: source.rawValue,
                groupTitle: source.title,
                status: DiffReviewFileStatus(gitStatus: change.status, conflict: change.conflict),
                additions: change.add,
                deletions: change.del,
                isRenderable: true,
                originalPath: change.renameFrom
            ))
        }
        return ReviewChangesLoadedSession(
            files: files,
            summary: ReviewChangesSessionModel(files: files.map(\.summary), groupsEnabled: true)
        )
    }

    private static func isImage(_ change: ChangedFile) -> Bool {
        ImageFileType.isSupported(relativePath: change.path)
            || change.renameFrom.map(ImageFileType.isSupported(relativePath:)) == true
    }

    private static func canRenderText(_ change: ChangedFile, diff: ParsedDiff) -> Bool {
        !diff.hunks.isEmpty && !isImage(change)
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

    private func orderedReviewableChanges(
        reconciling normalStatus: [ChangedFile],
        with imageStatus: [ChangedFile]
    ) -> [ChangedFile] {
        let imageRenames = imageStatus.filter {
            $0.status == "R"
                && ImageFileType.isSupported(relativePath: $0.path)
                && $0.renameFrom.map(ImageFileType.isSupported(relativePath:)) == true
        }
        let renamedDestinations = Dictionary(
            uniqueKeysWithValues: imageRenames.map { (ReviewChangesPathStage(path: $0.path, stage: $0.stage), $0) }
        )
        let renamedSources = Set(imageRenames.compactMap { rename in
            rename.renameFrom.map { ReviewChangesPathStage(path: $0, stage: rename.stage) }
        })

        return orderedReviewableChanges(normalStatus.compactMap { change in
            let pathStage = ReviewChangesPathStage(path: change.path, stage: change.stage)
            if let rename = renamedDestinations[pathStage] {
                return rename
            }
            if renamedSources.contains(pathStage) {
                return nil
            }
            return change
        })
    }

    private func fileSection(
        for change: ChangedFile,
        diff: ParsedDiff,
        displayModel: DiffDisplayModel?,
        worktreePath: URL
    ) async -> ReviewChangesFileSectionModel {
        let source = ReviewChangesSource(stage: change.stage)
        let staged = change.stage == .staged
        let isImage = Self.isImage(change)
        let canRenderText = Self.canRenderText(change, diff: diff)
        let counts = DiffReviewBatchLoading.lineCounts(in: diff)
        let summary = DiffReviewFileSummary(
            path: change.path,
            namespace: source.rawValue,
            groupID: source.rawValue,
            groupTitle: source.title,
            status: DiffReviewFileStatus(gitStatus: change.status, conflict: change.conflict),
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: isImage || canRenderText,
            originalPath: change.renameFrom
        )

        return ReviewChangesFileSectionModel(
            summary: summary,
            parsedDiff: diff,
            displayModel: displayModel,
            placeholderMessage: (isImage || canRenderText) ? nil : placeholderMessage(for: change, diff: diff),
            openFile: nil,
            contextProvider: DiffReviewContextProvider {
                try await git.contextSnapshot(
                    worktreePath: worktreePath,
                    file: change.path,
                    staged: staged,
                    originalPath: change.renameFrom
                )
            },
            imageProvider: isImage
                ? await git.workingCopyImageProvider(worktreePath: worktreePath, change: change)
                : nil
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

private struct ReviewChangesPathStage: Hashable {
    let path: String
    let stage: ChangeStage
}

private struct ReviewChangesDiffKey: Hashable, Sendable {
    let path: String
    let stage: ChangeStage
    let renameFrom: String?
    let isCopy: Bool

    init(_ change: ChangedFile) {
        path = change.path
        stage = change.stage
        renameFrom = change.renameFrom
        isCopy = change.status == "C"
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
