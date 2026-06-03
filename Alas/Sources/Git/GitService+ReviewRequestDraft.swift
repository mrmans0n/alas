import Foundation

struct ReviewRequestDraftContext: Equatable {
    let commitSubjects: [String]
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
        async let diffResult = Process.git(
            ["diff", "--no-color", "-M", diffRange],
            cwd: worktreePath
        )
        async let filesResult = Process.git(
            ["diff", "--no-color", "-M", "--numstat", diffRange],
            cwd: worktreePath
        )
        async let namesResult = Process.git(
            ["diff", "--no-color", "-M", "--name-status", diffRange],
            cwd: worktreePath
        )
        async let statusResult = Process.git(
            ["status", "--porcelain"],
            cwd: worktreePath
        )

        let subjects = try await subjectsResult
        let diff = try await diffResult
        let files = try await filesResult
        let names = try await namesResult
        let status = try await statusResult

        try Self.assertReviewRequestSuccess(subjects)
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
}

private extension CommitChangedFile {
    var diffPathspecs: [String] {
        if let originalPath, originalPath != path {
            return [originalPath, path]
        }
        return [path]
    }
}
