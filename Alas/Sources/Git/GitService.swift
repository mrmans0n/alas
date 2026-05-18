import Foundation
import os

struct GitService {
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "git-service")

    func isGitRepository(_ path: URL) async throws -> Bool {
        let result = try await Process.git(["rev-parse", "--is-inside-work-tree"], cwd: path)
        return result.exitCode == 0 &&
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Returns the directory name of the repository path as the default project name.
    func suggestProjectName(_ path: URL) async throws -> String {
        path.lastPathComponent
    }

    func branches(at repoPath: URL) async throws -> [String] {
        let local = try await Process.git(
            ["branch", "--list", "--format=%(refname:short)"],
            cwd: repoPath
        )
        guard local.exitCode == 0 else {
            throw BranchListError(stderr: local.stderr)
        }

        let remote = try await Process.git(
            ["branch", "--remotes", "--format=%(refname:short)"],
            cwd: repoPath
        )
        guard remote.exitCode == 0 else {
            throw BranchListError(stderr: remote.stderr)
        }

        return Self.parseBranchList(local.stdout + "\n" + remote.stdout)
    }

    static func parseBranchList(_ output: String) -> [String] {
        var seen = Set<String>()
        var branches: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            var branch = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if branch.hasPrefix("* ") {
                branch.removeFirst(2)
                branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !branch.isEmpty, seen.insert(branch).inserted else { continue }
            branches.append(branch)
        }
        return branches
    }
}

private struct BranchListError: LocalizedError {
    let stderr: String

    var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "Could not load branches."
        }
        return message
    }
}

extension GitService {
    /// Whether the repo has any commits yet. `git diff HEAD` and friends
    /// fail with `bad revision 'HEAD'` on unborn branches; callers swap to
    /// index-based diffs in that case.
    func hasHead(worktreePath: URL) async throws -> Bool {
        let result = try await Process.git(
            ["rev-parse", "--verify", "--quiet", "HEAD"],
            cwd: worktreePath
        )
        return result.exitCode == 0
    }

