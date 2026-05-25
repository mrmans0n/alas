import Foundation

struct CommitEditResult: Equatable {
    let currentSha: String
    let shaMap: [String: String]
}

enum CommitEditAction: Equatable {
    case message(subject: String, body: String)
    case dropFile(path: String)
    case dropHunk(path: String, hunk: ParsedDiff.Hunk)
}

enum CommitEditError: LocalizedError, Equatable {
    case dirtyWorktree
    case operationInProgress
    case targetNotAboveFold
    case mergeCommitUnsupported(String)
    case emptySubject
    case unsupportedAction
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .dirtyWorktree:
            return "Commit editing requires a clean worktree."
        case .operationInProgress:
            return "Another git operation is already in progress."
        case .targetNotAboveFold:
            return "The selected commit is not above the base commit."
        case .mergeCommitUnsupported(let sha):
            return "Merge commit editing is not supported: \(sha)"
        case .emptySubject:
            return "Commit subject cannot be empty."
        case .unsupportedAction:
            return "This commit editing action is not supported yet."
        case .gitFailed(let message):
            return message
        }
    }
}

extension GitService {
    func editCommit(
        worktreePath: URL,
        baseRef: String,
        targetSha: String,
        action: CommitEditAction
    ) async throws -> CommitEditResult {
        let subject: String
        let body: String
        switch action {
        case .message(let newSubject, let newBody):
            subject = newSubject.trimmingCharacters(in: .whitespacesAndNewlines)
            body = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        case .dropFile, .dropHunk:
            throw CommitEditError.unsupportedAction
        }

        guard !subject.isEmpty else { throw CommitEditError.emptySubject }
        try await validateEditableState(worktreePath: worktreePath)

        let chain = try await gitLines(["rev-list", "--reverse", "\(baseRef)..HEAD"], cwd: worktreePath)
        guard let targetIndex = chain.firstIndex(of: targetSha) else {
            throw CommitEditError.targetNotAboveFold
        }
        let replayRange = Array(chain[targetIndex...])

        for sha in replayRange {
            let parentCount = try await parents(of: sha, cwd: worktreePath).count
            if parentCount > 1 {
                throw CommitEditError.mergeCommitUnsupported(sha)
            }
        }

        let anchor = try await firstParent(of: targetSha, cwd: worktreePath) ?? baseRef
        let backupBranch = "alas-edit-backup-\(UUID().uuidString)"
        try await runGit(["branch", backupBranch, "HEAD"], cwd: worktreePath)

        var shouldDeleteBackup = true
        do {
            try await runGit(["reset", "--hard", anchor], cwd: worktreePath)

            var shaMap: [String: String] = [:]
            let author = try await gitOutput(["show", "-s", "--format=%an <%ae>", targetSha], cwd: worktreePath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try await runGit(["cherry-pick", "--no-commit", targetSha], cwd: worktreePath)
            var commitArgs = ["commit", "--author", author, "-m", subject]
            if !body.isEmpty {
                commitArgs += ["-m", body]
            }
            try await runGit(commitArgs, cwd: worktreePath)
            let currentSha = try await headSha(cwd: worktreePath)
            shaMap[targetSha] = currentSha

            for sha in replayRange.dropFirst() {
                try await runGit(["cherry-pick", sha], cwd: worktreePath)
                shaMap[sha] = try await headSha(cwd: worktreePath)
            }

            try await runGit(["branch", "-D", backupBranch], cwd: worktreePath)
            shouldDeleteBackup = false
            return CommitEditResult(currentSha: currentSha, shaMap: shaMap)
        } catch {
            _ = try? await Process.git(["cherry-pick", "--abort"], cwd: worktreePath)
            _ = try? await Process.git(["reset", "--hard", backupBranch], cwd: worktreePath)
            if shouldDeleteBackup {
                _ = try? await Process.git(["branch", "-D", backupBranch], cwd: worktreePath)
            }
            throw error
        }
    }
}

private extension GitService {
    func validateEditableState(worktreePath: URL) async throws {
        let status = try await gitOutput(["status", "--porcelain=v1"], cwd: worktreePath)
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CommitEditError.dirtyWorktree
        }

        let gitDir = try await gitOutput(["rev-parse", "--absolute-git-dir"], cwd: worktreePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirURL = URL(fileURLWithPath: gitDir)
        let operationPaths = [
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "rebase-merge",
            "rebase-apply"
        ]
        for path in operationPaths where FileManager.default.fileExists(atPath: gitDirURL.appendingPathComponent(path).path) {
            throw CommitEditError.operationInProgress
        }
    }

    func parents(of sha: String, cwd: URL) async throws -> [String] {
        let line = try await gitOutput(["rev-list", "--parents", "-n", "1", sha], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ").map(String.init)
        return Array(parts.dropFirst())
    }

    func firstParent(of sha: String, cwd: URL) async throws -> String? {
        try await parents(of: sha, cwd: cwd).first
    }

    func headSha(cwd: URL) async throws -> String {
        try await gitOutput(["rev-parse", "HEAD"], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitLines(_ args: [String], cwd: URL) async throws -> [String] {
        let output = try await gitOutput(args, cwd: cwd)
        return output.split(separator: "\n").map(String.init)
    }

    func gitOutput(_ args: [String], cwd: URL) async throws -> String {
        let result = try await Process.git(args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw CommitEditError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    func runGit(_ args: [String], cwd: URL) async throws {
        _ = try await gitOutput(args, cwd: cwd)
    }
}
