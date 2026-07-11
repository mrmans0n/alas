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
        if !options.regex { args.append("-F") }
        if options.wholeWord { args.append("-w") }

        // Content search's unchecked case control is smart-case, matching
        // the local ripgrep invocation.
        if !options.caseSensitive, !query.contains(where: \.isUppercase) {
            args.append("-i")
        }
        args += ["-e", query, "--"]
        return args
    }

    /// `git grep -z` output is `path\\0line:column:text`. The NUL delimiter
    /// keeps colon-containing paths unambiguous.
    static func parseGitGrepLine(_ line: String) -> (path: String, line: Int, column: Int, text: String)? {
        guard let nul = line.firstIndex(of: "\u{0}") else { return nil }
        let path = String(line[..<nul])
        let rest = line[line.index(after: nul)...]
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let lineNumber = Int(parts[0]),
              let column = Int(parts[1]),
              !path.isEmpty
        else { return nil }
        return (path, lineNumber, column, String(parts[2]))
    }
}