    func status(worktreePath: URL) async throws -> [ChangedFile] {
        async let statusResult = Process.git(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            cwd: worktreePath
        )
        let s = try await statusResult
        guard s.exitCode == 0 else { return [] }
        var entries = try StatusParser.parse(s.stdout)

        // Numstat needs a base revision. Use HEAD if one exists; on unborn
        // branches diff `--cached` (index vs empty tree) so initial-commit
        // workflows still see real add/del counts in the Changes pane.
        let head = try await hasHead(worktreePath: worktreePath)
        let numstatArgs: [String] = head
            ? ["diff", "--numstat", "HEAD"]
            : ["diff", "--numstat", "--cached"]
        let numstat = try await Process.git(numstatArgs, cwd: worktreePath)
        let counts = NumstatParser.parse(numstat.stdout)

        for i in entries.indices {
            if let c = counts[entries[i].path] {
                entries[i] = ChangedFile(path: entries[i].path,
                                          status: entries[i].status,
                                          stage: entries[i].stage,
                                          add: c.add,
                                          del: c.del,
                                          renameFrom: entries[i].renameFrom)
            } else if entries[i].add == 0 && entries[i].del == 0 {
                // Numstat doesn't include unstaged untracked files, so they'd
                // show 0/0 in the Changes pane and the totals would
                // under-report. Count the file's lines as adds when it exists
                // on disk; deleted files (no longer present) stay at 0/0.
                let url = worktreePath.appendingPathComponent(entries[i].path)
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8) {
                    let lines = text.isEmpty
                        ? 0
                        : text.split(separator: "\n", omittingEmptySubsequences: false).count
                    entries[i] = ChangedFile(path: entries[i].path,
                                             status: entries[i].status,
                                             stage: entries[i].stage,
                                             add: lines,
                                             del: 0,
                                             renameFrom: entries[i].renameFrom)
                }
            }
        }
        return entries
    }

    func diff(worktreePath: URL, file: String, staged: Bool = false) async throws -> ParsedDiff {
        // Untracked files have no HEAD entry, so `git diff HEAD -- <path>`
        // returns nothing. Detect via `git ls-files --error-unmatch` (exit 0
        // iff tracked) and fall back to comparing against /dev/null so the
        // user sees the file's contents as a single all-add hunk.
        let tracked = try await Process.git(
            ["ls-files", "--error-unmatch", "--", file],
            cwd: worktreePath
        )
        if tracked.exitCode != 0 && !staged {
            let result = try await Process.git(
                ["diff", "--no-color", "--no-index", "--", "/dev/null", file],
                cwd: worktreePath
            )
            // `git diff --no-index` exits non-zero (1) when there ARE differences
            // — that's the normal case for an untracked file. Only treat exit
            // codes >= 2 as real failures.
            guard result.exitCode <= 1 else { return ParsedDiff(hunks: []) }
            return DiffParser.parse(result.stdout)
        }

        // Two distinct views, never combine HEAD and worktree:
        //   staged: false → unstaged delta (worktree vs index): `git diff`.
        //     Works as-is on unborn HEAD (index may be empty tree). This is
        //     the patch shape `git apply --cached` expects when staging
        //     hunks, and it correctly surfaces AM-state worktree edits even
        //     on unborn branches.
        //   staged: true  → staged delta (index vs HEAD): `git diff --cached
        //     HEAD` when HEAD exists, otherwise `git diff --cached` (index
        //     vs empty tree) so initial-commit workflows still render the
        //     staged side.
        let head = try await hasHead(worktreePath: worktreePath)
        var args = ["diff", "--no-color"]
        if staged {
            args.append("--cached")
            if head { args.append("HEAD") }
        }
        args.append("--")
        args.append(file)
        let result = try await Process.git(args, cwd: worktreePath)
        return DiffParser.parse(result.stdout)
    }

    func diff(worktreePath: URL, sha: String, file: String, originalPath: String? = nil) async throws -> ParsedDiff {
        // Detect initial commit (no parent) so we can fall back to the empty
        // tree, mirroring the technique used in commitDetails. Empirically,
        // `<sha>^!` fails for parentless commits because `<sha>^` doesn't
        // resolve, and `git show --root` would emit a header we don't want
        // to feed to DiffParser. Use the explicit two-tree form against the
        // canonical empty-tree SHA so DiffParser sees a clean diff body.
        //
        // For merge commits, diff against the first parent — same first-
        // parent rule as commitDetails. `<sha>^1..<sha>` is the natural
        // range expression for this; equivalently `<sha>^1 <sha>` as the
        // two-tree form. We use the two-tree form for consistency.
        let parentsResult = try await Process.git(
            ["rev-list", "--parents", "-n", "1", sha],
            cwd: worktreePath
        )
        guard parentsResult.exitCode == 0 else {
            throw NSError(
                domain: "GitService.diff(sha:file:)",
                code: Int(parentsResult.exitCode),
                userInfo: [NSLocalizedDescriptionKey: parentsResult.stderr]
            )
        }
        let parts = parentsResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        let parentSha: String
        if parts.count > 1 {
            parentSha = String(parts[1])     // first parent
        } else {
            parentSha = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"   // canonical empty tree
        }

        // Always enable rename/copy detection so the diff header reflects
        // the same classification the file list shows, and ALWAYS include
        // the old path in the pathspec when one was provided — empirically
        // `git diff -M -C <parent> <sha> -- <new>` strips the copy header
        // and renders a copy as a full new-file addition, so we need both
        // paths in the pathspec to keep the "copy from old" header. The
        // resulting multi-file diff (for copies, since the source still
        // exists with its own modifications) is then sliced down to just
        // the requested file's section before handing it to DiffParser.
        // See commitDetails for the rationale on -c core.quotePath=false.
        var args: [String] = ["-c", "core.quotePath=false",
                              "diff", "--no-color", "-M", "-C", parentSha, sha, "--", file]
        if let originalPath { args.append(originalPath) }
        let result = try await Process.git(args, cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "GitService.diff(sha:file:)",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return DiffParser.parse(Self.sliceDiffForFile(result.stdout, file: file))
    }

    /// Given a multi-file `git diff` output and a target path, return only
    /// the slice of lines belonging to the section whose new-side path
    /// matches `file`. Sections start with `diff --git a/X b/Y`. When the
    /// target file is not present in any section, returns the empty string
    /// (DiffParser yields zero hunks). When the diff has a single section
    /// (the common non-copy case) the whole output passes through.
    static func sliceDiffForFile(_ raw: String, file: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        let bMarker = "b/\(file)"
        var sections: [(matches: Bool, lines: [String])] = []
        var current: (matches: Bool, lines: [String])? = nil
        for line in lines {
            if line.hasPrefix("diff --git ") {
                if let c = current { sections.append(c) }
                // The header reads `diff --git a/<old> b/<new>`. Check the
                // b/<...> token by suffix; we already know the new path
                // doesn't contain whitespace because git emits the raw
                // path here (no quoting unless the path contains special
                // chars, which we don't generate in tests / typical use).
                let matches = line.hasSuffix(" " + bMarker)
                current = (matches: matches, lines: [line])
            } else if current != nil {
                current!.lines.append(line)
            }
        }
        if let c = current { sections.append(c) }
        let kept = sections.first(where: { $0.matches })?.lines ?? []
        return kept.joined(separator: "\n")
    }

    func fileTree(worktreePath: URL, statusEntries: [ChangedFile]) async throws -> [FileTreeNode] {
        let visiblePaths = try await gitVisibleFilePaths(worktreePath: worktreePath)
        var paths = Set(visiblePaths)
        var badges: [String: String] = [:]
        var visibility: [String: FileVisibility] = [:]
        var directories = Set<String>()
        var lazyDirectories = Set<String>()

        for entry in statusEntries {
            badges[entry.path] = entry.status
            if entry.status == "A" {
                visibility[entry.path] = .untracked
            }
        }

        do {
            let rootEntries = try FileManager.default.contentsOfDirectory(
                at: worktreePath,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            )
            let excludedSources = try await excludedSourcePaths(worktreePath: worktreePath)
            let candidateRootEntries = rootEntries.compactMap { url -> RootIgnoreCandidate? in
                let rel = url.lastPathComponent
                guard rel != ".git", !paths.contains(rel) else { return nil }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return RootIgnoreCandidate(path: rel, isDirectory: isDirectory)
            }
            let rootVisibility = try await ignoredOrExcludedVisibility(
                candidates: candidateRootEntries,
                worktreePath: worktreePath,
                excludedSourcePaths: excludedSources
            )

            for candidate in candidateRootEntries {
                let rel = candidate.path
                guard let kind = rootVisibility[rel] else { continue }
                visibility[rel] = kind
                if candidate.isDirectory {
                    directories.insert(rel)
                    guard !hasVisibleDescendant(of: rel, in: paths) else { continue }
                    lazyDirectories.insert(rel)
                }
                paths.insert(rel)
            }
        } catch {
            // Git-visible paths are still useful if the best-effort all-files
            // root scan or ignore classification fails.
            Self.logger.error("file tree root scan failed for \(worktreePath.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return FileTreeBuilder.build(
            paths: Array(paths),
            badges: badges,
            visibility: visibility,
            directories: directories,
            lazyDirectories: lazyDirectories
        )
    }

    func fileTreeChildren(worktreePath: URL, path: String) async throws -> [FileTreeNode] {
        let directory = worktreePath.appendingPathComponent(path)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )

        var childPaths: [String] = []
        var directories = Set<String>()
        var lazyDirectories = Set<String>()
        var candidates: [RootIgnoreCandidate] = []

        for url in urls where url.lastPathComponent != ".git" {
            let rel = path.isEmpty ? url.lastPathComponent : "\(path)/\(url.lastPathComponent)"
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            childPaths.append(rel)
            candidates.append(RootIgnoreCandidate(path: rel, isDirectory: isDirectory))
            if isDirectory {
                directories.insert(rel)
                lazyDirectories.insert(rel)
            }
        }

        let excludedSources = try await excludedSourcePaths(worktreePath: worktreePath)
        let visiblePaths = Set(try await gitVisibleFilePaths(worktreePath: worktreePath))
        var visibility: [String: FileVisibility] = [:]
        let ignoredCandidates = candidates.filter { candidate in
            if visiblePaths.contains(candidate.path) {
                visibility[candidate.path] = .tracked
                return false
            }
            return true
        }
        let ignoredVisibility = try await ignoredOrExcludedVisibility(
            candidates: ignoredCandidates,
            worktreePath: worktreePath,
            excludedSourcePaths: excludedSources
        )
        visibility.merge(ignoredVisibility) { current, _ in current }
        for path in childPaths where visibility[path] == nil {
            visibility[path] = .tracked
        }

        let built = FileTreeBuilder.build(
            paths: childPaths,
            badges: [:],
            visibility: visibility,
            directories: directories,
            lazyDirectories: lazyDirectories
        )
        guard !path.isEmpty else { return built }
        return findFileTreeNode(path: path, in: built)?.children ?? []
    }

    private func findFileTreeNode(path: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.path == path {
                return node
            }
            if let children = node.children,
               let found = findFileTreeNode(path: path, in: children) {
                return found
            }
        }
        return nil
    }

    private func gitVisibleFilePaths(worktreePath: URL) async throws -> [String] {
        let result = try await Process.git(
            ["ls-files", "--cached", "--others", "--exclude-standard"],
            cwd: worktreePath
        )
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private struct RootIgnoreCandidate {
        let path: String
        let isDirectory: Bool
    }

    private func ignoredOrExcludedVisibility(
        candidates: [RootIgnoreCandidate],
        worktreePath: URL,
        excludedSourcePaths: Set<String>
    ) async throws -> [String: FileVisibility] {
        guard !candidates.isEmpty else { return [:] }

        var queriedPathToRoot: [String: String] = [:]
        var inputPaths: [String] = []
        for candidate in candidates {
            inputPaths.append(candidate.path)
            queriedPathToRoot[candidate.path] = candidate.path
            if candidate.isDirectory {
                let directoryPath = "\(candidate.path)/"
                inputPaths.append(directoryPath)
                queriedPathToRoot[directoryPath] = candidate.path
            }
        }

        let result = try await Process.git(
            ["check-ignore", "--stdin", "--no-index", "-v", "-z"],
            cwd: worktreePath,
            stdin: inputPaths.joined(separator: "\0") + "\0"
        )
        guard result.exitCode == 0 else { return [:] }

        var visibility: [String: FileVisibility] = [:]
        for entry in checkIgnoreMatches(result.stdout) {
            guard let root = queriedPathToRoot[entry.path] else { continue }
            let source = normalizedPath(entry.source, relativeTo: worktreePath)
            visibility[root] = excludedSourcePaths.contains(source) ? .excluded : .ignored
        }
        return visibility
    }

    private struct CheckIgnoreMatch {
        let source: String
        let path: String
    }

    private func checkIgnoreMatches(_ output: String) -> [CheckIgnoreMatch] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var matches: [CheckIgnoreMatch] = []
        var index = 0
        while index + 3 < fields.count {
            matches.append(CheckIgnoreMatch(source: fields[index], path: fields[index + 3]))
            index += 4
        }
        return matches
    }

    private func hasVisibleDescendant(of root: String, in paths: Set<String>) -> Bool {
        let prefix = "\(root)/"
        return paths.contains { $0.hasPrefix(prefix) }
    }

    private func excludedSourcePaths(worktreePath: URL) async throws -> Set<String> {
        var paths: Set<String> = []

        let infoExclude = try await Process.git(
            ["rev-parse", "--git-path", "info/exclude"],
            cwd: worktreePath
        )
        if infoExclude.exitCode == 0 {
            let path = infoExclude.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                paths.insert(normalizedPath(path, relativeTo: worktreePath))
            }
        }

        let result = try await Process.git(
            ["config", "--path", "--get", "core.excludesfile"],
            cwd: worktreePath
        )
        if result.exitCode == 0 {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                paths.insert(normalizedPath(path, relativeTo: worktreePath))
            }
        }
        if let defaultGlobalExcludes = defaultGlobalExcludesPath() {
            paths.insert(normalizedPath(defaultGlobalExcludes, relativeTo: worktreePath))
        }

        return paths
    }

    private func defaultGlobalExcludesPath() -> String? {
        if let xdgConfigHome = getenv("XDG_CONFIG_HOME").flatMap({ String(validatingUTF8: $0) }),
           !xdgConfigHome.isEmpty {
            return URL(fileURLWithPath: xdgConfigHome)
                .appendingPathComponent("git")
                .appendingPathComponent("ignore")
                .path
        }
        guard let home = getenv("HOME").flatMap({ String(validatingUTF8: $0) }),
              !home.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config")
            .appendingPathComponent("git")
            .appendingPathComponent("ignore")
            .path
    }

    private func normalizedPath(_ path: String, relativeTo base: URL) -> String {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : base.appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}

