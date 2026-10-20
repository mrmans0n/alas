import Foundation

/// Shared loading steps for the review loaders: take what one batched
/// `git diff` produced, diff the rest per file, then build display models.
enum DiffReviewBatchLoading {
    /// Bounds the per-file fallback; each one is a git process.
    static let maxConcurrentFallbacks = 8

    /// Diffs for `keys`, taken from `batched` when it covers them and loaded
    /// one by one otherwise. A failed batch only costs the per-file path.
    static func diffs<Key: Hashable & Sendable>(
        for keys: [Key],
        batched: @Sendable () async throws -> [Key: ParsedDiff],
        single: @escaping @Sendable (Key) async throws -> ParsedDiff
    ) async throws -> [Key: ParsedDiff] {
        var diffs: [Key: ParsedDiff]
        do {
            diffs = try await batched()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diffs = [:]
        }
        try Task.checkCancellation()

        let missing = keys.filter { diffs[$0] == nil }
        try await withThrowingTaskGroup(of: (Key, ParsedDiff).self) { group in
            var next = 0
            func addNext() {
                guard next < missing.count else { return }
                let key = missing[next]
                next += 1
                group.addTask { (key, try await single(key)) }
            }
            for _ in 0..<maxConcurrentFallbacks { addNext() }
            while let (key, diff) = try await group.next() {
                diffs[key] = diff
                addNext()
            }
        }
        return diffs
    }

    /// Display models for the diffs that render as text, keyed like `diffs`.
    static func displayModels<Key: Hashable>(
        for items: [(key: Key, diff: ParsedDiff, filePath: String)]
    ) async throws -> [Key: DiffDisplayModel] {
        let models = try await DiffDisplayModelBuilder.buildConcurrently(
            items.map { (diff: $0.diff, filePath: $0.filePath) }
        )
        try Task.checkCancellation()
        return Dictionary(zip(items.map(\.key), models), uniquingKeysWith: { first, _ in first })
    }

    /// The file list as pending sections, shown while the diffs load.
    static func pendingSession(files: [CommitChangedFile], namespace: String) -> DiffReviewLoadedSession {
        let sections = files.map { file in
            DiffReviewFileSectionModel.pending(summary: DiffReviewFileSummary(
                path: file.path,
                namespace: namespace,
                groupID: nil,
                groupTitle: nil,
                status: DiffReviewFileStatus(gitStatus: file.status),
                additions: file.add,
                deletions: file.del,
                isRenderable: true,
                originalPath: file.originalPath
            ))
        }
        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }

    static func lineCounts(in diff: ParsedDiff) -> (additions: Int, deletions: Int) {
        diff.hunks.reduce(into: (additions: 0, deletions: 0)) { counts, hunk in
            for line in hunk.lines {
                switch line.kind {
                case .add: counts.additions += 1
                case .delete: counts.deletions += 1
                case .context: break
                }
            }
        }
    }
}
