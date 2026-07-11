import Foundation

/// Remote content search either streams `rg --json` through ssh or uses the
/// host-aware `git grep` fallback when ripgrep is unavailable.
enum RemoteContentSearch {
    /// `git grep` does not offer a portable per-file result cap. Keep its
    /// buffered fallback bounded before yielding into the search model.
    static let maxGitGrepHits = 2_000

    static func rgInvocation(host: String, cwd: String, rgArgs: [String]) -> RemoteExecInvocation {
        let command = "rg " + rgArgs.map(SSHCommand.shellQuote).joined(separator: " ")
        return RemoteExec.invocation(host: host, cwd: cwd, command: command)
    }

    static func gitGrepArgs(query: String, options: SearchContentOptions) -> [String] {
        var args = ["grep", "-nI", "--column", "--untracked", "-z"]
        if options.regex {
            args.append("-E")
        } else {
            args.append("-F")
        }
        if options.wholeWord { args.append("-w") }

        // Content search's unchecked case control is smart-case, matching
        // the local ripgrep invocation.
        if !options.caseSensitive, !query.contains(where: \.isUppercase) {
            args.append("-i")
        }
        args += ["-e", query, "--"]
        return args
    }

    static func cappedGitGrepInvocation(host: String, cwd: String, query: String, options: SearchContentOptions) -> RemoteExecInvocation {
        let gitArgs = gitGrepArgs(query: query, options: options).map(SSHCommand.shellQuote).joined(separator: " ")
        let cap = maxGitGrepHits
        let command = [
            "fifo=\"${TMPDIR:-/tmp}/alas-git-grep-$$.fifo\"",
            "rm -f \"$fifo\"",
            "mkfifo \"$fifo\" || exit 2",
            "trap 'rm -f \"$fifo\"' EXIT HUP INT TERM",
            "awk -v cap=\(cap) '{ print; if (NR >= cap) exit }' < \"$fifo\" & awk_pid=$!",
            "env GIT_OPTIONAL_LOCKS=0 LC_ALL=C git \(gitArgs) > \"$fifo\"",
            "git_status=$?",
            "wait \"$awk_pid\"",
            "awk_status=$?",
            "case \"$git_status\" in 13|141) exit 0 ;; esac",
            "[ \"$awk_status\" -eq 0 ] || exit \"$awk_status\"",
            "exit \"$git_status\"",
        ].joined(separator: "; ")
        return RemoteExec.invocation(host: host, cwd: cwd, command: command)
    }

    /// `git grep -z` output is `path\\0line\\0column\\0text`.
    static func parseGitGrepLine(_ line: String) -> (path: String, line: Int, column: Int, text: String)? {
        let parts = line.split(separator: "\u{0}", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let lineNumber = Int(parts[1]),
              let column = Int(parts[2]),
              !parts[0].isEmpty
        else { return nil }
        let path = String(parts[0])
        return (path, lineNumber, column, String(parts[3]))
    }
}