extension GitService {
    func commitDetails(at worktree: URL, sha: String) async throws -> CommitDetails {
        // Header line: <H>\u{1f}<h>\u{1f}<an>\u{1f}<ae>\u{1f}<aI>\u{1f}<P>\u{1f}<s>
        // Body follows on a new line after the RS sentinel \u{1e}.
        // Use the RS as an unambiguous separator since the body may contain blank lines.
        let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%s%n%x1e%n%b"
        let header = try await Process.git(
            ["show", "--no-patch", "--pretty=tformat:\(format)", sha],
            cwd: worktree
        )
        guard header.exitCode == 0 else {
            throw NSError(domain: "GitService.commitDetails", code: Int(header.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: header.stderr])
        }

        let raw = header.stdout
        let parts = raw.components(separatedBy: "\n\u{1e}\n")
        let headerLine = parts.first ?? ""
        let body = (parts.count > 1 ? parts[1] : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = headerLine.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count == 7 else {
            throw NSError(domain: "GitService.commitDetails", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "malformed git show output: \(fields.count) fields"])
        }
        let fullSha = String(fields[0])
        let shortSha = String(fields[1])
        let author = String(fields[2])
        let authorEmail = String(fields[3])
        let dateStr = String(fields[4])
        let parentsField = String(fields[5])
        let rawSubject = String(fields[6])

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let date = isoFormatter.date(from: dateStr) ?? Date(timeIntervalSince1970: 0)
        let (tag, subject) = CommitInfo.parseConventional(subject: rawSubject)

        let parents = parentsField
            .split(separator: " ")
            .map { String($0).prefix(7) }
            .map(String.init)

        // Files: two separate diff-tree calls.
        // Use the explicit two-tree form (<left> <right>) instead of the
        // single-sha form so that:
        //   • Merge commits: compare first parent vs. the merge commit.
        //     The single-sha form suppresses output for merges without -m.
        //   • Initial commits: compare the canonical empty-tree SHA vs. the
        //     commit. The --root flag only works with the single-sha form and
        //     is not needed here.
        // --numstat and --name-status are mutually exclusive when combined in a
        // single invocation, so we run them separately and merge the results.
        let emptyTreeSha = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        let leftTree = parents.isEmpty ? emptyTreeSha : "\(sha)^1"
        let rightTree = sha

        // `-c core.quotePath=false` keeps non-ASCII / special characters in
        // paths emitted as raw UTF-8 instead of git's default backslash-
        // octal quoting (e.g. `"caf\303\251.txt"`). Without it, the parsed
        // path is the quoted text — the file list shows the escaped name,
        // the numstat↔name-status merge misses (key mismatch), and a later
        // `git diff -- <quoted-path>` finds nothing on disk.
        async let numstatResult = Process.git(
            ["-c", "core.quotePath=false",
             "diff-tree", "--no-commit-id", "-r", "-M", "-C", "--no-color", "--numstat", leftTree, rightTree],
            cwd: worktree
        )
        async let nameStatusResult = Process.git(
            ["-c", "core.quotePath=false",
             "diff-tree", "--no-commit-id", "-r", "-M", "-C", "--no-color", "--name-status", leftTree, rightTree],
            cwd: worktree
        )
        let numstatOut = try await numstatResult
        let nameStatusOut = try await nameStatusResult

        guard numstatOut.exitCode == 0 else {
            throw NSError(domain: "GitService.commitDetails", code: Int(numstatOut.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: numstatOut.stderr])
        }
        guard nameStatusOut.exitCode == 0 else {
            throw NSError(domain: "GitService.commitDetails", code: Int(nameStatusOut.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: nameStatusOut.stderr])
        }

        var addByPath: [String: Int] = [:]
        var delByPath: [String: Int] = [:]
        var statusByPath: [String: String] = [:]
        var originalByPath: [String: String] = [:]
        var ordered: [String] = []
        var orderedSet: Set<String> = []

        // Parse numstat: "adds \t dels \t path"
        // With -M/-C, git emits renames as a combined path field in one of two forms:
        //   simple: "old.txt => new.txt"
        //   brace:  "prefix/{old => new}/suffix"
        // Normalize to the new path before keying so the dict aligns with name-status.
        for line in numstatOut.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let addStr = parts[0]
            let delStr = parts[1]
            let path = Self.numstatNewPath(parts[2])
            addByPath[path] = (addStr == "-") ? 0 : (Int(addStr) ?? 0)
            delByPath[path] = (delStr == "-") ? 0 : (Int(delStr) ?? 0)
        }

