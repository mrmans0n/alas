import Foundation

/// Classification of a single FSEvents path against a project's resolved
/// `.git` directory. Used by `ProjectGitWatcher` to dispatch fast-path HEAD
/// updates vs slow-path topology refreshes, and by `WorktreeWatcher` to
/// share the lockfile rule.
enum GitEventCategory: Equatable {
    case ignored                  // *.lock under .git/ — mid-write, never react
    case headChange(URL)          // worktree root whose HEAD just changed
    case revisionChange           // shared refs moved; tracked revisions may resolve differently
    case revisionAndTopologyChange
    case topologyChange           // .git/worktrees/ contents changed
    case other                    // unrelated event, caller decides
}

enum GitEventFilter {
    /// Classify a single FSEvents path against `gitDir` (an absolute path to
    /// the repo's `.git` directory). For linked worktrees the worktree root
    /// is resolved by reading `.git/worktrees/<name>/gitdir`, which contains
    /// the absolute path to the worktree's `.git` link file.
    ///
    /// `worktreeRoot` is used only for the main-worktree HEAD case (`gitDir/HEAD`).
    /// For projects whose `.git` is a gitfile (submodules, separate-git-dir),
    /// `gitDir` lives outside the worktree, so we cannot infer the worktree
    /// root from `gitDir.deletingLastPathComponent()` — caller must resolve it
    /// via `git rev-parse --show-toplevel` and pass it explicitly.
    static func classify(eventPath: String, gitDir: URL, worktreeRoot: URL) -> GitEventCategory {
        let gitDirPath = gitDir.standardizedFileURL.path
        let prefix = gitDirPath.hasSuffix("/") ? gitDirPath : gitDirPath + "/"
        guard eventPath == gitDirPath || eventPath.hasPrefix(prefix) else {
            return .other
        }

        if eventPath.hasSuffix(".lock") { return .ignored }

        let rel: String
        if eventPath == gitDirPath {
            rel = ""
        } else {
            rel = String(eventPath.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        if rel == "HEAD" {
            return .headChange(worktreeRoot.standardizedFileURL)
        }

        if rel.hasPrefix("worktrees/") {
            let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.count == 2 { return .topologyChange }
            if parts.count == 3 && parts[2] == "HEAD" {
                let name = parts[1]
                let gitdirFile = gitDir
                    .appendingPathComponent("worktrees")
                    .appendingPathComponent(name)
                    .appendingPathComponent("gitdir")
                guard let contents = try? String(contentsOf: gitdirFile, encoding: .utf8) else {
                    return .other
                }
                let gitlink = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                let worktreeRoot = URL(fileURLWithPath: gitlink).deletingLastPathComponent()
                return .headChange(worktreeRoot.standardizedFileURL)
            }
            if parts.count == 3 && Self.revisionPseudoRefs.contains(parts[2]) {
                return .revisionChange
            }
            return .other
        }

        if rel == "worktrees" { return .topologyChange }

        if rel == "packed-refs" {
            return .revisionChange
        }
        if rel == "config" {
            return .revisionChange
        }
        if Self.revisionPseudoRefs.contains(rel) {
            return .revisionChange
        }
        if rel.hasPrefix("refs/heads/") {
            return .revisionAndTopologyChange
        }
        if rel.hasPrefix("refs/") {
            return .revisionChange
        }

        return .other
    }

    private static let revisionPseudoRefs: Set<String> = [
        "AUTO_MERGE",
        "CHERRY_PICK_HEAD",
        "FETCH_HEAD",
        "MERGE_HEAD",
        "ORIG_HEAD",
        "REBASE_HEAD",
        "REVERT_HEAD",
    ]
}
