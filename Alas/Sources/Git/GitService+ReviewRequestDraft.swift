import Foundation

struct ReviewRequestDraftContext: Equatable {
    let commitSubjects: [String]
    let commits: [CommitInfo]
    let changedFiles: [CommitChangedFile]
    let diff: String
    let fileDiffsByPath: [String: String]
    let hasUncommittedChanges: Bool
    let singleCommitBody: String?
    /// The HEAD commit every read was pinned to.
    let headSHA: String?
    /// Where the branch forks from the base, or nil when Git finds none. The
    /// branch diff and commit list change exactly when this or HEAD moves.
    let mergeBaseSHA: String?
    /// Changed files Git reports without line counts (`-` in numstat).
    let binaryPaths: Set<String>

    init(
        commitSubjects: [String],
        commits: [CommitInfo],
        changedFiles: [CommitChangedFile],
        diff: String,
        fileDiffsByPath: [String: String],
        hasUncommittedChanges: Bool,
        singleCommitBody: String? = nil,
        headSHA: String? = nil,
        mergeBaseSHA: String? = nil,
        binaryPaths: Set<String> = []
    ) {
        self.commitSubjects = commitSubjects
        self.commits = commits
        self.changedFiles = changedFiles
        self.diff = diff
        self.fileDiffsByPath = fileDiffsByPath
        self.hasUncommittedChanges = hasUncommittedChanges
        self.singleCommitBody = singleCommitBody
        self.headSHA = headSHA
        self.mergeBaseSHA = mergeBaseSHA
        self.binaryPaths = binaryPaths
    }
}

struct ReviewRequestRangeIdentity: Equatable, Sendable {
    let head: String?
    let mergeBase: String?
    let hasUncommittedChanges: Bool?
}

extension GitService {
    func reviewRequestDraftContext(worktreePath: URL, baseRef: String) async throws -> ReviewRequestDraftContext {
        // Every read below uses these commits, so a ref that moves mid-load
        // cannot mix two ranges into one context.
        let base = try await reviewRequestCommit(baseRef, worktreePath: worktreePath)
        let head = try await reviewRequestCommit("HEAD", worktreePath: worktreePath)
        let diffRange = "\(base)...\(head)"
        let logRange = "\(base)..\(head)"
        async let subjectsResult = Process.git(
            ["log", logRange, "--pretty=format:%s"],
            cwd: worktreePath
        )
        async let commitsResult = Process.git(
            ["log", logRange, "--pretty=tformat:%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s", "--numstat"],
            cwd: worktreePath
        )
        async let diffResult = Process.git(
            ["-c", "core.quotePath=false", "diff", "--no-color", "-M", diffRange],
            cwd: worktreePath
        )
        async let filesResult = Process.git(
            ["-c", "core.quotePath=false", "diff", "--no-color", "-M", "--numstat", diffRange],
            cwd: worktreePath
        )
        async let namesResult = Process.git(
            ["-c", "core.quotePath=false", "diff", "--no-color", "-M", "--name-status", diffRange],
            cwd: worktreePath
        )
        async let statusResult = Process.git(
            ["status", "--porcelain"],
            cwd: worktreePath
        )
        async let mergeBase = reviewRequestMergeBase(worktreePath: worktreePath, baseRef: base, headRef: head)
        async let commitBodyResult = Process.git(
            ["log", logRange, "--pretty=format:%b"],
            cwd: worktreePath
        )

        let subjects = try await subjectsResult
        let commits = try await commitsResult
        let diff = try await diffResult
        let files = try await filesResult
        let names = try await namesResult
        let status = try await statusResult
        let commitBody = try await commitBodyResult

        try Self.assertReviewRequestSuccess(subjects)
        try Self.assertReviewRequestSuccess(commits)
        try Self.assertReviewRequestSuccess(diff)
        try Self.assertReviewRequestSuccess(files)
        try Self.assertReviewRequestSuccess(names)
        try Self.assertReviewRequestSuccess(status)
        try Self.assertReviewRequestSuccess(commitBody)

        let commitSubjects = subjects.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        let singleCommitBody = commitSubjects.count == 1
            ? commitBody.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let changedFiles = Self.reviewRequestChangedFiles(numstat: files.stdout, nameStatus: names.stdout)
        var fileDiffsByPath: [String: String] = [:]
        for file in changedFiles {
            let fileDiff = try await Process.git(
                [
                    "-c",
                    "core.quotePath=false",
                    "diff",
                    "--no-color",
                    "-M",
                    diffRange,
                    "--",
                ] + file.diffPathspecs,
                cwd: worktreePath
            )
            try Self.assertReviewRequestSuccess(fileDiff)
            fileDiffsByPath[file.path] = fileDiff.stdout
        }

        return ReviewRequestDraftContext(
            commitSubjects: commitSubjects,
            commits: Self.reviewRequestCommits(log: commits.stdout),
            changedFiles: changedFiles,
            diff: diff.stdout,
            fileDiffsByPath: fileDiffsByPath,
            hasUncommittedChanges: !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            singleCommitBody: singleCommitBody,
            headSHA: head,
            mergeBaseSHA: await mergeBase,
            binaryPaths: Self.reviewRequestBinaryPaths(numstat: files.stdout)
        )
    }