        // Parse name-status: "status[score?] \t [old \t] new"
        for line in nameStatusOut.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let statusLetter = String(parts[0].prefix(1))
            let newPath: String
            let oldPath: String?
            if statusLetter == "R" || statusLetter == "C" {
                guard parts.count >= 3 else { continue }
                newPath = parts[2]
                oldPath = parts[1]
            } else {
                newPath = parts[1]
                oldPath = nil
            }
            statusByPath[newPath] = statusLetter
            if let oldPath { originalByPath[newPath] = oldPath }
            if orderedSet.insert(newPath).inserted { ordered.append(newPath) }
        }

        let files: [CommitChangedFile] = ordered.map { path in
            CommitChangedFile(
                path: path,
                originalPath: originalByPath[path],
                status: statusByPath[path] ?? "M",
                add: addByPath[path] ?? 0,
                del: delByPath[path] ?? 0
            )
        }

        let info = CommitInfo(
            sha: fullSha,
            shortSha: shortSha,
            author: author,
            authorInitials: CommitInfo.initials(for: author),
            date: date,
            subject: subject,
            conventionalTag: tag,
            filesChanged: files.count,
            insertions: files.reduce(0) { $0 + $1.add },
            deletions: files.reduce(0) { $0 + $1.del }
        )

        return CommitDetails(
            info: info,
            body: body,
            authorEmail: authorEmail,
            parents: parents,
            files: files
        )
    }

    /// Given a numstat path field that may describe a rename via `old => new`
    /// or the brace form `prefix/{old => new}/suffix`, return the new path.
    /// For non-rename paths, returns the input unchanged.
    private static func numstatNewPath(_ raw: String) -> String {
        // Brace form: prefix/{old => new}/suffix
        if let openBrace = raw.firstIndex(of: "{"),
           let closeBrace = raw.firstIndex(of: "}"),
           openBrace < closeBrace {
            let inside = raw[raw.index(after: openBrace)..<closeBrace]
            guard let arrow = inside.range(of: " => ") else { return raw }
            let newInside = inside[arrow.upperBound...]
            let prefix = raw[..<openBrace]
            let suffix = raw[raw.index(after: closeBrace)...]
            // Collapse any double-slash that arises from an empty new-inside
            // segment (e.g. "dir/{old => }foo" → "dir/foo").
            let joined = String(prefix) + String(newInside) + String(suffix)
            return joined.replacingOccurrences(of: "//", with: "/")
        }
        // Simple form: "old => new"
        if let arrow = raw.range(of: " => ") {
            return String(raw[arrow.upperBound...])
        }
        return raw
    }
}

