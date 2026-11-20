import Foundation
import AlasFoundation

extension CommitMessageSuggestionInput {
    struct GitFailure: Error {}

    public static func load(worktreePath: URL, ticketTitle: String?) async throws -> Self {
        async let branch = Process.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktreePath)
        // Every git output is bounded while reading: a huge generated file or
        // commit subject must not be buffered whole just to be cut down later.
        // An unborn branch has no log; that only means there is no convention to follow.
        let subjects = (try? await capped(
            ["log", "-\(CommitMessageSuggestionPolicy.recentSubjectCount)", "--pretty=format:%s"],
            worktreePath: worktreePath, maxOutputBytes: CommitMessageSuggestionPolicy.logOutputByteLimit
        ))?.stdout ?? ""
        let stat = try await capped(
            ["diff", "--cached", "--stat", "--no-color"],
            worktreePath: worktreePath, maxOutputBytes: CommitMessageSuggestionPolicy.statOutputByteLimit
        )
        // Renames and copies are read as pairs first: split across tier reads,
        // Git would report a moved file as a full addition plus a deletion.
        let renames = try await capped(
            ["diff", "--cached", "--name-status", "-z", "-M", "--diff-filter=RC"],
            worktreePath: worktreePath, maxOutputBytes: CommitMessageSuggestionPolicy.renameInventoryByteLimit
        )
        let pairedPaths = CommitMessageSuggestionPolicy.renamedPaths(nameStatus: renames.stdout, truncated: renames.truncated)
        var reads = CommitMessageSuggestionPolicy.tierPathspecs.map { $0 + pairedPaths.map { ":(exclude,literal)\($0)" } }
        if !pairedPaths.isEmpty { reads.insert(pairedPaths.map { ":(literal)\($0)" }, at: 0) }
        // One capped read per priority tier, selected by pathspec, so noisy
        // files that sort first cannot spend the cap before source changes.
        var diffs: [String] = []
        for pathspecs in reads {
            let diff = try await capped(
                ["diff", "--cached", "--no-color", "--no-ext-diff", "-M", "--"] + pathspecs,
                worktreePath: worktreePath, maxOutputBytes: CommitMessageSuggestionPolicy.diffOutputByteLimit
            )
            diffs.append(diff.truncated ? CommitMessageSuggestionPolicy.droppingPartialTail(diff.stdout) : diff.stdout)
        }
        let branchName = try await branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            stat: stat.stdout,
            diff: diffs.filter { !$0.isEmpty }.joined(separator: "\n"),
            branch: branchName.isEmpty || branchName == "HEAD" ? nil : branchName,
            ticketTitle: ticketTitle,
            recentSubjects: subjects.split(separator: "\n").map(String.init)
        )
    }

    /// A failed command is evidence of nothing, so it fails the suggestion
    /// instead of letting the model guess from the branch alone. A capped read
    /// ends with the SIGTERM that enforced the cap, which is not a failure.
    private static func capped(
        _ args: [String], worktreePath: URL, maxOutputBytes: Int
    ) async throws -> (stdout: String, truncated: Bool) {
        let result = try await Process.gitCapped(args, cwd: worktreePath, maxOutputBytes: maxOutputBytes)
        guard result.stdoutTruncated || result.exitCode == 0 else { throw GitFailure() }
        return (result.stdout, result.stdoutTruncated)
    }
}
