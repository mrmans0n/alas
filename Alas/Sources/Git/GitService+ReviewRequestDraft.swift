import Foundation

struct ReviewRequestDraftContext: Equatable {
    let commitSubjects: [String]
    let commits: [CommitInfo]
    let changedFiles: [CommitChangedFile]
    let diff: String
    let fileDiffsByPath: [String: String]
    let hasUncommittedChanges: Bool
}

extension GitService {
    func reviewRequestDraftContext(worktreePath: URL, baseRef: String) async throws -> ReviewRequestDraftContext {
        let diffRange = "\(baseRef)...HEAD"
        async let subjectsResult = Process.git(
            ["log", "\(baseRef)..HEAD", "--pretty=format:%s"],
            cwd: worktreePath
        )
        async let commitsResult = Process.git(
            ["log", "\(baseRef)..HEAD", "--pretty=tformat:%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s", "--numstat"],
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

        let subjects = try await subjectsResult
        let commits = try await commitsResult
        let diff = try await diffResult
        let files = try await filesResult
        let names = try await namesResult
        let status = try await statusResult

        try Self.assertReviewRequestSuccess(subjects)
        try Self.assertReviewRequestSuccess(commits)
        try Self.assertReviewRequestSuccess(diff)
        try Self.assertReviewRequestSuccess(files)
        try Self.assertReviewRequestSuccess(names)
        try Self.assertReviewRequestSuccess(status)

        let commitSubjects = subjects.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

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
            hasUncommittedChanges: !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private static func assertReviewRequestSuccess(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
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