extension GitService {
    /// Commits on the current branch but not on a comparison ref, using a
    /// 2-step cascade to pick the ref:
    ///   1. `@{u}..HEAD` if an upstream tracking branch is configured.
    ///   2. `<baseBranch>..HEAD` if `baseBranch` is supplied and resolves
    ///      locally (covers fresh branches with no remote upstream).
    ///   3. Returns `([], nil)` when neither resolves — detached HEAD,
    ///      orphan branches, etc.
    ///
    /// One `git log` invocation parses subject + author + ISO date +
    /// per-commit numstat in a single pass to avoid N round-trips.
    func commitsAhead(at worktree: URL, baseBranch: String? = nil) async throws -> (commits: [CommitInfo], comparisonRef: String?) {
        // Step 1: Resolve upstream first. `--symbolic-full-name @{u}` returns
        // `refs/remotes/origin/main`; `--abbrev-ref @{u}` returns
        // `origin/main`. Use the abbreviated form for display.
        let up = try await Process.git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            cwd: worktree
        )
        var upstreamName: String? = nil
        if up.exitCode == 0 {
            let candidate = up.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && candidate != "@{u}" {
                upstreamName = candidate
            }
        }

        // Step 2: If no upstream, try the base branch (if it resolves locally).
        var baseName: String? = nil
        if upstreamName == nil, let base = baseBranch, !base.isEmpty {
            let verify = try await Process.git(
                ["rev-parse", "--verify", "--quiet", base],
                cwd: worktree
            )
            if verify.exitCode == 0 { baseName = base }
        }

