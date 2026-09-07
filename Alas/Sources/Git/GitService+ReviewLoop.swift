import Foundation

enum HeadPublicationState: Equatable, Sendable {
    case noUpstream
    case unpublished
    case published
}

extension GitService {
    func headPublicationState(worktreePath: URL) async throws -> HeadPublicationState {
        let head = try await Process.git(["rev-parse", "--verify", "HEAD^{commit}"], cwd: worktreePath)
        try Self.assertSuccess(head, op: "Resolve HEAD")
        let branch = try await Process.git(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: worktreePath)
        if branch.exitCode == 1 { return .noUpstream }
        try Self.assertSuccess(branch, op: "Resolve branch")
        let branchName = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for key in ["remote", "merge"] {
            let config = try await Process.git(["config", "--get", "branch.\(branchName).\(key)"], cwd: worktreePath)
            if config.exitCode == 1 { return .noUpstream }
            try Self.assertSuccess(config, op: "Read upstream configuration")
        }
        let upstream = try await Process.git(["rev-parse", "--verify", "@{u}^{commit}"], cwd: worktreePath)
        try Self.assertSuccess(upstream, op: "Resolve upstream")
        let result = try await Process.git(
            ["merge-base", "--is-ancestor", head.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
             upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)], cwd: worktreePath
        )
        if result.exitCode == 1 { return .unpublished }
        try Self.assertSuccess(result, op: "Check HEAD publication")
        return .published
    }

    /// Publication callers must pass the captured push URL as `remote`.
    /// A configured remote name resolves its fetch URL, which may differ.
    func remoteBranchContainsCommit(
        worktreePath: URL,
        remote: String,
        branch: String,
        commitSHA: String
    ) async throws -> Bool {
        let branchRef = "refs/heads/\(branch)"
        let validation = try await Process.git(["check-ref-format", branchRef], cwd: worktreePath)
        try Self.assertSuccess(validation, op: "Validate remote branch")
        let advertisement = try await Process.git(
            ["ls-remote", "--exit-code", "--heads", "--", remote, branchRef], cwd: worktreePath
        )
        if advertisement.exitCode == 2 { return false }
        try Self.assertSuccess(advertisement, op: "Read remote branch")
        guard advertisement.stdout.split(separator: "\n").contains(where: {
            let fields = $0.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[1] == branchRef
        }) else { return false }

        let temporaryRef = "refs/alas/publish-check/\(UUID().uuidString)"
        let containsCommit: Bool
        do {
            let fetch = try await Process.git(
                ["fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--refmap=",
                 "--", remote, "+\(branchRef):\(temporaryRef)"], cwd: worktreePath
            )
            try Self.assertSuccess(fetch, op: "Fetch remote branch")
            let result = try await Process.git(
                ["merge-base", "--is-ancestor", commitSHA, temporaryRef], cwd: worktreePath
            )
            if result.exitCode != 1 { try Self.assertSuccess(result, op: "Check remote commit") }
            containsCommit = result.exitCode == 0
        } catch {
            try? await removePublicationProbeRef(temporaryRef, worktreePath: worktreePath)
            throw error
        }
        try await removePublicationProbeRef(temporaryRef, worktreePath: worktreePath)
        return containsCommit
    }

    private func removePublicationProbeRef(_ ref: String, worktreePath: URL) async throws {
        // Cleanup must survive caller cancellation, but still finish before the probe returns.
        try await Task.detached {
            let result = try await Process.git(["update-ref", "-d", ref], cwd: worktreePath)
            try Self.assertSuccess(result, op: "Delete publication probe ref")
        }.value
    }

    func remotes(worktreePath: URL) async throws -> [GitRemote] {
        let result = try await Process.git(["remote", "-v"], cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
        return Self.parseRemotes(result.stdout)
    }

    static func parseRemotes(_ output: String) -> [GitRemote] {
        var seen = Set<String>()
        var remotes: [GitRemote] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let direction: GitRemote.Direction = parts.count >= 3 && parts[2] == "(push)" ? .push : .fetch

            let remote = GitRemote(name: String(parts[0]), url: String(parts[1]), direction: direction)
            let key = "\(remote.name)\u{0}\(remote.url)\u{0}\(remote.direction)"
            guard seen.insert(key).inserted else { continue }
            remotes.append(remote)
        }

        return remotes
    }

    func needsPush(worktreePath: URL) async throws -> Bool {
        let upstream = try await Process.git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            cwd: worktreePath
        )
        guard upstream.exitCode == 0 else {
            return true
        }

        let upstreamRef = upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upstreamRef.isEmpty, upstreamRef != "@{u}" else {
            return true
        }

        let result = try await Process.git(["rev-list", "--count", "@{u}..HEAD"], cwd: worktreePath)
        guard result.exitCode == 0 else {
            return true
        }

        let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return count > 0
    }

    func upstreamAheadCommitCount(worktreePath: URL) async throws -> Int {
        guard let upstream = try await resolveUpstreamRef(worktreePath: worktreePath) else {
            return 0
        }

        let result = try await Process.git(["rev-list", "--count", "HEAD..\(upstream.ref)"], cwd: worktreePath)
        guard result.exitCode == 0 else {
            return 0
        }

        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
