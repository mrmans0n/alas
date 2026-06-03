import Foundation

extension GitService {
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
            if parts.count >= 3, parts[2] == "(push)" {
                continue
            }

            let remote = GitRemote(name: String(parts[0]), url: String(parts[1]))
            let key = "\(remote.name)\u{0}\(remote.url)"
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
