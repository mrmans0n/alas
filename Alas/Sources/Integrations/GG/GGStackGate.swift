import Foundation

enum GGCommitMetadata {
    static func ggID(in body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("GG-ID:") else { continue }

            let value = trimmedLine.dropFirst("GG-ID:".count)
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// Pure gating logic for the stacked-diffs integration. UI renders only
/// when every gate passes: master toggle → gg installed → per-project
/// mode → the current branch is actually stack-shaped.
enum GGStackGate {
    private static let alasOperationMarkerName = "alas-gg-operation"

    /// Gate 3 (auto mode): the repo's common git dir carries gg config.
    /// `repoPath` is a project's checkout path, which is not guaranteed to
    /// be the primary one — a project can be added from a linked worktree,
    /// where `.git` is a file (`gitdir: <path>`) rather than a directory.
    /// gg itself stores config at `<commondir>/gg/config.json` (mirrors
    /// `repo.commondir()` in gg's own source), so resolve the same way
    /// instead of assuming `<repoPath>/.git` is the config's home.
    static func repoHasGGConfig(repoPath: String) -> Bool {
        guard let path = ggConfigPath(repoPath: repoPath) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Path to the repo's gg config file (`<commondir>/gg/config.json`),
    /// or nil when the repo path doesn't resolve to a git checkout.
    static func ggConfigPath(repoPath: String) -> String? {
        guard let commonGitDir = commonGitDir(repoPath: repoPath) else { return nil }
        return (commonGitDir as NSString).appendingPathComponent("gg/config.json")
    }

    /// True when a git rebase/merge/cherry-pick/revert is in progress in the
    /// worktree — i.e. a gg mutation paused on a conflict. The drawer's
    /// Continue/Abort presentation is driven by this cheap filesystem probe;
    /// `gg ls --json` separately supplies the exact operation ID used for
    /// post-Continue Undo correlation.
    /// Uses `worktreeGitDir`, not `commonGitDir`: these markers are written
    /// to the private per-worktree git dir, not the dir shared across
    /// worktrees.
    static func operationInProgress(repoPath: String) -> Bool {
        guard let gitDir = worktreeGitDir(repoPath: repoPath) else { return false }
        let markers = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        return markers.contains {
            FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent($0))
        }
    }

    static func alasGGOperationInProgress(repoPath: String) -> Bool {
        guard let markerPath = alasGGOperationMarkerPath(repoPath: repoPath) else { return false }
        return FileManager.default.fileExists(atPath: markerPath)
    }

    static func markAlasGGOperationInProgress(repoPath: String) {
        guard let markerPath = alasGGOperationMarkerPath(repoPath: repoPath) else { return }
        FileManager.default.createFile(atPath: markerPath, contents: Data())
    }

    static func clearAlasGGOperationInProgress(repoPath: String) {
        guard let markerPath = alasGGOperationMarkerPath(repoPath: repoPath) else { return }
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    /// Resolves the shared git directory for `repoPath`: itself when `.git`
    /// is a real directory (primary checkout), or — for a linked worktree,
    /// where `.git` is a file pointing at a private per-worktree dir under
    /// `<commondir>/worktrees/<name>` — the directory named by that private
    /// dir's `commondir` file.
    private static func commonGitDir(repoPath: String) -> String? {
        guard let gitDir = worktreeGitDir(repoPath: repoPath) else { return nil }
        let commondirFile = (gitDir as NSString).appendingPathComponent("commondir")
        guard let commondirContents = try? String(contentsOfFile: commondirFile, encoding: .utf8) else {
            return gitDir
        }
        let relativeCommonDir = commondirContents.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolvedPath(relativeCommonDir, relativeTo: gitDir)
    }

    /// Resolves the *private*, per-checkout git directory for `repoPath`:
    /// itself when `.git` is a real directory (primary checkout — there is
    /// no separate private dir; the checkout's own `.git` holds all local
    /// state), or — for a linked worktree — the directory named by the
    /// `.git` file's `gitdir:` line, *without* following it on to the
    /// shared `commondir`. This is where git actually writes per-worktree
    /// state such as a paused `rebase-merge`, unlike `commonGitDir`, which
    /// resolves through to the dir shared across all worktrees.
    private static func worktreeGitDir(repoPath: String) -> String? {
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
        return resolvedPath(rawPath, relativeTo: repoPath)
    }

    private static func alasGGOperationMarkerPath(repoPath: String) -> String? {
        worktreeGitDir(repoPath: repoPath).map {
            ($0 as NSString).appendingPathComponent(alasOperationMarkerName)
        }
    }

    private static func resolvedPath(_ path: String, relativeTo base: String) -> String {
        let ns = path as NSString
        let absolute = ns.isAbsolutePath ? ns as String : (base as NSString).appendingPathComponent(path)
        return (absolute as NSString).standardizingPath
    }

    /// Gates 1–3 combined for a project.
    /// - Parameter isRemoteProject: true when the project is a registered
    ///   SSH destination rather than a local checkout. gg's runner is
    ///   local-only (`/usr/bin/env gg`), unlike git's own process wrapper,
    ///   which rewrites invocations to SSH for registered remote hosts —
    ///   running gg against a remote path either fails repeatedly or, if
    ///   the same path coincidentally exists locally too, reads an
    ///   unrelated repo. Fail closed regardless of mode.
    static func projectEnabled(
        masterEnabled: Bool,
        ggInstalled: Bool,
        mode: GGProjectMode,
        repoPath: String,
        isRemoteProject: Bool
    ) -> Bool {
        guard masterEnabled, ggInstalled, !isRemoteProject else { return false }
        switch mode {
        case .off: return false
        case .on: return true
        case .auto: return repoHasGGConfig(repoPath: repoPath)
        }
    }

    /// Gate 4: any commit ahead of base carries a `GG-ID:` trailer line.
    /// Pure check over already-loaded commit bodies — no extra git call.
    static func isStackShaped(commits: [CommitInfo]) -> Bool {
        commits.contains { GGCommitMetadata.ggID(in: $0.body) != nil }
    }
}
