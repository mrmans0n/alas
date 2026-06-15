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
                                          renameFrom: entries[i].renameFrom,
                                          conflict: entries[i].conflict)
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
                                             renameFrom: entries[i].renameFrom,
                                             conflict: entries[i].conflict)
                }
            }
        }
        return entries
    }

    func diff(worktreePath: URL, file: String, staged: Bool = false, originalPath: String? = nil) async throws -> ParsedDiff {
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
            return await Self.parseOffMain(result.stdout)
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
        var args = ["diff", "--no-color", "-M", "-C"]
        if staged {
            args.append("--cached")
            if head { args.append("HEAD") }
        }
        args.append("--")
        args.append(file)
        if let originalPath, !originalPath.isEmpty {
            args.append(originalPath)
        }
        let result = try await Process.git(args, cwd: worktreePath)
        let stdout = originalPath?.isEmpty == false
            ? Self.sliceDiffForFile(result.stdout, file: file)
            : result.stdout
        return await Self.parseOffMain(stdout)
    }

    func contextSnapshot(worktreePath: URL, file: String, staged: Bool, originalPath: String? = nil) async throws -> DiffReviewFileContextSnapshot {
        let oldPath = originalPath?.isEmpty == false ? originalPath! : file
        let old: DiffReviewFileContextLines
        let new: DiffReviewFileContextLines

        if staged {
            if try await hasHead(worktreePath: worktreePath) {
                old = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: "HEAD", path: oldPath)
            } else {
                old = .available([])
            }
            new = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: ":", path: file)
        } else {
            old = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: ":", path: oldPath)
            new = try await worktreeLinesOrUnavailable(worktreePath: worktreePath, path: file)
        }

        return DiffReviewFileContextSnapshot(old: old, new: new)
    }

    func commitContextSnapshot(worktreePath: URL, sha: String, file: String, originalPath: String? = nil) async throws -> DiffReviewFileContextSnapshot {
        let oldPath = originalPath?.isEmpty == false ? originalPath! : file
        let parentSha = try await firstParentOrEmptyTree(worktreePath: worktreePath, sha: sha)
        let old = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: parentSha, path: oldPath)
        let new = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: sha, path: file)
        return DiffReviewFileContextSnapshot(old: old, new: new)
    }

    func refContextSnapshot(worktreePath: URL, baseRef: String, headRef: String, file: String, originalPath: String? = nil) async throws -> DiffReviewFileContextSnapshot {
        let oldPath = originalPath?.isEmpty == false ? originalPath! : file
        let mergeBase = try await mergeBase(worktreePath: worktreePath, baseRef: baseRef, headRef: headRef)
        let old = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: mergeBase, path: oldPath)
        let new = try await blobLinesOrUnavailable(worktreePath: worktreePath, ref: headRef, path: file)
        return DiffReviewFileContextSnapshot(old: old, new: new)
    }

    private func mergeBase(worktreePath: URL, baseRef: String, headRef: String) async throws -> String {
        let result = try await Process.git(["merge-base", baseRef, headRef], cwd: worktreePath)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !stdout.isEmpty else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty
                ? "Unable to resolve merge base for \(baseRef) and \(headRef)."
                : detail
            throw ProcessError.nonZeroExit(result.exitCode, message)
        }
        return stdout
    }

    private func firstParentOrEmptyTree(worktreePath: URL, sha: String) async throws -> String {
        let parentsResult = try await Process.git(
            ["rev-list", "--parents", "-n", "1", sha],
            cwd: worktreePath
        )
        guard parentsResult.exitCode == 0 else {
            throw NSError(
                domain: "GitService.commitContextSnapshot(sha:file:)",
                code: Int(parentsResult.exitCode),
                userInfo: [NSLocalizedDescriptionKey: parentsResult.stderr]
            )
        }
        let parts = parentsResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        if parts.count > 1 {
            return String(parts[1])
        }
        return "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    }

    private func blobLinesOrUnavailable(worktreePath: URL, ref: String, path: String) async throws -> DiffReviewFileContextLines {
        let blobSpec = ref == ":" ? ":\(path)" : "\(ref):\(path)"
        let result = try await Process.gitData(["show", blobSpec], cwd: worktreePath)
        guard result.exitCode == 0 else {
            return .unavailable
        }
        return Self.contextLinesOrUnavailable(from: result.stdout)
    }

    private func worktreeLinesOrUnavailable(worktreePath: URL, path: String) async throws -> DiffReviewFileContextLines {
        let url = worktreePath.appendingPathComponent(path)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return .available([destination])
        }
        do {
            let data = try Data(contentsOf: url)
            return Self.contextLinesOrUnavailable(from: data)
        } catch {
            return .unavailable
        }
    }

    private static func contextLinesOrUnavailable(from data: Data) -> DiffReviewFileContextLines {
        guard !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            return .unavailable
        }
        return .available(splitContextLines(text))
    }

    private static func splitContextLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Parses diff stdout on a detached executor so callers awaited from the
    /// MainActor (SwiftUI `.task`) don't resume on main for tens of thousands
    /// of lines of synchronous string work — that's the freeze users see on
    /// large generated files / lockfiles even though the pane shows a loader.
    private static func parseOffMain(_ stdout: String) async -> ParsedDiff {
        await Task.detached(priority: .userInitiated) {
            DiffParser.parse(stdout)
        }.value
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
        let stdout = result.stdout
        return await Task.detached(priority: .userInitiated) {
            DiffParser.parse(Self.sliceDiffForFile(stdout, file: file))
        }.value
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

            // Non-lazy ignored/excluded directories still have tracked
            // descendants in `paths`.  The tree builder only knows a
            // node's visibility from the dict, so intermediate sub-
            // directory segments (e.g. ".build/nested") that aren't in
            // the dict default to .tracked, causing a brief visual
            // flicker when the tree refreshes.  Propagate the root
            // visibility to those intermediate directory segments.
            for candidate in candidateRootEntries where candidate.isDirectory {
                let rel = candidate.path
                guard let kind = rootVisibility[rel],
                      !lazyDirectories.contains(rel) else { continue }
                let prefix = rel + "/"
                for p in paths where p.hasPrefix(prefix) {
                    let parts = p.dropFirst(prefix.count).split(separator: "/")
                    guard parts.count > 1 else { continue }
                    var current = rel
                    for part in parts.dropLast() {
                        current += "/" + String(part)
                        if visibility[current] == nil {
                            visibility[current] = kind
                        }
                    }
                }
            }
        } catch {
            // Git-visible paths are still useful if the best-effort all-files
            // root scan or ignore classification fails.
            Self.logger.error("file tree root scan failed for \(worktreePath.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let submodules = (try? await submodulePaths(worktreePath: worktreePath)) ?? []

        return FileTreeBuilder.build(
            paths: Array(paths),
            badges: badges,
            visibility: visibility,
            directories: directories,
            lazyDirectories: lazyDirectories,
            submodules: submodules
        )
    }

    func submodulePaths(worktreePath: URL) async throws -> Set<String> {
        let result = try await Process.git(["ls-files", "--stage", "-z"], cwd: worktreePath)
        guard result.exitCode == 0 else { return [] }
        var paths = Set<String>()
        // With -z the format is: "<mode> <sha> <stage>\t<path>\0 ..."
        // — lines separated by \0 so paths with spaces are verbatim.
        let entries = result.stdout.split(separator: "\0", omittingEmptySubsequences: true)
        for entry in entries {
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let meta = String(entry[..<tab])
            let path = String(entry[entry.index(after: tab)...])
            let parts = meta.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3, parts[0] == "160000" else { continue }
            paths.insert(path)
        }
        return paths
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

        let submodules = (try? await submodulePaths(worktreePath: worktreePath)) ?? []

        let built = FileTreeBuilder.build(
            paths: childPaths,
            badges: [:],
            visibility: visibility,
            directories: directories,
            lazyDirectories: lazyDirectories,
            submodules: submodules
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
            guard !entry.pattern.hasPrefix("!") else { continue }
            let source = normalizedPath(entry.source, relativeTo: worktreePath)
            visibility[root] = excludedSourcePaths.contains(source) ? .excluded : .ignored
        }
        return visibility
    }

    private struct CheckIgnoreMatch {
        let source: String
        let pattern: String
        let path: String
    }

    private func checkIgnoreMatches(_ output: String) -> [CheckIgnoreMatch] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var matches: [CheckIgnoreMatch] = []
        var index = 0
        while index + 3 < fields.count {
            matches.append(CheckIgnoreMatch(source: fields[index], pattern: fields[index + 2], path: fields[index + 3]))
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

    /// Returns the list of staged (index vs HEAD) changed files in the same
    /// `[CommitChangedFile]` shape that `commitDetails` produces.
    ///
    /// - Probes `hasHead` first; on an unborn branch (no HEAD) it diffs the
    ///   index against the canonical empty-tree SHA so the initial-commit
    ///   workflow works correctly.
    /// - Runs `--name-status -z` and `--numstat -z` in parallel, then merges.
    /// - Unparseable lines are logged and skipped rather than throwing.
    func stagedChangedFiles(at worktreePath: URL) async throws -> [CommitChangedFile] {
        let head = try await hasHead(worktreePath: worktreePath)
        // Against the empty tree when no HEAD exists (unborn branch).
        let baseArgs: [String] = head
            ? ["-c", "core.quotePath=false", "diff", "--cached", "HEAD"]
            : ["-c", "core.quotePath=false", "diff", "--cached",
               "4b825dc642cb6eb9a060e54bf8d69288fbee4904"]

        async let nameStatusResult = Process.git(
            baseArgs + ["--name-status", "-z"],
            cwd: worktreePath
        )
        async let numstatResult = Process.git(
            baseArgs + ["--numstat", "-z"],
            cwd: worktreePath
        )
        let nameStatus = try await nameStatusResult
        let numstat   = try await numstatResult

        guard nameStatus.exitCode == 0 else {
            throw NSError(
                domain: "GitService.stagedChangedFiles",
                code: Int(nameStatus.exitCode),
                userInfo: [NSLocalizedDescriptionKey: nameStatus.stderr]
            )
        }
        guard numstat.exitCode == 0 else {
            throw NSError(
                domain: "GitService.stagedChangedFiles",
                code: Int(numstat.exitCode),
                userInfo: [NSLocalizedDescriptionKey: numstat.stderr]
            )
        }

        // Parse --numstat -z output.
        // Format per entry (NUL-separated fields within each record):
        //   "<add>\t<del>\t<path>\0"   (ordinary files)
        //   "<add>\t<del>\t\0<oldPath>\0<newPath>\0"  (renames/copies)
        // The -z flag separates records with NUL; we split on NUL and then
        // handle the tab-delimited first element per record.
        var addByPath: [String: Int] = [:]
        var delByPath: [String: Int] = [:]

        // With -z the stream is NUL-terminated. Split and process tokens.
        let numstatTokens = numstat.stdout.components(separatedBy: "\0").filter { !$0.isEmpty }
        var ni = 0
        while ni < numstatTokens.count {
            let token = numstatTokens[ni]
            // Split on the first two tabs only so paths containing tab
            // characters survive intact. Format is `<adds>\t<dels>\t<path>`;
            // the trailing path field may itself contain tabs.
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { ni += 1
            continue }
            let addStr = parts[0]
            let delStr = parts[1]
            let pathField = parts[2]

            let newPath: String
            if pathField.isEmpty {
                // Rename/copy: next two tokens are old and new path.
                guard ni + 2 < numstatTokens.count else { ni += 1
                continue }
                // ni+1 = old path, ni+2 = new path
                newPath = numstatTokens[ni + 2]
                ni += 3
            } else {
                newPath = Self.numstatNewPath(pathField)
                ni += 1
            }
            addByPath[newPath] = (addStr == "-") ? 0 : (Int(addStr) ?? 0)
            delByPath[newPath] = (delStr == "-") ? 0 : (Int(delStr) ?? 0)
        }

        // Parse --name-status -z output.
        // Format: "<status>\0<path>\0"  (ordinary)
        //         "<status>\0<oldPath>\0<newPath>\0"  (R/C)
        var statusByPath: [String: String] = [:]
        var originalByPath: [String: String] = [:]
        var ordered: [String] = []
        var orderedSet: Set<String> = []

        let nsTokens = nameStatus.stdout.components(separatedBy: "\0").filter { !$0.isEmpty }
        var si = 0
        while si < nsTokens.count {
            let statusField = nsTokens[si]
            guard !statusField.isEmpty else { si += 1
            continue }
            let statusLetter = String(statusField.prefix(1))
            if statusLetter == "R" || statusLetter == "C" {
                guard si + 2 < nsTokens.count else { si += 1
                continue }
                let oldPath = nsTokens[si + 1]
                let newPath = nsTokens[si + 2]
                statusByPath[newPath] = statusLetter
                originalByPath[newPath] = oldPath
                if orderedSet.insert(newPath).inserted { ordered.append(newPath) }
                si += 3
            } else {
                guard si + 1 < nsTokens.count else { si += 1
                continue }
                let path = nsTokens[si + 1]
                statusByPath[path] = statusLetter
                if orderedSet.insert(path).inserted { ordered.append(path) }
                si += 2
            }
        }

        return ordered.map { path in
            CommitChangedFile(
                path: path,
                originalPath: originalByPath[path],
                status: statusByPath[path] ?? "M",
                add: addByPath[path] ?? 0,
                del: delByPath[path] ?? 0
            )
        }
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
    func commitsAhead(at worktree: URL, baseBranch: String? = nil, ignoreUpstream: Bool = false) async throws -> (commits: [CommitInfo], comparisonRef: String?) {
        // Step 1: Resolve upstream first. `--symbolic-full-name @{u}` returns
        // `refs/remotes/origin/main`; `--abbrev-ref @{u}` returns
        // `origin/main`. Use the abbreviated form for display.
        var upstreamName: String? = nil
        if !ignoreUpstream {
            let up = try await Process.git(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                cwd: worktree
            )
            if up.exitCode == 0 {
                let candidate = up.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && candidate != "@{u}" {
                    upstreamName = candidate
                }
            }
        }

        // Step 2: If no upstream, try the base branch. Prefer `origin/<base>`
        // over local `<base>` for simple branch names. Slash-named bases are
        // ambiguous, so resolve local refs first before treating them as
        // remote-qualified refs.
        var baseName: String? = nil
        if upstreamName == nil, let base = baseBranch, !base.isEmpty {
            if base.contains("/") {
                let local = try await Process.git(
                    ["show-ref", "--verify", "--quiet", "refs/heads/\(base)"],
                    cwd: worktree
                )
                if local.exitCode == 0 {
                    baseName = base
                } else {
                    let direct = try await Process.git(
                        ["show-ref", "--verify", "--quiet", "refs/remotes/\(base)"],
                        cwd: worktree
                    )
                    if direct.exitCode == 0 { baseName = base }
                }
            }
            if baseName == nil {
                if ignoreUpstream {
                    let local = try await Process.git(
                        ["show-ref", "--verify", "--quiet", "refs/heads/\(base)"],
                        cwd: worktree
                    )
                    if local.exitCode == 0 { baseName = base }
                }
                if baseName == nil {
                    let origin = try await Process.git(
                        ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(base)"],
                        cwd: worktree
                    )
                    if origin.exitCode == 0 {
                        baseName = "origin/\(base)"
                    } else if !ignoreUpstream {
                        let local = try await Process.git(
                            ["show-ref", "--verify", "--quiet", "refs/heads/\(base)"],
                            cwd: worktree
                        )
                        if local.exitCode == 0 { baseName = base }
                    }
                }
            }
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

extension GitService {
    /// One probe of HEAD's behind-count against an arbitrary ref. Used both
    /// for "behind base" (origin/main) and "behind upstream" (origin/<branch>).
    struct BehindStatus: Equatable, Sendable {
        let ref: String      // e.g. "origin/main" or "origin/my-feature"
        let sha: String      // SHA of ref at probe time
        let count: Int       // git rev-list --count HEAD..<ref>
        let probedAt: Date
    }

    /// Errors emitted by `behindStatus`. Either git invocation can fail
    /// (e.g. ref disappeared between resolution and the probe).
    enum BehindStatusError: Error, Equatable, Sendable {
        case revParseFailed(stderr: String)
        case revListFailed(stderr: String)
    }

    /// Reads the current branch name for a worktree. Returns empty string
    /// when HEAD is detached or the branch is unborn (no commits yet).
    func currentBranch(worktreePath: URL) async throws -> String {
        let result = try await Process.git(
            ["symbolic-ref", "--short", "-q", "HEAD"],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else { return "" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the current HEAD SHA for the worktree.
    func revParseHEAD(worktreePath: URL) async throws -> String {
        let result = try await Process.git(
            ["rev-parse", "HEAD"],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves the base ref to compare against for a given worktree.
    /// Returns nil when neither `origin/<base>`, `refs/remotes/<base>`, nor local `<base>` exists.
    /// `remote == nil` means "no fetch path; use the local ref as-is".
    func resolveBaseRef(
        worktreePath: URL,
        baseBranch: String,
        preferLocal: Bool = false
    ) async throws -> (remote: String?, baseRef: String, fetchBranch: String?)? {
        guard !baseBranch.isEmpty else { return nil }

        if baseBranch.contains("/") {
            let localCheck = try await Process.git(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(baseBranch)"],
                cwd: worktreePath
            )
            if localCheck.exitCode == 0 {
                return (remote: nil, baseRef: baseBranch, fetchBranch: nil)
            }

            let directRef = "refs/remotes/\(baseBranch)"
            let directCheck = try await Process.git(
                ["show-ref", "--verify", "--quiet", directRef],
                cwd: worktreePath
            )
            if directCheck.exitCode == 0 {
                let remoteBranch = try await splitRemoteQualifiedRef(baseBranch, worktreePath: worktreePath)
                return (remote: remoteBranch.remote, baseRef: baseBranch, fetchBranch: remoteBranch.branch)
            }
        }

        if preferLocal {
            let localCheck = try await Process.git(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(baseBranch)"],
                cwd: worktreePath
            )
            if localCheck.exitCode == 0 {
                return (remote: nil, baseRef: baseBranch, fetchBranch: nil)
            }
        }

        // Prefer origin/<base> for configured defaults.
        let originRef = "refs/remotes/origin/\(baseBranch)"
        let originCheck = try await Process.git(
            ["show-ref", "--verify", "--quiet", originRef],
            cwd: worktreePath
        )
        if originCheck.exitCode == 0 {
            return (remote: "origin", baseRef: "origin/\(baseBranch)", fetchBranch: baseBranch)
        }

        if !preferLocal {
            let localCheck = try await Process.git(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(baseBranch)"],
                cwd: worktreePath
            )
            if localCheck.exitCode == 0 {
                return (remote: nil, baseRef: baseBranch, fetchBranch: nil)
            }
        }

        return nil
    }

    private func splitRemoteQualifiedRef(_ ref: String, worktreePath: URL) async throws -> (remote: String?, branch: String?) {
        let remotesResult = try await Process.git(["remote"], cwd: worktreePath)
        if remotesResult.exitCode == 0 {
            let remotes = remotesResult.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let remote = remotes
                .filter({ ref.hasPrefix($0 + "/") })
                .max(by: { $0.count < $1.count }) {
                return (remote: remote, branch: String(ref.dropFirst(remote.count + 1)))
            }
        }

        let parts = ref.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return (remote: nil, branch: nil) }
        return (remote: String(parts[0]), branch: String(parts[1]))
    }

    /// Resolves the upstream tracking ref (e.g. `origin/my-feature`) of the
    /// current branch, or nil when none is configured. Used to detect when
    /// the local HEAD is behind a ref that someone else (or another machine)
    /// pushed to.
    func resolveUpstreamRef(worktreePath: URL) async throws -> (remote: String, ref: String)? {
        let result = try await Process.git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "@{u}" else { return nil }
        // `name` is "<remote>/<branch>". Both segments may contain slashes
        // (`foo/bar` is a valid remote name, `release/v1` is a valid branch
        // name), so we can't split on the first slash. Match against the
        // configured remotes and pick the longest one that prefixes `name`.
        let remotesResult = try await Process.git(["remote"], cwd: worktreePath)
        guard remotesResult.exitCode == 0 else { return nil }
        let remotes = remotesResult.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let remote = remotes
            .filter({ name.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count })
        else { return nil }
        return (remote: remote, ref: name)
    }

    /// Computes behind-count of HEAD relative to `ref`, plus the resolved
    /// SHA of `ref`. `probedAt` is stamped to `Date()` at call time.
    /// Throws `BehindStatusError` when either git invocation exits non-zero;
    /// callers catch and treat as a transient probe failure.
    func behindStatus(
        worktreePath: URL,
        ref: String
    ) async throws -> BehindStatus {
        let shaResult = try await Process.git(
            ["rev-parse", ref],
            cwd: worktreePath
        )
        guard shaResult.exitCode == 0 else {
            throw BehindStatusError.revParseFailed(stderr: shaResult.stderr)
        }
        let sha = shaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let countResult = try await Process.git(
            ["rev-list", "--count", "HEAD..\(ref)"],
            cwd: worktreePath
        )
        guard countResult.exitCode == 0,
              let behind = Int(countResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw BehindStatusError.revListFailed(stderr: countResult.stderr)
        }

        return BehindStatus(
            ref: ref,
            sha: sha,
            count: behind,
            probedAt: Date()
        )
    }

    /// Runs `git fetch <remote> <branch>` and returns the completion time.
    /// Throws if the subprocess exits non-zero so callers can log.
    @discardableResult
    func fetchRef(
        worktreePath: URL,
        remote: String,
        branch: String
    ) async throws -> Date {
        let result = try await Process.git(
            ["fetch", remote, branch],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "GitService.fetchRef",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return Date()
    }

    /// Returns the remote and branch to fetch if `ref` is a remote-tracking
    /// ref (e.g. `origin/main`). Returns `nil` for local refs, SHAs, or
    /// anything without a known `<remote>/` prefix.
    func remoteForFetch(worktreePath: URL, ref: String) async throws -> (remote: String, branch: String)? {
        guard ref.contains("/") else { return nil }
        // Guard against local branches whose name happens to match a remote
        // prefix (e.g. a local branch literally named "origin/main").
        let localCheck = try await Process.git(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(ref)"],
            cwd: worktreePath
        )
        if localCheck.exitCode == 0 { return nil }
        let remotesResult = try await Process.git(["remote"], cwd: worktreePath)
        guard remotesResult.exitCode == 0 else { return nil }
        let remotes = remotesResult.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let remote = remotes
            .filter({ ref.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count })
        else { return nil }
        let branch = String(ref.dropFirst(remote.count + 1))
        return (remote, branch)
    }
}

extension GitService {
    /// Detects an in-progress merge / rebase / cherry-pick by inspecting
    /// .git marker files. Returns nil when the worktree is idle.
    func mergeState(worktreePath: URL) async throws -> MergeOperation? {
        let gitDir = try await self.gitDir(worktreePath: worktreePath)

        // Rebase first — both `MERGE_HEAD` and `rebase-merge` can coexist
        // briefly during a `rebase -m`. Rebase is the more specific signal.
        let rebaseMergeDir = gitDir.appendingPathComponent("rebase-merge")
        if FileManager.default.fileExists(atPath: rebaseMergeDir.path) {
            let plan = try await Self.readRebasePlan(
                gitDir: gitDir,
                rebaseMergeDir: rebaseMergeDir,
                worktreePath: worktreePath
            )
            return .rebase(plan: plan)
        }

        // .git/rebase-apply is also used by `git am`, which writes an
        // `applying` sentinel instead of `rebasing`. Treat only the
        // rebase-shaped case as an in-progress rebase; an `am` conflict is
        // out of scope for this UI (driving `rebase --continue` against an
        // am state would error).
        let rebaseApplyDir = gitDir.appendingPathComponent("rebase-apply")
        let rebasingSentinel = rebaseApplyDir.appendingPathComponent("rebasing")
        if FileManager.default.fileExists(atPath: rebaseApplyDir.path),
           FileManager.default.fileExists(atPath: rebasingSentinel.path) {
            let plan = try await Self.readRebaseApplyPlan(rebaseApplyDir: rebaseApplyDir)
            return .rebase(plan: plan)
        }

        let cherryHead = gitDir.appendingPathComponent("CHERRY_PICK_HEAD")
        if FileManager.default.fileExists(atPath: cherryHead.path) {
            let sha = (try? String(contentsOf: cherryHead, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = (try? await Process.git(
                ["log", "-1", "--pretty=%s", sha],
                cwd: worktreePath
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? sha
            return .cherryPick(sha: sha, summary: summary)
        }

        let mergeHead = gitDir.appendingPathComponent("MERGE_HEAD")
        if FileManager.default.fileExists(atPath: mergeHead.path) {
            // Try to read MERGE_MSG for the source-branch name (`merge branch 'X'`).
            let mergeMsg = gitDir.appendingPathComponent("MERGE_MSG")
            let msg = (try? String(contentsOf: mergeMsg, encoding: .utf8)) ?? ""
            let source = Self.parseMergeMsgBranch(msg)
            return .merge(sourceBranch: source)
        }
        return nil
    }

    /// Resolves the absolute `.git` directory for the given worktree
    /// (handles linked worktrees, where `.git` is a file pointing into a
    /// subdir of the main repo).
    private func gitDir(worktreePath: URL) async throws -> URL {
        let result = try await Process.git(
            ["rev-parse", "--absolute-git-dir"],
            cwd: worktreePath
        )
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !raw.isEmpty else {
            throw OperationError.gitFailed(command: "rev-parse --absolute-git-dir", stderr: result.stderr)
        }
        return URL(fileURLWithPath: raw)
    }

    /// MERGE_MSG looks like:
    ///   Merge branch 'feature/x'
    /// or:
    ///   Merge branch 'feature/x' into main
    /// We only need the first quoted token.
    static func parseMergeMsgBranch(_ msg: String) -> String? {
        guard let openQuote = msg.firstIndex(of: "'") else { return nil }
        let after = msg.index(after: openQuote)
        guard let closeQuote = msg[after...].firstIndex(of: "'") else { return nil }
        return String(msg[after ..< closeQuote])
    }

    /// Reads `rebase-merge/git-rebase-todo` (pending) plus `done` (already
    /// applied) and `msgnum`/`end` (1-indexed current commit) to build a
    /// RebasePlan with `done` / `current` / `pending` state per commit.
    private static func readRebasePlan(
        gitDir: URL,
        rebaseMergeDir: URL,
        worktreePath: URL
    ) async throws -> RebasePlan {
        func read(_ name: String) -> String? {
            try? String(
                contentsOf: rebaseMergeDir.appendingPathComponent(name),
                encoding: .utf8
            )
        }
        let todo = read("git-rebase-todo") ?? ""
        let done = read("done") ?? ""
        let ontoRef = read("onto")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headName = read("head-name")?.trimmingCharacters(in: .whitespacesAndNewlines)

        func parseLines(_ raw: String) -> [(String, String)] {
            // Lines look like: "pick abcd123 commit subject"
            raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { l in
                let line = l.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                let parts = line.split(
                    separator: " ",
                    maxSplits: 2,
                    omittingEmptySubsequences: true
                )
                guard parts.count >= 3 else { return nil }
                return (String(parts[1]), String(parts[2]))
            }
        }

        let doneCommits = parseLines(done)
        let todoCommits = parseLines(todo)

        // `done` includes the *currently-conflicting* commit as its last
        // entry. Mark it as .current; everything before is .done; todo is .pending.
        var commits: [RebasePlanCommit] = []
        if doneCommits.count >= 1 {
            for (sha, summary) in doneCommits.dropLast() {
                commits.append(RebasePlanCommit(sha: sha, summary: summary, state: .done))
            }
            let last = doneCommits.last!
            commits.append(RebasePlanCommit(sha: last.0, summary: last.1, state: .current))
        }
        for (sha, summary) in todoCommits {
            commits.append(RebasePlanCommit(sha: sha, summary: summary, state: .pending))
        }

        let onto = ontoRef
        let source = headName.flatMap { ref -> String in
            ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }

        return RebasePlan(ontoBranch: onto, sourceBranch: source, commits: commits)
    }

    /// Builds a RebasePlan from a `.git/rebase-apply` directory (apply-backend rebase).
    /// Layout: `next` (current 1-based index), `last` (total), `0001`..`NNNN` (patch files),
    /// `head-name` (source branch ref), `onto` (target SHA).
    private static func readRebaseApplyPlan(rebaseApplyDir: URL) async throws -> RebasePlan {
        func readFile(_ name: String) -> String? {
            try? String(
                contentsOf: rebaseApplyDir.appendingPathComponent(name),
                encoding: .utf8
            )
        }

        let nextInt = readFile("next").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let lastInt = readFile("last").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let ontoRef = readFile("onto")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headName = readFile("head-name")?.trimmingCharacters(in: .whitespacesAndNewlines)

        let source = headName.flatMap { ref -> String in
            ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }

        var commits: [RebasePlanCommit] = []
        // Guard the range: a missing or unparsable `last` would make
        // `1...lastInt` trap (Range requires lowerBound <= upperBound).
        // Return an empty plan in that case so the OperationCard still
        // surfaces with Continue/Abort, just without a per-commit list.
        guard lastInt >= 1 else {
            return RebasePlan(ontoBranch: ontoRef, sourceBranch: source, commits: [])
        }
        for i in 1...lastInt {
            let patchName = String(format: "%04d", i)
            var summary = "commit \(i)"
            if let patchContent = readFile(patchName) {
                for line in patchContent.split(separator: "\n", omittingEmptySubsequences: false) {
                    let lineStr = String(line)
                    if lineStr.hasPrefix("Subject: ") {
                        summary = String(lineStr.dropFirst("Subject: ".count)).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
            let state: RebasePlanCommit.State
            if i < nextInt {
                state = .done
            } else if i == nextInt {
                state = .current
            } else {
                state = .pending
            }
            commits.append(RebasePlanCommit(sha: "patch-\(i)", summary: summary, state: state))
        }

        return RebasePlan(ontoBranch: ontoRef, sourceBranch: source, commits: commits)
    }
}

extension GitService {
    /// Reads BASE / LOCAL / REMOTE for a conflicted file from index stages.
    /// Stage indexes: 1 = common ancestor (base), 2 = ours (HEAD), 3 = theirs (incoming).
    /// Returns nil for sides that don't exist (e.g., `bothAdded` has no base).
    func conflictedFile(worktreePath: URL, relativePath: String) async throws -> ConflictedFile {
        // Determine the conflict kind from current status (cheaper than
        // calling status() and filtering — but this is what status() does
        // anyway, so we just reuse it).
        let allChanges = try await status(worktreePath: worktreePath)
        guard let entry = allChanges.first(where: {
            $0.path == relativePath && $0.conflict != nil
        }), let kind = entry.conflict else {
            throw ConflictedFileError.notConflicted(path: relativePath)
        }

        let base = try await readStageOrNil(worktreePath: worktreePath, stage: 1, path: relativePath)
        let local = try await readStageOrNil(worktreePath: worktreePath, stage: 2, path: relativePath)
        let remote = try await readStageOrNil(worktreePath: worktreePath, stage: 3, path: relativePath)

        let absolute = worktreePath.appendingPathComponent(relativePath)
        let mergedData = (try? Data(contentsOf: absolute)) ?? Data()
        let isBinary = Self.looksBinary(mergedData)
        let merged = isBinary ? "" : (String(data: mergedData, encoding: .utf8) ?? "")

        return ConflictedFile(
            relativePath: relativePath,
            kind: kind,
            base: base,
            local: local,
            remote: remote,
            merged: merged,
            isBinary: isBinary
        )
    }

    /// `git show :N:path` returns the blob at index stage N. Returns nil
    /// when the stage doesn't exist (git exits non-zero in that case).
    private func readStageOrNil(worktreePath: URL, stage: Int, path: String) async throws -> String? {
        let result = try await Process.git(
            ["show", ":\(stage):\(path)"],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else { return nil }
        return result.stdout
    }

    /// Same heuristic git uses: a NUL byte in the first 8KB → binary.
    static func looksBinary(_ data: Data) -> Bool {
        let probe = data.prefix(8192)
        return probe.contains(0x00)
    }
}

extension GitService {
    /// Runs `git merge <branch>` with the zdiff3 conflict style so the
    /// on-disk merged file includes the BASE section inline. Returns:
    ///   - .clean   on a fast-forward or no-conflict merge
    ///   - .conflict(files)   when the working tree is left in conflict
    ///   - .error(message)    for any other non-zero exit
    func merge(worktreePath: URL, branch: String) async throws -> MergeResult {
        let result = try await Process.git(
            ["-c", "merge.conflictStyle=zdiff3", "merge", branch, "--no-edit"],
            cwd: worktreePath
        )
        return try await classifyOperationResult(
            worktreePath: worktreePath,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    /// After running any conflict-producing operation, check the worktree
    /// state and classify. Used by merge, rebase, cherry-pick, continue.
    func classifyOperationResult(worktreePath: URL, exitCode: Int32, stderr: String) async throws -> MergeResult {
        if exitCode == 0 {
            return .clean
        }
        let changes = try await status(worktreePath: worktreePath)
        let conflicted = changes.filter { $0.conflict != nil }
        if !conflicted.isEmpty {
            return .conflict(files: conflicted)
        }
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .error(message: msg.isEmpty ? "Operation failed with exit code \(exitCode)" : msg)
    }
}

extension GitService {
    func rebase(worktreePath: URL, onto: String) async throws -> MergeResult {
        let result = try await Process.git(
            ["-c", "merge.conflictStyle=zdiff3", "rebase", onto],
            cwd: worktreePath
        )
        return try await classifyOperationResult(
            worktreePath: worktreePath,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    func cherryPick(worktreePath: URL, sha: String) async throws -> MergeResult {
        let parents = try await parentCount(worktreePath: worktreePath, sha: sha)
        var args: [String] = ["-c", "merge.conflictStyle=zdiff3", "cherry-pick"]
        if parents >= 2 {
            // Merge commit: pick changes relative to the first parent (mainline).
            // Selecting a different mainline is a follow-up if needed.
            args.append(contentsOf: ["-m", "1"])
        }
        args.append(sha)
        let result = try await Process.git(args, cwd: worktreePath)
        return try await classifyOperationResult(
            worktreePath: worktreePath,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    /// Number of parent commits for `sha`. Returns 1 for a normal commit, 2+ for a merge.
    private func parentCount(worktreePath: URL, sha: String) async throws -> Int {
        let result = try await Process.git(
            ["rev-list", "--parents", "-n", "1", sha],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else { return 1 }  // be lenient — let cherry-pick surface the real error
        // Output: "<sha> <parent1> <parent2> ..."
        let parts = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        // parents = parts.count - 1 (the first token is the commit itself)
        return max(parts.count - 1, 0)
    }
}

extension GitService {
    /// Resolves a delete-side conflict by removing the file from worktree + index.
    /// Used for `bothDeleted` / `deletedByUs` / `deletedByThem` resolutions
    /// where "keep it deleted" is the user's intent.
    func keepDeleted(worktreePath: URL, relativePath: String) async throws {
        let result = try await Process.git(["rm", "--", relativePath], cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw OperationError.gitFailed(command: "rm", stderr: result.stderr)
        }
    }
}

enum ConflictedFileError: LocalizedError {
    case notConflicted(path: String)

    var errorDescription: String? {
        switch self {
        case .notConflicted(let path):
            return "File '\(path)' is not in a conflicted state."
        }
    }
}

extension GitService {
    /// Resolves a conflict by accepting LOCAL/HEAD content (`git checkout --ours <path>`).
    /// Caller is responsible for staging via `markResolved` afterwards.
    func useOurs(worktreePath: URL, relativePath: String) async throws {
        let result = try await Process.git(
            ["checkout", "--ours", "--", relativePath],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else {
            throw OperationError.gitFailed(command: "checkout --ours", stderr: result.stderr)
        }
    }

    /// Resolves a conflict by accepting REMOTE/incoming content (`git checkout --theirs <path>`).
    func useTheirs(worktreePath: URL, relativePath: String) async throws {
        let result = try await Process.git(
            ["checkout", "--theirs", "--", relativePath],
            cwd: worktreePath
        )
        guard result.exitCode == 0 else {
            throw OperationError.gitFailed(command: "checkout --theirs", stderr: result.stderr)
        }
    }

    /// Stages a file (`git add <path>`). Used after the user marks a
    /// conflict resolution complete.
    func markResolved(worktreePath: URL, relativePath: String) async throws {
        let result = try await Process.git(["add", "--", relativePath], cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw OperationError.gitFailed(
                command: "add",
                stderr: result.stderr
            )
        }
    }

    /// `git merge --continue` / `git rebase --continue` / `git cherry-pick --continue`,
    /// chosen by the operation kind. Returns the same MergeResult shape as
    /// the initiating call — a rebase Continue may produce a new conflict
    /// on the next commit.
    func continueOperation(worktreePath: URL, op: MergeOperation) async throws -> MergeResult {
        let subcommand: String
        switch op {
        case .merge:      subcommand = "merge"
        case .rebase:     subcommand = "rebase"
        case .cherryPick: subcommand = "cherry-pick"
        }
        let result = try await Process.git(
            ["-c", "merge.conflictStyle=zdiff3", "-c", "core.editor=true", subcommand, "--continue"],
            cwd: worktreePath
        )
        return try await classifyOperationResult(
            worktreePath: worktreePath,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    /// `git <op> --abort`. Restores the worktree and clears in-progress state.
    func abortOperation(worktreePath: URL, op: MergeOperation) async throws {
        let subcommand: String
        switch op {
        case .merge:      subcommand = "merge"
        case .rebase:     subcommand = "rebase"
        case .cherryPick: subcommand = "cherry-pick"
        }
        let result = try await Process.git([subcommand, "--abort"], cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw OperationError.gitFailed(command: "\(subcommand) --abort", stderr: result.stderr)
        }
    }

    /// `git rebase --skip` / `git cherry-pick --skip`. Throws for `.merge`
    /// (merge has no --skip).
    func skipOperation(worktreePath: URL, op: MergeOperation) async throws -> MergeResult {
        let subcommand: String
        switch op {
        case .rebase:     subcommand = "rebase"
        case .cherryPick: subcommand = "cherry-pick"
        case .merge:      throw OperationError.skipNotSupported
        }
        let result = try await Process.git(
            ["-c", "merge.conflictStyle=zdiff3", "-c", "core.editor=true", subcommand, "--skip"],
            cwd: worktreePath
        )
        return try await classifyOperationResult(
            worktreePath: worktreePath,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }
}

enum OperationError: LocalizedError {
    case gitFailed(command: String, stderr: String)
    case skipNotSupported

    var errorDescription: String? {
        switch self {
        case .gitFailed(let cmd, let stderr):
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "git \(cmd) failed" : msg
        case .skipNotSupported:
            return "Skip is not supported for a merge."
        }
    }
}
