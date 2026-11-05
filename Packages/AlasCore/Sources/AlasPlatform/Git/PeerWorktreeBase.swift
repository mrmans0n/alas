import Foundation

/// What a new worktree for a paired Mac's child branches from.
public enum PeerWorktreeBase {
    public struct Failure: Error, Equatable, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// As `WorktreeService` allows comparable network work.
    private static let fetchTimeout: TimeInterval = 90

    /// Fetches `base` explicitly, since a bare branch name is otherwise never
    /// refreshed, and returns its remote-tracking ref when there is one. With
    /// `expectedSHA` the peer is relying on this exact code, so anything but
    /// finding it is a failure. Without, the fetch is best effort and a `base`
    /// the remote does not have (a tag, a local branch) is returned as given.
    /// `machine` names this Mac in the failure, which goes to the peer.
    public static func resolve(
        branch: String,
        base: String,
        expectedSHA: String?,
        repo: URL,
        machine: String
    ) async -> Result<String, Failure> {
        let git = GitService()
        // A base with a remote prefix names it. Otherwise `origin`, the remote
        // a peer's project is matched by.
        var source = try? await git.remoteForFetch(worktreePath: repo, ref: base)
        if source == nil, (try? await git.remotes(worktreePath: repo))?.contains(where: { $0.name == "origin" }) == true {
            source = ("origin", base)
        }
        guard let source else {
            guard let expectedSHA else { return .success(base) }
            return .failure(.init(message: "\(base) on \(machine) has no origin remote to fetch from, expected \(expectedSHA)."))
        }
        var fetchError: String?
        do {
            try await git.fetchRef(worktreePath: repo, remote: source.remote, branch: source.branch, timeout: fetchTimeout)
        } catch {
            fetchError = redactingCredentials(error.localizedDescription).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let remoteBase = "\(source.remote)/\(source.branch)"
        let tracked = await commit(of: "refs/remotes/\(remoteBase)", in: repo)
        guard let expectedSHA else { return .success(tracked != nil ? remoteBase : base) }

        // Not "push and try again": this can as well be auth or the network.
        if let fetchError {
            return .failure(.init(
                message: "\(source.branch) on \(machine) could not be fetched from \(source.remote), expected \(expectedSHA): \(fetchError)"
            ))
        }
        guard let tracked else {
            return .failure(.init(
                message: "\(source.branch) on \(machine) has no \(remoteBase) after fetching, expected \(expectedSHA)."
            ))
        }
        guard tracked == expectedSHA else {
            return .failure(.init(message: "\(source.branch) on \(machine) is at \(tracked), expected \(expectedSHA). Push and try again."))
        }
        // A worktree checks out a branch that already exists, whatever the base.
        if let existing = await commit(of: "refs/heads/\(branch)", in: repo), existing != expectedSHA {
            return .failure(.init(
                message: "\(branch) already exists on \(machine) at \(existing), expected \(expectedSHA). Delete it or pick another name."
            ))
        }
        return .success(remoteBase)
    }

    /// Git's error goes to another machine, and a remote URL can carry a token.
    static func redactingCredentials(_ text: String) -> String {
        text.replacingOccurrences(of: #"://[^/\s@]+@"#, with: "://", options: .regularExpression)
    }

    private static func commit(of ref: String, in repo: URL) async -> String? {
        guard let result = try? await Process.git(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], cwd: repo),
              result.exitCode == 0
        else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
