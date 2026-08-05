import Foundation

struct GitStash: Codable, Equatable, Identifiable, Sendable {
    var id: String { ref }

    let ref: String
    let subject: String
    let relativeTime: String
    let sha: String
}

struct GitStashFile: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(path)\u{0}\(isUntracked)" }

    let path: String
    let status: String
    let add: Int
    let del: Int
    let oldPath: String?
    let isUntracked: Bool

    init(
        path: String,
        status: String,
        add: Int,
        del: Int,
        oldPath: String? = nil,
        isUntracked: Bool = false
    ) {
        self.path = path
        self.status = status
        self.add = add
        self.del = del
        self.oldPath = oldPath
        self.isUntracked = isUntracked
    }

    enum CodingKeys: String, CodingKey {
        case path, status, add, del, oldPath, isUntracked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        status = try container.decode(String.self, forKey: .status)
        add = try container.decode(Int.self, forKey: .add)
        del = try container.decode(Int.self, forKey: .del)
        oldPath = try container.decodeIfPresent(String.self, forKey: .oldPath)
        isUntracked = try container.decodeIfPresent(Bool.self, forKey: .isUntracked) ?? false
    }
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

    static func parseStashFiles(
        numstat: String,
        nameStatus: String,
        isUntracked: Bool = false
    ) -> [GitStashFile] {
        let counts = NumstatParser.parse(numstat)

        return nameStatus
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> GitStashFile? in
                let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { return nil }

                let rawStatus = parts[0]
                let status = String(rawStatus.prefix(1))
                let path = parts.count >= 3 ? parts[2] : parts[1]
                let oldPath = parts.count >= 3 ? parts[1] : nil
                let fallback = NumstatParser.destinationPath(from: path)
                let count = counts[path] ?? counts[fallback] ?? (add: 0, del: 0)

                return GitStashFile(
                    path: path,
                    status: status,
                    add: count.add,
                    del: count.del,
                    oldPath: oldPath,
                    isUntracked: isUntracked
                )
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
        return Self.stashOperationResult(result, fallback: "Could not stash changes.")
    }

    func stashFiles(worktreePath: URL, stash: GitStash) async throws -> [GitStashFile] {
        try await verifyStashIdentity(worktreePath: worktreePath, stash: stash)

        let numstat = try await Process.git(
            ["diff", "--numstat", "--find-renames", "--find-copies", "\(stash.ref)^1", stash.ref],
            cwd: worktreePath
        )
        guard numstat.exitCode == 0 else {
            throw GitStashError.stderr(numstat.stderr, fallback: "Could not load stash files.")
        }

        let nameStatus = try await Process.git(
            ["diff", "--name-status", "--find-renames", "--find-copies", "\(stash.ref)^1", stash.ref],
            cwd: worktreePath
        )
        guard nameStatus.exitCode == 0 else {
            throw GitStashError.stderr(nameStatus.stderr, fallback: "Could not load stash files.")
        }

        async let untrackedNumstatProbe = Process.git(
            ["show", "--format=", "--numstat", "\(stash.ref)^3"],
            cwd: worktreePath
        )
        async let untrackedNameStatusProbe = Process.git(
            ["show", "--format=", "--name-status", "\(stash.ref)^3"],
            cwd: worktreePath
        )
        let untrackedNumstat = try? await untrackedNumstatProbe
        let untrackedNameStatus = try? await untrackedNameStatusProbe

        let tracked = Self.parseStashFiles(
            numstat: numstat.stdout,
            nameStatus: nameStatus.stdout,
            isUntracked: false
        )
        let untracked = Self.parseStashFiles(
            numstat: untrackedNumstat?.exitCode == 0 ? untrackedNumstat?.stdout ?? "" : "",
            nameStatus: untrackedNameStatus?.exitCode == 0 ? untrackedNameStatus?.stdout ?? "" : "",
            isUntracked: true
        )
        return tracked + untracked
    }

    func stashDiff(worktreePath: URL, stash: GitStash, file: GitStashFile) async throws -> ParsedDiff {
        let pathspecs = [file.oldPath, file.path].compactMap(\.self)
        let stashRevision = stash.sha
        var result = try await Process.git(
            ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--find-copies", "\(stashRevision)^1", stashRevision, "--"] + pathspecs,
            cwd: worktreePath
        )
        if result.exitCode == 0, result.stdout.isEmpty {
            result = try await Process.git(
                ["show", "--format=", "--no-ext-diff", "--no-color", "\(stashRevision)^3", "--", file.path],
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
        try await verifyStashIdentity(worktreePath: worktreePath, stash: stash)
        let result = try await Process.git(["stash", "apply", stash.ref], cwd: worktreePath)
        return Self.stashOperationResult(result, fallback: "Could not apply stash.")
    }

    func popStash(worktreePath: URL, stash: GitStash) async throws -> StashOperationResult {
        try await verifyStashIdentity(worktreePath: worktreePath, stash: stash)
        let result = try await Process.git(["stash", "pop", stash.ref], cwd: worktreePath)
        return Self.stashOperationResult(result, fallback: "Could not pop stash.")
    }

    func dropStash(worktreePath: URL, stash: GitStash) async throws {
        try await verifyStashIdentity(worktreePath: worktreePath, stash: stash)
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

    private func verifyStashIdentity(worktreePath: URL, stash: GitStash) async throws {
        let result = try await Process.git(["rev-parse", "--verify", stash.ref], cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw GitStashError.stderr(result.stderr, fallback: "\(stash.ref) is no longer available.")
        }

        let actualSHA = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualSHA == stash.sha else {
            throw GitStashError.staleRef(ref: stash.ref, expectedSHA: stash.sha, actualSHA: actualSHA)
        }
    }
}

private enum GitStashError: LocalizedError {
    case stderr(String, fallback: String)
    case staleRef(ref: String, expectedSHA: String, actualSHA: String)

    var errorDescription: String? {
        switch self {
        case .stderr(let stderr, let fallback):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? fallback : message
        case .staleRef(let ref, let expectedSHA, let actualSHA):
            return "\(ref) changed before the operation could run. Expected \(expectedSHA), found \(actualSHA). Refresh and try again."
        }
    }
}
