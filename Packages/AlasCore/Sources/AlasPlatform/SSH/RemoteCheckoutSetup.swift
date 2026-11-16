import Foundation
import AlasFoundation
import AlasModel

/// Finds or clones a local project's repository on a Machine, the first time
/// a worktree runs there.
public enum RemoteCheckoutSetup {
    public struct Checkout: Equatable, Sendable {
        /// Absolute path on the machine.
        public let path: String
        /// Alas cloned it, so its main worktree is not the user's own checkout.
        public let cloned: Bool

        public init(path: String, cloned: Bool) {
            self.path = path
            self.cloned = cloned
        }
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        /// ssh itself failed: unreachable, or a host key or password is needed.
        case connection(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case let .connection(detail): detail.isEmpty ? "Could not reach the machine over SSH." : detail
            case let .failed(message): message
            }
        }
    }

    /// The child whose origin names `identity`, from `name<TAB>origin` lines:
    /// the one named after the repository, otherwise the first by name.
    public static func matchingClone(listing: String, identity: String, repoName: String) -> String? {
        let matches = listing.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, GitRemoteIdentity.normalized(parts[1]) == identity else { return nil }
            return parts[0]
        }
        return matches.contains(repoName) ? repoName : matches.min()
    }

    /// The first of `<repo>`, `<repo>-2`, `<repo>-3`… not taken.
    public static func freeCloneName(repoName: String, taken: Set<String>) -> String {
        var name = repoName
        var suffix = 1
        while taken.contains(name) {
            suffix += 1
            name = "\(repoName)-\(suffix)"
        }
        return name
    }

    /// Uses the clone of `originURL` in the machine's projects folder, or
    /// clones it there. Cancelling stops the clone; git removes what it left.
    public static func ensure(
        host: String,
        projectsFolder: String,
        originURL: String,
        runner: @escaping RemoteRepoValidator.Runner = { executable, args, timeout in
            try await Process.run(executable, args: args, timeout: timeout)
        }
    ) async throws -> Checkout {
        guard let identity = GitRemoteIdentity.normalized(originURL),
              let repoName = identity.split(separator: "/").last.map(String.init)
        else { throw Failure.failed("\(originURL) names no repository a machine can clone.") }
        // The folder's absolute path, then `name<TAB>origin` for each child; origin is empty for non-clones.
        let folder = MachineCheck.shellPath(projectsFolder)
        let listing = try await run(
            host: host,
            command: #"mkdir -p \#(folder) && cd \#(folder) && pwd && for d in *; do [ -e "$d" ] || continue; "#
                + #"u=; [ -d "$d/.git" ] && u=$(git -C "$d" remote get-url origin 2>/dev/null); "#
                + #"printf '%s\t%s\n' "$d" "$u"; done"#,
            timeout: 60,
            runner: runner
        )
        guard listing.exitCode == 0, let root = listing.stdout.split(whereSeparator: \.isNewline).first.map(String.init) else {
            throw Failure.failed(lastLine(listing.stderr) ?? "Can't use \(projectsFolder) on \(host).")
        }
        let children = String(listing.stdout.dropFirst(root.count))
        if let name = matchingClone(listing: children, identity: identity, repoName: repoName) {
            return Checkout(path: "\(root)/\(name)", cloned: false)
        }
        let taken = Set(children.split(whereSeparator: \.isNewline).map { String($0.prefix { $0 != "\t" }) })
        let name = freeCloneName(repoName: repoName, taken: taken)
        let clone = try await run(
            host: host,
            command: "cd \(SSHCommand.shellQuote(root)) && git clone --progress -- "
                + "\(SSHCommand.shellQuote(originURL)) \(SSHCommand.shellQuote(name))",
            // ponytail: one blocking call, no streamed progress; stream git's stderr if big clones need a percentage.
            timeout: 3600,
            runner: runner
        )
        guard clone.exitCode == 0 else {
            throw Failure.failed(cloneFailureMessage(stderr: clone.stderr, originHost: identity.prefix { $0 != "/" }))
        }
        return Checkout(path: "\(root)/\(name)", cloned: true)
    }

    /// A checkout the user points at instead: it must be a clone of `originURL`'s repository.
    public static func adopt(
        host: String,
        path: String,
        originURL: String,
        runner: @escaping RemoteRepoValidator.Runner = { executable, args, timeout in
            try await Process.run(executable, args: args, timeout: timeout)
        }
    ) async throws -> String {
        let result = try await run(
            host: host,
            command: "cd \(MachineCheck.shellPath(path)) && git rev-parse --show-toplevel && git remote get-url origin",
            timeout: 30,
            runner: runner
        )
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard result.exitCode == 0, lines.count == 2 else {
            throw Failure.failed(lines.count == 1 ? "This clone has no origin." : "Not a git checkout on \(host): \(path)")
        }
        let expected = GitRemoteIdentity.normalized(originURL)
        let found = GitRemoteIdentity.normalized(lines[1])
        guard found == expected else {
            throw Failure.failed("This clone's origin is \(found ?? lines[1]), not \(expected ?? originURL).")
        }
        return lines[0]
    }

    /// git's error, plus what to fix when the machine can't authenticate to origin.
    public static func cloneFailureMessage(stderr: String, originHost: some StringProtocol) -> String {
        let lines = stderr.split(whereSeparator: { $0.isNewline || $0 == "\r" }).map(String.init)
        let errors = lines.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.hasPrefix("ERROR") }
        let message = errors.isEmpty ? (lines.last ?? "git clone failed.") : errors.joined(separator: "\n")
        let authMarkers = ["Permission denied", "Authentication failed", "could not read Username", "Host key verification failed"]
        guard authMarkers.contains(where: stderr.contains) else { return message }
        return "\(message)\nThe machine needs access to \(originHost)."
    }

    private static func run(
        host: String,
        command: String,
        timeout: TimeInterval,
        runner: RemoteRepoValidator.Runner
    ) async throws -> ProcessResult {
        let argv = SSHCommand(host: host, mode: .batch).argv(remoteScript: SSHCommand.remoteScript(command: command))
        let result: ProcessResult
        do {
            result = try await runner(SSHCommand.executable, argv, timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.connection(error.localizedDescription)
        }
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw Failure.connection(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}
