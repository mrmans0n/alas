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
        let message: (subject: String, body: String)?
        switch action {
        case .message(let newSubject, let newBody):
            message = (
                subject: newSubject.trimmingCharacters(in: .whitespacesAndNewlines),
                body: newBody.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .dropFile, .dropHunk:
            message = nil
        }

        if let message {
            guard !message.subject.isEmpty else { throw CommitEditError.emptySubject }
        }
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

        if case .dropHunk(let path, _) = action {
            let details = try await commitDetails(at: worktreePath, sha: targetSha)
            guard details.files.first(where: { $0.path == path })?.status == "M" else {
                throw CommitEditError.unsupportedAction
            }
        }

        let anchor = try await firstParent(of: targetSha, cwd: worktreePath) ?? baseRef
        let backupBranch = "alas-edit-backup-\(UUID().uuidString)"
        try await runGit(["branch", backupBranch, "HEAD"], cwd: worktreePath)

        var shouldDeleteBackup = true
        do {
            try await runGit(["reset", "--hard", anchor], cwd: worktreePath)

            var shaMap: [String: String] = [:]
            let author = try await authorMetadata(for: targetSha, cwd: worktreePath)
            let targetIsEmpty = try await isEmptyCommit(targetSha, cwd: worktreePath)
            if !targetIsEmpty {
                try await runGit(["cherry-pick", "--no-commit", targetSha], cwd: worktreePath)
            }

            switch action {
            case .message:
                guard let message else { throw CommitEditError.emptySubject }
                var commitArgs = ["commit", "--author", author.ident, "-m", message.subject]
                if targetIsEmpty {
                    commitArgs.append("--allow-empty")
                }
                if !message.body.isEmpty {
                    commitArgs += ["-m", message.body]
                }
                try await runGit(commitArgs, cwd: worktreePath, env: ["GIT_AUTHOR_DATE": author.date])
            case .dropFile(let path):
                try await dropFileFromStagedCommit(worktreePath: worktreePath, parentSha: anchor, path: path)
                try await commitIfNonEmpty(worktreePath: worktreePath, sourceSha: targetSha)
            case .dropHunk(let path, let hunk):
                try await dropHunkFromStagedCommit(worktreePath: worktreePath, path: path, hunk: hunk)
                try await commitIfNonEmpty(worktreePath: worktreePath, sourceSha: targetSha)
            }
            let currentSha = try await headSha(cwd: worktreePath)
            shaMap[targetSha] = currentSha

            for sha in replayRange.dropFirst() {
                try await runGit(["cherry-pick", "--allow-empty", sha], cwd: worktreePath)
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
    struct AuthorMetadata {
        let ident: String
        let date: String
    }

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

    func authorMetadata(for sha: String, cwd: URL) async throws -> AuthorMetadata {
        let output = try await gitOutput(["show", "-s", "--format=%an <%ae>%x1f%aI", sha], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw CommitEditError.gitFailed("Could not read commit author metadata.")
        }
        return AuthorMetadata(ident: parts[0], date: parts[1])
    }

    func isEmptyCommit(_ sha: String, cwd: URL) async throws -> Bool {
        if let parent = try await firstParent(of: sha, cwd: cwd) {
            let result = try await Process.git(["diff-tree", "--quiet", "--exit-code", parent, sha], cwd: cwd)
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw CommitEditError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result.exitCode == 0
        }

        let result = try await Process.git(["diff-tree", "--quiet", "--exit-code", "--root", sha], cwd: cwd)
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw CommitEditError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.exitCode == 0
    }

    func headSha(cwd: URL) async throws -> String {
        try await gitOutput(["rev-parse", "HEAD"], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dropFileFromStagedCommit(worktreePath: URL, parentSha: String, path: String) async throws {
        let parentProbe = try await Process.git(["cat-file", "-e", "\(parentSha):\(path)"], cwd: worktreePath)
        if parentProbe.exitCode == 0 {
            try await runGit(["restore", "--source", parentSha, "--staged", "--worktree", "--", path], cwd: worktreePath)
        } else {
            try await runGit(["rm", "-f", "--", path], cwd: worktreePath)
        }
    }

    func dropHunkFromStagedCommit(worktreePath: URL, path: String, hunk: ParsedDiff.Hunk) async throws {
        let patch = HunkPatchBuilder.patch(file: path, hunk: hunk, tracked: true)
        let result = try await Process.git(["apply", "--reverse", "--index", "-"], cwd: worktreePath, stdin: patch)
        guard result.exitCode == 0 else {
            throw CommitEditError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func commitIfNonEmpty(worktreePath: URL, sourceSha: String) async throws {
        let diff = try await Process.git(["diff", "--cached", "--quiet"], cwd: worktreePath)
        if diff.exitCode == 0 {
            throw CommitEditError.gitFailed("This edit would make the commit empty; dropping whole commits is not supported yet.")
        }
        try await runGit(["commit", "-C", sourceSha], cwd: worktreePath)
    }

    func gitLines(_ args: [String], cwd: URL) async throws -> [String] {
        let output = try await gitOutput(args, cwd: cwd)
        return output.split(separator: "\n").map(String.init)
    }

    func gitOutput(_ args: [String], cwd: URL) async throws -> String {
        try await gitOutput(args, cwd: cwd, env: [:])
    }

    func gitOutput(_ args: [String], cwd: URL, env extraEnv: [String: String]) async throws -> String {
        var env = Process.gitEnv()
        for (key, value) in extraEnv {
            env[key] = value
        }
        let result = try await Process.run("/usr/bin/env", args: ["git"] + args, cwd: cwd, env: env)
        guard result.exitCode == 0 else {
            throw CommitEditError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    func runGit(_ args: [String], cwd: URL) async throws {
        try await runGit(args, cwd: cwd, env: [:])
    }

    func runGit(_ args: [String], cwd: URL, env: [String: String]) async throws {
        _ = try await gitOutput(args, cwd: cwd, env: env)
    }
}
