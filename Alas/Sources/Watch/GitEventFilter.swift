import Foundation

/// Classification of a single FSEvents path against a project's resolved
/// `.git` directory. Used by `ProjectGitWatcher` to dispatch fast-path HEAD
/// updates vs slow-path topology refreshes, and by `WorktreeWatcher` to
/// share the lockfile rule.
enum GitEventCategory: Equatable {
    case ignored                  // *.lock under .git/ — mid-write, never react
    case headChange(URL)          // worktree root whose HEAD just changed
    case topologyChange           // .git/worktrees/ contents changed
    case other                    // unrelated event, caller decides
}

enum GitEventFilter {
    /// Classify a single FSEvents path against `gitDir` (an absolute path to
    /// the repo's `.git` directory). For linked worktrees the worktree root
    /// is resolved by reading `.git/worktrees/<name>/gitdir`, which contains
    /// the absolute path to the worktree's `.git` link file.
    static func classify(eventPath: String, gitDir: URL) -> GitEventCategory {
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
            let repoRoot = URL(fileURLWithPath: gitDir.deletingLastPathComponent().path)
            return .headChange(repoRoot.standardizedFileURL)
        }

        if rel.hasPrefix("worktrees/") == false {
            if rel == "worktrees" { return .topologyChange }
            return .other
        }

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
        return .other
    }
}