        // Step 3: If neither resolves, bail out.
        guard let comparisonRef = upstreamName ?? baseName else {
            return ([], nil)
        }

        // %x1f = ASCII 0x1f (unit separator), %x1e = 0x1e (record
        // separator). Avoids collisions with any text in messages.
        //
        // Place %x1e at the START of each commit's format line (using
        // tformat: so git appends a LF after each record). Splitting on
        // \x1e then yields one empty leading piece followed by one piece
        // per commit, each containing:
        //   <sha>\x1f<short>\x1f<author-name>\x1f<author-iso-date>\x1f<subject>\n
        //   \n                        ← blank separator between header and numstat
        //   <numstat lines: "A\tD\tpath" each>
        let format = "%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s"
        let log = try await Process.git(
            ["log", "\(comparisonRef)..HEAD", "--pretty=tformat:\(format)", "--numstat"],
            cwd: worktree
        )
        guard log.exitCode == 0 else {
            return ([], comparisonRef)
        }

        let records = log.stdout
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .map { String($0) }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var commits: [CommitInfo] = []
        for record in records {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard let headerLine = lines.first else { continue }
            let fields = headerLine.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5 else { continue }
            let sha = String(fields[0])
            let short = String(fields[1])
            let author = String(fields[2])
            let dateStr = String(fields[3])
            let rawSubject = String(fields[4])
            let date = isoFormatter.date(from: dateStr) ?? Date(timeIntervalSince1970: 0)
            let (tag, subject) = CommitInfo.parseConventional(subject: rawSubject)

            // Numstat lines: tab-separated "adds\tdels\tpath". For
            // binary files git emits "-" for adds/dels; we count those
            // files but treat their numbers as 0.
            var filesChanged = 0
            var adds = 0
            var dels = 0
            for line in lines.dropFirst() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { continue }
                let parts = trimmedLine.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                filesChanged += 1
                if let a = Int(parts[0]) { adds += a }
                if let d = Int(parts[1]) { dels += d }
            }