    /// HEAD, the merge base with `baseRef`, and whether the tree is dirty, as
    /// they are now, for checking that loaded branch context still describes
    /// the repository. A failed read is nil and matches nothing. HEAD is read
    /// on both sides of the other reads; if it moved meanwhile they may mix
    /// two states, so the head is reported as unknown.
    func reviewRequestRangeIdentity(worktreePath: URL, baseRef: String) async -> ReviewRequestRangeIdentity {
        let before = await reviewRequestHead(worktreePath: worktreePath)
        async let status = Process.git(["status", "--porcelain"], cwd: worktreePath)
        async let mergeBase = reviewRequestMergeBase(worktreePath: worktreePath, baseRef: baseRef)
        let dirty = (try? await status).flatMap { $0.exitCode == 0 ? $0.stdout : nil }
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let resolvedMergeBase = await mergeBase
        let after = await reviewRequestHead(worktreePath: worktreePath)
        return ReviewRequestRangeIdentity(
            head: before == after ? after : nil,
            mergeBase: resolvedMergeBase,
            hasUncommittedChanges: dirty
        )
    }

    private func reviewRequestHead(worktreePath: URL) async -> String? {
        guard let result = try? await Process.git(["rev-parse", "HEAD"], cwd: worktreePath),
              result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reviewRequestCommit(_ ref: String, worktreePath: URL) async throws -> String {
        let result = try await Process.git(["rev-parse", "--verify", "\(ref)^{commit}"], cwd: worktreePath)
        try Self.assertReviewRequestSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reviewRequestMergeBase(worktreePath: URL, baseRef: String, headRef: String = "HEAD") async -> String? {
        guard let result = try? await Process.git(["merge-base", baseRef, headRef], cwd: worktreePath),
              result.exitCode == 0 else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private static func assertReviewRequestSuccess(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
    }

    /// Destination paths of numstat entries whose counts are `-`, which Git
    /// uses for binary files.
    static func reviewRequestBinaryPaths(numstat: String) -> Set<String> {
        Set(numstat.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3, parts[0] == "-", parts[1] == "-" else { return nil }
            return NumstatParser.destinationPath(from: String(parts[2]))
        })
    }

    private static func reviewRequestChangedFiles(numstat: String, nameStatus: String) -> [CommitChangedFile] {
        let stats = NumstatParser.parse(numstat)

        return nameStatus
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 2 else { return nil }
                let status = String(parts[0].prefix(1))
                let path = String(parts.last ?? "")
                let originalPath = parts.count >= 3 ? String(parts[1]) : nil
                let stat = stats[path] ?? (0, 0)
                return CommitChangedFile(
                    path: path,
                    originalPath: originalPath,
                    status: status,
                    add: stat.add,
                    del: stat.del
                )
            }
    }

    private static func reviewRequestCommits(log: String) -> [CommitInfo] {
        let records = log
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .map(String.init)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        return records.compactMap { record in
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard let headerLine = lines.first else { return nil }
            let fields = headerLine.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5 else { return nil }

            let rawSubject = String(fields[4])
            let (tag, subject) = CommitInfo.parseConventional(subject: rawSubject)
            var filesChanged = 0
            var additions = 0
            var deletions = 0
            for line in lines.dropFirst() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { continue }
                let parts = trimmedLine.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                filesChanged += 1
                if let add = Int(parts[0]) { additions += add }
                if let del = Int(parts[1]) { deletions += del }
            }

            return CommitInfo(
                sha: String(fields[0]),
                shortSha: String(fields[1]),
                author: String(fields[2]),
                authorInitials: CommitInfo.initials(for: String(fields[2])),
                date: isoFormatter.date(from: String(fields[3])) ?? Date(timeIntervalSince1970: 0),
                subject: subject,
                rawSubject: rawSubject,
                conventionalTag: tag,
                filesChanged: filesChanged,
                insertions: additions,
                deletions: deletions
            )
        }
    }
}

private extension CommitChangedFile {
    var diffPathspecs: [String] {
        if let originalPath, originalPath != path {
            return [originalPath, path]
        }
        return [path]
    }
}
