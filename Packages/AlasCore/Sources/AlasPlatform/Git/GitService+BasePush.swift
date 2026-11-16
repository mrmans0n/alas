import Foundation

/// Whether a machine can create from a base: it only sees what is on origin.
public enum BasePushState: Equatable, Sendable {
    case pushed
    case notOnOrigin
    case ahead(commits: Int)

    /// The inline notice for an unpushed base; nil once it is pushed.
    public func notice(base: String) -> String? {
        switch self {
        case .pushed: nil
        case .notOnOrigin: "\(base) isn't on origin"
        case let .ahead(commits) where commits == 1: "\(base) has 1 commit that isn't on origin"
        case let .ahead(commits): "\(base) has \(commits) commits that aren't on origin"
        }
    }
}

extension GitService {
    /// Checked in the local primary before creating on a machine. A
    /// remote-tracking base is on its remote by definition; a local branch is
    /// pushed once `origin/<base>` has every commit it has.
    public func basePushState(repoPath: URL, base: String) async throws -> BasePushState {
        if try await remoteForFetch(worktreePath: repoPath, ref: base) != nil { return .pushed }
        let tracking = try await Process.git(
            ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(base)"], cwd: repoPath
        )
        guard tracking.exitCode == 0 else { return .notOnOrigin }
        let count = try await Process.git(["rev-list", "--count", "origin/\(base)..\(base)"], cwd: repoPath)
        try GitService.assertSuccess(count, op: "Count unpushed commits")
        let ahead = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return ahead == 0 ? .pushed : .ahead(commits: ahead)
    }

    /// `git push -u origin <base>`. Never forced: a rejection throws git's message.
    public func pushBase(repoPath: URL, base: String) async throws {
        let result = try await Process.git(["push", "-u", "origin", base], cwd: repoPath)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "GitService.pushBase",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.pushFailureMessage]
            )
        }
    }
}