            commits.append(CommitInfo(
                sha: sha,
                shortSha: short,
                author: author,
                authorInitials: CommitInfo.initials(for: author),
                date: date,
                subject: subject,
                conventionalTag: tag,
                filesChanged: filesChanged,
                insertions: adds,
                deletions: dels
            ))
        }

        return (commits, comparisonRef)
    }

    /// Older history for the "Load older" affordance in the right sidebar.
    /// Returns up to `count` commits reachable from `beforeSha^`, following
    /// only the first parent so merge-side ancestry doesn't drown the list.
    /// Same record format as `commitsAhead`, so callers can reuse the same
    /// `CommitInfo` shape and the divider/dimming lives in the view layer.
    func commitsOlder(worktreePath: URL, beforeSha: String, count: Int) async throws -> [CommitInfo] {
        let range = "\(beforeSha)^"
        let format = "%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s"
        let log = try await Process.git(
            ["log", range, "-n", String(count), "--first-parent",
             "--pretty=tformat:\(format)", "--numstat"],
            cwd: worktreePath
        )
        guard log.exitCode == 0 else {
            throw NSError(
                domain: "GitService.commitsOlder",
                code: Int(log.exitCode),
                userInfo: [NSLocalizedDescriptionKey: log.stderr.isEmpty ? "git log failed" : log.stderr]
            )
        }

        let records = log.stdout
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .map { String($0) }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var commits: [CommitInfo] = []
        for record in records {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard let headerLine = lines.first else { continue }
            let fields = headerLine.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5 else { continue }
            let sha = String(fields[0])
            let short = String(fields[1])
            let author = String(fields[2])
            let dateStr = String(fields[3])
            let rawSubject = String(fields[4])
            let date = isoFormatter.date(from: dateStr) ?? Date(timeIntervalSince1970: 0)
            let (tag, subject) = CommitInfo.parseConventional(subject: rawSubject)

            var filesChanged = 0
            var adds = 0
            var dels = 0
            for line in lines.dropFirst() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { continue }
                let parts = trimmedLine.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                filesChanged += 1
                if let a = Int(parts[0]) { adds += a }
                if let d = Int(parts[1]) { dels += d }
            }

            commits.append(CommitInfo(
                sha: sha,
                shortSha: short,
                author: author,
                authorInitials: CommitInfo.initials(for: author),
                date: date,
                subject: subject,
                conventionalTag: tag,
                filesChanged: filesChanged,
                insertions: adds,
                deletions: dels
            ))
        }
        return commits
    }
}
