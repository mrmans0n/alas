import Foundation

/// Pure gating logic for the stacked-diffs integration. UI renders only
/// when every gate passes: master toggle → gg installed → per-project
/// mode → the current branch is actually stack-shaped.
enum GGStackGate {
    /// Gate 3 (auto mode): the repo's common git dir carries gg config.
    /// `repoPath` is a project's checkout path, which is not guaranteed to
    /// be the primary one — a project can be added from a linked worktree,
    /// where `.git` is a file (`gitdir: <path>`) rather than a directory.
    /// gg itself stores config at `<commondir>/gg/config.json` (mirrors
    /// `repo.commondir()` in gg's own source), so resolve the same way
    /// instead of assuming `<repoPath>/.git` is the config's home.
    static func repoHasGGConfig(repoPath: String) -> Bool {
        guard let commonGitDir = commonGitDir(repoPath: repoPath) else { return false }
        let path = (commonGitDir as NSString).appendingPathComponent("gg/config.json")
        return FileManager.default.fileExists(atPath: path)
    }

    /// Resolves the shared git directory for `repoPath`: itself when `.git`
    /// is a real directory (primary checkout), or — for a linked worktree,
    /// where `.git` is a file pointing at a private per-worktree dir under
    /// `<commondir>/worktrees/<name>` — the directory named by that private
    /// dir's `commondir` file.
    private static func commonGitDir(repoPath: String) -> String? {
        let dotGitPath = (repoPath as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGitPath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return dotGitPath
        }
        guard let contents = try? String(contentsOfFile: dotGitPath, encoding: .utf8),
              let gitdirLine = contents.split(whereSeparator: \.isNewline)
                  .first(where: { $0.hasPrefix("gitdir:") })
        else {
            return nil
        }
        let rawPath = gitdirLine.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let privateGitDir = resolvedPath(rawPath, relativeTo: repoPath)
        let commondirFile = (privateGitDir as NSString).appendingPathComponent("commondir")
        guard let commondirContents = try? String(contentsOfFile: commondirFile, encoding: .utf8) else {
            return privateGitDir
        }
        let relativeCommonDir = commondirContents.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolvedPath(relativeCommonDir, relativeTo: privateGitDir)
    }

    private static func resolvedPath(_ path: String, relativeTo base: String) -> String {
        let ns = path as NSString
        let absolute = ns.isAbsolutePath ? ns as String : (base as NSString).appendingPathComponent(path)
        return (absolute as NSString).standardizingPath
    }

    /// Gates 1–3 combined for a project.
    static func projectEnabled(
        masterEnabled: Bool,
        ggInstalled: Bool,
        mode: GGProjectMode,
        repoPath: String
    ) -> Bool {
        guard masterEnabled, ggInstalled else { return false }
        switch mode {
        case .off: return false
        case .on: return true
        case .auto: return repoHasGGConfig(repoPath: repoPath)
        }
    }

    /// Gate 4: any commit ahead of base carries a `GG-ID:` trailer line.
    /// Pure check over already-loaded commit bodies — no extra git call.
    static func isStackShaped(commits: [CommitInfo]) -> Bool {
        commits.contains { commit in
            commit.body.split(whereSeparator: \.isNewline).contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("GG-ID:")
            }
        }
    }
}
