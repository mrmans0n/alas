import Foundation

struct GitStash: Codable, Equatable, Identifiable, Sendable {
    var id: String { ref }

    let ref: String
    let subject: String
    let relativeTime: String
    let sha: String
}

struct GitStashFile: Codable, Equatable, Identifiable, Sendable {
    var id: String { path }

    let path: String
    let status: String
    let add: Int
    let del: Int
}

enum StashOperationResult: Equatable, Sendable {
    case clean
    case conflict(message: String)
    case error(message: String)
}

extension GitService {
    static func parseStashList(_ output: String) -> [GitStash] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> GitStash? in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4 else { return nil }

                let ref = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty else { return nil }

                return GitStash(
                    ref: ref,
                    subject: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                    relativeTime: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
                    sha: parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    static func parseStashFiles(numstat: String, nameStatus: String) -> [GitStashFile] {
        let counts = NumstatParser.parse(numstat)

        return nameStatus
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> GitStashFile? in
                let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { return nil }

                let rawStatus = parts[0]
                let status = String(rawStatus.prefix(1))
                let path = parts.count >= 3 ? parts[2] : parts[1]
                let fallback = NumstatParser.destinationPath(from: path)
                let count = counts[path] ?? counts[fallback] ?? (add: 0, del: 0)

                return GitStashFile(path: path, status: status, add: count.add, del: count.del)
            }
    }

    func stashes(worktreePath: URL) async throws -> [GitStash] {
        let result = try await Process.git(
            ["stash", "list", "--format=%gd%x1f%gs%x1f%cr%x1f%H"],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else {
            throw GitStashError.stderr(result.stderr, fallback: "Could not list stashes.")
        }
        return Self.parseStashList(result.stdout)
    }

    func pushStash(worktreePath: URL, message: String, includeUntracked: Bool) async throws -> StashOperationResult {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            args.append(contentsOf: ["--message", trimmed])
        }

        let result = try await Process.git(args, cwd: worktreePath)
        return Self.stashOperationResult(result, fallback: "Could not park changes.")
    }

    func stashFiles(worktreePath: URL, stash: GitStash) async throws -> [GitStashFile] {
        let numstat = try await Process.git(
            ["stash", "show", "--include-untracked", "--numstat", "--format=", stash.ref],
            cwd: worktreePath
        )
        guard numstat.exitCode == 0 else {
            throw GitStashError.stderr(numstat.stderr, fallback: "Could not load stash files.")
        }

        let nameStatus = try await Process.git(
            ["stash", "show", "--include-untracked", "--name-status", "--format=", stash.ref],
            cwd: worktreePath
        )
        guard nameStatus.exitCode == 0 else {
            throw GitStashError.stderr(nameStatus.stderr, fallback: "Could not load stash files.")
        }

        return Self.parseStashFiles(numstat: numstat.stdout, nameStatus: nameStatus.stdout)
    }

    func stashDiff(worktreePath: URL, stash: GitStash, file: GitStashFile) async throws -> ParsedDiff {
        var result = try await Process.git(
            ["diff", "--no-ext-diff", "--no-color", "\(stash.ref)^1", stash.ref, "--", file.path],
            cwd: worktreePath
        )
        if result.exitCode == 0, result.stdout.isEmpty {
            result = try await Process.git(
                ["show", "--format=", "--no-ext-diff", "--no-color", "\(stash.ref)^3", "--", file.path],
                cwd: worktreePath
            )
        }
        guard result.exitCode == 0 else {
            throw GitStashError.stderr(result.stderr, fallback: "Could not load stash diff.")
        }

        return await Task.detached(priority: .userInitiated) {
            DiffParser.parse(result.stdout)
        }.value
    }

    func applyStash(worktreePath: URL, stash: GitStash) async throws -> StashOperationResult {
        let result = try await Process.git(["stash", "apply", stash.ref], cwd: worktreePath)
        return Self.stashOperationResult(result, fallback: "Could not apply stash.")
    }

    func popStash(worktreePath: URL, stash: GitStash) async throws -> StashOperationResult {
        let result = try await Process.git(["stash", "pop", stash.ref], cwd: worktreePath)
        return Self.stashOperationResult(result, fallback: "Could not pop stash.")
    }

    func dropStash(worktreePath: URL, stash: GitStash) async throws {
        let result = try await Process.git(["stash", "drop", stash.ref], cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw GitStashError.stderr(result.stderr, fallback: "Could not drop stash.")
        }
    }

    private static func stashOperationResult(_ result: ProcessResult, fallback: String) -> StashOperationResult {
        if result.exitCode == 0 { return .clean }

        let output = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let message = output.isEmpty ? fallback : output
        if message.localizedCaseInsensitiveContains("conflict") {
            return .conflict(message: message)
        }
        return .error(message: message)
    }
}

private enum GitStashError: LocalizedError {
    case stderr(String, fallback: String)

    var errorDescription: String? {
        switch self {
        case .stderr(let stderr, let fallback):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? fallback : message
        }
    }
}
